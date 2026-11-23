import CloudKit
import Foundation
@testable import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// A first upload iCloud refuses (DEV-1207). On 18 November 2026 a Release Arx turned sync on against
/// a Production container without Arx's schema: every save failed, the profiles with an error the
/// library drops, and every record whose parent is a profile or space with `referenceViolation`.
/// SQLiteData 1.13 takes that as "the parent was deleted on the server" and deletes the row here as
/// a user deletion, with its cascade, and queues the deletions for iCloud: every space, folder, pin
/// and Favorite went.
@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct RefusedSaveTests {
	private let profileID: UUID = UUID(1)
	private let spaceID: UUID = UUID(2)
	private let otherSpaceID: UUID = UUID(3)
	private let folderID: UUID = UUID(10)
	private let tabID: UUID = UUID(20)
	private let otherTabID: UUID = UUID(21)
	private let favoriteID: UUID = UUID(30)
	private let openTabID: UUID = UUID(40)

	private func seed(_ mac: TestMac) throws {
		try edit(mac.organization) { db in
			try db.seed {
				ProfileRecord(id: profileID, name: "Personal", position: "V")
				SpaceRecord(id: spaceID, profileID: profileID, name: "Home", position: "V")
				SpaceRecord(id: otherSpaceID, profileID: profileID, name: "Work", position: "W")
				FolderRecord(id: folderID, spaceID: spaceID, name: "Reading", position: "V")
				PinnedTabRecord(id: tabID, spaceID: spaceID, folderID: folderID, title: "Arx", url: "https://arx.example", position: "X")
				PinnedTabRecord(id: otherTabID, spaceID: otherSpaceID, title: "Docs", url: "https://docs.example", position: "Y")
				FavoriteRecord(id: favoriteID, profileID: profileID, title: "Mail", url: "https://mail.example", position: "V")
				RegularTabRecord(id: openTabID, spaceID: spaceID, position: "V")
			}
		}
	}

	/// Builds the organization's next batch as CloudKit sends it, then answers it as Production did
	/// without the schema: the records without a parent fail with `invalidArguments`, which the library
	/// drops, and every other with `referenceViolation`, since its parent wasn't saved.
	@discardableResult
	private func refuseNextUpload(_ mac: TestMac) async throws -> Int {
		let engine: SyncEngine = try #require(await mac.sync.engine(.organization))
		let privateEngine: any SyncEngineProtocol = try #require(engine.syncEngines.private)
		let batch: CKSyncEngine.RecordZoneChangeBatch = try #require(
			await engine.nextRecordZoneChangeBatch(syncEngine: privateEngine)
		)
		#expect(!batch.recordsToSave.isEmpty)
		let failures: [(record: CKRecord, error: CKError)] = batch.recordsToSave.map { record in
			(record: record, error: CKError(record.parent == nil ? .invalidArguments : .referenceViolation))
		}
		await engine.handleEvent(
			.sentRecordZoneChanges(
				savedRecords: [],
				failedRecordSaves: failures,
				deletedRecordIDs: [],
				failedRecordDeletes: [:]
			),
			syncEngine: privateEngine
		)
		return failures.count
	}

	private func pendingDeletions(_ mac: TestMac) async throws -> [CKRecord.ID] {
		let engine: SyncEngine = try #require(await mac.sync.engine(.organization))
		let privateEngine: any SyncEngineProtocol = try #require(engine.syncEngines.private)
		return privateEngine.state.pendingRecordZoneChanges.compactMap { change in
			guard case let .deleteRecord(id) = change else { return nil }

			return id
		}
	}

	@Test
	func aRefusedParentLeavesEveryChildHereAndQueuesNoDeletion() async throws {
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }
		try seed(mac)
		let before: OrganizationRows = try .init(mac.organization)
		await mac.sync.setEnabled(true)

		try await refuseNextUpload(mac)

		#expect(try OrganizationRows(mac.organization) == before)
		let openTabs: Int = try await mac.organization.read { db in try RegularTabRecord.fetchCount(db) }
		#expect(openTabs == 1)
		let deletions: [CKRecord.ID] = try await pendingDeletions(mac)
		#expect(deletions.isEmpty)
		let deletedHere: Int = try await mac.organization.read { db in
			try Int.fetchOne(db, sql: #"SELECT count(*) FROM "sqlitedata_icloud_metadata" WHERE "_isDeleted""#) ?? 0
		}
		#expect(deletedHere == 0)
	}

	@Test
	func whatICloudNeverConfirmedIsSentAgainAtTheNextLaunch() async throws {
		let cloud: TestCloud = .init()
		let mac: TestMac = try .init(cloud: cloud)
		defer { mac.remove() }
		try seed(mac)
		await mac.sync.setEnabled(true)
		try await refuseNextUpload(mac)

		// The library dropped every refused save: nothing is left to send.
		try await mac.send()
		#expect(cloud.records(.organization).isEmpty)

		// The schema is in place now; Arx launches again.
		let relaunched: TestMac = try .init(cloud: cloud, directory: mac.directory)
		await relaunched.sync.launch()
		try await relaunched.send()

		let names: Set<String> = Set(cloud.records(.organization).map(\.recordID.recordName))
		let expected: [String] = [
			"\(profileID.uuidString.lowercased()):\(ProfileRecord.tableName)",
			"\(spaceID.uuidString.lowercased()):\(SpaceRecord.tableName)",
			"\(otherSpaceID.uuidString.lowercased()):\(SpaceRecord.tableName)",
			"\(folderID.uuidString.lowercased()):\(FolderRecord.tableName)",
			"\(tabID.uuidString.lowercased()):\(PinnedTabRecord.tableName)",
			"\(otherTabID.uuidString.lowercased()):\(PinnedTabRecord.tableName)",
			"\(favoriteID.uuidString.lowercased()):\(FavoriteRecord.tableName)",
		]
		for name in expected {
			#expect(names.contains(name), "iCloud is missing \(name)")
		}
	}

	@Test
	func whatICloudSavedIsntSentAgainAtTheNextLaunch() async throws {
		let cloud: TestCloud = .init()
		let mac: TestMac = try .init(cloud: cloud)
		defer { mac.remove() }
		try seed(mac)
		await mac.sync.setEnabled(true)
		try await mac.send()
		#expect(!cloud.records(.organization).isEmpty)

		let relaunched: TestMac = try .init(cloud: cloud, directory: mac.directory)
		await relaunched.sync.launch()

		let engine: SyncEngine = try #require(await relaunched.sync.engine(.organization))
		let privateEngine: any SyncEngineProtocol = try #require(engine.syncEngines.private)
		let saves: [CKRecord.ID] = privateEngine.state.pendingRecordZoneChanges.compactMap { change in
			guard case let .saveRecord(id) = change else { return nil }

			return id
		}
		#expect(saves.isEmpty)
	}

	/// SQLiteData drops most refused saves without telling its delegate, so sync looked healthy on
	/// 18 November while nothing reached iCloud (DEV-1209). The rows a start queued and a send then
	/// tried without iCloud saving them show the category as failing in Settings.
	@Test
	func aSendICloudRefusedShowsTheCategoryAsFailing() async throws {
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }
		try seed(mac)
		await mac.sync.setEnabled(true)

		// Queued, not sent yet: nothing is refused.
		await mac.sync.checkConfirmations(.organization)
		#expect(await mac.sync.status[.organization].isError == false)

		let sent: Int = try await refuseNextUpload(mac)
		await mac.sync.checkConfirmations(.organization)

		// The seven seeded rows the start queued. A row written after the start, such as this Mac's
		// device row, is watched from the next start.
		let status: WorkspaceSyncStatus = await mac.sync.status
		#expect(sent > 7)
		#expect(status[.organization] == .refused(7))
		#expect(status.overall == .refused(7))
		#expect(status[.preferences].isError == false)
	}

	@Test
	func aSendICloudSavedShowsNoFailureAndStopsNotingAttempts() async throws {
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }
		try seed(mac)
		await mac.sync.setEnabled(true)

		try await mac.send()
		await mac.sync.checkConfirmations(.organization)

		#expect(await mac.sync.status[.organization].isError == false)
		// Nothing is watched any more: the trigger that notes attempts is gone.
		let triggers: Int = try await mac.organization.write { db in
			try Int.fetchOne(db, sql: #"SELECT count(*) FROM temp.sqlite_master WHERE "name" = 'arx_sync_send_attempt_noted'"#) ?? 0
		}
		#expect(triggers == 0)
	}

	@Test
	func refusedRowsICloudSavesAtTheNextLaunchClearTheFailure() async throws {
		let cloud: TestCloud = .init()
		let mac: TestMac = try .init(cloud: cloud)
		defer { mac.remove() }
		try seed(mac)
		await mac.sync.setEnabled(true)
		try await refuseNextUpload(mac)

		// Still refused at the next launch: the rows are queued again, and the send fails again.
		let refusedAgain: TestMac = try .init(cloud: cloud, directory: mac.directory)
		await refusedAgain.sync.launch()
		let refused: Int = try await refuseNextUpload(refusedAgain)
		await refusedAgain.sync.checkConfirmations(.organization)
		#expect(await refusedAgain.sync.status[.organization] == .refused(refused))

		// The schema is in place now.
		let relaunched: TestMac = try .init(cloud: cloud, directory: mac.directory)
		await relaunched.sync.launch()
		try await relaunched.send()
		await relaunched.sync.checkConfirmations(.organization)

		#expect(await relaunched.sync.status[.organization].isError == false)
	}

	/// A save refused with `serverRejectedRequest` makes the library forget the row's record, so the
	/// row has no last known record at all, as before the send: it still shows as refused, and it's
	/// queued again at the next launch.
	@Test
	func aRowWhoseRecordTheLibraryForgotShowsAsRefusedAndIsSentAgain() async throws {
		let cloud: TestCloud = .init()
		let mac: TestMac = try .init(cloud: cloud)
		defer { mac.remove() }
		try seed(mac)
		await mac.sync.setEnabled(true)
		let engine: SyncEngine = try #require(await mac.sync.engine(.organization))
		let privateEngine: any SyncEngineProtocol = try #require(engine.syncEngines.private)
		let batch: CKSyncEngine.RecordZoneChangeBatch = try #require(
			await engine.nextRecordZoneChangeBatch(syncEngine: privateEngine)
		)
		await engine.handleEvent(
			.sentRecordZoneChanges(
				savedRecords: [],
				failedRecordSaves: batch.recordsToSave.map { (record: $0, error: CKError(.serverRejectedRequest)) },
				deletedRecordIDs: [],
				failedRecordDeletes: [:]
			),
			syncEngine: privateEngine
		)
		await mac.sync.checkConfirmations(.organization)
		#expect(await mac.sync.status[.organization] == .refused(7))
		try await mac.send()
		#expect(cloud.records(.organization).isEmpty)

		let relaunched: TestMac = try .init(cloud: cloud, directory: mac.directory)
		await relaunched.sync.launch()
		try await relaunched.send()

		let names: Set<String> = Set(cloud.records(.organization).map(\.recordID.recordName))
		#expect(names.contains("\(profileID.uuidString.lowercased()):\(ProfileRecord.tableName)"))
		#expect(names.contains("\(favoriteID.uuidString.lowercased()):\(FavoriteRecord.tableName)"))
	}

	@Test
	func theFirstSyncOfACategoryBacksItsDatabaseUp() async throws {
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }
		try seed(mac)

		await mac.sync.setEnabled(true)

		let folder: URL = mac.directory.appendingPathComponent(WorkspaceSync.backupDirectoryName)
		let files: [String] = try FileManager.default.contentsOfDirectory(atPath: folder.path)
		let organization: String = try #require(files.first { $0.hasSuffix("-first-sync-organization.sqlite") })
		let copy: DatabaseQueue = try .init(path: folder.appendingPathComponent(organization).path)
		#expect(try OrganizationRows(copy) == OrganizationRows(mac.organization))
		#expect(files.contains { $0.hasSuffix("-first-sync-preferences.sqlite") })

		// Only the first start: a later one leaves the folder as it was.
		await mac.sync.setEnabled(false)
		await mac.sync.setEnabled(true)
		#expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == files.count)
	}
}
