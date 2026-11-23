import BrowserCore
import CloudKit
import ConcurrencyExtras
import Foundation
import GRDB
@testable import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// Removing a synced profile or space from iCloud, or deleting it from this Mac only (DEV-1336).
/// Either way nothing goes from another Mac at once. A removal from iCloud marks it on every other
/// Mac: those with "sync deletions after" on delete it after that time unless someone uses it, the
/// others keep it until the person removes it there too; Keep cancels it everywhere. A deletion from
/// this Mac only marks nothing and never counts for "sync deletions after".
@Suite(.timeLimit(.minutes(1)))
struct ICloudRemovalTests {
	private let profileID: Profile.ID = .init(rawValue: UUID(-1))
	private let homeID: Space.ID = .init(rawValue: UUID(-2))
	private let workID: Space.ID = .init(rawValue: UUID(-3))
	private let pinID: BrowserCore.Tab.ID = .init(rawValue: UUID(-4))

	private static let month: TimeInterval = 31 * 24 * 60 * 60

	/// Two spaces, Work with a pin.
	private var organization: BrowserOrganization {
		let url: URL = URL(string: "https://work.example")!
		return .init(
			profiles: [.init(id: profileID, name: "Personal")],
			legacyProfileID: profileID,
			spaces: [
				.init(id: homeID, profileID: profileID, name: "Home"),
				.init(id: workID, profileID: profileID, name: "Work", savedItems: [.tab(pinID)]),
			],
			tabs: [.init(id: pinID, profileID: profileID, savedDestination: .init(title: "Work", url: url), restoration: .init(title: "Work", url: url))]
		)
	}

	private var withoutWork: BrowserOrganization {
		var organization: BrowserOrganization = organization
		organization.spaces.remove(id: workID)
		organization.tabs.remove(id: pinID)
		return organization
	}

	/// One Mac: its store, with iCloud sync on its connections, on `cloud`.
	private struct Mac {
		let directory: URL
		let store: WorkspaceDatabase
		let sync: WorkspaceSync
		let now: LockIsolated<Date>

		init(cloud: TestCloud) throws {
			self.directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("ICloudRemovalTests-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			self.store = try .init(directory: directory, separatePreferencesConnection: true)
			let now: LockIsolated<Date> = .init(Date())
			self.now = now
			self.sync = try WorkspaceSync(
				organization: store.database,
				preferences: try #require(store.preferencesDatabase),
				devices: try DeviceDirectory.open(in: directory),
				settings: SyncSettingsStore(directory: directory),
				cloud: CloudAccess(
					account: { .available("account-a") },
					deleteZone: { try cloud.deleteZone($0) },
					placements: { try cloud.placements($0) },
					recordValues: { try cloud.recordValues($0, $1) },
					zoneRecords: { try cloud.zoneRecords($0, $1) }
				),
				makeEngine: cloud.makeEngine(),
				makeDirectoryEngine: cloud.makeDirectoryEngine(),
				now: { now.value }
			)
		}

		/// Sends the organization's changes and this Mac's directory row.
		func send() async throws {
			try await sync.engine(.organization)?.sendChanges()
			if let directory = await sync.directoryEngineForDiagnostics(), directory.isRunning {
				try await directory.sendChanges()
			}
		}

		/// Fetches the organization, then the device directory, and repairs the organization. The
		/// directory goes second: the mock database hands each deletion to whichever engine fetches
		/// next, and every engine fetches the whole private database.
		func fetch() async throws {
			try await sync.engine(.organization)?.fetchChanges()
			if let directory = await sync.directoryEngineForDiagnostics(), directory.isRunning {
				try await directory.fetchChanges()
			}
			try await sync.repair(.organization)
		}

		func hasSpaceRow(_ id: Space.ID) throws -> Bool {
			try store.database.read { db in try SpaceRecord.find(id.rawValue).fetchOne(db) != nil }
		}

		func hasPinRow(_ id: BrowserCore.Tab.ID) throws -> Bool {
			try store.database.read { db in try PinnedTabRecord.find(id.rawValue).fetchOne(db) != nil }
		}

		func deviceID() throws -> UUID {
			try #require(try store.database.read { db in try LocalDeletion.existingDeviceID(db) })
		}

		func marks() async -> [UUID: WorkspaceRepair.DeletionMark] {
			await sync.status.deletionMarks
		}

		func remove() {
			TestFolders.removeAtExit(directory)
		}
	}

