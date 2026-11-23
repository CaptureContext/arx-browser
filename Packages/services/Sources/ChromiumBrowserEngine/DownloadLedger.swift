import BrowserCore
import BrowserDownloadsClient
import Foundation

/// Reconciles persisted presentation metadata with Chromium's authoritative startup enumeration.
internal struct DownloadLedger {
	/// Finished transfers kept in history; older ones are dropped when the ledger is saved.
	internal static let finishedRecordLimit: Int = 500

	private var seen: [Profile.ID: Set<BrowserDownload.ID>]

	/// Profiles whose native history finished loading this session (Chromium enumerated their
	/// downloads; DEV-880, DEV-892), and the current profiles.
	private var initializedProfiles: Set<Profile.ID>
	private var profileIDs: Set<Profile.ID>?

	/// Transfers removed from the list this session. A notification already on its way doesn't
	/// bring one back (DEV-892).
	private var removed: Set<BrowserDownload.ID>

	/// DEV-880. The saved history couldn't be read, so only Chromium knows each profile's downloads.
	private var recoversFromChromium: Bool
	private let file: URL
	private var saved: Data?

	/// Newest first. Progress ticks don't change it, so it is rebuilt only when records are added,
	/// removed, or restarted.
	private var order: [BrowserDownload.ID]
	internal private(set) var records: [BrowserDownload.ID: BrowserDownload]
	internal private(set) var message: String?

	internal init(file: URL) {
		self.seen = [:]
		self.initializedProfiles = []
		self.profileIDs = nil
		self.removed = []
		self.recoversFromChromium = false
		self.file = file
		self.saved = nil
		self.order = []
		self.records = [:]
		self.message = nil

		do {
			guard FileManager.default.fileExists(atPath: file.path)
			else { return }

			let data = try Data(contentsOf: file)
			let archive = try JSONDecoder().decode(Archive.self, from: data)

			guard archive.version == 1
			else { throw CocoaError(.coderReadCorrupt) }

			for var record in archive.records where !record.isPrivate {
				// Until native initialization, persisted active records are pending reconciliation.
				if record.status == .complete {
					record.isMissing = Self.missing(record.target)
				}

				records[record.id] = record
			}

			reorder()
			saved = data
		} catch {
			message = "Saved download history could not be read. Chromium will restore available downloads."
			recoversFromChromium = true
		}
	}

	internal var snapshot: DownloadQueue {
		let values = order.compactMap { records[$0] }
		return .init(downloads: values, privateDownloads: values, message: message)
	}

	private mutating func reorder() {
		order = records.values
			.sorted { $0.startedAt > $1.startedAt }
			.map(\.id)
	}

	/// DEV-880. Among `profiles`, those only loading can reconcile: Chromium then enumerates
	/// their downloads, resuming or interrupting each, and `initialized` settles the rest. One
	/// has a persisted transfer still in progress that Chromium hasn't reported this session;
	/// or, when the saved history couldn't be read, Chromium hasn't enumerated it yet.
	internal func pendingReconciliation(among profiles: Set<Profile.ID>) -> Set<Profile.ID> {
		var pending = Set(
			records.values
				.filter { record in
					!record.isPrivate
						&& record.status == .inProgress
						&& !seen[record.id.profileID, default: []].contains(record.id)
				}
				.map(\.id.profileID)
		)
		if recoversFromChromium { pending.formUnion(profiles.subtracting(initializedProfiles)) }
		return pending.intersection(profiles)
	}

	/// Chromium has no such transfer, and won't bring it back: its profile's history loaded without
	/// it, or the profile is gone (DEV-892).
	internal func isKnownAbsentNatively(_ id: BrowserDownload.ID) -> Bool {
		if let profileIDs, !profileIDs.contains(id.profileID) { return true }
		return initializedProfiles.contains(id.profileID) && !seen[id.profileID, default: []].contains(id)
	}

	/// Moves the records of profiles merged into others (DEV-1216) to the kept profile: its storage
	/// is the merged one's here, so Chromium reports their transfers under it now.
	internal mutating func reassign(_ profiles: [Profile.ID: Profile.ID]) {
		guard !profiles.isEmpty else { return }

		func moved(_ id: BrowserDownload.ID) -> BrowserDownload.ID {
			profiles[id.profileID].map { BrowserDownload.ID(profileID: $0, guid: id.guid) } ?? id
		}

		var changed: Bool = false
		for id in Array(records.keys) {
			let new: BrowserDownload.ID = moved(id)
			guard new != id, records[new] == nil, var record = records.removeValue(forKey: id) else { continue }

			record.id = new
			records[new] = record
			changed = true
		}
		guard changed else { return }

		order = order.map(moved)
		removed = Set(removed.map(moved))
		for (merged, kept) in profiles {
			if let ids = seen.removeValue(forKey: merged) {
				seen[kept, default: []].formUnion(ids.map(moved))
			}
			if initializedProfiles.remove(merged) != nil {
				initializedProfiles.insert(kept)
			}
		}
		persist()
	}

