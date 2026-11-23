import BrowserCore
import BrowserHistoryClient
import Foundation
import HistoryDatabase
import Testing
import _SQLiteData
import _TestSupport

/// History in `arx-history.sqlite` (DEV-984): the JSON store's behavior, the move from the JSON files,
/// and the History sync mirror.
@Suite
internal struct BrowserHistoryDatabaseTests {
	private let profile: Profile.ID = .init(rawValue: UUID(1))
	private let other: Profile.ID = .init(rawValue: UUID(2))
	private let now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)

	private func store(
		_ history: HistoryDatabase,
		legacy: URL,
		now: Date? = nil
	) -> BrowserHistoryDatabaseStore {
		let date: Date = now ?? self.now
		return .init(history: history, legacyDirectory: legacy, now: { date })
	}

	private func days(_ count: Double) -> TimeInterval { count * 86_400 }

	private func temporaryDirectory() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("arx-history-database-\(UUID())")
	}

	@Test
	internal func aProfilesJSONFileMovesInOnceAndIsLeftAsItWas() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let json = BrowserHistoryStore(directory: legacy)
		let url = URL(string: "https://capturecontext.dev/a%2Fb?q=1#f")!
		let recorded = try await json.record(profile, url: url, title: "First", date: Date(timeIntervalSince1970: 10))
		await json.flush()
		let file = BrowserHistoryStore.file(profile, in: legacy)
		let bytes = try Data(contentsOf: file)

		let history = try HistoryDatabase(directory: directory)
		let loaded = try await store(history, legacy: legacy).load(profile)
		#expect(loaded.snapshot.entries == recorded.snapshot.entries)
		#expect(try Data(contentsOf: file) == bytes)

		// The database holds it now: a later change to the file isn't read.
		_ = try await json.record(profile, url: URL(string: "https://example.com")!, title: "Later", date: Date(timeIntervalSince1970: 20))
		await json.flush()
		let reloaded = try await store(HistoryDatabase(directory: directory), legacy: legacy).load(profile)
		#expect(reloaded.snapshot.entries == recorded.snapshot.entries)
	}

	@Test
	internal func unreadableJSONFailsUntilClearReplacesIt() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
		try Data("{".utf8).write(to: BrowserHistoryStore.file(profile, in: legacy))
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)

		await #expect(throws: BrowserHistoryClient.Failure.corrupt) { try await store.load(profile) }
		let cleared = try await store.clear(profile)
		#expect(cleared.failure == nil)
		#expect(cleared.snapshot.entries.isEmpty)
		#expect(try await self.store(HistoryDatabase(directory: directory), legacy: legacy).load(profile).snapshot.entries.isEmpty)
	}

	@Test
	internal func revisitsKeepTheirEntryAndEveryChangeIsWrittenAtOnce() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let url = URL(string: "https://capturecontext.dev/a")!
		let first = try await store.record(profile, url: url, title: "First", date: Date(timeIntervalSince1970: 10))
		let second = try await store.record(profile, url: url, title: "Second", date: Date(timeIntervalSince1970: 20))
		#expect(second.snapshot.entries.map(\.id) == first.snapshot.entries.map(\.id))
		_ = try await store.record(other, url: url, title: "Other", date: Date(timeIntervalSince1970: 30))
		_ = try await store.record(profile, url: URL(string: "https://example.com/b")!, title: "B", date: Date(timeIntervalSince1970: 40))

		let reopened = self.store(try HistoryDatabase(directory: directory), legacy: legacy)
		let restored = try await reopened.load(profile)
		#expect(restored.snapshot.entries.map(\.title) == ["B", "Second"])
		#expect(restored.snapshot.revision == 3)
		#expect(try await reopened.load(other).snapshot.entries.map(\.title) == ["Other"])

		let since = try await reopened.clear(profile, since: Date(timeIntervalSince1970: 30))
		#expect(since.snapshot.entries.map(\.title) == ["Second"])
		#expect(try await self.store(HistoryDatabase(directory: directory), legacy: legacy).load(profile).snapshot.entries.map(\.title) == ["Second"])
	}

	@Test
	internal func aRemovedPageStaysGoneWhenAnEarlierVisitArrivesLate() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let a = URL(string: "https://capturecontext.dev/a")!
		_ = try await store.record(profile, url: a, title: "A", date: Date(timeIntervalSince1970: 10))
		_ = try await store.record(profile, url: URL(string: "https://www.example.com/b")!, title: "B", date: Date(timeIntervalSince1970: 20))
		let loaded = try await store.load(profile)
		let entry = try #require(loaded.snapshot.entries.first { $0.title == "A" })

		_ = try await store.remove(profile, .entries([entry.id]), before: Date(timeIntervalSince1970: 100))
		_ = try await store.remove(profile, .site("example.com"), before: Date(timeIntervalSince1970: 100))

		// Rules are kept in the database, so a new run remembers them too.
		let reopened = self.store(try HistoryDatabase(directory: directory), legacy: legacy)
		let late = try await reopened.record(profile, url: a, title: "A", date: Date(timeIntervalSince1970: 50))
		#expect(late.snapshot.entries.isEmpty)
		let lateSite = try await reopened.record(profile, url: URL(string: "https://example.com/c")!, title: "C", date: Date(timeIntervalSince1970: 60))
		#expect(lateSite.snapshot.entries.isEmpty)
		let later = try await reopened.record(profile, url: a, title: "A", date: Date(timeIntervalSince1970: 200))
		#expect(later.snapshot.entries.map(\.title) == ["A"])
	}

	@Test
	internal func theMirrorHoldsOnlyTheWindowAndOnlyWhileHistorySyncIsOn() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let old = URL(string: "https://capturecontext.dev/old")!
		let recent = URL(string: "https://capturecontext.dev/recent")!
		_ = try await store.record(profile, url: old, title: "Old", date: now.addingTimeInterval(-days(40)))
		_ = try await store.record(profile, url: recent, title: "Recent", date: now.addingTimeInterval(-days(10)))

		// Off: nothing is mirrored.
		#expect(try visits(history).isEmpty)

		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }
		#expect(try visits(history).map(\.url) == [recent.absoluteString])
		#expect(try visits(history).first?.id == HistoryDatabase.visitID(profileID: profile, url: recent))

		_ = try await store.record(profile, url: old, title: "Old again", date: now)
		#expect(Set(try visits(history).map(\.url)) == [old.absoluteString, recent.absoluteString])

		// A shorter window prunes the mirror only; none is shorter than a week (DEV-1088).
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 1, now: now) }
		#expect(try await history.database.read { db in try HistoryDatabase.mirrorWindow(db) } == HistoryDatabase.minimumWindowDays)
		#expect(try visits(history).map(\.url) == [old.absoluteString])
		#expect(try await store.load(profile).snapshot.entries.count == 2)

		// Off again: the mirror stays, and new visits aren't added to it.
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: nil, now: now) }
		_ = try await store.record(profile, url: URL(string: "https://example.com")!, title: "New", date: now)
		#expect(try visits(history).map(\.url) == [old.absoluteString])
	}

	@Test
	internal func clearsAreWrittenForOtherMacsOnlyWhileHistorySyncIsOn() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		_ = try await store.record(profile, url: URL(string: "https://capturecontext.dev/a")!, title: "A", date: now.addingTimeInterval(-60))
		_ = try await store.clear(profile)
		#expect(try clears(history).isEmpty)

		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }
		_ = try await store.record(profile, url: URL(string: "https://capturecontext.dev/b")!, title: "B", date: now.addingTimeInterval(-60))
		_ = try await store.record(profile, url: URL(string: "https://example.com/c")!, title: "C", date: now.addingTimeInterval(-30))
		#expect(try visits(history).count == 2)

		_ = try await store.remove(profile, .site("example.com"), before: now)
		#expect(try clears(history).map(\.host) == ["example.com"])
		#expect(try visits(history).map(\.title) == ["B"])

		_ = try await store.clear(profile)
		#expect(try clears(history).count == 2)
		#expect(try visits(history).isEmpty)
	}

	@Test
	internal func syncedVisitsAndClearsReachThisMacsHistory() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let mine = URL(string: "https://capturecontext.dev/mine")!
		let theirs = URL(string: "https://capturecontext.dev/theirs")!
		let removed = URL(string: "https://capturecontext.dev/removed")!
		let old = URL(string: "https://capturecontext.dev/old")!
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }
		let mineEntry = try #require(
			try await store.record(profile, url: mine, title: "Mine", date: now.addingTimeInterval(-300)).snapshot.entries.first
		)
		_ = try await store.record(profile, url: removed, title: "Removed", date: now.addingTimeInterval(-200))
		let removedEntry = try #require(try await store.load(profile).snapshot.entries.first { $0.url == removed })
		_ = try await store.remove(profile, .entries([removedEntry.id]), before: now.addingTimeInterval(-100))

		// Another Mac's mirror: a page this Mac lacks, a later visit of one it has, one this Mac
		// removed, one from before this Mac's window, and a visit of a profile this Mac doesn't know.
		try await history.database.write { db in
			try HistoryVisitRecord.upsert {
				HistoryVisitRecord(
					id: HistoryDatabase.visitID(profileID: profile, url: old),
					profileID: profile.rawValue,
					url: old.absoluteString,
					title: "Old",
					lastVisited: now.addingTimeInterval(-days(40)).timeIntervalSinceReferenceDate
				)
				HistoryVisitRecord(
					id: HistoryDatabase.visitID(profileID: profile, url: theirs),
					profileID: profile.rawValue,
					url: theirs.absoluteString,
					title: "Theirs",
					lastVisited: now.addingTimeInterval(-250).timeIntervalSinceReferenceDate
				)
				HistoryVisitRecord(
					id: HistoryDatabase.visitID(profileID: profile, url: mine),
					profileID: profile.rawValue,
					url: mine.absoluteString,
					title: "Mine, later",
					lastVisited: now.addingTimeInterval(-50).timeIntervalSinceReferenceDate
				)
				HistoryVisitRecord(
					id: HistoryDatabase.visitID(profileID: profile, url: removed),
					profileID: profile.rawValue,
					url: removed.absoluteString,
					title: "Removed",
					lastVisited: now.addingTimeInterval(-200).timeIntervalSinceReferenceDate
				)
				HistoryVisitRecord(
					id: HistoryDatabase.visitID(profileID: other, url: theirs),
					profileID: other.rawValue,
					url: theirs.absoluteString,
					title: "Unknown profile",
					lastVisited: now.timeIntervalSinceReferenceDate
				)
			}
			.execute(db)
		}
		let outcomes = await store.applySynced(profiles: [profile])
		#expect(outcomes.count == 1)
		let entries = try await store.load(profile).snapshot.entries
		#expect(entries.map(\.title) == ["Mine, later", "Theirs"])
		#expect(entries.first?.id == mineEntry.id)
		// Another Mac's later visit counts once.
		#expect(entries.map(\.visitCount) == [2, 1])
		#expect(try await store.load(other).snapshot.entries.isEmpty)
		// Nothing new: no answer.
		#expect(await store.applySynced(profiles: [profile]).isEmpty)

		// The same visit's corrected title comes in too.
		try await history.database.write { db in
			try HistoryVisitRecord.find(HistoryDatabase.visitID(profileID: profile, url: theirs))
				.update { $0.titledVisit = HistoryVisitRecord.titledVisit(title: "Theirs, renamed", lastVisited: now.addingTimeInterval(-250).timeIntervalSinceReferenceDate) }
				.execute(db)
		}
		_ = await store.applySynced(profiles: [profile])
		#expect(try await store.load(profile).snapshot.entries.map(\.title) == ["Mine, later", "Theirs, renamed"])
		// A renamed visit isn't another visit.
		#expect(try await store.load(profile).snapshot.entries.map(\.visitCount) == [2, 1])

		// Another Mac cleared everything up to a moment: visits after it stay.
		_ = try await store.record(profile, url: URL(string: "https://example.com/after")!, title: "After", date: now.addingTimeInterval(10))
		try await history.database.write { db in
			try HistoryClearRecord.insert {
				HistoryClearRecord(id: UUID(9), profileID: profile.rawValue, before: now.timeIntervalSinceReferenceDate)
			}
			.execute(db)
		}
		_ = await store.applySynced(profiles: [profile])
		#expect(try await self.store(HistoryDatabase(directory: directory), legacy: legacy).load(profile).snapshot.entries.map(\.title) == ["After"])
	}

	@Test
	internal func rankingDataIsKeptInTheDatabaseAndMovesInFromJSON() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let space: Space.ID = .init(rawValue: UUID(7))
		let page = URL(string: "https://capturecontext.dev")!
		let json = BrowserHistoryStore(directory: legacy)
		_ = try await json.record(profile, .init(url: page, title: "Arx", date: Date(timeIntervalSince1970: 10), isTyped: true, spaceID: space))
		_ = try await json.record(profile, .init(url: page, title: "Arx", date: Date(timeIntervalSince1970: 20)))
		await json.flush()

		let history = try HistoryDatabase(directory: directory)
		let moved = try #require(try await store(history, legacy: legacy).load(profile).snapshot.entries.first)
		#expect(moved.visitCount == 2)
		#expect(moved.typedCount == 1)
		#expect(moved.lastSpaceID == space)

		let store = store(history, legacy: legacy)
		_ = try await store.record(profile, .init(url: page, title: "Arx", date: Date(timeIntervalSince1970: 30), isTyped: true, spaceID: space))

		// A title update isn't a visit.
		_ = try await store.record(profile, .init(url: page, title: "Arx, renamed", date: Date(timeIntervalSince1970: 30), isNew: false))
		let reread = try #require(try await self.store(HistoryDatabase(directory: directory), legacy: legacy).load(profile).snapshot.entries.first)
		#expect(reread.title == "Arx, renamed")
		#expect(reread.visitCount == 3)
		#expect(reread.typedCount == 2)
		#expect(reread.lastSpaceID == space)
	}

	@Test
	internal func importsKeepTheLargerCountsAndCountNothingTwice() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let page = URL(string: "https://capturecontext.dev")!
		_ = try await store.record(profile, .init(url: page, title: "Arx", date: Date(timeIntervalSince1970: 50), isTyped: true))
		let imported: BrowsingHistoryEntry = .init(
			id: UUID(3),
			url: page,
			title: "Imported",
			lastVisited: Date(timeIntervalSince1970: 40),
			visitCount: 5,
			typedCount: 2
		)
		_ = try await store.merge(profile, entries: [imported])
		_ = try await store.merge(profile, entries: [imported])
		let entry = try #require(try await self.store(HistoryDatabase(directory: directory), legacy: legacy).load(profile).snapshot.entries.first)
		#expect(entry.title == "Arx")
		#expect(entry.visitCount == 5)
		#expect(entry.typedCount == 2)
	}

	@Test
	internal func aReceivedClearMakesRoomBeforeSyncedVisitsComeInAtTheLimit() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }
		let entries: [BrowsingHistoryEntry] = (0..<BrowsingHistorySnapshot.limit).map { index in
			.init(
				id: UUID(),
				url: URL(string: "https://capturecontext.dev/\(index)")!,
				title: "\(index)",
				lastVisited: now.addingTimeInterval(-100 - Double(index))
			)
		}
		_ = try await store.merge(profile, entries: entries)
		let newest = URL(string: "https://capturecontext.dev/0")!
		let oldest = URL(string: "https://capturecontext.dev/\(BrowsingHistorySnapshot.limit - 1)")!
		let theirs = URL(string: "https://example.com/theirs")!
		try await history.database.write { db in
			try HistoryClearRecord.insert {
				HistoryClearRecord(
					id: UUID(9),
					profileID: profile.rawValue,
					before: now.timeIntervalSinceReferenceDate,
					url: newest.absoluteString
				)
			}
			.execute(db)
			try HistoryVisitRecord.upsert {
				HistoryVisitRecord(
					id: HistoryDatabase.visitID(profileID: profile, url: theirs),
					profileID: profile.rawValue,
					url: theirs.absoluteString,
					title: "Theirs",
					lastVisited: now.addingTimeInterval(-50).timeIntervalSinceReferenceDate
				)
			}
			.execute(db)
		}
		_ = await store.applySynced(profiles: [profile])
		let urls = try await store.load(profile).snapshot.entries.map(\.url)
		#expect(urls.count == BrowsingHistorySnapshot.limit)
		#expect(urls.contains(theirs))
		#expect(urls.contains(oldest))
		#expect(!urls.contains(newest))
	}

	@Test
	internal func aLaterVisitHereKeepsItsMirrorRowWhenAClearCoversTheOlderOne() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let page = URL(string: "https://capturecontext.dev/page")!
		let id = HistoryDatabase.visitID(profileID: profile, url: page)
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }
		_ = try await store.record(profile, url: page, title: "Page", date: now.addingTimeInterval(-10))

		// Another Mac's earlier visit replaced the row, and it cleared up to a moment before this
		// Mac's visit.
		try await history.database.write { db in
			try HistoryVisitRecord.upsert {
				HistoryVisitRecord(
					id: id,
					profileID: profile.rawValue,
					url: page.absoluteString,
					title: "Page",
					lastVisited: now.addingTimeInterval(-100).timeIntervalSinceReferenceDate
				)
			}
			.execute(db)
			try HistoryClearRecord.insert {
				HistoryClearRecord(id: UUID(9), profileID: profile.rawValue, before: now.addingTimeInterval(-50).timeIntervalSinceReferenceDate)
			}
			.execute(db)
		}
		_ = await store.applySynced(profiles: [profile])
		let row = try await history.database.read { db in try HistoryVisitRecord.find(id).fetchOne(db) }
		#expect(row?.lastVisited == now.addingTimeInterval(-10).timeIntervalSinceReferenceDate)
		#expect(try await store.load(profile).snapshot.entries.map(\.url) == [page])
	}

	@Test
	internal func aRemovalWhoseWriteFailedSavesItsRulesWithTheRetry() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }
		_ = try await store.record(profile, url: URL(string: "https://example.com/a")!, title: "A", date: now.addingTimeInterval(-60))
		try await history.database.write { db in
			try db.execute(sql: "CREATE TRIGGER failRemoval BEFORE INSERT ON historyRemoval BEGIN SELECT RAISE(ABORT, 'test'); END")
		}

		let failed = try await store.remove(profile, .site("example.com"), before: now)
		#expect(failed.failure == .writeFailed)
		#expect(failed.snapshot.entries.isEmpty)
		try await history.database.write { db in try db.execute(sql: "DROP TRIGGER failRemoval") }

		let retried = try await store.retry(profile)
		#expect(retried.failure == nil)
		#expect(try clears(history).map(\.host) == ["example.com"])
		#expect(try visits(history).isEmpty)
		let removals = try await history.database.read { db in try HistoryDatabase.removals(db, profileID: profile) }
		#expect(removals.map(\.site) == ["example.com"])
	}

	@Test
	internal func clearCoversAVisitDatedAfterItAndAnotherStoreSeesTheClear() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let first = store(history, legacy: legacy)
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }

		// A clock that ran fast dated this visit tomorrow.
		_ = try await first.record(profile, url: URL(string: "https://example.com/ahead")!, title: "Ahead", date: now.addingTimeInterval(days(1)))

		// Another store on the same database clears without having read the profile.
		let second = store(history, legacy: legacy)
		let cleared = try await second.clear(profile)
		#expect(cleared.snapshot.revision == 2)
		#expect(try visits(history).isEmpty)
		#expect(await first.applySynced(profiles: [profile]).first?.snapshot.entries.isEmpty ?? true)
		#expect(try await second.load(profile).snapshot.entries.isEmpty)

		let stale = try await first.record(profile, url: URL(string: "https://example.com/b")!, title: "B", date: now)
		#expect(stale.failure == .changedOnDisk)
	}

	@Test
	internal func aClearEndsAtItsOwnTimeAndClearsAFutureDatedVisitAsItself() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let ahead = URL(string: "https://example.com/ahead")!
		let page = URL(string: "https://capturecontext.dev/page")!
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }

		// A clock that ran fast dated this visit tomorrow.
		_ = try await store.record(profile, url: ahead, title: "Ahead", date: now.addingTimeInterval(days(1)))
		_ = try await store.record(profile, url: page, title: "Before", date: now.addingTimeInterval(-60))

		_ = try await store.clear(profile)
		let written = try clears(history)
		#expect(written.count == 2)
		#expect(written.contains { $0.url == nil && $0.before == now.timeIntervalSinceReferenceDate })
		#expect(written.contains { $0.url == ahead.absoluteString && $0.after == $0.before })

		// Browsing after the clear stays, through any number of sync passes (DEV-1091).
		_ = try await store.record(profile, url: page, title: "After", date: now.addingTimeInterval(60))
		_ = await store.applySynced(profiles: [profile])
		_ = await store.applySynced(profiles: [profile])

		// The cleared visit itself, arriving late, stays out.
		_ = try await store.record(profile, url: ahead, title: "Ahead", date: now.addingTimeInterval(days(1)))
		let reread = try await self.store(HistoryDatabase(directory: directory), legacy: legacy).load(profile)
		#expect(reread.snapshot.entries.map(\.title) == ["After"])

		// A ranged clear ends at its own time too.
		_ = try await store.record(profile, url: ahead, title: "Ahead again", date: now.addingTimeInterval(days(2)))
		_ = try await store.clear(profile, since: now.addingTimeInterval(-120))
		_ = try await store.record(profile, url: page, title: "Later", date: now.addingTimeInterval(120))
		_ = await store.applySynced(profiles: [profile])
		#expect(try await store.load(profile).snapshot.entries.map(\.title) == ["Later"])
	}

	@Test
	internal func aReceivedPageClearKeepsALateRecordOut() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let page = URL(string: "https://example.com/page")!
		try await history.database.write { db in try HistoryDatabase.setMirrorWindow(db, days: 30, now: now) }
		_ = try await store.record(profile, url: page, title: "Page", date: now.addingTimeInterval(-120))
		try await history.database.write { db in
			try HistoryClearRecord.insert {
				HistoryClearRecord(
					id: UUID(7),
					profileID: profile.rawValue,
					before: now.timeIntervalSinceReferenceDate,
					url: page.absoluteString
				)
			}
			.execute(db)
		}
		_ = await store.applySynced(profiles: [profile])
		let late = try await store.record(profile, url: page, title: "Page", date: now.addingTimeInterval(-60))
		#expect(late.snapshot.entries.isEmpty)

		// So does another Mac's Clear History, for any page.
		try await history.database.write { db in
			try HistoryClearRecord.insert {
				HistoryClearRecord(id: UUID(8), profileID: profile.rawValue, before: now.timeIntervalSinceReferenceDate)
			}
			.execute(db)
		}
		_ = await store.applySynced(profiles: [profile])
		let other = try await store.record(profile, url: URL(string: "https://example.com/other")!, title: "Other", date: now.addingTimeInterval(-30))
		#expect(other.snapshot.entries.isEmpty)
		let after = try await store.record(profile, url: URL(string: "https://example.com/other")!, title: "Other", date: now.addingTimeInterval(30))
		#expect(after.snapshot.entries.map(\.title) == ["Other"])
	}

	@Test
	internal func aVisitSentAgainAfterAClearLeavesTheMirror() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		let store = store(history, legacy: legacy)
		let page = URL(string: "https://example.com/page")!
		try await history.database.write { db in
			try HistoryDatabase.setMirrorWindow(db, days: 30, now: now)

			// A Mac that was offline sent its visit again after another Mac cleared it.
			try HistoryClearRecord.insert {
				HistoryClearRecord(id: UUID(7), profileID: profile.rawValue, before: now.timeIntervalSinceReferenceDate)
			}
			.execute(db)
			try HistoryVisitRecord.insert {
				HistoryVisitRecord(
					id: HistoryDatabase.visitID(profileID: profile, url: page),
					profileID: profile.rawValue,
					url: page.absoluteString,
					title: "Page",
					lastVisited: now.addingTimeInterval(-60).timeIntervalSinceReferenceDate
				)
			}
			.execute(db)
		}
		#expect(await store.applySynced(profiles: [profile]).isEmpty)
		#expect(try await store.load(profile).snapshot.entries.isEmpty)
		#expect(try visits(history).isEmpty)
	}

	@Test
	internal func aClearWhoseWriteFailedStillClearsOnRetry() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let legacy = directory.appending(path: "History")
		let history = try HistoryDatabase(directory: directory)
		_ = try await store(history, legacy: legacy).record(profile, url: URL(string: "https://example.com/a")!, title: "A", date: now)
		try await history.database.write { db in
			try db.execute(sql: "CREATE TRIGGER failDelete BEFORE DELETE ON historyEntry BEGIN SELECT RAISE(ABORT, 'test'); END")
		}

		// A store that hasn't read the profile clears it.
		let store = store(history, legacy: legacy)
		#expect(try await store.clear(profile).failure == .writeFailed)
		try await history.database.write { db in try db.execute(sql: "DROP TRIGGER failDelete") }

		let retried = try await store.retry(profile)
		#expect(retried.failure == nil)
		#expect(try await self.store(HistoryDatabase(directory: directory), legacy: legacy).load(profile).snapshot.entries.isEmpty)
	}

	private func visits(_ history: HistoryDatabase) throws -> [HistoryVisitRecord] {
		try history.database.read { db in try HistoryVisitRecord.order(by: \.lastVisited).fetchAll(db) }
	}

	private func clears(_ history: HistoryDatabase) throws -> [HistoryClearRecord] {
		try history.database.read { db in try HistoryClearRecord.order(by: \.before).fetchAll(db) }
	}

	// MARK: - Merged profiles (DEV-1216)

	@Test
	internal func aMergedProfilesHistoryMovesThroughTheStoreAndTheKeptProfileKeepsRecording() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = store(try HistoryDatabase(directory: directory), legacy: directory.appending(path: "History"))
		_ = try await store.record(other, url: URL(string: "https://merged.example")!, title: "Merged", date: Date(timeIntervalSince1970: 10))

		// The kept profile's history is shown already.
		_ = try await store.record(profile, url: URL(string: "https://kept.example")!, title: "Kept", date: Date(timeIntervalSince1970: 20))

		// Both visited this page: it stays one entry.
		_ = try await store.record(other, url: URL(string: "https://both.example")!, title: "Both", date: Date(timeIntervalSince1970: 11))
		_ = try await store.record(profile, url: URL(string: "https://both.example")!, title: "Both", date: Date(timeIntervalSince1970: 21))

		await store.moveProfile(other, into: profile)

		// The next sync answer shows the kept profile with both, though nothing synced.
		let outcomes = await store.applySynced(profiles: [profile])
		#expect(outcomes.map(\.snapshot.profileID) == [profile])
		#expect(outcomes.first?.snapshot.entries.map(\.title).sorted() == ["Both", "Kept", "Merged"])
		#expect(try await store.load(other).snapshot.entries.isEmpty)
		// And it still records: the move bumped the revision, and the store read it again.
		let recorded = try await store.record(profile, url: URL(string: "https://later.example")!, title: "Later", date: Date(timeIntervalSince1970: 30))
		#expect(recorded.failure == nil)
		#expect(recorded.snapshot.entries.count == 4)
		// Answered once.
		#expect(await store.applySynced(profiles: [profile]).isEmpty)
	}

	@Test
	internal func theJSONStoreMovesAMergedProfilesHistoryToo() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let json = BrowserHistoryStore(directory: directory)
		_ = try await json.record(other, url: URL(string: "https://merged.example")!, title: "Merged", date: Date(timeIntervalSince1970: 10))
		_ = try await json.record(profile, url: URL(string: "https://kept.example")!, title: "Kept", date: Date(timeIntervalSince1970: 20))
		await json.flush()

		await json.moveProfile(other, into: profile)

		#expect(try await json.load(profile).snapshot.entries.map(\.title).sorted() == ["Kept", "Merged"])
		#expect(!FileManager.default.fileExists(atPath: BrowserHistoryStore.file(other, in: directory).path))
	}
}