	private func twoMacs(_ cloud: TestCloud) async throws -> (Mac, Mac) {
		let a: Mac = try .init(cloud: cloud)
		let b: Mac = try .init(cloud: cloud)
		for mac in [a, b] {
			try mac.store.save(organization, preferences: .init())
			await mac.sync.setEnabled(true)
		}
		try await a.send()
		try await b.fetch()
		try await b.send()
		try await a.fetch()
		try await a.send()
		_ = try a.store.load()
		_ = try b.store.load()
		return (a, b)
	}

	// MARK: - Remove from iCloud

	@Test
	func aRemovalFromICloudIsMarkedOnTheOtherMacWhateverItsSetting() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutWork, preferences: .init())
		try await a.send()
		try await b.fetch()

		// Off on B: marked, with the Mac that removed it and no date, and it stays.
		let kept: WorkspaceRepair.DeletionMark = try #require(await b.marks()[workID.rawValue])
		#expect(kept.deviceID == (try a.deviceID()))
		#expect(kept.deletesAt == nil)
		#expect(try b.store.load()?.organization.spaces[id: workID] != nil)

		// On: marked with the day it goes, and still there.
		await b.sync.setSyncsDeletions(true)
		let mark: WorkspaceRepair.DeletionMark = try #require(await b.marks()[workID.rawValue])
		let deletesAt: Date = try #require(mark.deletesAt)
		#expect(abs(deletesAt.timeIntervalSince(mark.removedAt) - 30 * 24 * 60 * 60) < 1)
		#expect(try b.hasSpaceRow(workID))
		#expect(try b.store.load()?.organization.spaces[id: workID] != nil)

		// Only profiles and spaces are marked; the pin in the space isn't, though it goes with it.
		#expect(await b.marks()[pinID.rawValue] == nil)

		// Opened since on B: still marked, but nothing removes it any more.
		try b.store.recordUse(of: [workID.rawValue], now: Date().addingTimeInterval(1))
		await b.sync.refreshStatus()
		#expect(try #require(await b.marks()[workID.rawValue]).deletesAt == nil)