	internal mutating func configure(profileIDs: Set<Profile.ID>) {
		self.profileIDs = profileIDs

		// A profile can disappear while native initialization is pending. Reconcile
		// only records never observed this session; live and private queues keep ownership.
		for id in records.keys where !profileIDs.contains(id.profileID) {
			guard
				let record = records[id],
				!record.isPrivate,
				record.status == .inProgress,
				!seen[id.profileID, default: []].contains(id)
			else { continue }

			records[id]?.status = .interrupted
			records[id]?.interruptReason = 0
		}

		persist()
	}

	internal mutating func receive(_ value: BrowserDownload) {
		guard !removed.contains(value.id) else { return }

		var value = value
		let previous = records[value.id]

		if let previous {
			value.profileName = previous.profileName
			value.spaceName = previous.spaceName ?? value.spaceName

			// The page that started it may close before it finishes (DEV-1116).
			value.sourceTabID = value.sourceTabID ?? previous.sourceTabID
		}

		// Checking the file system once per completion is enough; later events reuse the result.
		if value.status == .complete {
			let wasComplete = previous?.status == .complete
			value.isMissing = value.isMissing
			|| (wasComplete ? previous?.isMissing == true : Self.missing(value.target))
		}

		records[value.id] = value
		if previous?.startedAt != value.startedAt { reorder() }
		seen[value.id.profileID, default: []].insert(value.id)

		// Byte progress is not persisted, so a progress-only event needs no encoding.
		let needsPersisting = previous.map(Self.persisted) != Self.persisted(value)
		if needsPersisting { persist() }
	}

	internal mutating func initialized(profileID: Profile.ID) {
		initializedProfiles.insert(profileID)
		for id in records.keys where
			id.profileID == profileID
			&& !seen[profileID, default: []].contains(id)
		{
			guard records[id]?.status == .inProgress
			else { continue }

			records[id]?.status = .interrupted
			records[id]?.interruptReason = 0
		}

		persist()
	}

	/// Forgets these transfers if they're still finished and not private. Their files
	/// stay. Clear Browsing Data picks them before the engine clears Chromium's own
	/// records, so a transfer that finishes meanwhile, which Chromium keeps, stays
	/// here too. Throws when the list couldn't be saved.
	internal mutating func removeFinished(_ ids: Set<BrowserDownload.ID>) throws -> Int {
		let removed = ids.filter { id in
			guard let record = records[id] else { return false }
			return !record.isPrivate && record.status != .inProgress
		}
		guard !removed.isEmpty else { return 0 }

		var restore: [BrowserDownload] = []
		for id in removed {
			if let record = records.removeValue(forKey: id) { restore.append(record) }
		}
		reorder()
		guard persist() else {
			// Unsaved, they'd come back at launch; keep them listed so a later clear retries.
			for record in restore {
				records[record.id] = record
			}
			reorder()
			throw BrowserDownloadsClient.Failure.unavailable
		}
		self.removed.formUnion(removed)
		return removed.count
	}

	/// The file went away through Arx, such as Move to Trash.
	internal mutating func markMissing(_ id: BrowserDownload.ID) {
		guard records[id] != nil else { return }
		records[id]?.isMissing = true
		persist()
	}

	internal mutating func fileForOpening(_ id: BrowserDownload.ID) throws -> URL {
		guard let record = records[id]
		else { throw BrowserDownloadsClient.Failure.missingDownload }
		guard
			record.status == .complete,
			!record.isDangerous,
			let target = record.target,
			target.isFileURL
		else { throw BrowserDownloadsClient.Failure.notOpenable }

		if Self.missing(target) {
			records[id]?.isMissing = true
			persist()
			throw BrowserDownloadsClient.Failure.fileMissing
		}

		records[id]?.isMissing = false
		return target
	}

	/// The stored form: lifecycle and origin changes, not every progress tick.
	private static func persisted(_ record: BrowserDownload) -> BrowserDownload {
		var record = record
		if record.status == .inProgress { record.receivedBytes = 0 }
		record.sourceTabID = nil
		return record
	}

	private mutating func trimFinishedRecords() {
		let finished = records.values
			.filter { $0.status != .inProgress }
			.sorted { $0.startedAt > $1.startedAt }
		guard finished.count > Self.finishedRecordLimit else { return }

		for record in finished.dropFirst(Self.finishedRecordLimit) {
			records[record.id] = nil
		}
		reorder()
	}

	@discardableResult
	private mutating func persist() -> Bool {
		trimFinishedRecords()
		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys]
			let records = records.values
				.filter { !$0.isPrivate }
				.map(Self.persisted)
				.sorted { $0.id.guid < $1.id.guid }
			let data = try encoder.encode(Archive(version: 1, records: records))

			guard saved != data else { return true }

			try FileManager.default.createDirectory(
				at: file.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			try data.write(to: file, options: .atomic)
			saved = data
			return true
		} catch {
			message = "Download history could not be saved. Transfers continue; history may be incomplete after restarting."
			return false
		}
	}

	private static func missing(_ url: URL?) -> Bool {
		guard let url, url.isFileURL else { return true }

		var isDirectory: ObjCBool = false
		return !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
		|| isDirectory.boolValue
	}

	private struct Archive: Codable {
		internal var version: Int
		internal var records: [BrowserDownload]

		internal init(
			version: Int,
			records: [BrowserDownload]
		) {
			self.version = version
			self.records = records
		}
	}
}
