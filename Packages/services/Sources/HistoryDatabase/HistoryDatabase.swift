import BrowserCore
import CryptoKit
import Foundation
import _SQLiteData

/// Browsing history in SQLite (ADR 0001, section 2, DEV-984): `arx-history.sqlite` beside the
/// workspace databases, one file for every profile.
///
/// Local history is `historyEntry`, which never syncs. With History sync on, `historyVisit` mirrors
/// the visits of the sync window and `historyClear` carries clears to the other Macs; both are written
/// in the same transaction as the local change they follow. The History `SyncEngine` must be made on
/// ``database``, the connection every write goes through.
public final class HistoryDatabase: Sendable {
	public static let fileName: String = "arx-history.sqlite"

	/// How long removal rules and clears are kept: longer than any sync window, so a visit they
	/// cover can't come back from a mirror.
	public static let ruleLifetime: TimeInterval = 400 * 86_400

	/// How often a write prunes the mirror at most.
	public static let pruneInterval: TimeInterval = 3_600

	/// The shortest sync window: a longer one is used as given, a shorter one as this. So no Mac
	/// prunes a mirror row this recent (DEV-1088).
	public static let minimumWindowDays: Int = 7

	/// How recent a visit is for its missing mirror row to be put back after a fetch: inside every
	/// Mac's window with a day to spare for clocks, so only a clear's deletion, never pruning, can
	/// have taken it (DEV-1088).
	public static let restorableAge: TimeInterval = Double(minimumWindowDays - 1) * 86_400

	public let database: DatabaseQueue
	public let file: URL

	/// Opens or creates the database in `directory` and runs its migrations.
	public init(directory: URL) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		self.file = directory.appendingPathComponent(Self.fileName)

		var configuration: Configuration = .init()
		configuration.busyMode = .timeout(10)
		self.database = try .init(path: file.path, configuration: configuration)
		try HistorySchema.migrator().migrate(database)
	}

	/// The database file and its journal: files nothing else may replace.
	public static func files(in directory: URL) -> [URL] {
		[fileName, "\(fileName)-journal"].map { directory.appendingPathComponent($0) }
	}

	/// The mirror record's ID for a profile's page: the same on every Mac, so they share one record
	/// per page. A name-based UUID (version 5 layout) over SHA-256.
	public static func visitID(
		profileID: Profile.ID,
		url: URL
	) -> UUID {
		let name: String = "\(profileID.rawValue.uuidString.lowercased()) \(url.absoluteString)"
		var bytes: [UInt8] = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
		bytes[6] = (bytes[6] & 0x0F) | 0x50
		bytes[8] = (bytes[8] & 0x3F) | 0x80
		return UUID(uuid: (
			bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
			bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
		))
	}
}

// MARK: - Local history

extension HistoryDatabase {
	/// The profile's write revision, or `nil` when its history isn't in the database yet.
	public static func revision(
		_ db: Database,
		profileID: Profile.ID
	) throws -> Int? {
		try HistoryProfileRecord.find(profileID.rawValue).fetchOne(db)?.revision
	}

	/// The profile's entries, newest first.
	public static func entries(
		_ db: Database,
		profileID: Profile.ID
	) throws -> [BrowsingHistoryEntry] {
		try HistoryEntryRecord
			.where { $0.profileID.eq(profileID.rawValue) }
			.fetchAll(db)
			.compactMap(\.entry)
			.sorted { lhs, rhs in
				lhs.lastVisited == rhs.lastVisited
				? lhs.id.uuidString < rhs.id.uuidString
				: lhs.lastVisited > rhs.lastVisited
			}
	}

