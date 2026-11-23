import BrowserCore
import Foundation

/// Serial, profile-separated storage. A failed write retains memory history for explicit retry.
public actor BrowserHistoryStore {
	public typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

	private struct Document: Codable {
		internal var version: Int
		internal var snapshot: BrowsingHistorySnapshot

		internal init(
			version: Int = 1,
			snapshot: BrowsingHistorySnapshot
		) {
			self.version = version
			self.snapshot = snapshot
		}
	}

	private struct Cached {
		internal var snapshot: BrowsingHistorySnapshot
		internal var expectedBytes: Data?
		internal var failure: BrowserHistoryClient.Failure?
		internal var isClearing: Bool

		internal init(
			snapshot: BrowsingHistorySnapshot,
			expectedBytes: Data?,
			failure: BrowserHistoryClient.Failure? = nil,
			isClearing: Bool = false
		) {
			self.snapshot = snapshot
			self.expectedBytes = expectedBytes
			self.failure = failure
			self.isClearing = isClearing
		}
	}

	private static let maximumFileBytes: Int = 80_000_000

	private let directory: URL
	private let writer: AtomicWriter
	private let uuid: @Sendable () -> UUID
	private var removedProfiles: Set<Profile.ID> = []

	/// Merged profiles whose history couldn't move yet, with the kept profile: until it does, their
	/// file is never deleted (DEV-1216).
	private var pendingMoves: [Profile.ID: Profile.ID] = [:]
	private var cache: [Profile.ID: Cached] = [:]
	private var lastWrite: [Profile.ID: ContinuousClock.Instant] = [:]
	private var pendingWrites: [Profile.ID: Task<Void, Never>] = [:]

	/// What each profile's removals took and when (DEV-810). A visit from before a removal that
	/// reaches the store after it, such as a record already on its way, doesn't bring the page
	/// back.
	private var removals: [Profile.ID: [Removed]] = [:]

	private struct Removed {
		internal var urls: Set<URL>
		internal var site: String?
		internal var at: Date

		internal init(
			urls: Set<URL>,
			site: String?,
			at: Date
		) {
			self.urls = urls
			self.site = site
			self.at = at
		}

		internal func covers(
			_ url: URL,
			visitedAt date: Date
		) -> Bool {
			guard date <= at else { return false }
			if urls.contains(url) { return true }
			guard let site, let host = url.host() else { return false }
			return BrowsingHistoryRemoval.siteKey(host) == site
		}
	}

	/// Navigation can record several visits per second (redirects, title updates);
	/// the first write happens at once and later ones are coalesced into this window.
	public static let writeInterval: Duration = .seconds(1)

	public init(
		directory: URL,
		writer: @escaping AtomicWriter = { try $0.write(to: $1, options: .atomic) },
		uuid: @escaping @Sendable () -> UUID = UUID.init
	) {
		self.directory = directory
		self.writer = writer
		self.uuid = uuid
	}

	public nonisolated var client: BrowserHistoryClient {
		.init(
			load: { try await self.load($0) },
			record: { try await self.record($0, $1) },
			merge: { try await self.merge($0, entries: $1) },
			clear: { try await self.clear($0) },
			clearSince: { try await self.clear($0, since: $1) },
			removeEntries: { try await self.remove($0, $1, before: $2) },
			retry: { try await self.retry($0) },
			remove: { try await self.remove($0) },
			flush: { await self.flush() },
			moveProfile: { await self.moveProfile($0, into: $1) }
		)
	}

	/// Moves a merged profile's history to the profile it merged into (DEV-1216): its entries merge
	/// into the kept profile's as an import's do, and its file goes once that's saved.
	public func moveProfile(
		_ merged: Profile.ID,
		into kept: Profile.ID
	) {
		guard merged != kept else { return }

		pendingMoves[merged] = kept
		removedProfiles.remove(merged)
		guard let entries = try? load(merged).snapshot.entries else { return }

		if !entries.isEmpty {
			guard let outcome = try? merge(kept, entries: entries), outcome.failure == nil else { return }
		}
		pendingMoves[merged] = nil
		try? remove(merged)
		removedProfiles.remove(merged)
	}

	public func load(_ profileID: Profile.ID) throws -> BrowserHistoryClient.Outcome {
		guard !removedProfiles.contains(profileID)
		else { throw BrowserHistoryClient.Failure.unavailable }

		if cache[profileID] == nil {
			let data = try Self.bytes(at: file(profileID))
			let snapshot: BrowsingHistorySnapshot = try data.map { try Self.snapshot(from: $0, profileID: profileID) }
			?? .init(profileID: profileID)
			cache[profileID] = .init(snapshot: snapshot, expectedBytes: data)
		}
		return outcome(profileID)
	}

	/// A profile's history as its JSON file in `directory` holds it, or `nil` without a file. The
	/// SQLite store reads it once, to move it into the history database.
	public static func readSnapshot(
		in directory: URL,
		profileID: Profile.ID
	) throws -> BrowsingHistorySnapshot? {
		try bytes(at: file(profileID, in: directory)).map { try snapshot(from: $0, profileID: profileID) }
	}

	private static func snapshot(
		from data: Data,
		profileID: Profile.ID
	) throws -> BrowsingHistorySnapshot {
		guard data.count <= Self.maximumFileBytes
		else { throw BrowserHistoryClient.Failure.corrupt }

		let document: Document
		do {
			document = try JSONDecoder().decode(Document.self, from: data)
		} catch {
			throw BrowserHistoryClient.Failure.corrupt
		}

		guard document.version == 1
		else { throw BrowserHistoryClient.Failure.futureVersion }

		guard
			document.snapshot.profileID == profileID,
			document.snapshot.isValid
		else { throw BrowserHistoryClient.Failure.corrupt }

		return document.snapshot
	}

	public func record(
		_ profileID: Profile.ID,
		_ visit: BrowsingVisit
	) throws -> BrowserHistoryClient.Outcome {
		try Task.checkCancellation()
		_ = try load(profileID)
		guard
			BrowsingHistoryEntry.accepts(visit.url),
			visit.date.timeIntervalSince1970.isFinite,
			removals[profileID]?.contains(where: { $0.covers(visit.url, visitedAt: visit.date) }) != true
		else { return outcome(profileID) }

		cache[profileID]?.snapshot.record(visit, id: uuid())
		return throttledPersist(profileID)
	}

	/// Records a new, untyped visit.
	public func record(
		_ profileID: Profile.ID,
		url: URL,
		title: String,
		date: Date
	) throws -> BrowserHistoryClient.Outcome {
		try record(profileID, .init(url: url, title: title, date: date))
	}

	/// Imported history is written at once, so the import can report a failed write. Visit and
	/// typed counts come along (DEV-1015).
	public func merge(
		_ profileID: Profile.ID,
		entries: [BrowsingHistoryEntry]
	) throws -> BrowserHistoryClient.Outcome {
		try Task.checkCancellation()
		_ = try load(profileID)
		for entry in entries {
			cache[profileID]?.snapshot.merge(entry, id: uuid())
		}
		pendingWrites.removeValue(forKey: profileID)?.cancel()
		return persist(profileID)
	}

	/// Writes every profile with a coalesced, not yet written change.
	public func flush() {
		let profiles: [Profile.ID] = Array(pendingWrites.keys)
		for profileID in profiles {
			pendingWrites.removeValue(forKey: profileID)?.cancel()
			_ = persist(profileID)
		}
	}

	private func throttledPersist(_ profileID: Profile.ID) -> BrowserHistoryClient.Outcome {
		guard pendingWrites[profileID] == nil else { return outcome(profileID) }

		let now = ContinuousClock.now
		guard
			let previous = lastWrite[profileID],
			now < previous.advanced(by: Self.writeInterval)
		else { return persist(profileID) }

		let deadline = previous.advanced(by: Self.writeInterval)
		pendingWrites[profileID] = Task { [weak self] in
			do {
				try await Task.sleep(until: deadline, clock: .continuous)
			} catch {
				return
			}

			await self?.writePending(profileID)
		}
		return outcome(profileID)
	}

	private func writePending(_ profileID: Profile.ID) {
		guard pendingWrites.removeValue(forKey: profileID) != nil else { return }

		_ = persist(profileID)
	}

	public func retry(_ profileID: Profile.ID) throws -> BrowserHistoryClient.Outcome {
		_ = try load(profileID)
		pendingWrites.removeValue(forKey: profileID)?.cancel()
		return persist(profileID)
	}

	/// Explicit clearing also works for unreadable history; no unrelated profile file is touched.
	public func clear(_ profileID: Profile.ID) throws -> BrowserHistoryClient.Outcome {
		guard !removedProfiles.contains(profileID)
		else { throw BrowserHistoryClient.Failure.unavailable }

		pendingWrites.removeValue(forKey: profileID)?.cancel()
		let revision: Int = cache[profileID]?.snapshot.revision ?? 0
		cache[profileID] = .init(
			snapshot: .init(profileID: profileID, revision: revision),
			expectedBytes: nil,
			isClearing: true
		)
		return persist(profileID)
	}

	/// Drops entries last visited at or after `since`. Unlike clearing everything,
	/// this needs readable history: older entries are kept.
	public func clear(
		_ profileID: Profile.ID,
		since: Date
	) throws -> BrowserHistoryClient.Outcome {
		_ = try load(profileID)
		pendingWrites.removeValue(forKey: profileID)?.cancel()
		cache[profileID]?.snapshot.remove(since: since)
		return persist(profileID)
	}

	/// Drops chosen entries or a whole site. Like a ranged clear, it needs readable history.
	/// - Parameters:
	///   - date: When the removal was asked for. Entries visited later stay, and so do later
	///     visits that reach the store afterwards; earlier ones arriving late are dropped.
	public func remove(
		_ profileID: Profile.ID,
		_ removal: BrowsingHistoryRemoval,
		before date: Date
	) throws -> BrowserHistoryClient.Outcome {
		_ = try load(profileID)
		pendingWrites.removeValue(forKey: profileID)?.cancel()
		let takes: (BrowsingHistoryEntry) -> Bool = { $0.lastVisited <= date && removal.matches($0) }
		let taken = cache[profileID]?.snapshot.entries.filter(takes) ?? []
		let site: String? = if case let .site(host) = removal { BrowsingHistoryRemoval.siteKey(host) } else { nil }
		removals[profileID, default: []].append(.init(urls: Set(taken.map(\.url)), site: site, at: date))
		cache[profileID]?.snapshot.entries.removeAll(where: takes)
		return persist(profileID)
	}

	public func remove(_ profileID: Profile.ID) throws {
		// A merged profile's history that couldn't move yet: tried again, and kept if it still can't.
		if let kept = pendingMoves[profileID] {
			moveProfile(profileID, into: kept)
			if pendingMoves[profileID] != nil {
				removedProfiles.insert(profileID)
				cache[profileID] = nil
				return
			}
		}
		removedProfiles.insert(profileID)
		removals[profileID] = nil
		pendingWrites.removeValue(forKey: profileID)?.cancel()
		lastWrite[profileID] = nil
		cache[profileID] = nil
		do {
			try FileManager.default.removeItem(at: file(profileID))
		} catch let error as CocoaError where error.code == .fileNoSuchFile {
			return
		} catch {
			throw BrowserHistoryClient.Failure.unavailable
		}
	}

	private func persist(_ profileID: Profile.ID) -> BrowserHistoryClient.Outcome {
		guard var value = cache[profileID]
		else { return .init(snapshot: .init(profileID: profileID), failure: .unavailable) }

		guard value.snapshot.revision < Int.max - 1
		else { return .init(snapshot: value.snapshot, failure: .unavailable) }

		value.snapshot.revision += 1
		do {
			if !value.isClearing {
				guard try Self.bytes(at: file(profileID)) == value.expectedBytes
				else { throw BrowserHistoryClient.Failure.changedOnDisk }
			}

			let encoder: JSONEncoder = .init()
			encoder.outputFormatting = .withoutEscapingSlashes
			var data = try encoder.encode(Document(snapshot: value.snapshot))
			while data.count > Self.maximumFileBytes, !value.snapshot.entries.isEmpty {
				value.snapshot.entries.removeLast(max(1, value.snapshot.entries.count / 8))
				data = try encoder.encode(Document(snapshot: value.snapshot))
			}
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			try writer(data, file(profileID))
			lastWrite[profileID] = .now
			value.expectedBytes = data
			value.isClearing = false
			value.failure = nil
		} catch let failure as BrowserHistoryClient.Failure {
			value.failure = failure
		} catch {
			value.failure = .writeFailed
		}
		cache[profileID] = value
		return outcome(profileID)
	}

	private func outcome(_ profileID: Profile.ID) -> BrowserHistoryClient.Outcome {
		guard let value = cache[profileID]
		else { return .init(snapshot: .init(profileID: profileID), failure: .unavailable) }

		return .init(snapshot: value.snapshot, failure: value.failure)
	}

	private func file(_ profileID: Profile.ID) -> URL {
		Self.file(profileID, in: directory)
	}

	/// A profile's JSON file in `directory`.
	public static func file(
		_ profileID: Profile.ID,
		in directory: URL
	) -> URL {
		directory
			.appendingPathComponent(profileID.rawValue.uuidString)
			.appendingPathExtension("json")
	}

	private static func bytes(at file: URL) throws -> Data? {
		do {
			let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
			let size: Int = (attributes[.size] as? NSNumber)?.intValue ?? 0
			guard size <= Self.maximumFileBytes
			else { throw BrowserHistoryClient.Failure.corrupt }

			return try Data(contentsOf: file)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
			return nil
		} catch let failure as BrowserHistoryClient.Failure {
			throw failure
		} catch {
			throw BrowserHistoryClient.Failure.unavailable
		}
	}
}
