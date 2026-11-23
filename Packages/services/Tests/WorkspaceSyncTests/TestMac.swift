import CloudKit
import ConcurrencyExtras
import Foundation
import HistoryDatabase
@testable import SQLiteData
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport
import os

/// One iCloud account's private database, which every ``TestMac`` of a test shares: SQLiteData's
/// mock container, reached with `@testable` because the library keeps it `package`.
final class TestCloud: @unchecked Sendable {
	let container: MockCloudContainer

	/// Makes the next zone deletions fail, as without a network.
	let failsZoneDeletion: LockIsolated<Bool> = .init(false)

	/// Deletes the zone but loses the reply, so the caller sees an error.
	let losesZoneDeletionReply: LockIsolated<Bool> = .init(false)

	init() {
		let privateDatabase: MockCloudDatabase = .init(databaseScope: .private)
		let sharedDatabase: MockCloudDatabase = .init(databaseScope: .shared)
		self.container = .init(
			containerIdentifier: "iCloud.dev.capturecontext.arx.tests.\(UUID())",
			privateCloudDatabase: privateDatabase,
			sharedCloudDatabase: sharedDatabase
		)
		privateDatabase.set(container: container)
		sharedDatabase.set(container: container)
	}

	/// Records stored in `category`'s zone.
	func records(_ category: SyncCategory) -> [CKRecord] {
		container.privateCloudDatabase.state.withValue { state in
			state.storage[CKRecordZone.ID(zoneName: category.zoneName)].map { Array($0.records.values) } ?? []
		}
	}

	func hasZone(_ category: SyncCategory) -> Bool {
		container.privateCloudDatabase.state.withValue { state in
			state.storage[CKRecordZone.ID(zoneName: category.zoneName)] != nil
		}
	}

	/// Fails, as offline, while `isOffline` is set.
	let isOffline: LockIsolated<Bool> = .init(false)

	func placements(
		_ records: Set<WorkspaceRepair.PlacementRecord>
	) throws -> [WorkspaceRepair.PlacementRecord: WorkspaceRepair.Placement] {
		struct Offline: Error {}
		if isOffline.value { throw Offline() }
		let zoneID: CKRecordZone.ID = .init(zoneName: SyncCategory.organization.zoneName)
		var result: [WorkspaceRepair.PlacementRecord: WorkspaceRepair.Placement] = [:]
		for record in records {
			let id: CKRecord.ID = .init(recordName: record.recordName, zoneID: zoneID)
			if let ckRecord = try? container.privateCloudDatabase.record(for: id) {
				result[record] = record.placement(of: ckRecord)
			} else {
				result[record] = .missing
			}
		}
		return result
	}

	func recordValues(
		_ zoneName: String,
		_ recordNames: [String]
	) throws -> [String: [String: String]] {
		struct Offline: Error {}
		if isOffline.value { throw Offline() }
		let zoneID: CKRecordZone.ID = .init(zoneName: zoneName)
		var values: [String: [String: String]] = [:]
		for name in recordNames {
			if let record = try? container.privateCloudDatabase.record(for: CKRecord.ID(recordName: name, zoneID: zoneID)) {
				values[name] = record.textValues()
			}
		}
		return values
	}

	func zoneRecords(
		_ zoneName: String,
		_ fields: [String]
	) throws -> [CloudAccess.ZoneRecord] {
		struct Offline: Error {}
		if isOffline.value { throw Offline() }
		let wanted: Set<String> = Set(fields)
		return container.privateCloudDatabase.state.withValue { state in
			(state.storage[CKRecordZone.ID(zoneName: zoneName)]?.records.values).map { records in
				records.map { record in
					.init(
						name: record.recordID.recordName,
						type: record.recordType,
						fields: record.textValues().filter { wanted.contains($0.key) }
					)
				}
			} ?? []
		}
	}

	func deleteZone(_ zoneName: String) throws {
		struct Offline: Error {}
		if failsZoneDeletion.value { throw Offline() }
		_ = try container.privateCloudDatabase.modifyRecordZones(
			deleting: [CKRecordZone.ID(zoneName: zoneName)]
		)
		if losesZoneDeletionReply.value { throw Offline() }
	}