	/// Writes the difference between two of a profile's entry lists and records its revision.
	public static func write(
		_ db: Database,
		profileID: Profile.ID,
		from old: [BrowsingHistoryEntry],
		to new: [BrowsingHistoryEntry],
		revision: Int,
		migratedFromJSON: Bool
	) throws {
		let kept: Set<UUID> = Set(new.map(\.id))
		let removed: [UUID] = old.map(\.id).filter { !kept.contains($0) }
		if !removed.isEmpty {
			try HistoryEntryRecord.where { $0.id.in(removed) }.delete().execute(db)
		}
		let previous: [UUID: BrowsingHistoryEntry] = Dictionary(old.map { ($0.id, $0) }) { first, _ in first }
		let changed: [HistoryEntryRecord] = new
			.filter { previous[$0.id] != $0 }
			.map { HistoryEntryRecord($0, profileID: profileID) }
		if !changed.isEmpty {
			try HistoryEntryRecord.upsert { changed }.execute(db)
		}
		try HistoryProfileRecord.upsert {
			HistoryProfileRecord(id: profileID.rawValue, revision: revision, migratedFromJSON: migratedFromJSON)
		}
		.execute(db)
	}

	/// A page and the time it was visited.
	public struct Visit: Hashable, Sendable {
		public var url: URL
		public var date: Date

		public init(
			url: URL,
			date: Date
		) {
			self.url = url
			self.date = date
		}
	}

	/// The profile's visits dated after `date`, in its history here or in the mirror.
	public static func visits(
		_ db: Database,
		profileID: Profile.ID,
		after date: Date
	) throws -> [Visit] {
		let start: Double = date.timeIntervalSinceReferenceDate
		let local: [Visit] = try HistoryEntryRecord
			.where { $0.profileID.eq(profileID.rawValue).and($0.lastVisited.gt(start)) }
			.fetchAll(db)
			.compactMap { record in
				URL(string: record.url).map { .init(url: $0, date: Date(timeIntervalSinceReferenceDate: record.lastVisited)) }
			}
		let mirrored: [Visit] = try HistoryVisitRecord
			.where { $0.profileID.eq(profileID.rawValue).and($0.lastVisited.gt(start)) }
			.fetchAll(db)
			.compactMap { record in
				URL(string: record.url).map { .init(url: $0, date: Date(timeIntervalSinceReferenceDate: record.lastVisited)) }
			}
		return local + mirrored
	}

	/// Whether the profile's entries came from its JSON file.
	public static func migratedFromJSON(
		_ db: Database,
		profileID: Profile.ID
	) throws -> Bool {
		try HistoryProfileRecord.find(profileID.rawValue).fetchOne(db)?.migratedFromJSON ?? false
	}

	/// Deletes every entry of the profile, whatever was read of them.
	public static func deleteEntries(
		_ db: Database,
		profileID: Profile.ID
	) throws {
		try HistoryEntryRecord.where { $0.profileID.eq(profileID.rawValue) }.delete().execute(db)
	}

	/// Deletes the profile's history and removal rules here. Its mirror rows and clears stay: they
	/// belong to the other Macs too, and pruning takes the visits.
	public static func deleteProfile(
		_ db: Database,
		profileID: Profile.ID
	) throws {
		try HistoryEntryRecord.where { $0.profileID.eq(profileID.rawValue) }.delete().execute(db)
		try HistoryRemovalRecord.where { $0.profileID.eq(profileID.rawValue) }.delete().execute(db)
		try HistoryProfileRecord.find(profileID.rawValue).delete().execute(db)
	}

