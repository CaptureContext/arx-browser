import BrowserCore
import Foundation
import HistoryDatabase
import _SQLiteData

/// History in `arx-history.sqlite` (DEV-984), while the `ARX_SQLITE_WORKSPACE` feature flag is on:
/// the same behavior as ``BrowserHistoryStore``, with every change written at once as row changes.
///
/// A profile's JSON file (`History/<profile>.json`) moves into the database the first time the
/// profile's history is read, in one transaction, and is left as it was, so turning the flag off
/// returns to it. An unreadable file fails as before until Clear History replaces it.
///
/// With History sync on, each write also mirrors visits of the sync window and writes clears for the
/// other Macs (``HistoryDatabase``). ``applySynced(profiles:)`` takes what other Macs mirrored and
/// cleared into this Mac's history.
public actor BrowserHistoryDatabaseStore {
	private struct Cached {
		internal var snapshot: BrowsingHistorySnapshot

		/// The entries and revision the database holds, which the next write is diffed against.
		internal var stored: [BrowsingHistoryEntry]
		internal var storedRevision: Int?
		internal var migratedFromJSON: Bool
		internal var removals: [HistoryRule]

		/// Removal rules a failed write didn't save yet, with the IDs they're saved under: the next
		/// write, a retry among them, saves them with the snapshot.
		internal var unsavedRules: [UnsavedRule] = []

		/// Clears other Macs made, taken in this run. Unlike this Mac's own full and ranged clears,
		/// whose visits on their way the app holds back, they keep out any visit they cover.
		internal var receivedClears: [HistoryRule] = []

		/// A Clear History whose write failed: the next write replaces every stored entry too.
		internal var replacesAll: Bool = false
		internal var failure: BrowserHistoryClient.Failure?
	}

	private struct UnsavedRule {
		internal var rule: HistoryRule
		internal var removalID: UUID
		internal var clearID: UUID
	}

	private let history: HistoryDatabase
	private let legacyDirectory: URL
	private let uuid: @Sendable () -> UUID
	private let now: @Sendable () -> Date
	private var removedProfiles: Set<Profile.ID> = []
	private var cache: [Profile.ID: Cached] = [:]

	/// Profiles whose history a merge moved in (DEV-1216): the next ``applySynced(profiles:)`` answers
	/// for them whether or not anything synced.
	private var movedInto: Set<Profile.ID> = []

	/// Merged profiles whose history couldn't move yet, with the kept profile: until it does, their
	/// history is never deleted.
	private var pendingMoves: [Profile.ID: Profile.ID] = [:]

	/// - Parameters:
	///   - legacyDirectory: the folder of the per-profile JSON files, read once to move them in.
	/// - Parameters:
	///   - localProfiles: the "this Mac only" profiles now (DEV-981), or `nil` while the app
	///     can't say yet; every write first records them, so a visit is never mirrored with a stale list.
	public init(
		history: HistoryDatabase,
		legacyDirectory: URL,
		uuid: @escaping @Sendable () -> UUID = UUID.init,
		now: @escaping @Sendable () -> Date = Date.init,
		localProfiles: @escaping @Sendable () -> ProfileSync? = { nil }
	) {
		self.history = history
		self.legacyDirectory = legacyDirectory
		self.uuid = uuid
		self.now = now
		self.localProfiles = localProfiles
	}

	private let localProfiles: @Sendable () -> ProfileSync?

	/// A write to the history file, after recording the current "this Mac only" profiles in it.
	private func write<T>(_ body: (Database) throws -> T) throws -> T {
		let profiles: ProfileSync? = localProfiles()
		let date: Date = now()
		return try history.database.write { db in
			if let profiles {
				try HistoryDatabase.setLocalProfiles(
					db,
					Set(profiles.local.map(\.rawValue)),
					syncing: Set(profiles.syncing.map(\.rawValue)),
					now: date
				)
			}
			return try body(db)
		}
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
			flush: {},
			applySynced: { await self.applySynced(profiles: $0) },
			setLocalProfiles: { await self.setLocalProfiles($0) },
			moveProfile: { await self.moveProfile($0, into: $1) }
		)
	}

	/// Moves a merged profile's history to the profile it merged into (DEV-1216): its entries merge
	/// into the kept profile's as an import's do, one per page and within the history limit, its
	/// removal rules follow, and its own history goes. The next ``applySynced(profiles:)`` answers for
	/// the kept profile. Nothing is removed when the merge couldn't be saved.
	public func moveProfile(
		_ merged: Profile.ID,
		into kept: Profile.ID
	) {
		guard merged != kept else { return }

		// Kept until the move succeeds, whatever removes the merged profile meanwhile.
		pendingMoves[merged] = kept

		// What this store holds of it, which a failed write may not have saved, else the database's.
		guard let entries = cache[merged]?.snapshot.entries ?? (try? read(merged).snapshot.entries) else { return }

		if !entries.isEmpty {
			guard let outcome = try? merge(kept, entries: entries), outcome.failure == nil else { return }
		}
		do {
			try write { db in
				try HistoryDatabase.moveRemovals(db, from: merged, to: kept)
				try HistoryDatabase.deleteProfile(db, profileID: merged)
			}
		} catch {
			return
		}
		pendingMoves[merged] = nil
		cache[merged] = nil
		cache[kept] = nil
		movedInto.insert(kept)
	}

	/// Records the "this Mac only" profiles in the history file (DEV-981), as the app says they are
	/// now. `profiles` is the list when the handoff was made, used only while the app can't say yet:
	/// handoffs run as separate effects, so an older one can arrive after a newer change, and
	/// recording its list would mirror the history a profile kept while it was "this Mac only".
	public func setLocalProfiles(_ profiles: ProfileSync) {
		let profiles: ProfileSync = localProfiles() ?? profiles
		let date: Date = now()
		try? history.database.write { db in
			try HistoryDatabase.setLocalProfiles(
				db,
				Set(profiles.local.map(\.rawValue)),
				syncing: Set(profiles.syncing.map(\.rawValue)),
				now: date
			)
		}
	}

	public func load(_ profileID: Profile.ID) throws -> BrowserHistoryClient.Outcome {
		guard !removedProfiles.contains(profileID)
		else { throw BrowserHistoryClient.Failure.unavailable }

		if cache[profileID] == nil {
			cache[profileID] = try read(profileID)
		}
		return outcome(profileID)
	}

	/// Records a page view: a new one counts as a visit, and a typed one as a typed visit too
	/// (DEV-1015).
	public func record(
		_ profileID: Profile.ID,
		_ visit: BrowsingVisit
	) throws -> BrowserHistoryClient.Outcome {
		try Task.checkCancellation()
		_ = try load(profileID)
		guard
			var value = cache[profileID],
			BrowsingHistoryEntry.accepts(visit.url),
			visit.date.timeIntervalSince1970.isFinite,
			// What Delete from History took, or another Mac cleared, stays gone when a visit from
			// before it arrives late.
			!value.removals.contains(where: { $0.isNarrowed && $0.covers(visit.url, visitedAt: visit.date) }),
			!value.receivedClears.contains(where: { $0.covers(visit.url, visitedAt: visit.date) })
		else { return outcome(profileID) }

		value.snapshot.record(visit, id: uuid())
		cache[profileID] = value
		return persist(profileID)
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

	/// Imported history is written at once, so the import can report a failed write. As in
	/// ``BrowserHistoryStore``, a page keeps its later visit and the larger visit and typed counts,
	/// so importing the same history twice counts nothing twice (DEV-1015).
	public func merge(
		_ profileID: Profile.ID,
		entries: [BrowsingHistoryEntry]
	) throws -> BrowserHistoryClient.Outcome {
		try Task.checkCancellation()
		_ = try load(profileID)
		for entry in entries {
			cache[profileID]?.snapshot.merge(entry, id: uuid())
		}
		return persist(profileID)
	}

	public func retry(_ profileID: Profile.ID) throws -> BrowserHistoryClient.Outcome {
		_ = try load(profileID)
		return persist(profileID)
	}

	/// Clearing also works for unreadable history: it replaces whatever the profile had.
	public func clear(_ profileID: Profile.ID) throws -> BrowserHistoryClient.Outcome {
		guard !removedProfiles.contains(profileID)
		else { throw BrowserHistoryClient.Failure.unavailable }

		let revision: Int = cache[profileID]?.snapshot.revision ?? 0
		let date: Date = now()
		let rules: [HistoryRule] = [.init(profileID: profileID, before: date)] + futureVisitRules(profileID, after: date)
		var value: Cached = cache[profileID] ?? .init(
			snapshot: .init(profileID: profileID, revision: revision),
			stored: [],
			storedRevision: nil,
			migratedFromJSON: false,
			removals: []
		)
		value.snapshot = .init(profileID: profileID, revision: revision)
		value.removals.append(contentsOf: rules)
		cache[profileID] = value
		return persist(profileID, replacingAll: true, rules: rules)
	}

	/// Drops entries last visited at or after `since`. Unlike clearing everything, this needs
	/// readable history: older entries are kept.
	public func clear(
		_ profileID: Profile.ID,
		since: Date
	) throws -> BrowserHistoryClient.Outcome {
		_ = try load(profileID)
		let date: Date = max(now(), since)
		let rules: [HistoryRule] = [.init(profileID: profileID, before: date, after: since)]
			+ futureVisitRules(profileID, after: date)
		cache[profileID]?.snapshot.remove(since: since)
		cache[profileID]?.removals.append(contentsOf: rules)
		return persist(profileID, rules: rules)
	}

	/// Drops chosen entries or a whole site visited at or before `date`, when the removal was asked
	/// for. Like a ranged clear, it needs readable history.
	public func remove(
		_ profileID: Profile.ID,
		_ removal: BrowsingHistoryRemoval,
		before date: Date
	) throws -> BrowserHistoryClient.Outcome {
		_ = try load(profileID)
		let takes: (BrowsingHistoryEntry) -> Bool = { $0.lastVisited <= date && removal.matches($0) }
		let taken: [BrowsingHistoryEntry] = cache[profileID]?.snapshot.entries.filter(takes) ?? []
		let rules: [HistoryRule] = switch removal {
		case let .site(host):
			[.init(profileID: profileID, before: date, site: BrowsingHistoryRemoval.siteKey(host))]
		case .entries:
			Set(taken.map(\.url)).sorted { $0.absoluteString < $1.absoluteString }.map {
				.init(profileID: profileID, before: date, url: $0)
			}
		}
		cache[profileID]?.snapshot.entries.removeAll(where: takes)
		cache[profileID]?.removals.append(contentsOf: rules)
		return persist(profileID, rules: rules)
	}

	/// The profile is gone: its history here and its JSON file are deleted, and nothing records to
	/// it for the store's lifetime.
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
		cache[profileID] = nil
		do {
			try write { db in
				try HistoryDatabase.deleteProfile(db, profileID: profileID)
			}
		} catch {
			throw BrowserHistoryClient.Failure.unavailable
		}
		do {
			try FileManager.default.removeItem(at: BrowserHistoryStore.file(profileID, in: legacyDirectory))
		} catch let error as CocoaError where error.code == .fileNoSuchFile {
			return
		} catch {
			throw BrowserHistoryClient.Failure.unavailable
		}
	}

	/// Takes what other Macs mirrored and cleared into these profiles' history: a visit this Mac
	/// doesn't have, or has an older visit of, unless a clear or a removal here covers it, and every
	/// clear. Returns the profiles whose history changed.
	public func applySynced(profiles: Set<Profile.ID>) -> [BrowserHistoryClient.Outcome] {
		let synced: [Profile.ID: SyncedHistory]
		let window: Int?
		do {
			// Recorded first, so another Mac's copy of a "this Mac only" profile's history stays out.
			(synced, window) = try write { db in
				(try HistoryDatabase.synced(db), try HistoryDatabase.mirrorWindow(db))
			}
		} catch {
			return []
		}

		// Only visits in this Mac's own window come in, whatever another Mac's window kept; none
		// while History sync is off here. Clears always apply.
		let start: Date? = window.map { now().addingTimeInterval(-Double($0) * 86_400) }

		var outcomes: [BrowserHistoryClient.Outcome] = []

		// Every profile asked about, so a mirror row deleted from under one with nothing else synced is
		// put back too.
		for profileID in profiles.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
			let value: SyncedHistory = synced[profileID] ?? .init()
			guard
				(try? load(profileID)) != nil,
				let cached = cache[profileID]
			else { continue }

			var snapshot: BrowsingHistorySnapshot = cached.snapshot
			let rules: [HistoryRule] = cached.removals + value.clears

			// A record on its way that a received clear covers doesn't bring the page back either.
			// This Mac's own clears are among its removals too.
			let received: [HistoryRule] = value.clears.filter { !cached.removals.contains($0) }
			cache[profileID]?.receivedClears = received

			// Cleared first, so pages on their way out don't take room under the history limit.
			snapshot.entries.removeAll { entry in value.clears.contains { $0.covers(entry) } }
			let local: [URL: BrowsingHistoryEntry] = Dictionary(snapshot.entries.map { ($0.url, $0) }) { first, _ in first }
			for visit in value.visits {
				guard
					let start,
					visit.lastVisited >= start,
					local[visit.url].map({ entry in

						// A later visit, or the same visit's corrected title.
						entry.lastVisited < visit.lastVisited
						|| (entry.lastVisited == visit.lastVisited && entry.title != visit.title && !visit.title.isEmpty)
					}) ?? true,
					!rules.contains(where: { $0.covers(visit) })
				else { continue }

				// A later visit counts once; a corrected title only renames the page.
				let isLater: Bool = local[visit.url].map { $0.lastVisited < visit.lastVisited } ?? true
				snapshot.record(
					.init(url: visit.url, title: visit.title, date: visit.lastVisited, isNew: isLater),
					id: uuid()
				)
			}
			if snapshot.entries != cached.snapshot.entries {
				cache[profileID]?.snapshot = snapshot
				outcomes.append(persist(profileID))
			} else if movedInto.contains(profileID) {
				outcomes.append(outcome(profileID))
			}
			movedInto.remove(profileID)
			restoreMirror(profileID, clears: value.clears)
		}
		return outcomes
	}

	/// Puts this Mac's later visit back in mirror rows another Mac overwrote with an earlier one: the
	/// library keeps the value written last, not the latest visit. Only rows that are there, as one
	/// another Mac pruned or cleared stays gone, except for recent visits no rule covers: no Mac
	/// prunes those, so a clear sent late took a row it didn't cover (DEV-1088). And deletes mirror
	/// rows the clears cover, which a Mac that was offline can send again after a clear.
	private func restoreMirror(
		_ profileID: Profile.ID,
		clears: [HistoryRule]
	) {
		guard let value = cache[profileID], value.failure == nil else { return }

		let date: Date = now()
		let rules: [HistoryRule] = value.removals + clears
		let entries: [BrowsingHistoryEntry] = value.snapshot.entries.filter { entry in
			!rules.contains { $0.covers(entry) }
		}
		try? write { db in

			// A later visit here goes back first: the clear doesn't cover it, so its row stays.
			try HistoryDatabase.mirror(
				db,
				profileID: profileID,
				entries: entries,
				now: date,
				addsMissing: false,
				addsMissingSince: date.addingTimeInterval(-HistoryDatabase.restorableAge)
			)
			try HistoryDatabase.deleteVisits(db, coveredBy: clears)
		}
	}

	// MARK: - Storage

	/// The profile's history from the database, or from its JSON file, moved in, when the database
	/// doesn't have it yet.
	private func read(_ profileID: Profile.ID) throws -> Cached {
		let stored: (revision: Int?, entries: [BrowsingHistoryEntry], removals: [HistoryRule], migrated: Bool)
		do {
			stored = try history.database.read { db in
				(
					try HistoryDatabase.revision(db, profileID: profileID),
					try HistoryDatabase.entries(db, profileID: profileID),
					try HistoryDatabase.removals(db, profileID: profileID),
					try HistoryDatabase.migratedFromJSON(db, profileID: profileID)
				)
			}
		} catch {
			throw BrowserHistoryClient.Failure.unavailable
		}
		if let revision = stored.revision {
			return .init(
				snapshot: .init(profileID: profileID, entries: stored.entries, revision: revision),
				stored: stored.entries,
				storedRevision: revision,
				migratedFromJSON: stored.migrated,
				removals: stored.removals
			)
		}

		// Unreadable JSON fails as it did on the file, and nothing is written.
		let legacy: BrowsingHistorySnapshot? = try BrowserHistoryStore.readSnapshot(in: legacyDirectory, profileID: profileID)
		let snapshot: BrowsingHistorySnapshot = legacy ?? .init(profileID: profileID)
		let migrated: Bool = legacy != nil
		do {
			try write { db in

				// Another process may have moved it in meanwhile.
				guard try HistoryDatabase.revision(db, profileID: profileID) == nil
				else { throw BrowserHistoryClient.Failure.changedOnDisk }

				try HistoryDatabase.write(
					db,
					profileID: profileID,
					from: [],
					to: snapshot.entries,
					revision: snapshot.revision,
					migratedFromJSON: migrated
				)
				try HistoryDatabase.mirror(db, profileID: profileID, entries: snapshot.entries, now: now())
			}
		} catch let failure as BrowserHistoryClient.Failure {
			throw failure
		} catch {
			throw BrowserHistoryClient.Failure.unavailable
		}
		return .init(
			snapshot: snapshot,
			stored: snapshot.entries,
			storedRevision: snapshot.revision,
			migratedFromJSON: migrated,
			removals: []
		)
	}

	/// Writes the cached snapshot as one transaction, with `rules` recorded as removals here and, with
	/// History sync on, as clears for the other Macs. A failed write keeps the snapshot in memory for
	/// ``retry(_:)``.
	///
	/// - Parameters:
	///   - replacingAll: delete every stored entry of the profile first, as Clear History
	///     does even when the stored history couldn't be read.
	private func persist(
		_ profileID: Profile.ID,
		replacingAll: Bool = false,
		rules: [HistoryRule] = []
	) -> BrowserHistoryClient.Outcome {
		guard var value = cache[profileID]
		else { return .init(snapshot: .init(profileID: profileID), failure: .unavailable) }

		let replacingAll: Bool = replacingAll || value.replacesAll
		value.replacesAll = replacingAll
		guard value.snapshot.revision < Int.max - 1
		else { return .init(snapshot: value.snapshot, failure: .unavailable) }

		value.snapshot.revision += 1
		let snapshot: BrowsingHistorySnapshot = value.snapshot
		let expected: Int? = value.storedRevision
		let stored: [BrowsingHistoryEntry] = value.stored
		let migrated: Bool = value.migratedFromJSON
		let date: Date = now()
		value.unsavedRules += rules.map { .init(rule: $0, removalID: uuid(), clearID: uuid()) }
		let unsaved: [UnsavedRule] = value.unsavedRules
		do {
			let written: Int = try write { db in
				var revision: Int = snapshot.revision
				if replacingAll {
					try HistoryDatabase.deleteEntries(db, profileID: profileID)

					// Newer than any revision another store wrote, so that store's next write sees the
					// clear as a change on disk.
					if let current = try HistoryDatabase.revision(db, profileID: profileID), current >= revision {
						guard current < Int.max - 1 else { throw BrowserHistoryClient.Failure.unavailable }

						revision = current + 1
					}
				} else {
					guard try HistoryDatabase.revision(db, profileID: profileID) == expected
					else { throw BrowserHistoryClient.Failure.changedOnDisk }
				}

				let previous: [BrowsingHistoryEntry] = replacingAll ? [] : stored
				try HistoryDatabase.write(
					db,
					profileID: profileID,
					from: previous,
					to: snapshot.entries,
					revision: revision,
					migratedFromJSON: migrated
				)
				for pending in unsaved {
					try HistoryDatabase.addRemoval(db, pending.rule, id: pending.removalID)
					try HistoryDatabase.clear(db, pending.rule, id: pending.clearID)
				}
				let earlier: [UUID: BrowsingHistoryEntry] = Dictionary(previous.map { ($0.id, $0) }) { first, _ in first }
				try HistoryDatabase.mirror(
					db,
					profileID: profileID,
					entries: snapshot.entries.filter { earlier[$0.id] != $0 },
					now: date
				)
				try HistoryDatabase.pruneIfDue(db, now: date)
				return revision
			}
			value.snapshot.revision = written
			value.stored = snapshot.entries
			value.storedRevision = written
			value.unsavedRules = []
			value.replacesAll = false
			value.failure = nil
		} catch let failure as BrowserHistoryClient.Failure {
			value.failure = failure
		} catch {
			value.failure = .writeFailed
		}
		cache[profileID] = value
		return outcome(profileID)
	}

	/// When a clear made at `date` ends: then, or the latest visit of the profile here or in the
	/// mirror if one is dated later, as after a clock that ran fast, so the clear covers it on every
	/// Mac.
	/// A clear ends at its own time, so browsing after it is never covered (DEV-1091). Visits dated
	/// later than that, as with a clock that ran fast, are each cleared as themselves: one rule per
	/// page and time, here or in the mirror.
	private func futureVisitRules(
		_ profileID: Profile.ID,
		after date: Date
	) -> [HistoryRule] {
		let cached: [HistoryDatabase.Visit] = (cache[profileID]?.snapshot.entries ?? [])
			.filter { $0.lastVisited > date }
			.map { .init(url: $0.url, date: $0.lastVisited) }
		let stored: [HistoryDatabase.Visit] = (try? history.database.read { db in
			try HistoryDatabase.visits(db, profileID: profileID, after: date)
		}) ?? []
		return Set(cached + stored)
			.sorted { $0.date == $1.date ? $0.url.absoluteString < $1.url.absoluteString : $0.date < $1.date }
			.map { .init(profileID: profileID, before: $0.date, after: $0.date, url: $0.url) }
	}

	private func outcome(_ profileID: Profile.ID) -> BrowserHistoryClient.Outcome {
		guard let value = cache[profileID]
		else { return .init(snapshot: .init(profileID: profileID), failure: .unavailable) }

		return .init(snapshot: value.snapshot, failure: value.failure)
	}
}