	/// The device directory's engine on the shared mock database (DEV-979).
	func makeDirectoryEngine() -> WorkspaceSync.MakeDirectoryEngine {
		let container: MockCloudContainer = container
		return { writer, delegate in
			let engine: SyncEngine = try .init(
				container: container,
				defaultZone: CKRecordZone(zoneName: DeviceDirectory.zoneName),
				defaultSyncEngines: { _, engine in
					(
						private: MockSyncEngine(
							database: container.privateCloudDatabase,
							parentSyncEngine: engine,
							state: MockSyncEngineState()
						),
						shared: MockSyncEngine(
							database: container.sharedCloudDatabase,
							parentSyncEngine: engine,
							state: MockSyncEngineState()
						)
					)
				},
				userDatabase: UserDatabase(database: writer),
				logger: Logger(.disabled),
				delegate: delegate,
				tables: [SynchronizedTable(for: DeviceDirectoryRecord.self)]
			)
			try engine.setUpSyncEngine()
			return engine
		}
	}

	/// Engines on the shared mock database, as `WorkspaceSync.liveEngine` makes them on CloudKit.
	func makeEngine() -> WorkspaceSync.MakeEngine {
		let container: MockCloudContainer = container
		return { category, writer, delegate in
			let tables: [any SynchronizableTable] = switch category {
			case .organization:
				[
					SynchronizedTable(for: ProfileRecord.self),
					SynchronizedTable(for: SpaceRecord.self),
					SynchronizedTable(for: FolderRecord.self),
					SynchronizedTable(for: PinnedTabRecord.self),
					SynchronizedTable(for: FavoriteRecord.self),
					SynchronizedTable(for: DeletionRecord.self),
					SynchronizedTable(for: UsageRecord.self),
					SynchronizedTable(for: SyncDeviceRecord.self),
					SynchronizedTable(for: MergedItemRecord.self),
				]

			case .preferences:
				[
					SynchronizedTable(for: PreferenceRecord.self),
					SynchronizedTable(for: SearchShortcutRecord.self),
					SynchronizedTable(for: KeyboardShortcutRecord.self),
					SynchronizedTable(for: RoutingRuleRecord.self),
					SynchronizedTable(for: ProxyLinkRuleRecord.self),
				]

			case .history:
				[
					SynchronizedTable(for: HistoryVisitRecord.self),
					SynchronizedTable(for: HistoryClearRecord.self),
				]

			case .archive:
				[
					SynchronizedTable(for: ArchiveEntryRecord.self),
					SynchronizedTable(for: ArchiveDeletionRecord.self),
					SynchronizedTable(for: ArchiveDeviceRecord.self),
				]
			}
			let engine: SyncEngine = try .init(
				container: container,
				defaultZone: CKRecordZone(zoneName: category.zoneName),
				defaultSyncEngines: { _, engine in
					(
						private: MockSyncEngine(
							database: container.privateCloudDatabase,
							parentSyncEngine: engine,
							state: MockSyncEngineState()
						),
						shared: MockSyncEngine(
							database: container.sharedCloudDatabase,
							parentSyncEngine: engine,
							state: MockSyncEngineState()
						)
					)
				},
				userDatabase: UserDatabase(database: writer),
				logger: Logger(.disabled),
				delegate: delegate,
				tables: tables
			)
			try engine.setUpSyncEngine()
			return engine
		}
	}
}

/// One Mac: its own workspace databases in a temporary folder, and its own ``WorkspaceSync``.
struct TestMac: Sendable {
	let directory: URL
	let organization: DatabaseQueue
	let preferences: DatabaseQueue
	let history: HistoryDatabase

	/// Tab Archive's file, which this Mac's sync is given only with `syncsArchive`: ArchiveSyncTests cover the rest.
	let archive: DatabaseQueue

	/// The device directory (DEV-979).
	let devices: DatabaseQueue
	let sync: WorkspaceSync

	/// The account the Mac is signed in to, as ``CloudAccess`` reports it.
	let account: LockIsolated<CloudAccess.Account>

	/// How often sync asked for the account, which only happens once sync is on.
	let accountReads: LockIsolated<Int>

	/// Makes account reads fail, as offline.
	let accountFails: LockIsolated<Bool>

	/// Makes sending the device directory's changes throw, as offline.
	let directorySendFails: LockIsolated<Bool>

	/// Makes a rejoin's fetch throw after it applied what it fetched, as a connection that drops or a
	/// Mac that quits partway (DEV-1148).
	let rejoinFetchFails: LockIsolated<Bool>

	/// Makes a rejoin's fetch never return after it applied what it fetched, as when Arx quits
	/// partway.
	let rejoinFetchHangs: LockIsolated<Bool>

	/// Runs right before a rejoin's fetch, as the person acting while it starts.
	let beforeRejoinFetch: LockIsolated<(@Sendable () throws -> Void)?>