	/// Moves a merged profile's removal rules to the profile it was merged into (DEV-1216), so a visit
	/// they cover doesn't come back there.
	public static func moveRemovals(
		_ db: Database,
		from merged: Profile.ID,
		to kept: Profile.ID
	) throws {
		try HistoryRemovalRecord
			.where { $0.profileID.eq(merged.rawValue) }
			.update { $0.profileID = #bind(kept.rawValue) }
			.execute(db)
	}

	/// Records what a removal took, so a visit it covers doesn't come back later.
	public static func addRemoval(
		_ db: Database,
		_ rule: HistoryRule,
		id: UUID
	) throws {
		try HistoryRemovalRecord.insert {
			HistoryRemovalRecord(
				id: id,
				profileID: rule.profileID.rawValue,
				before: rule.before.timeIntervalSinceReferenceDate,
				after: rule.after?.timeIntervalSinceReferenceDate,
				host: rule.site,
				url: rule.url?.absoluteString
			)
		}
		.execute(db)
	}

	/// This Mac's removal rules for the profile.
	public static func removals(
		_ db: Database,
		profileID: Profile.ID
	) throws -> [HistoryRule] {
		try HistoryRemovalRecord
			.where { $0.profileID.eq(profileID.rawValue) }
			.fetchAll(db)
			.map(HistoryRule.init)
	}
}

// MARK: - Mirror

extension HistoryDatabase {
	/// The sync window in days while History sync is on, `nil` while it's off.
	public static func mirrorWindow(_ db: Database) throws -> Int? {
		try HistorySyncStateRecord.find(HistorySyncStateKey.mirrorWindowDays).fetchOne(db)
			.flatMap { Int($0.value) }
			.flatMap { $0 > 0 ? max($0, minimumWindowDays) : nil }
	}

	/// The "this Mac only" profiles (DEV-981), whose visits and clears are never mirrored, and whose
	/// mirror rows and clears from other Macs are never taken in.
	public static func localProfiles(_ db: Database) throws -> Set<UUID> {
		guard let stored = try HistorySyncStateRecord.find(HistorySyncStateKey.localProfiles).fetchOne(db) else { return [] }

		return Set((try? JSONDecoder().decode([UUID].self, from: Data(stored.value.utf8))) ?? [])
	}

	/// Records the "this Mac only" profiles. One turned back on, among `syncing`, mirrors its visits in
	/// the window again; one that's gone stays local.
	public static func setLocalProfiles(
		_ db: Database,
		_ ids: Set<UUID>,
		syncing: Set<UUID>,
		now: Date
	) throws {
		let previous: Set<UUID> = try localProfiles(db)

		// One that's no longer local without syncing, as when it was removed, stays local: whatever
		// history it leaves never reaches iCloud.
		let local: Set<UUID> = ids.union(previous.subtracting(syncing))
		guard local != previous else { return }

		let value: String = String(decoding: try JSONEncoder().encode(local.sorted { $0.uuidString < $1.uuidString }), as: UTF8.self)
		try HistorySyncStateRecord.upsert { HistorySyncStateRecord(id: HistorySyncStateKey.localProfiles, value: value) }.execute(db)
		guard let days = try mirrorWindow(db) else { return }

		let start: Double = try mirrorStart(db, days: days, now: now)
		for profileID in previous.subtracting(local) {
			let entries: [BrowsingHistoryEntry] = try HistoryEntryRecord
				.where { $0.profileID.eq(profileID) && $0.lastVisited.gte(start) }
				.fetchAll(db)
				.compactMap(\.entry)
			try mirror(db, profileID: .init(rawValue: profileID), entries: entries, now: now)
		}
	}

	/// Turns the mirror on with a window, or off with `nil`. On, every profile's visits in the window
	/// are mirrored and older mirror rows pruned. Off, the mirror stays as it is, and so does
	/// iCloud's copy, as for any category that's turned off.
	public static func setMirrorWindow(
		_ db: Database,
		days: Int?,
		now: Date
	) throws {
		guard let days = days.flatMap({ $0 > 0 ? max($0, minimumWindowDays) : nil }) else {
			try HistorySyncStateRecord.find(HistorySyncStateKey.mirrorWindowDays).delete().execute(db)
			return
		}

		let unchanged: Bool = try mirrorWindow(db) == days
		try HistorySyncStateRecord.upsert {
			HistorySyncStateRecord(id: HistorySyncStateKey.mirrorWindowDays, value: String(days))
		}
		.execute(db)
		try prune(db, now: now)
		guard !unchanged else { return }

		let start: Double = try mirrorStart(db, days: days, now: now)
		let recent: [HistoryEntryRecord] = try HistoryEntryRecord
			.where { $0.lastVisited.gte(start) }
			.fetchAll(db)
		let local: Set<UUID> = try localProfiles(db)
		let byProfile: [UUID: [HistoryEntryRecord]] = Dictionary(grouping: recent, by: \.profileID)
		for (profileID, records) in byProfile where !local.contains(profileID) {
			try mirror(db, profileID: .init(rawValue: profileID), entries: records.compactMap(\.entry), now: now)
		}
	}

