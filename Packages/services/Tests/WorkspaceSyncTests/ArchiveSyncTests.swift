import BrowserCore
import ConcurrencyExtras
import Foundation
import GRDB
@testable import SQLiteData
import Testing
@testable import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// Tab Archive in its own file and sync category (DEV-983): off by default, and a restore on one Mac
/// leaves the entry on the others.
@Suite(.timeLimit(.minutes(1)))
struct ArchiveSyncTests {
	private let profileID: Profile.ID = .init(rawValue: UUID(-1))
	private let spaceID: Space.ID = .init(rawValue: UUID(-2))
	private let entryID: ArchivedTab.ID = .init(rawValue: UUID(-3))

	private var organization: BrowserOrganization {
		.init(
			profiles: [.init(id: profileID, name: "Personal")],
			legacyProfileID: profileID,
			spaces: [.init(id: spaceID, profileID: profileID, name: "Home")]
		)
	}

	private func archived(_ id: ArchivedTab.ID, _ title: String, tab: UUID) -> ArchivedTab {
		.init(
			id: id,
			groupID: UUID(-10),
			closedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.25),
			originalSpaceID: spaceID,
			originalSpaceName: "Home",
			originalIndex: 0,
			tab: .init(
				id: .init(rawValue: tab),
				profileID: profileID,
				restoration: .init(title: title, url: URL(string: "https://\(title.lowercased()).example")!),
				customTitle: "Named"
			)
		)
	}

	private var withEntry: BrowserOrganization {
		var organization: BrowserOrganization = organization
		organization.archive = [archived(entryID, "Read", tab: UUID(-4))]
		return organization
	}

	/// One Mac: its store with iCloud sync on its connections, on `cloud`.
	private struct Mac {
		let directory: URL
		let store: WorkspaceDatabase
		let sync: WorkspaceSync

		init(cloud: TestCloud) throws {
			self.directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("ArchiveSyncTests-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			self.store = try .init(directory: directory, separatePreferencesConnection: true)
			self.sync = try WorkspaceSync(
				organization: store.database,
				preferences: try #require(store.preferencesDatabase),
				archive: try #require(store.archiveDatabase),
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

		func send() async throws {
			try await sync.engine(.archive)?.sendChanges()
		}

		func fetch() async throws {
			try await sync.engine(.archive)?.fetchChanges()
			try await sync.repair(.archive)
		}

		var archive: [ArchivedTab] {
			get throws { try store.load()?.organization.archive ?? [] }
		}

		func remove() {
			TestFolders.removeAtExit(directory)
		}
	}

	private func twoMacs(
		_ cloud: TestCloud,
		archiveSyncs: Bool
	) async throws -> (Mac, Mac) {
		let a: Mac = try .init(cloud: cloud)
		let b: Mac = try .init(cloud: cloud)
		for mac in [a, b] {
			try mac.store.save(organization, preferences: .init())
			await mac.sync.setEnabled(true)
			if archiveSyncs {
				await mac.sync.setCategory(.archive, isEnabled: true)
			}
		}
		return (a, b)
	}

	@Test
	func anEntryArchivedOnOneMacReachesTheOtherOnce() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud, archiveSyncs: true)
		defer {
			a.remove()
			b.remove()
		}

		_ = try a.store.load()
		try a.store.save(withEntry, preferences: .init())
		try await a.send()
		try await b.fetch()

		#expect(try b.archive == withEntry.archive)
	}

	@Test
	func tabArchiveStaysOnEachMacUntilTurnedOn() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud, archiveSyncs: false)
		defer {
			a.remove()
			b.remove()
		}

		#expect(await a.sync.status[.archive] == .off)
		_ = try a.store.load()
		try a.store.save(withEntry, preferences: .init())
		try await a.send()
		try await b.fetch()

		#expect(try b.archive.isEmpty)
		#expect(!cloud.records(.archive).contains { $0.recordType == ArchiveEntryRecord.tableName })
	}

	@Test
	func restoringOnOneMacLeavesTheEntryOnTheOther() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud, archiveSyncs: true)
		defer {
			a.remove()
			b.remove()
		}

		_ = try a.store.load()
		try a.store.save(withEntry, preferences: .init())
		try await a.send()
		try await b.fetch()

		// A restores it: gone from A's Tab Archive, still on B's and in iCloud.
		_ = try a.store.load()
		try a.store.save(organization, preferences: .init())
		try await a.send()
		try await b.fetch()
		#expect(try a.archive.isEmpty)
		#expect(try b.archive.map(\.id) == [entryID])
		#expect(cloud.records(.archive).contains { $0.recordType == ArchiveEntryRecord.tableName })
	}

	@Test
	func anEntryEveryMacRestoredGoesEverywhere() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud, archiveSyncs: true)
		defer {
			a.remove()
			b.remove()
		}

		_ = try a.store.load()
		try a.store.save(withEntry, preferences: .init())
		try await a.send()
		try await b.fetch()
		try await b.send()
		try await a.fetch()

		_ = try a.store.load()
		try a.store.save(organization, preferences: .init())
		try await a.send()
		try await b.fetch()
		_ = try b.store.load()
		try b.store.save(organization, preferences: .init())
		try await b.send()
		try await a.fetch()
		try await a.send()
		try await b.fetch()

		let rows: Int = try await a.store.archiveDatabase!.read { db in try ArchiveEntryRecord.all.fetchCount(db) }
		#expect(rows == 0)
		#expect(!cloud.records(.archive).contains { $0.recordType == ArchiveEntryRecord.tableName })
	}

	private func syncedStore() throws -> (URL, WorkspaceDatabase) {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ArchiveSyncTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return (directory, try .init(directory: directory, separatePreferencesConnection: true))
	}

	@Test
	func twoEntriesForOneTabShowAsTheLatest() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try syncedStore()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(withEntry, preferences: .init())

		// Another Mac archived the same tab again later, under another entry.
		var later: ArchivedTab = archived(.init(rawValue: UUID(-5)), "Read", tab: UUID(-4))
		later = .init(
			id: later.id,
			groupID: later.groupID,
			closedAt: later.closedAt.addingTimeInterval(60),
			originalSpaceID: later.originalSpaceID,
			originalSpaceName: later.originalSpaceName,
			originalIndex: later.originalIndex,
			tab: later.tab
		)
		try #require(store.archiveDatabase).write { db in
			try ArchiveEntryRecord.insert { ArchiveEntryRecord(later, position: "W") }.execute(db)
		}

		#expect(try store.load()?.organization.archive == [later])
	}

	@Test
	func anEntryAddedBackShowsAgain() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try syncedStore()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization, preferences: .init())
		try #require(store.archiveDatabase).write { db in
			try ArchiveStateRecord.insert { ArchiveStateRecord(id: ArchiveStateKey.deletionsStayLocal, value: "1") }.execute(db)
		}
		try store.save(withEntry, preferences: .init())

		// Restored: hidden here.
		try store.save(organization, preferences: .init())
		#expect(try store.load()?.organization.archive.isEmpty == true)

		// Undone: the same entry, with nothing else removed.
		try store.save(withEntry, preferences: .init())
		#expect(try store.load()?.organization.archive == withEntry.archive)
		#expect(try WorkspaceDatabase(directory: directory).load()?.organization.archive == withEntry.archive)
	}

	@Test
	func aFirstSaveCutShortAfterTheArchiveReadsAsEmpty() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try syncedStore()
		defer { TestFolders.removeAtExit(directory) }

		// The archive's rows landed; the other files didn't.
		try #require(store.archiveDatabase).write { db in
			try ArchiveEntryRecord.insert { ArchiveEntryRecord(withEntry.archive[0], position: "V") }.execute(db)
		}

		#expect(try store.load() == nil)
		try store.save(organization, preferences: .init())
		#expect(try store.load()?.organization.archive.isEmpty == true)
	}

	@Test
	func aRestoreCutShortBeforeTheArchiveFileIsFinishedOnOpen() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try syncedStore()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(withEntry, preferences: .init())

		// The organization file took the restore and its archive change; the archive file didn't yet.
		let change: PendingArchiveChange = .init(upserted: [], removed: [entryID.rawValue], deviceID: nil)
		try store.database.write { db in
			let value: String = try JSONColumn.encode(change)
			try StoreInfoRecord.upsert {
				StoreInfoRecord(id: StoreInfoKey.pendingArchive, value: value)
			}
			.execute(db)
		}

		let reopened: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		#expect(try reopened.load()?.organization.archive.isEmpty == true)
		#expect(try reopened.database.read { db in try StoreInfoRecord.find(StoreInfoKey.pendingArchive).fetchOne(db) } == nil)
	}

	private func leavePendingRemoval(_ store: WorkspaceDatabase) throws {
		let change: PendingArchiveChange = .init(upserted: [], removed: [entryID.rawValue], deviceID: nil)
		let value: String = try JSONColumn.encode(change)
		try store.database.write { db in
			try StoreInfoRecord.upsert { StoreInfoRecord(id: StoreInfoKey.pendingArchive, value: value) }.execute(db)
		}
	}

	@Test
	func aPendingArchiveChangeIsFinishedWithoutSyncToo() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try syncedStore()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(withEntry, preferences: .init())
		try leavePendingRemoval(store)

		// Opened again with sync off: the attached copy takes the change.
		let reopened: WorkspaceDatabase = try .init(directory: directory)
		#expect(try reopened.load()?.organization.archive.isEmpty == true)
		#expect(try reopened.database.read { db in try StoreInfoRecord.find(StoreInfoKey.pendingArchive).fetchOne(db) } == nil)
	}

	@Test
	func aSaveWithNothingNewFinishesAPendingArchiveChange() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try syncedStore()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(withEntry, preferences: .init())
		try store.save(organization, preferences: .init())

		// As if the archive file had refused the restore's write.
		try #require(store.archiveDatabase).write { db in
			try ArchiveEntryRecord.insert { ArchiveEntryRecord(withEntry.archive[0], position: "V") }.execute(db)
		}
		try leavePendingRemoval(store)

		try store.save(organization, preferences: .init())
		let rows: Int = try #require(store.archiveDatabase).read { db in try ArchiveEntryRecord.all.fetchCount(db) }
		#expect(rows == 0)
	}

	@Test
	func aLostArchiveFileIsAPartialStore() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try syncedStore()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(withEntry, preferences: .init())
		try store.database.close()
		try store.preferencesDatabase?.close()
		try store.archiveDatabase?.close()
		try FileManager.default.removeItem(at: directory.appendingPathComponent(WorkspaceDatabase.archiveFileName))

		#expect(throws: WorkspaceDatabase.Failure.partialStore) {
			_ = try WorkspaceDatabase(directory: directory)
		}
	}

	@Test
	func withoutSyncARemovalIsHiddenOnceTabArchiveSynced() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try syncedStore()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(withEntry, preferences: .init())
		try #require(store.archiveDatabase).write { db in
			try ArchiveStateRecord.insert { ArchiveStateRecord(id: ArchiveStateKey.deletionsStayLocal, value: "1") }.execute(db)
		}

		// Opened with sync off, as with the feature flag off again: a restore still hides the entry.
		let local: WorkspaceDatabase = try .init(directory: directory)
		_ = try local.load()
		try local.save(organization, preferences: .init())
		#expect(try local.load()?.organization.archive.isEmpty == true)
		let rows: Int = try local.database.read { db in
			try Int.fetchOne(db, sql: #"SELECT count(*) FROM "archive"."archiveEntry""#) ?? 0
		}
		#expect(rows == 1)

		// And archiving it again shows it.
		try local.save(withEntry, preferences: .init())
		#expect(try WorkspaceDatabase(directory: directory).load()?.organization.archive == withEntry.archive)
	}

	@Test
	func phaseOneArchiveMovesIntoItsOwnFile() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ArchiveSyncTests-\(UUID().uuidString)")
		defer { TestFolders.removeAtExit(directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let entry: ArchivedTab = archived(entryID, "Read", tab: UUID(-4))
		do {
			let store: WorkspaceDatabase = try .init(directory: directory)
			try store.save(organization, preferences: .init())

			// The entry as phase 1 kept it: JSON in the organization file.
			let json: String = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
			try store.database.write { db in
				try db.execute(
					sql: #"INSERT INTO "main"."archivedTab" ("id", "value", "position") VALUES (?, ?, 'V')"#,
					arguments: [entryID.rawValue.uuidString.lowercased(), json]
				)
			}
		}

		let reopened: WorkspaceDatabase = try .init(directory: directory)
		#expect(try reopened.load()?.organization.archive == [entry])
		let left: Int = try reopened.database.read { db in
			try Int.fetchOne(db, sql: #"SELECT count(*) FROM "main"."archivedTab""#) ?? -1
		}
		#expect(left == 0)
		#expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(WorkspaceDatabase.archiveFileName).path))
	}
}
