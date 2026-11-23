import BrowserCore
import BrowserWorkspaceClient
import CloudKit
import ConcurrencyExtras
import Foundation
import GRDB
@testable import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// The SQLite workspace's store and client with iCloud sync (DEV-977): preference rows go through
/// the preferences file's own connection, which the Preferences engine watches.
@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct WorkspaceStoreSyncTests {
	private let profileID: Profile.ID = .init(rawValue: UUID(-1))
	private let spaceID: Space.ID = .init(rawValue: UUID(-2))
	private let tabID: BrowserCore.Tab.ID = .init(rawValue: UUID(-3))

	private var organization: BrowserOrganization {
		.init(
			profiles: [.init(id: profileID, name: "Personal")],
			legacyProfileID: profileID,
			spaces: [.init(id: spaceID, profileID: profileID, name: "Home", savedItems: [.tab(tabID)])],
			tabs: [
				.init(
					id: tabID,
					profileID: profileID,
					savedDestination: .init(title: "Arx", url: URL(string: "https://arx.example")!),
					restoration: .init(title: "Arx", url: URL(string: "https://arx.example")!)
				),
			]
		)
	}

	private func preferences(keyword: String) -> BrowserPreferences {
		var preferences: BrowserPreferences = .init()
		preferences.searchShortcuts.append(
			.init(name: "Sync", keyword: keyword, template: "https://sync.example/?q={query}")
		)
		return preferences
	}

	private func temporaryDirectory() throws -> URL {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceStoreSyncTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private func sync(
		_ store: WorkspaceDatabase,
		cloud: TestCloud,
		directory: URL
	) throws -> WorkspaceSync {
		try WorkspaceSync(
			organization: store.database,
			preferences: try #require(store.preferencesDatabase),
			settings: SyncSettingsStore(directory: directory),
			cloud: CloudAccess(
				account: { .available("account-a") },
				deleteZone: { try cloud.deleteZone($0) },
				placements: { try cloud.placements($0) },
				recordValues: { try cloud.recordValues($0, $1) },
				zoneRecords: { try cloud.zoneRecords($0, $1) }
			),
			makeEngine: cloud.makeEngine()
		)
	}

	@Test
	func aPreferenceSavedThroughTheStoreReachesICloud() async throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let cloud: TestCloud = .init()
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try store.save(organization, preferences: preferences(keyword: "first"))
		let sync: WorkspaceSync = try sync(store, cloud: cloud, directory: directory)
		await sync.setEnabled(true)
		try await sync.engine(.preferences)?.sendChanges()

		// A save after sync started: only the engine's change tracking can send it.
		try store.save(organization, preferences: preferences(keyword: "second"))
		try await sync.engine(.preferences)?.sendChanges()
		try await sync.engine(.organization)?.sendChanges()

		let keywords: Set<String> = Set(cloud.records(.preferences).compactMap { record in
			record.recordType == SearchShortcutRecord.tableName ? record.encryptedValues["keyword"] as? String : nil
		})

		// The second save replaced "first" with "second": both the insert and the deletion went out.
		#expect(keywords.contains("second"))
		#expect(!keywords.contains("first"))
		#expect(cloud.records(.organization).contains { $0.recordType == ProfileRecord.tableName })
	}

	@Test
	func preferenceRowsGoThroughTheAttachedCopyOnlyWithoutSync() throws {
		for separate in [false, true] {
			let directory: URL = try temporaryDirectory()
			defer { TestFolders.removeAtExit(directory) }
			let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: separate)
			let observer: PreferenceWrites = .init()
			store.database.add(transactionObserver: observer, extent: .observerLifetime)

			try store.save(organization, preferences: preferences(keyword: "first"))
			try store.save(organization, preferences: preferences(keyword: "second"))

			#expect((observer.count.value > 0) == !separate)
			#expect(try store.load()?.preferences.searchShortcuts.contains { $0.keyword == "second" } == true)
			#expect((store.preferencesDatabase != nil) == separate)
		}
	}

	@Test
	func aSaveCutShortBetweenTheTwoFilesStillLoads() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try store.save(organization, preferences: preferences(keyword: "first"))
		let preferencesDatabase: DatabaseQueue = try #require(store.preferencesDatabase)

		func setPreferencesRevision(ahead: Int) throws {
			try preferencesDatabase.write { db in
				let organizationRevision: Int = try #require(
					try store.database.read { try StoreInfoRecord.find(StoreInfoKey.revision).fetchOne($0) }
						.flatMap { Int($0.value) }
				)
				try PreferenceStoreInfoRecord.upsert {
					PreferenceStoreInfoRecord(id: StoreInfoKey.revision, value: String(organizationRevision + ahead))
				}
				.execute(db)
			}
		}

		// The preferences file was written, the organization file wasn't.
		try setPreferencesRevision(ahead: 1)
		let reopened: WorkspaceDatabase = try .init(directory: directory)
		#expect(try reopened.load()?.organization == organization)
		// Its next save puts both files on one revision again.
		try reopened.save(organization, preferences: preferences(keyword: "again"))
		#expect(try WorkspaceDatabase(directory: directory).load() != nil)

		// Two ahead is a file restored or replaced alone.
		try setPreferencesRevision(ahead: 2)
		#expect(throws: WorkspaceDatabase.Failure.partialStore) {
			try WorkspaceDatabase(directory: directory).load()
		}
	}

	/// Fails the organization file's half of every save through `store` until `body` returns, as a
	/// crash or full disk between the two transactions would.
	private func cuttingOrganizationWrites(
		_ store: WorkspaceDatabase,
		_ body: () throws -> Void
	) throws {
		try store.database.write { db in
			try db.execute(sql: """
				CREATE TEMP TRIGGER cutOrganizationWrite BEFORE INSERT ON "\(StoreInfoRecord.tableName)"
				BEGIN SELECT RAISE(ABORT, 'cut'); END
				""")
		}
		defer {
			try? store.database.write { try $0.execute(sql: "DROP TRIGGER cutOrganizationWrite") }
		}
		try body()
	}

	@Test
	func aReloadThatFailsValidationKeepsTheBaseLocalSavesDiffAgainst() throws {
		struct Rejected: Error {}
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try store.save(organization, preferences: preferences(keyword: "first"))

		// Another Mac renamed the space, but what sync left doesn't validate yet.
		try store.database.write { db in
			try SpaceRecord.find(spaceID.rawValue).update { $0.name = "Renamed" }.execute(db)
		}
		#expect(throws: Rejected.self) {
			try store.load { _ in throw Rejected() }
		}

		// A local edit saved before a reload succeeds writes only what this Mac changed.
		var edited: BrowserOrganization = organization
		edited.profiles[id: profileID]?.name = "Work"
		try store.save(edited, preferences: preferences(keyword: "first"))
		let saved: BrowserOrganization = try #require(try store.load()?.organization)
		#expect(saved.spaces.first?.name == "Renamed")
		#expect(saved.profiles.first?.name == "Work")
	}

	@Test
	func preferencesSavedWithoutTheirOrganizationAreTheNextSavesBase() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try store.save(organization, preferences: preferences(keyword: "first"))

		try cuttingOrganizationWrites(store) {
			#expect(throws: (any Error).self) {
				try store.save(organization, preferences: preferences(keyword: "second"))
			}
		}

		// Back to what was last saved in full: the preference rows that did land go back too.
		try store.save(organization, preferences: preferences(keyword: "first"))

		let keywords: [String] = try #require(try WorkspaceDatabase(directory: directory).load())
			.preferences.searchShortcuts.map(\.keyword)
		#expect(keywords.contains("first"))
		#expect(!keywords.contains("second"))
	}

	@Test
	func aFirstSaveCutShortBetweenTheFilesReadsAsEmpty() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try cuttingOrganizationWrites(store) {
			#expect(throws: (any Error).self) {
				try store.save(organization, preferences: preferences(keyword: "cut"))
			}
		}
		#expect(WorkspaceDatabase.contents(of: directory) == .empty)
		#expect(try WorkspaceDatabase(directory: directory).load() == nil)

		// The next first save, after a relaunch, replaces what it left.
		let reopened: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		#expect(try reopened.load() == nil)
		try reopened.save(organization, preferences: preferences(keyword: "next"))
		let keywords: [String] = try #require(try WorkspaceDatabase(directory: directory).load())
			.preferences.searchShortcuts.map(\.keyword)
		#expect(keywords.contains("next"))
		#expect(!keywords.contains("cut"))

		// A whole store again: losing its organization file is refused, as it always is.
		try FileManager.default.removeItem(at: directory.appendingPathComponent(WorkspaceDatabase.organizationFileName))
		#expect(throws: WorkspaceDatabase.Failure.partialStore) { try WorkspaceDatabase(directory: directory).load() }
	}

	@Test
	func aFirstSaveCutShortIsRetriedByTheSameRun() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try cuttingOrganizationWrites(store) {
			#expect(throws: (any Error).self) {
				try store.save(organization, preferences: preferences(keyword: "cut"))
			}
		}

		try store.save(organization, preferences: preferences(keyword: "next"))

		let loaded: WorkspaceDatabase.Snapshot = try #require(try WorkspaceDatabase(directory: directory).load())
		#expect(loaded.organization == organization)
		#expect(loaded.preferences.searchShortcuts.map(\.keyword).contains("next"))
		#expect(WorkspaceDatabase.contents(of: directory) == .workspace)
	}

	@Test
	func aMigrationCutShortBetweenTheFilesRunsAgainFromTheFile() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let file: URL = directory.appendingPathComponent("arx-workspace.json")
		let json: BrowserWorkspaceClient = .init(file: file, storage: .json)
		_ = try json.loadWithRecovery()
		try json.save(organization)
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try cuttingOrganizationWrites(store) {
			#expect(throws: (any Error).self) {
				try store.migrate(
					organization: organization,
					preferences: preferences(keyword: "cut"),
					fromWorkspaceVersion: 4,
					sourceRevision: 0
				)
			}
		}

		let client: BrowserWorkspaceClient = .init(file: file, storage: .sqlite, separatePreferencesConnection: true)
		#expect(try client.loadWithRecovery().organization == organization)
		#expect(client.storage == .sqlite)
		let migrated: WorkspaceDatabase.Snapshot = try #require(try WorkspaceDatabase(directory: directory).load())
		#expect(migrated.migratedFromWorkspaceVersion != nil)
		#expect(!migrated.preferences.searchShortcuts.map(\.keyword).contains("cut"))
	}

	/// Opens a write transaction on `path` on another thread, as another process in the middle of a
	/// write would, and returns once it holds the file's lock. It commits when `release` is signaled.
	private func holdWriteLock(on path: String, until release: DispatchSemaphore) throws -> Task<Void, any Error> {
		let queue: DatabaseQueue = try sharedQueue(path: path)
		let locked: DispatchSemaphore = .init(value: 0)
		let holder: Task<Void, any Error> = Task.detached {
			try queue.inDatabase { db in
				do {
					try db.execute(sql: "BEGIN IMMEDIATE")
				} catch {
					locked.signal()
					throw error
				}
				locked.signal()
				release.wait()
				try db.execute(sql: "COMMIT")
			}
		}
		locked.wait()
		return holder
	}

	/// Another connection to one of the store's files, which waits for the store's own writes as the
	/// store's connections do (DEV-1214). Without the busy timeout, a read that lands inside a save's
	/// write fails at once with "database is locked", which a busy Mac makes likely.
	private func sharedQueue(path: String) throws -> DatabaseQueue {
		var configuration: Configuration = .init()
		configuration.busyMode = .timeout(10)
		return try DatabaseQueue(path: path, configuration: configuration)
	}

	/// Polls until `condition` holds, and fails the test if it never does. A fixed number of polls
	/// ran out on a busy Mac and let the test go on before the first save had reached its mark.
	private func waitUntil(_ condition: () throws -> Bool) async throws {
		let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(60))
		while try !condition() {
			try #require(ContinuousClock.now < deadline, "The first save never reached its mark")
			try await Task.sleep(for: .milliseconds(10))
		}
	}

	/// The preferences file's copy of a ``StoreInfoKey``.
	private func storeInfo(_ key: String, in queue: DatabaseQueue) throws -> String? {
		try queue.read { db in try PreferenceStoreInfoRecord.find(key).fetchOne(db)?.value }
	}

	@Test
	func aSaveFromAnotherProcessWaitsForTheWholeSaveBeforeIt() async throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let organization: BrowserOrganization = organization
		let firstPreferences: BrowserPreferences = preferences(keyword: "first")
		let secondPreferences: BrowserPreferences = preferences(keyword: "second")
		let first: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try first.save(organization, preferences: preferences(keyword: "base"))

		// Another process's store on the same files.
		let second: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		_ = try second.load()

		// The organization file is busy, so the first save stops between its two files.
		let release: DispatchSemaphore = .init(value: 0)
		let blocker: Task<Void, any Error> = try holdWriteLock(on: first.organizationFile.path, until: release)
		let firstSave: Task<Void, any Error> = Task.detached {
			try first.save(organization, preferences: firstPreferences)
		}
		let preferencesFile: DatabaseQueue = try sharedQueue(path: first.preferencesFile.path)
		try await waitUntil { try storeInfo(StoreInfoKey.revision, in: preferencesFile) == "2" }
		let secondSave: Task<Void, any Error> = Task.detached {
			try second.save(organization, preferences: secondPreferences)
		}
		try await Task.sleep(for: .milliseconds(300))
		release.signal()
		try await blocker.value

		try await firstSave.value
		await #expect(throws: WorkspaceDatabase.Failure.changedOnDisk) { try await secondSave.value }
		let keywords: [String] = try #require(try WorkspaceDatabase(directory: directory).load())
			.preferences.searchShortcuts.map(\.keyword)
		#expect(keywords.contains("first"))
		#expect(!keywords.contains("second"))
	}

	@Test
	func twoFirstSavesAtOnceLeaveOneWholeStore() async throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let organization: BrowserOrganization = organization
		let firstPreferences: BrowserPreferences = preferences(keyword: "first")
		let secondPreferences: BrowserPreferences = preferences(keyword: "second")
		let first: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		let second: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		#expect(try first.load() == nil)
		#expect(try second.load() == nil)

		// The first save stops between its two files, its mark in the preferences file.
		let release: DispatchSemaphore = .init(value: 0)
		let blocker: Task<Void, any Error> = try holdWriteLock(on: first.organizationFile.path, until: release)
		let firstSave: Task<Void, any Error> = Task.detached {
			try first.save(organization, preferences: firstPreferences)
		}
		let preferencesFile: DatabaseQueue = try sharedQueue(path: first.preferencesFile.path)
		try await waitUntil { try storeInfo(StoreInfoKey.unfinishedFirstWrite, in: preferencesFile) != nil }

		// The other first save doesn't take it for one cut short.
		let secondSave: Task<Void, any Error> = Task.detached {
			try second.save(organization, preferences: secondPreferences)
		}
		try await Task.sleep(for: .milliseconds(300))
		release.signal()
		try await blocker.value

		try await firstSave.value
		await #expect(throws: WorkspaceDatabase.Failure.changedOnDisk) { try await secondSave.value }
		let loaded: WorkspaceDatabase.Snapshot = try #require(try WorkspaceDatabase(directory: directory).load())
		#expect(loaded.preferences.searchShortcuts.map(\.keyword).contains("first"))
		#expect(!loaded.preferences.searchShortcuts.map(\.keyword).contains("second"))
	}

	@Test
	func aProfileThisMacRetiredStaysOutWhenSyncBringsItBack() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let client: BrowserWorkspaceClient = .init(
			file: directory.appendingPathComponent("arx-workspace.json"),
			storage: .sqlite,
			separatePreferencesConnection: true
		)
		_ = try client.loadWithRecovery()
		let retiredID: Profile.ID = .init(rawValue: UUID(-4))
		var withRetired: BrowserOrganization = organization
		withRetired.profiles.append(.init(id: retiredID, name: "Old"))
		withRetired.spaces.append(.init(id: .init(rawValue: UUID(-5)), profileID: retiredID, name: "Old"))
		try client.save(withRetired, preferences: preferences(keyword: "first"))

		// This Mac retired the profile, and another Mac's offline edit brought its rows back.
		let store: WorkspaceDatabase = try #require(client.workspaceDatabase)
		try store.database.write { db in
			try RetiredProfileRecord.insert { RetiredProfileRecord(id: retiredID.rawValue) }.execute(db)
		}

		let reloaded: BrowserOrganization = try #require(try client.reloadDatabase()?.organization)
		#expect(reloaded.profiles.map(\.id) == [profileID])
		#expect(reloaded.spaces.map(\.id) == [spaceID])
		#expect(reloaded.retiredProfileIDs == [retiredID])
		// And at the next launch.
		#expect(try WorkspaceDatabase(directory: directory).load()?.organization.profiles.map(\.id) == [profileID])
	}

	@Test
	func theClientReadsWhatSyncWroteToTheDatabase() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let client: BrowserWorkspaceClient = .init(
			file: directory.appendingPathComponent("arx-workspace.json"),
			storage: .sqlite,
			separatePreferencesConnection: true
		)
		_ = try client.loadWithRecovery()
		try client.save(organization, preferences: preferences(keyword: "first"))
		let store: WorkspaceDatabase = try #require(client.workspaceDatabase)
		#expect(store.preferencesDatabase != nil)

		// Another Mac renamed the space, as an engine writes it.
		try store.database.write { db in
			try SpaceRecord.find(spaceID.rawValue).update { $0.name = "Renamed" }.execute(db)
		}
		let reloaded: BrowserWorkspaceClient.Recovery = try #require(try client.reloadDatabase())
		let renamed: BrowserOrganization = try #require(reloaded.organization)
		#expect(renamed.spaces.first?.name == "Renamed")

		// Saving what was read keeps the change.
		try client.save(renamed, preferences: reloaded.preferences)
		#expect(try client.reloadDatabase()?.organization?.spaces.first?.name == "Renamed")
	}
}

/// Counts changes to preference tables made on the connection it observes.
private final class PreferenceWrites: TransactionObserver, @unchecked Sendable {
	let count: LockIsolated<Int> = .init(0)

	func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
		[SearchShortcutRecord.tableName, PreferenceRecord.tableName, KeyboardShortcutRecord.tableName, LocalPreferenceRecord.tableName]
			.contains(eventKind.tableName)
	}

	func databaseDidChange(with event: DatabaseEvent) {
		count.withValue { $0 += 1 }
	}

	func databaseDidCommit(_ db: Database) {}

	func databaseDidRollback(_ db: Database) {}
}