	/// This Mac's data was replaced with an account's: history visited before `date` is never mirrored,
	/// even when the window widens or History turns on again.
	public static func mirrorOnlyFrom(
		_ db: Database,
		_ date: Date
	) throws {
		try HistorySyncStateRecord.upsert {
			HistorySyncStateRecord(id: HistorySyncStateKey.mirrorsFrom, value: String(date.timeIntervalSinceReferenceDate))
		}
		.execute(db)
	}

	/// The earliest visit the mirror takes: the window's start, or later when this Mac's data was
	/// replaced with an account's since.
	private static func mirrorStart(
		_ db: Database,
		days: Int,
		now: Date
	) throws -> Double {
		let windowStart: Double = now.timeIntervalSinceReferenceDate - Double(days) * 86_400
		let replaced: Double? = try HistorySyncStateRecord.find(HistorySyncStateKey.mirrorsFrom).fetchOne(db)
			.flatMap { Double($0.value) }
		return max(windowStart, replaced ?? -.infinity)
	}

	/// Mirrors entries visited in the window, where the mirror has no later visit of the page.
	/// Nothing while History sync is off.
	///
	/// - Parameters:
	///   - addsMissing: `false` only updates rows the mirror has, as after a fetch, when a row another
	///     Mac pruned or cleared must stay gone.
	///   - addsMissingSince: with `addsMissing` `false`, a missing row of a visit from this moment on
	///     is added all the same: the caller knows nothing pruned or cleared it.
	public static func mirror(
		_ db: Database,
		profileID: Profile.ID,
		entries: [BrowsingHistoryEntry],
		now: Date,
		addsMissing: Bool = true,
		addsMissingSince: Date? = nil
	) throws {
		guard
			let days = try mirrorWindow(db),
			!entries.isEmpty,
			try !localProfiles(db).contains(profileID.rawValue)
		else { return }

		let start: Double = try mirrorStart(db, days: days, now: now)
		let candidates: [HistoryVisitRecord] = entries
			.filter { $0.lastVisited.timeIntervalSinceReferenceDate >= start }
			.map { entry in
				HistoryVisitRecord(
					id: visitID(profileID: profileID, url: entry.url),
					profileID: profileID.rawValue,
					url: entry.url.absoluteString,
					title: entry.title,
					lastVisited: entry.lastVisited.timeIntervalSinceReferenceDate
				)
			}
		guard !candidates.isEmpty else { return }

		let existing: [UUID: HistoryVisitRecord] = try Dictionary(
			HistoryVisitRecord.where { $0.id.in(candidates.map(\.id)) }.fetchAll(db).map { ($0.id, $0) }
		) { first, _ in first }
		let newer: [HistoryVisitRecord] = candidates.filter { candidate in
			guard let current = existing[candidate.id] else {
				return addsMissing || addsMissingSince.map { candidate.lastVisited >= $0.timeIntervalSinceReferenceDate } == true
			}

			// An equal-time visit's title changes only with a write made here, never when putting
			// back a later visit after a fetch: two Macs with different titles would rewrite each
			// other's on every fetch.
			return candidate.lastVisited > current.lastVisited
			|| (addsMissing && candidate.lastVisited == current.lastVisited && candidate.title != current.title && !candidate.title.isEmpty)
		}
		guard !newer.isEmpty else { return }

		try HistoryVisitRecord.upsert { newer }.execute(db)
	}