	/// - Parameters:
	///   - directory: an earlier Mac's folder, to launch it again; a new one by default.
	///   - hasHistory: `false` runs without the history database, as when it doesn't open.
	///   - syncsArchive: gives sync Tab Archive's file, which tests then write directly.
	///   - mergesWhenJoining: the `ARX_ICLOUD_SYNC_MERGE` feature flag (DEV-1216), off for the tests
	///     of what came before it.
	init(
		cloud: TestCloud,
		account: String = "account-a",
		directory: URL? = nil,
		hasHistory: Bool = true,
		syncsArchive: Bool = false,
		name: String = "Test Mac",
		mergesWhenJoining: Bool = false
	) throws {
		self.directory = directory ?? FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceSyncTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)

		// As the app's connections: a Mac launched again on the same files can meet the earlier run's.
		var configuration: Configuration = .init()
		configuration.busyMode = .timeout(10)
		self.organization = try DatabaseQueue(
			path: self.directory.appendingPathComponent(WorkspaceDatabaseFiles.organization).path,
			configuration: configuration
		)
		try WorkspaceSchema.organizationMigrator().migrate(organization)
		self.preferences = try DatabaseQueue(
			path: self.directory.appendingPathComponent(WorkspaceDatabaseFiles.preferences).path,
			configuration: configuration
		)
		try WorkspaceSchema.preferencesMigrator().migrate(preferences)
		self.history = try HistoryDatabase(directory: self.directory)
		self.archive = try DatabaseQueue(
			path: self.directory.appendingPathComponent(WorkspaceDatabase.archiveFileName).path,
			configuration: configuration
		)
		try WorkspaceSchema.archiveMigrator().migrate(archive)
		self.devices = try DeviceDirectory.open(in: self.directory)

		let accountState: LockIsolated<CloudAccess.Account> = .init(.available(account))
		let accountReads: LockIsolated<Int> = .init(0)
		let accountFails: LockIsolated<Bool> = .init(false)
		self.account = accountState
		self.accountReads = accountReads
		self.accountFails = accountFails
		let directorySendFails: LockIsolated<Bool> = .init(false)
		self.directorySendFails = directorySendFails
		let rejoinFetchFails: LockIsolated<Bool> = .init(false)
		self.rejoinFetchFails = rejoinFetchFails
		let rejoinFetchHangs: LockIsolated<Bool> = .init(false)
		self.rejoinFetchHangs = rejoinFetchHangs
		let beforeRejoinFetch: LockIsolated<(@Sendable () throws -> Void)?> = .init(nil)
		self.beforeRejoinFetch = beforeRejoinFetch
		self.sync = try WorkspaceSync(
			organization: organization,
			preferences: preferences,
			history: hasHistory ? history.database : nil,
			archive: syncsArchive ? archive : nil,
			devices: devices,
			settings: SyncSettingsStore(directory: self.directory),
			cloud: CloudAccess(
				account: {
					struct Offline: Error {}
					accountReads.withValue { $0 += 1 }
					if accountFails.value { throw Offline() }
					return accountState.value
				},
				deleteZone: { zoneName in try cloud.deleteZone(zoneName) },
				placements: { records in try cloud.placements(records) },
				recordValues: { zoneName, recordNames in try cloud.recordValues(zoneName, recordNames) },
				zoneRecords: { zoneName, fields in try cloud.zoneRecords(zoneName, fields) }
			),
			makeEngine: cloud.makeEngine(),
			makeDirectoryEngine: cloud.makeDirectoryEngine(),
			sendDirectoryChanges: { engine in
				struct Offline: Error {}
				if directorySendFails.value { throw Offline() }
				try await engine.sendChanges()
			},
			fetchRejoinChanges: { _, engine in
				struct Interrupted: Error {}
				try beforeRejoinFetch.value?()
				try await engine.fetchChanges()
				while rejoinFetchHangs.value {
					try? await Task.sleep(for: .milliseconds(20))
				}
				if rejoinFetchFails.value { throw Interrupted() }
			},
			deviceName: { name },
			accountRetryDelay: .milliseconds(20),
			mergesWhenJoining: mergesWhenJoining
		)
	}

	func writer(_ category: SyncCategory) -> DatabaseQueue {
		switch category {
		case .organization: organization
		case .preferences: preferences
		case .history: history.database
		case .archive: archive
		}
	}

	/// Sends this Mac's pending changes for every running category, and the device directory's.
	func send() async throws {
		for category in SyncCategory.allCases {
			try await sync.engine(category)?.sendChanges()
		}
		if let directory = await sync.directoryEngineForDiagnostics(), directory.isRunning {
			try await directory.sendChanges()
		}
	}

	/// Fetches iCloud's changes for every running category and runs the repair pass, as the batch
	/// observer does in the app.
	func fetch() async throws {
		for category in SyncCategory.allCases {
			guard let engine = await sync.engine(category), engine.isRunning else { continue }

			try await engine.fetchChanges()
			try await sync.repair(category)
		}

		// The directory last: the mock database hands each deletion to whichever engine fetches next,
		// and every engine fetches the whole private database.
		if let directory = await sync.directoryEngineForDiagnostics(), directory.isRunning {
			try await directory.fetchChanges()
		}
	}

	/// Delivers an account event the way CKSyncEngine does, to every running engine.
	func accountEvent(_ change: CKSyncEngine.Event.AccountChange.ChangeType) async {
		for category in SyncCategory.allCases {
			guard
				let engine = await sync.engine(category),
				let privateEngine = engine.syncEngines.private
			else { continue }

			await engine.handleEvent(.accountChange(changeType: change), syncEngine: privateEngine)
		}
		await directoryAccountEvent(change)
	}

	/// Delivers an account event to the device directory's engine alone, as when it's the only one
	/// running.
	func directoryAccountEvent(_ change: CKSyncEngine.Event.AccountChange.ChangeType) async {
		guard
			let engine = await sync.directoryEngineForDiagnostics(),
			let privateEngine = engine.syncEngines.private
		else { return }

		await engine.handleEvent(.accountChange(changeType: change), syncEngine: privateEngine)
	}

	/// Another Mac deleted `category`'s zone, as this Mac's engine learns it from a fetch.
	func zoneDeletedElsewhere(_ category: SyncCategory) async {
		guard
			let engine = await sync.engine(category),
			let privateEngine = engine.syncEngines.private
		else { return }

		await engine.handleEvent(
			.fetchedDatabaseChanges(
				modifications: [],
				deletions: [(zoneID: CKRecordZone.ID(zoneName: category.zoneName), reason: .deleted)]
			),
			syncEngine: privateEngine
		)
	}

	/// Deletes this Mac's folder once the tests end, since its sync may still be starting an engine.
	func remove() {
		TestFolders.removeAtExit(directory)
	}
}