		// A Mac doesn't mark what it deleted itself.
		await a.sync.refreshStatus()
		#expect(await a.marks().isEmpty)
	}

	@Test
	func removeHereTooClearsTheMarkAndEveryMacsRemovalPurges() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutWork, preferences: .init())
		try await a.send()
		try await b.fetch()
		#expect(await b.marks()[workID.rawValue] != nil)

		_ = try b.store.load()
		try b.store.save(withoutWork, preferences: .init())
		await b.sync.refreshStatus()
		#expect(await b.marks().isEmpty)
		try await b.send()
		try await a.fetch()
		#expect(try !a.hasSpaceRow(workID))
	}

	@Test
	func aMarkedSpaceGoesOnceTheTimePassed() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutWork, preferences: .init())
		try await a.send()
		try await b.fetch()
		await b.sync.setSyncsDeletions(true)
		#expect(await b.marks()[workID.rawValue] != nil)

		b.now.setValue(Date().addingTimeInterval(Self.month))
		try await b.fetch()
		#expect(try !b.hasSpaceRow(workID))
		#expect(await b.marks().isEmpty)
	}

	@Test
	func withSyncDeletionsOffARemovalFromICloudNeverDeletes() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutWork, preferences: .init())
		try await a.send()
		try await b.fetch()

		b.now.setValue(Date().addingTimeInterval(Self.month))
		try await b.fetch()
		#expect(try b.hasSpaceRow(workID))
		#expect(try b.hasPinRow(pinID))
		#expect(try #require(await b.marks()[workID.rawValue]).deletesAt == nil)
	}

	@Test
	func keepClearsTheMarkOnEveryMacAndCancelsTheRemoval() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutWork, preferences: .init())
		try await a.send()
		try await b.fetch()
		await b.sync.setSyncsDeletions(true)
		#expect(await b.marks()[workID.rawValue] != nil)

		await b.sync.keep([workID.rawValue, pinID.rawValue])
		#expect(await b.marks().isEmpty)
		try await b.send()

		// A's removal is a deletion from A only now, in iCloud and on A, which still hides it.
		let records: [CKRecord] = cloud.records(.organization).filter { $0.recordType == DeletionRecord.tableName }
		#expect(records.count == 2)
		#expect(records.allSatisfy { ($0.encryptedValues["keepsElsewhere"] as? Int64) == 1 })
		try await a.fetch()
		let rows: [DeletionRecord] = try await a.store.database.read { db in try DeletionRecord.all.fetchAll(db) }
		#expect(rows.allSatisfy { $0.keepsElsewhere })
		#expect(try a.store.load()?.organization.spaces[id: workID] == nil)

		b.now.setValue(Date().addingTimeInterval(Self.month))
		try await b.fetch()
		#expect(try b.hasSpaceRow(workID))
		#expect(try b.hasPinRow(pinID))
		#expect(await b.marks().isEmpty)
	}

	// MARK: - Every Mac that has it decides (DEV-1337)

	@Test
	func aRemoverSyncingDeletionsNeverPurgesWhatAMacWithItOffKeeps() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		// A syncs deletions and removes Work from iCloud; B, with it off, keeps it.
		await a.sync.setSyncsDeletions(true)
		try a.store.save(withoutWork, preferences: .init())
		try await a.send()
		try await b.fetch()
		try await b.send()
		try await a.fetch()
		#expect(try #require(await b.marks()[workID.rawValue]).deletesAt == nil)

		// A month on, both Macs still seen: A's purge leaves it, in iCloud and on B, and B's hint holds.
		a.now.setValue(Date().addingTimeInterval(Self.month))
		b.now.setValue(Date().addingTimeInterval(Self.month))
		try await b.fetch()
		try await b.send()
		try await a.fetch()
		try await a.send()
		try await b.fetch()
		#expect(try a.hasSpaceRow(workID))
		#expect(try b.hasSpaceRow(workID))
		#expect(try b.hasPinRow(pinID))
		#expect(cloud.records(.organization).contains { $0.recordType == SpaceRecord.tableName && $0.recordID.recordName.hasPrefix(workID.rawValue.uuidString.lowercased()) })
		#expect(try #require(await b.marks()[workID.rawValue]).deletesAt == nil)

		// Once B turns it on too, the day has passed: B's own purge takes it, and A follows.
		await b.sync.setSyncsDeletions(true)
		#expect(try !b.hasSpaceRow(workID))
		try await b.send()
		try await a.fetch()
		#expect(try !a.hasSpaceRow(workID))
	}

	@Test
	func aKeeperSyncingDeletionsPurgesWhatARemoverWithItOffRemoved() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		// A, with it off, removes Work from iCloud; B syncs deletions: marked with the day it goes.
		try a.store.save(withoutWork, preferences: .init())
		try await a.send()
		try await b.fetch()
		await b.sync.setSyncsDeletions(true)
		let mark: WorkspaceRepair.DeletionMark = try #require(await b.marks()[workID.rawValue])
		#expect(mark.deletesAt != nil)
		#expect(try b.hasSpaceRow(workID))

		// A doesn't have it any more, so its setting doesn't keep it: B's purge takes it on the day.
		b.now.setValue(Date().addingTimeInterval(Self.month))
		try await b.fetch()
		#expect(try !b.hasSpaceRow(workID))
	}

	@Test
	func aDirectoryRowThatDoesntSaySyncsDeletionsKeeps() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ICloudRemovalTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { TestFolders.removeAtExit(directory) }

		// A row an older Arx wrote, before the column, and one from a Mac with the option on.
		let queue: DatabaseQueue = try .init(path: directory.appendingPathComponent(DeviceDirectory.fileName).path)
		var older: DatabaseMigrator = DeviceDirectory.migrator()
		older.eraseDatabaseOnSchemaChange = false
		try older.migrate(queue, upTo: "v2-left-categories")
		try queue.write { db in
			try db.execute(
				sql: "INSERT INTO \"syncDeviceDirectory\" (\"id\", \"name\", \"lastSeen\") VALUES (?, 'Old Mac', 1)",
				arguments: [UUID(-20).uuidString.lowercased()]
			)
		}
		try DeviceDirectory.migrator().migrate(queue)
		try queue.write { db in
			try DeviceDirectory.write(
				db,
				id: UUID(-21),
				name: "New Mac",
				categories: [.organization],
				leftCategories: [],
				preferenceGroups: [],
				stoppedAt: nil,
				syncDeletionsAfterDays: 30,
				now: .init()
			)
		}
		let syncing: Set<UUID> = try queue.read { db in try DeviceDirectory.devicesSyncingDeletions(db) }
		#expect(syncing == [UUID(-21)])

		// With the older Mac still having the item, neither the purge nor the mark's date goes ahead.
		let now: Date = .init()
		let item: UUID = UUID(-22)
		var snapshot: WorkspaceRepair.PurgeSnapshot = .init()
		snapshot.items[SpaceRecord.tableName] = [item]
		snapshot.sightings = [UUID(-20): now.timeIntervalSince1970, UUID(-21): now.timeIntervalSince1970, UUID(-23): now.timeIntervalSince1970]
		snapshot.deletions = [
			.init(itemID: item, itemTable: SpaceRecord.tableName, deviceID: UUID(-23), deletedAt: now.timeIntervalSince1970 - Self.month),
		]
		let policy: WorkspaceRepair.DeletionPolicy = .init(
			now: now,
			syncDeletionsAfter: 30 * 24 * 60 * 60,
			devicesSyncingDeletions: syncing
		)
		#expect(WorkspaceRepair.purgeCandidates(snapshot, policy: policy).isEmpty)
		let mark: WorkspaceRepair.DeletionMark? = WorkspaceRepair.deletionMarks(snapshot, policy: policy, thisDevice: UUID(-21))[
			.init(table: SpaceRecord.tableName, id: item)
		]
		#expect(mark != nil)
		#expect(mark?.deletesAt == nil)

		// Once the older Mac deleted it too, it holds nothing back.
		snapshot.deletions.append(.init(itemID: item, itemTable: SpaceRecord.tableName, deviceID: UUID(-20), deletedAt: now.timeIntervalSince1970))
		#expect(WorkspaceRepair.purgeCandidates(snapshot, policy: policy) == [.init(table: SpaceRecord.tableName, id: item)])
	}

	// MARK: - Delete from This Mac Only

	@Test
	func aDeletionFromThisMacOnlyIsNeverMarkedOrPurgedByTime() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		a.store.keepRemovalOnThisMac([workID.rawValue])
		try a.store.save(withoutWork, preferences: .init())
		try await a.send()

		// The space and the pin in it are hidden on A, kept elsewhere, and iCloud carries that.
		#expect(try a.store.load()?.organization.spaces[id: workID] == nil)
		let kept: [DeletionRecord] = try await a.store.database.read { db in try DeletionRecord.all.fetchAll(db) }
		#expect(Set(kept.map(\.itemID)) == [workID.rawValue, pinID.rawValue])
		#expect(kept.allSatisfy { $0.keepsElsewhere })
		let records: [CKRecord] = cloud.records(.organization).filter { $0.recordType == DeletionRecord.tableName }
		#expect(records.count == 2)
		#expect(records.allSatisfy { ($0.encryptedValues["keepsElsewhere"] as? Int64) == 1 })

		try await b.fetch()
		#expect(await b.marks().isEmpty)
		await b.sync.setSyncsDeletions(true)
		#expect(await b.marks().isEmpty)

		b.now.setValue(Date().addingTimeInterval(Self.month))
		try await b.fetch()
		#expect(try b.hasSpaceRow(workID))
		#expect(try b.hasPinRow(pinID))
		#expect(try b.store.load()?.organization.spaces[id: workID] != nil)
	}

	@Test
	func aDeletionFromThisMacOnlyStillCountsWhenEveryMacDeletedIt() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		a.store.keepRemovalOnThisMac([workID.rawValue])
		try a.store.save(withoutWork, preferences: .init())
		try await a.send()
		try await b.fetch()
		_ = try b.store.load()
		try b.store.save(withoutWork, preferences: .init())
		try await b.send()
		try await a.fetch()
		#expect(try !a.hasSpaceRow(workID))
	}

	@Test
	func onlyTheNextRemovalOfThatItemStaysOnThisMac() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		// Asked for Home, which this save doesn't remove: Work's removal asks the other Macs.
		a.store.keepRemovalOnThisMac([homeID.rawValue])
		try a.store.save(withoutWork, preferences: .init())
		let rows: [DeletionRecord] = try await a.store.database.read { db in try DeletionRecord.all.fetchAll(db) }
		#expect(!rows.isEmpty)
		#expect(rows.allSatisfy { !$0.keepsElsewhere })
	}

	// MARK: - Purge rules

	@Test
	func syncDeletionsAfterSkipsDeletionsKeptElsewhere() {
		let now: Date = .init()
		let item: UUID = UUID(-7)
		let a: UUID = UUID(-8)
		let b: UUID = UUID(-9)
		var snapshot: WorkspaceRepair.PurgeSnapshot = .init()
		snapshot.items[SpaceRecord.tableName] = [item]
		snapshot.sightings = [a: now.timeIntervalSince1970, b: now.timeIntervalSince1970]
		snapshot.deletions = [
			.init(itemID: item, itemTable: SpaceRecord.tableName, deviceID: a, deletedAt: now.timeIntervalSince1970 - Self.month, keepsElsewhere: true),
		]
		let policy: WorkspaceRepair.DeletionPolicy = .init(now: now, syncDeletionsAfter: 30 * 24 * 60 * 60)
		#expect(WorkspaceRepair.purgeCandidates(snapshot, policy: policy).isEmpty)
		#expect(WorkspaceRepair.deletionMarks(snapshot, policy: policy, thisDevice: b).isEmpty)

		// A later removal from iCloud by another Mac counts from its own date.
		let removedAt: Double = now.timeIntervalSince1970 - 24 * 60 * 60
		snapshot.deletions.append(.init(itemID: item, itemTable: SpaceRecord.tableName, deviceID: UUID(-10), deletedAt: removedAt))
		#expect(WorkspaceRepair.purgeCandidates(snapshot, policy: policy).isEmpty)
		let mark: WorkspaceRepair.DeletionMark? = WorkspaceRepair.deletionMarks(snapshot, policy: policy, thisDevice: b)[
			.init(table: SpaceRecord.tableName, id: item)
		]
		#expect(mark?.deviceID == UUID(-10))
		#expect(mark?.deletesAt == Date(timeIntervalSince1970: removedAt + 30 * 24 * 60 * 60))

		// Off, it's marked with no date.
		let off: WorkspaceRepair.DeletionMark? = WorkspaceRepair.deletionMarks(
			snapshot,
			policy: .init(now: now, syncDeletionsAfter: nil),
			thisDevice: b
		)[.init(table: SpaceRecord.tableName, id: item)]
		#expect(off != nil)
		#expect(off?.deletesAt == nil)
	}

	// MARK: - When Delete asks

	private func status(
		devices: [SyncDevice],
		organization: CategoryStatus = .synced,
		isEnabled: Bool = true
	) -> WorkspaceSyncStatus {
		.init(isEnabled: isEnabled, categories: [.organization: organization], devices: devices)
	}

	private func device(
		_ id: Int,
		isThisMac: Bool = false,
		lastSeen: Date = .init(),
		categories: Set<SyncCategory> = [.organization],
		leftCategories: Set<SyncCategory> = [],
		stoppedAt: Date? = nil
	) -> SyncDevice {
		.init(
			id: UUID(id),
			name: "Mac \(id)",
			lastSeen: lastSeen,
			categories: categories,
			leftCategories: leftCategories,
			preferenceGroups: [],
			stoppedAt: stoppedAt,
			isThisMac: isThisMac
		)
	}

	@Test
	func deleteAsksOnlyWhileAnotherMacSyncsProfilesAndSpaces() {
		let now: Date = .init()
		let here: SyncDevice = device(1, isThisMac: true)
		#expect(status(devices: [here, device(2)]).asksWhereToRemove(now: now))
		#expect(status(devices: [here, device(2)]).deviceName(UUID(2)) == "Mac 2")

		// Alone, with sync or Profiles and spaces off, or with only Macs that left, it doesn't ask.
		#expect(!status(devices: [here]).asksWhereToRemove(now: now))
		#expect(!status(devices: [here, device(2)], isEnabled: false).asksWhereToRemove(now: now))
		#expect(!status(devices: [here, device(2)], organization: .off).asksWhereToRemove(now: now))
		#expect(!status(devices: [here, device(2, categories: [.preferences])]).asksWhereToRemove(now: now))
		#expect(!status(devices: [here, device(2, leftCategories: [.organization])]).asksWhereToRemove(now: now))
		#expect(!status(devices: [here, device(2, stoppedAt: now)]).asksWhereToRemove(now: now))
		#expect(!status(devices: [here, device(2, lastSeen: now.addingTimeInterval(-Self.month))]).asksWhereToRemove(now: now))
	}
}