	/// A clear made here: with History sync on, a `historyClear` row for the other Macs, and the
	/// mirror rows it covers are deleted. Off, nothing is written to the synced tables.
	public static func clear(
		_ db: Database,
		_ rule: HistoryRule,
		id: UUID
	) throws {
		guard try mirrorWindow(db) != nil, try !localProfiles(db).contains(rule.profileID.rawValue) else { return }

		try HistoryClearRecord.insert {
			HistoryClearRecord(
				id: id,
				profileID: rule.profileID.rawValue,
				before: rule.before.timeIntervalSinceReferenceDate,
				after: rule.after?.timeIntervalSinceReferenceDate,
				host: rule.site,
				url: rule.url?.absoluteString
			)
		}
		.execute(db)
		let covered: [UUID] = try HistoryVisitRecord
			.where { $0.profileID.eq(rule.profileID.rawValue) }
			.fetchAll(db)
			.filter { visit in
				URL(string: visit.url).map {
					rule.covers($0, visitedAt: Date(timeIntervalSinceReferenceDate: visit.lastVisited))
				} ?? false
			}
			.map(\.id)
		if !covered.isEmpty {
			try HistoryVisitRecord.where { $0.id.in(covered) }.delete().execute(db)
		}
	}

	/// Deletes the mirror rows these clears cover, while History sync is on.
	public static func deleteVisits(
		_ db: Database,
		coveredBy clears: [HistoryRule]
	) throws {
		guard try mirrorWindow(db) != nil, !clears.isEmpty else { return }

		// Other Macs' copies of a "this Mac only" profile's history are theirs: left as they are.
		let profiles: [UUID] = Array(Set(clears.map(\.profileID.rawValue)).subtracting(try localProfiles(db)))
		let covered: [UUID] = try HistoryVisitRecord
			.where { $0.profileID.in(profiles) }
			.fetchAll(db)
			.filter { visit in
				guard let url = URL(string: visit.url) else { return false }

				let date: Date = Date(timeIntervalSinceReferenceDate: visit.lastVisited)
				return clears.contains { $0.profileID.rawValue == visit.profileID && $0.covers(url, visitedAt: date) }
			}
			.map(\.id)
		guard !covered.isEmpty else { return }

		try HistoryVisitRecord.where { $0.id.in(covered) }.delete().execute(db)
	}

	/// Deletes mirror rows older than the window (only while History sync is on), and removal rules
	/// and clears older than ``ruleLifetime``. Never touches local history.
	public static func prune(
		_ db: Database,
		now: Date
	) throws {
		let reference: Double = now.timeIntervalSinceReferenceDate
		if let days = try mirrorWindow(db) {
			let start: Double = reference - Double(days) * 86_400
			try HistoryVisitRecord.where { $0.lastVisited.lt(start) }.delete().execute(db)
			let expired: Double = reference - ruleLifetime
			try HistoryClearRecord.where { $0.before.lt(expired) }.delete().execute(db)
		}
		let expired: Double = reference - ruleLifetime
		try HistoryRemovalRecord.where { $0.before.lt(expired) }.delete().execute(db)
		try HistorySyncStateRecord.upsert {
			HistorySyncStateRecord(id: HistorySyncStateKey.lastPruned, value: String(reference))
		}
		.execute(db)
	}

	/// Prunes when the last prune was more than ``pruneInterval`` ago.
	public static func pruneIfDue(
		_ db: Database,
		now: Date
	) throws {
		let last: Double? = try HistorySyncStateRecord.find(HistorySyncStateKey.lastPruned).fetchOne(db)
			.flatMap { Double($0.value) }
		guard last.map({ now.timeIntervalSinceReferenceDate - $0 >= pruneInterval || $0 > now.timeIntervalSinceReferenceDate }) ?? true
		else { return }

		try prune(db, now: now)
	}