/// The phase 1 file names, without depending on its store type.
enum WorkspaceDatabaseFiles {
	static let organization: String = "arx-organization.sqlite"
	static let preferences: String = "arx-preferences.sqlite"
}

/// Rounds of sending and fetching between two Macs until neither has anything left to exchange.
/// Each Mac fetches right after the other sends, so the mock database hands every deletion to the
/// Mac that didn't make it.
func converge(
	_ first: TestMac,
	_ second: TestMac,
	rounds: Int = 3
) async throws {
	for _ in 0 ..< rounds {
		try await first.send()
		try await second.fetch()
		try await second.send()
		try await first.fetch()
	}
}

/// Every synced organization row, comparable between Macs.
struct OrganizationRows: Equatable {
	var profiles: [ProfileRecord]
	var spaces: [SpaceRecord]
	var folders: [FolderRecord]
	var pinnedTabs: [PinnedTabRecord]
	var favorites: [FavoriteRecord]

	init(_ writer: DatabaseQueue) throws {
		(profiles, spaces, folders, pinnedTabs, favorites) = try writer.read { db in
			(
				try ProfileRecord.order(by: \.id).fetchAll(db),
				try SpaceRecord.order(by: \.id).fetchAll(db),
				try FolderRecord.order(by: \.id).fetchAll(db),
				try PinnedTabRecord.order(by: \.id).fetchAll(db),
				try FavoriteRecord.order(by: \.id).fetchAll(db)
			)
		}
	}
}

/// Every synced preference row, comparable between Macs.
struct PreferenceRows: Equatable {
	var preferences: [PreferenceRecord]
	var searchShortcuts: [SearchShortcutRecord]
	var keyboardShortcuts: [KeyboardShortcutRecord]

	init(_ writer: DatabaseQueue) throws {
		(preferences, searchShortcuts, keyboardShortcuts) = try writer.read { db in
			(
				try PreferenceRecord.order(by: \.id).fetchAll(db),
				try SearchShortcutRecord.order(by: \.id).fetchAll(db),
				try KeyboardShortcutRecord.order(by: \.id).fetchAll(db)
			)
		}
	}
}

/// A local edit on `writer`, as Arx's own code writes, which may delete synced rows
/// (``SyncedDeletions``). Per-column last-writer-wins compares the writing Mac's clock, so a test
/// orders concurrent edits by making them one after the other.
func edit<T: Sendable>(
	_ writer: DatabaseQueue,
	_ updates: @Sendable (Database) throws -> T
) throws -> T {
	try writer.writeAllowingSyncedDeletions(updates)
}
