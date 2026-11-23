import BrowserCore
import CloudKit
import BrowserHistoryClient
import Foundation
import HistoryDatabase
@testable import SQLiteData
import Testing
@testable import WorkspaceSync
import _TestSupport

/// History sync between two Macs (DEV-984, ADR 0001 decision 5): off by default, a mirror of the
/// sync window, and clears every Mac applies.
@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct HistorySyncTests {
	private let profile: Profile.ID = .init(rawValue: UUID(1))

	private func historyStore(_ mac: TestMac) -> BrowserHistoryDatabaseStore {
		.init(history: mac.history, legacyDirectory: mac.directory.appendingPathComponent("History"))
	}

	private func mirrorWindow(_ mac: TestMac) throws -> Int? {
		try mac.history.database.read { db in try HistoryDatabase.mirrorWindow(db) }
	}

	@Test
	func historyIsOffUntilItsToggleIsTurnedOn() async throws {
		let cloud: TestCloud = .init()
		let mac: TestMac = try .init(cloud: cloud)
		defer { mac.remove() }
		let store = historyStore(mac)
		_ = try await store.record(profile, url: URL(string: "https://capturecontext.dev")!, title: "Arx", date: Date())

		let changes: AsyncStream<SyncCategory> = await mac.sync.remoteChanges()
		var heard: AsyncStream<SyncCategory>.Iterator = changes.makeAsyncIterator()
		await mac.sync.setEnabled(true)
		#expect(await mac.sync.status[.history] == .off)
		#expect(await mac.sync.engine(.history) == nil)
		#expect(try mirrorWindow(mac) == nil)
		#expect(await mac.sync.status.historyWindowDays == 30)

		// Turning it on asks the app to take in what's already fetched.
		await mac.sync.setCategory(.history, isEnabled: true)
		#expect(await heard.next() == .history)
		#expect(await mac.sync.status[.history] != .off)
		#expect(try mirrorWindow(mac) == 30)
		try await mac.send()
		#expect(cloud.records(.history).count == 1)

		await mac.sync.setHistoryWindow(days: 7)
		#expect(try mirrorWindow(mac) == 7)
		#expect(try SyncSettingsStore(directory: mac.directory).load().historyWindowDays == 7)

		// Off keeps both copies and stops mirroring.
		await mac.sync.setCategory(.history, isEnabled: false)
		#expect(try mirrorWindow(mac) == nil)
		#expect(cloud.records(.history).count == 1)
		await mac.sync.setEnabled(false)
		#expect(try mirrorWindow(mac) == nil)
	}

	@Test
	func visitsReachTheSameProfileOnTheOtherMacAndClearsClearThere() async throws {
		let cloud: TestCloud = .init()
		let first: TestMac = try .init(cloud: cloud)
		let second: TestMac = try .init(cloud: cloud)
		defer {
			first.remove()
			second.remove()
		}
		let firstHistory = historyStore(first)
		let secondHistory = historyStore(second)
		for mac in [first, second] {
			await mac.sync.setEnabled(true)
			await mac.sync.setCategory(.history, isEnabled: true)
		}

		let page = URL(string: "https://capturecontext.dev/page")!
		let old = URL(string: "https://capturecontext.dev/old")!
		_ = try await firstHistory.record(profile, url: page, title: "Page", date: Date())
		_ = try await firstHistory.record(profile, url: old, title: "Old", date: Date().addingTimeInterval(-40 * 86_400))
		_ = try await secondHistory.record(profile, url: URL(string: "https://example.com/mine")!, title: "Mine", date: Date())
		try await converge(first, second)

		_ = await secondHistory.applySynced(profiles: [profile])

		// The window's visit arrives; the 40-day-old one never left the first Mac.
		#expect(Set(try await secondHistory.load(profile).snapshot.entries.map(\.title)) == ["Page", "Mine"])
		_ = await firstHistory.applySynced(profiles: [profile])
		#expect(Set(try await firstHistory.load(profile).snapshot.entries.map(\.title)) == ["Page", "Old", "Mine"])

		// Pruning the window on one Mac deletes mirror rows everywhere, never local history.
		await first.sync.setHistoryWindow(days: 1)
		try await first.history.database.write { db in
			try HistoryDatabase.prune(db, now: Date().addingTimeInterval(8 * 86_400))
		}
		try await converge(first, second)
		#expect(cloud.records(.history).isEmpty)
		_ = await secondHistory.applySynced(profiles: [profile])
		#expect(Set(try await secondHistory.load(profile).snapshot.entries.map(\.title)) == ["Page", "Mine"])

		// Clearing on the first Mac clears the second.
		_ = try await firstHistory.clear(profile)
		try await converge(first, second)
		_ = await secondHistory.applySynced(profiles: [profile])
		#expect(try await secondHistory.load(profile).snapshot.entries.isEmpty)
	}

	@Test
	func anEarlierVisitWrittenLaterDoesntReplaceTheLatestOne() async throws {
		let cloud: TestCloud = .init()
		let first: TestMac = try .init(cloud: cloud)
		let second: TestMac = try .init(cloud: cloud)
		defer {
			first.remove()
			second.remove()
		}
		let firstHistory = historyStore(first)
		let secondHistory = historyStore(second)
		for mac in [first, second] {
			await mac.sync.setEnabled(true)
			await mac.sync.setCategory(.history, isEnabled: true)
		}
		let page = URL(string: "https://capturecontext.dev/page")!
		let now: Date = Date()
		_ = try await firstHistory.record(profile, url: page, title: "Baseline", date: now.addingTimeInterval(-2 * 86_400))
		try await converge(first, second)
		_ = await secondHistory.applySynced(profiles: [profile])

		// The first Mac visits today; the second, before it hears of that, imports yesterday's visit,
		// and its write reaches iCloud last.
		_ = try await firstHistory.record(profile, url: page, title: "Today", date: now)
		try await Task.sleep(for: .milliseconds(100))
		_ = try await secondHistory.merge(
			profile,
			entries: [.init(id: UUID(), url: page, title: "Yesterday", lastVisited: now.addingTimeInterval(-86_400))]
		)
		try await converge(first, second)
		for store in [firstHistory, secondHistory] {
			_ = await store.applySynced(profiles: [profile])
		}
		try await converge(first, second)
		_ = await secondHistory.applySynced(profiles: [profile])

		#expect(try await firstHistory.load(profile).snapshot.entries.map(\.title) == ["Today"])
		#expect(try await secondHistory.load(profile).snapshot.entries.map(\.title) == ["Today"])
		let mirrored = try await second.history.database.read { db in try HistoryVisitRecord.fetchAll(db) }
		#expect(mirrored.map(\.lastVisited) == [now.timeIntervalSinceReferenceDate])
	}

	@Test
	func historyFromBeforeReplacingWithAnAccountsDataNeverReachesThatAccount() async throws {
		let cloud: TestCloud = .init()
		let mac: TestMac = try .init(cloud: cloud)
		defer { mac.remove() }
		let store = historyStore(mac)
		await mac.sync.setEnabled(true)
		await mac.sync.setCategory(.history, isEnabled: true)
		_ = try await store.record(profile, url: URL(string: "https://capturecontext.dev/old")!, title: "Old", date: Date().addingTimeInterval(-60))
		mac.account.setValue(.available("account-b"))
		await mac.accountEvent(.signIn(currentUser: CKRecord.ID(recordName: "account-b")))
		await mac.sync.resolve(.replaceWithAccountData)
		#expect(await mac.sync.status.review == nil)

		// Neither a wider window nor History on again mirrors it; later visits do.
		await mac.sync.setHistoryWindow(days: 90)
		await mac.sync.setCategory(.history, isEnabled: false)
		await mac.sync.setCategory(.history, isEnabled: true)
		_ = try await store.record(profile, url: URL(string: "https://capturecontext.dev/new")!, title: "New", date: Date().addingTimeInterval(60))
		try await mac.send()
		#expect(cloud.records(.history).count == 1)
		let mirrored = try await mac.history.database.read { db in try HistoryVisitRecord.fetchAll(db) }
		#expect(mirrored.map(\.title) == ["New"])
		// This Mac keeps its own history.
		#expect(Set(try await store.load(profile).snapshot.entries.map(\.title)) == ["Old", "New"])
	}

	@Test
	func historyThatDidntOpenWhenReplacingIsReplacedBeforeItSyncsAgain() async throws {
		let cloud: TestCloud = .init()
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceSyncTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

		// History synced with the first account, and has a page from then.
		let seeded: BrowserHistoryDatabaseStore = .init(
			history: try HistoryDatabase(directory: directory),
			legacyDirectory: directory.appendingPathComponent("History")
		)
		_ = try await seeded.record(profile, url: URL(string: "https://capturecontext.dev/old")!, title: "Old", date: Date().addingTimeInterval(-60))
		try SyncSettingsStore(directory: directory).save(
			.init(
				isEnabled: true,
				disabledCategories: [.organization, .preferences],
				enabledCategories: [.history],
				startedCategories: [.history],
				account: "account-a"
			)
		)

		// Another account, in a run where the history database didn't open: replaced all the same.
		let withoutHistory: TestMac = try .init(cloud: cloud, account: "account-b", directory: directory, hasHistory: false)
		await withoutHistory.sync.launch()
		#expect(await withoutHistory.sync.status.review == .accountChanged)
		await withoutHistory.sync.resolve(.replaceWithAccountData)
		#expect(await withoutHistory.sync.status.review == nil)
		#expect(try SyncSettingsStore(directory: directory).load().pendingReplacements == [.history])

		let mac: TestMac = try .init(cloud: cloud, account: "account-b", directory: directory)
		defer { mac.remove() }
		await mac.sync.launch()
		try await mac.send()
		#expect(try SyncSettingsStore(directory: directory).load().pendingReplacements.isEmpty)
		#expect(cloud.records(.history).isEmpty)
		#expect(try await historyStore(mac).load(profile).snapshot.entries.map(\.title) == ["Old"])
	}

	@Test
	func historyThatDidntOpenWhenUsingWithAnotherAccountIsResetBeforeItSyncsAgain() async throws {
		let cloud: TestCloud = .init()
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceSyncTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try SyncSettingsStore(directory: directory).save(
			.init(
				isEnabled: true,
				disabledCategories: [.organization, .preferences],
				enabledCategories: [.history],
				startedCategories: [.history],
				account: "account-a"
			)
		)

		let withoutHistory: TestMac = try .init(cloud: cloud, account: "account-b", directory: directory, hasHistory: false)
		await withoutHistory.sync.launch()
		#expect(await withoutHistory.sync.status.review == .accountChanged)
		await withoutHistory.sync.resolve(.useWithThisAccount)
		#expect(await withoutHistory.sync.status.review == nil)
		// Its engine still knows the first account's records: forgotten before it starts again.
		#expect(try SyncSettingsStore(directory: directory).load().pendingResets == [.history])

		let mac: TestMac = try .init(cloud: cloud, account: "account-b", directory: directory)
		defer { mac.remove() }
		await mac.sync.launch()
		#expect(try SyncSettingsStore(directory: directory).load().pendingResets.isEmpty)
		#expect(await mac.sync.engine(.history)?.isRunning == true)
	}

	@Test
	func noWindowSettingsOfferIsShorterThanTheMirrorsMinimum() {
		// Recent mirror rows are put back after a fetch on the promise that no Mac prunes them.
		#expect(SyncSettings.historyWindowChoices.allSatisfy { $0 >= HistoryDatabase.minimumWindowDays })
		#expect(SyncSettings.defaultHistoryWindowDays >= HistoryDatabase.minimumWindowDays)
	}

	@Test
	func aClearSentLateDoesntTakeANewerVisitFromTheMirror() async throws {
		let cloud: TestCloud = .init()
		let first: TestMac = try .init(cloud: cloud)
		let second: TestMac = try .init(cloud: cloud)
		defer {
			first.remove()
			second.remove()
		}
		let firstHistory = historyStore(first)
		let secondHistory = historyStore(second)
		for mac in [first, second] {
			await mac.sync.setEnabled(true)
			await mac.sync.setCategory(.history, isEnabled: true)
		}
		let page = URL(string: "https://capturecontext.dev/page")!
		_ = try await firstHistory.record(profile, url: page, title: "Page", date: Date().addingTimeInterval(-86_400))
		try await converge(first, second)
		_ = await secondHistory.applySynced(profiles: [profile])

		// The second Mac clears while offline; the first visits the page again and sends first.
		_ = try await secondHistory.clear(profile)
		_ = try await firstHistory.record(profile, url: page, title: "Again", date: Date().addingTimeInterval(60))
		try await first.send()
		try await second.send()

		// The mock hands a deletion to the first engine that fetches any zone: the first Mac's History
		// engine here, as iCloud would.
		try await first.sync.engine(.history)?.fetchChanges()
		#expect(try await first.history.database.read { db in try HistoryVisitRecord.fetchCount(db) } == 0)
		_ = await firstHistory.applySynced(profiles: [profile])
		try await converge(first, second)
		_ = await secondHistory.applySynced(profiles: [profile])

		#expect(cloud.records(.history).filter { $0.recordType == HistoryVisitRecord.tableName }.count == 1)
		#expect(try await secondHistory.load(profile).snapshot.entries.map(\.title) == ["Again"])
	}

	@Test
	func aTitleStaysWithItsVisitWhenTwoMacsWriteThePageOffline() async throws {
		let cloud: TestCloud = .init()
		let first: TestMac = try .init(cloud: cloud)
		let second: TestMac = try .init(cloud: cloud)
		defer {
			first.remove()
			second.remove()
		}
		let firstHistory = historyStore(first)
		let secondHistory = historyStore(second)
		for mac in [first, second] {
			await mac.sync.setEnabled(true)
			await mac.sync.setCategory(.history, isEnabled: true)
		}
		let page = URL(string: "https://capturecontext.dev/page")!
		let now: Date = Date()
		_ = try await firstHistory.record(profile, url: page, title: "Page", date: now.addingTimeInterval(-2 * 86_400))
		try await converge(first, second)
		_ = await secondHistory.applySynced(profiles: [profile])

		// Offline, the second Mac imports an earlier visit with another title; then the first visits
		// again, its title unchanged, and writes last.
		_ = try await secondHistory.merge(
			profile,
			entries: [.init(id: UUID(), url: page, title: "Imported", lastVisited: now.addingTimeInterval(-86_400))]
		)
		try await Task.sleep(for: .milliseconds(100))
		_ = try await firstHistory.record(profile, url: page, title: "Page", date: now)
		try await converge(first, second)
		for store in [firstHistory, secondHistory] {
			_ = await store.applySynced(profiles: [profile])
		}
		try await converge(first, second)
		for store in [firstHistory, secondHistory] {
			_ = await store.applySynced(profiles: [profile])
		}

		for store in [firstHistory, secondHistory] {
			let entries = try await store.load(profile).snapshot.entries
			#expect(entries.map(\.title) == ["Page"])
			#expect(entries.map(\.lastVisited) == [now])
		}
	}
}