	/// What other Macs' mirror and clears hold, by profile.
	public static func synced(_ db: Database) throws -> [Profile.ID: SyncedHistory] {
		var result: [Profile.ID: SyncedHistory] = [:]

		// A "this Mac only" profile takes in nothing (DEV-981).
		let local: Set<UUID> = try localProfiles(db)
		for visit in try HistoryVisitRecord.fetchAll(db) where !local.contains(visit.profileID) {
			guard let url = URL(string: visit.url) else { continue }

			result[.init(rawValue: visit.profileID), default: .init()].visits.append(
				.init(
					id: visit.id,
					url: url,
					title: visit.title,
					lastVisited: Date(timeIntervalSinceReferenceDate: visit.lastVisited)
				)
			)
		}
		for clear in try HistoryClearRecord.fetchAll(db) where !local.contains(clear.profileID) {
			result[.init(rawValue: clear.profileID), default: .init()].clears.append(.init(clear))
		}
		return result
	}
}

/// A profile's mirrored visits and clears.
public struct SyncedHistory: Equatable, Sendable {
	public var visits: [BrowsingHistoryEntry]
	public var clears: [HistoryRule]

	public init(
		visits: [BrowsingHistoryEntry] = [],
		clears: [HistoryRule] = []
	) {
		self.visits = visits
		self.clears = clears
	}
}

/// What a clear or a removal takes from a profile's history: visits up to `before`, narrowed to
/// those from `after` on, to one site, or to one page.
public struct HistoryRule: Equatable, Sendable {
	public var profileID: Profile.ID
	public var before: Date
	public var after: Date?

	/// A site as ``BrowserCore/BrowsingHistoryRemoval/siteKey(_:)`` compares it.
	public var site: String?
	public var url: URL?

	public init(
		profileID: Profile.ID,
		before: Date,
		after: Date? = nil,
		site: String? = nil,
		url: URL? = nil
	) {
		self.profileID = profileID
		self.before = before
		self.after = after
		self.site = site
		self.url = url
	}

	/// Whether it's a removal of chosen pages or a site, rather than of a time range.
	public var isNarrowed: Bool { site != nil || url != nil }

	public func covers(
		_ url: URL,
		visitedAt date: Date
	) -> Bool {
		guard date <= before else { return false }
		if let after, date < after { return false }
		if let site {
			guard let host = url.host(), BrowsingHistoryRemoval.siteKey(host) == site else { return false }
		}
		if let ruleURL = self.url, ruleURL != url { return false }
		return true
	}

	public func covers(_ entry: BrowsingHistoryEntry) -> Bool {
		covers(entry.url, visitedAt: entry.lastVisited)
	}

	internal init(_ record: HistoryRemovalRecord) {
		self.init(
			profileID: .init(rawValue: record.profileID),
			before: Date(timeIntervalSinceReferenceDate: record.before),
			after: record.after.map(Date.init(timeIntervalSinceReferenceDate:)),
			site: record.host,
			url: record.url.flatMap(URL.init(string:))
		)
	}

	internal init(_ record: HistoryClearRecord) {
		self.init(
			profileID: .init(rawValue: record.profileID),
			before: Date(timeIntervalSinceReferenceDate: record.before),
			after: record.after.map(Date.init(timeIntervalSinceReferenceDate:)),
			site: record.host,
			url: record.url.flatMap(URL.init(string:))
		)
	}
}

extension HistoryEntryRecord {
	internal init(
		_ entry: BrowsingHistoryEntry,
		profileID: Profile.ID
	) {
		self.init(
			id: entry.id,
			profileID: profileID.rawValue,
			url: entry.url.absoluteString,
			title: entry.title,
			lastVisited: entry.lastVisited.timeIntervalSinceReferenceDate,
			visitCount: entry.visitCount,
			typedCount: entry.typedCount,
			lastSpaceID: entry.lastSpaceID?.rawValue
		)
	}

	/// The entry, or `nil` for a row whose address no longer reads as one.
	public var entry: BrowsingHistoryEntry? {
		URL(string: url).map {
			.init(
				id: id,
				url: $0,
				title: title,
				lastVisited: Date(timeIntervalSinceReferenceDate: lastVisited),
				visitCount: visitCount,
				typedCount: typedCount,
				lastSpaceID: lastSpaceID.map(Space.ID.init(rawValue:))
			)
		}
	}
}
