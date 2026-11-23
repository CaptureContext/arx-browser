import BrowserCore
import ConcurrencyExtras
import Foundation
import GRDB
@testable import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// Deletions stay on the Mac that made them (DEV-980): another Mac keeps the item until every Mac
/// deleted it, or, with "sync deletions after" on, until nobody used it for that long.
@Suite(.timeLimit(.minutes(1)))
struct LocalDeletionTests {
	private let profileID: Profile.ID = .init(rawValue: UUID(-1))
	private let spaceID: Space.ID = .init(rawValue: UUID(-2))
	private let pinID: BrowserCore.Tab.ID = .init(rawValue: UUID(-3))
	private let folderID: Folder.ID = .init(rawValue: UUID(-4))
	private let childID: BrowserCore.Tab.ID = .init(rawValue: UUID(-5))

	private func pinned(_ id: BrowserCore.Tab.ID, _ title: String) -> BrowserCore.Tab {
		let url: URL = URL(string: "https://\(title.lowercased()).example")!
		return .init(
			id: id,
			profileID: profileID,
			savedDestination: .init(title: title, url: url),
			restoration: .init(title: title, url: url)
		)
	}

	/// A pin at the space's root and a folder holding another.
	private var organization: BrowserOrganization {
		.init(
			profiles: [.init(id: profileID, name: "Personal")],
			legacyProfileID: profileID,
			spaces: [.init(id: spaceID, profileID: profileID, name: "Home", savedItems: [.tab(pinID), .folder(folderID)])],
			folders: [.init(id: folderID, spaceID: spaceID, name: "Reading", children: [.tab(childID)])],
			tabs: [pinned(pinID, "Pin"), pinned(childID, "Child")]
		)
	}

	private func withoutPin(_ organization: BrowserOrganization) -> BrowserOrganization {
		var organization: BrowserOrganization = organization
		organization.spaces[id: spaceID]?.savedItems.removeAll { $0 == .tab(pinID) }
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
				.appendingPathComponent("LocalDeletionTests-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			self.store = try .init(directory: directory, separatePreferencesConnection: true)
			let now: LockIsolated<Date> = .init(Date())
			self.now = now
			self.sync = try WorkspaceSync(
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
				makeEngine: cloud.makeEngine(),
				now: { now.value }
			)
		}

		func send() async throws {
			try await sync.engine(.organization)?.sendChanges()
		}

		func fetch() async throws {
			try await sync.engine(.organization)?.fetchChanges()
			try await sync.repair(.organization)
		}

		/// Whether `id`'s row is in this Mac's database at all, shown or not.
		func hasRow(_ id: BrowserCore.Tab.ID) throws -> Bool {
			try store.database.read { db in try PinnedTabRecord.find(id.rawValue).fetchOne(db) != nil }
		}

		func remove() {
			TestFolders.removeAtExit(directory)
		}
	}

	/// Two Macs with the same workspace, both syncing.
	private func twoMacs(
		_ cloud: TestCloud,
		starting start: BrowserOrganization? = nil
	) async throws -> (Mac, Mac) {
		let a: Mac = try .init(cloud: cloud)
		let b: Mac = try .init(cloud: cloud)
		for mac in [a, b] {
			try mac.store.save(start ?? organization, preferences: .init())
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

	@Test
	func aPinDeletedOnOneMacStaysOnTheOther() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutPin(organization), preferences: .init())
		try await a.send()
		try await b.fetch()

		// Hidden on A, kept in iCloud and on B.
		#expect(try a.store.load()?.organization.tabs[id: pinID] == nil)
		#expect(try a.hasRow(pinID))
		#expect(try b.store.load()?.organization.tabs[id: pinID] != nil)
		#expect(cloud.records(.organization).contains { $0.recordID.recordName.hasPrefix(pinID.rawValue.uuidString.lowercased()) })
	}

	@Test
	func anItemEveryMacDeletedGoesEverywhere() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutPin(organization), preferences: .init())
		try await a.send()
		try await b.fetch()
		_ = try b.store.load()
		try b.store.save(withoutPin(organization), preferences: .init())
		try await b.send()
		try await a.fetch()
		try await a.send()
		try await b.fetch()

		#expect(try !a.hasRow(pinID))
		#expect(try !b.hasRow(pinID))
		let deletions: Int = try await a.store.database.read { db in try DeletionRecord.all.fetchAll(db).count }
		#expect(deletions == 0)
	}

	@Test
	func withSyncDeletionsAfterAnItemNobodyUsedGoesEverywhere() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutPin(organization), preferences: .init())
		try await a.send()
		try await b.fetch()
		#expect(try b.hasRow(pinID))

		// Off, a month changes nothing.
		b.now.setValue(Date().addingTimeInterval(31 * 24 * 60 * 60))
		try await b.fetch()
		#expect(try b.hasRow(pinID))

		await b.sync.setSyncsDeletions(true)
		#expect(try !b.hasRow(pinID))
		try await b.send()
		try await a.fetch()
		#expect(try !a.hasRow(pinID))
	}

	@Test
	func anItemSomeoneOpenedSinceStays() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutPin(organization), preferences: .init())
		try await a.send()
		try await b.fetch()

		// B opens the pin after A deleted it, the same day B last used it.
		var opened: BrowserOrganization = try #require(try b.store.load()?.organization)
		opened.spaces[id: spaceID]?.selectedTabID = pinID
		try b.store.save(opened, preferences: .init())

		await b.sync.setSyncsDeletions(true)
		b.now.setValue(Date().addingTimeInterval(31 * 24 * 60 * 60))
		try await b.fetch()
		#expect(try b.hasRow(pinID))
		#expect(try b.store.load()?.organization.tabs[id: pinID] != nil)
	}

	@Test
	func anItemOpenedWithoutASaveStays() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		// B's space shows the pin before A deletes it, so going back to it later changes no row.
		var selected: BrowserOrganization = try #require(try b.store.load()?.organization)
		selected.spaces[id: spaceID]?.selectedTabID = pinID
		try b.store.save(selected, preferences: .init())
		try await b.send()
		try await a.fetch()
		_ = try a.store.load()
		var deleted: BrowserOrganization = withoutPin(selected)
		deleted.spaces[id: spaceID]?.selectedTabID = nil
		try a.store.save(deleted, preferences: .init())
		try await a.send()
		try await b.fetch()

		try b.store.recordUse(of: [spaceID.rawValue, pinID.rawValue], now: Date().addingTimeInterval(1))

		await b.sync.setSyncsDeletions(true)
		b.now.setValue(Date().addingTimeInterval(31 * 24 * 60 * 60))
		try await b.fetch()
		#expect(try b.hasRow(pinID))
		#expect(try b.store.load()?.organization.tabs[id: pinID] != nil)
	}

	@Test
	func anOpenTabOrAStoreWithoutSyncRecordsNoUse() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalDeletionTests-\(UUID().uuidString)")
		defer { TestFolders.removeAtExit(directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let local: WorkspaceDatabase = try .init(directory: directory)
		try local.save(organization, preferences: .init())
		try local.recordUse(of: [pinID.rawValue])
		#expect(try local.database.read { db in try UsageRecord.all.fetchAll(db).count } == 0)

		let (syncedDirectory, synced): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(syncedDirectory) }
		try synced.save(organization, preferences: .init())

		// The first save recorded everything as edited.
		try synced.database.write { db in try UsageRecord.delete().execute(db) }
		try synced.recordUse(of: [UUID(-9)])
		#expect(try synced.database.read { db in try UsageRecord.all.fetchAll(db).count } == 0)

		// A space counts with its profile; opening it again the same day writes nothing.
		try synced.recordUse(of: [spaceID.rawValue])
		let used: Set<UUID> = try synced.database.read { db in Set(try UsageRecord.all.fetchAll(db).map(\.itemID)) }
		#expect(used == [spaceID.rawValue, profileID.rawValue])
		try synced.database.write { db in try UsageRecord.delete().execute(db) }
		try synced.recordUse(of: [spaceID.rawValue])
		#expect(try synced.database.read { db in try UsageRecord.all.fetchAll(db).count } == 0)
	}

	@Test
	func aFavoriteTurnedIntoAPinMovesOnEveryMac() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		var start: BrowserOrganization = withoutPin(organization)
		start.profiles[id: profileID]?.favorites = [pinID]
		start.tabs.append(pinned(pinID, "Pin"))
		try store.save(start, preferences: .init())

		// The tab keeps its ID: the Favorite it was goes, rather than staying hidden here only, so
		// no Mac's duplicate repair removes the pin as a copy of it.
		try store.save(organization, preferences: .init())

		#expect(try store.load()?.organization == organization)
		#expect(try store.database.read { db in try FavoriteRecord.find(pinID.rawValue).fetchOne(db) } == nil)
		#expect(try store.database.read { db in try DeletionRecord.all.fetchAll(db).count } == 0)
	}

	@Test
	func aDeletionCountsOnlyForTheTableItWasMadeIn() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let a: UUID = UUID(-30)
		let b: UUID = UUID(-31)
		let now: Date = .init()
		try database.write { db in
			try db.seed {
				ProfileRecord(id: profileID.rawValue, name: "Personal", position: "V")
				SpaceRecord(id: spaceID.rawValue, profileID: profileID.rawValue, name: "Home", position: "V")
				PinnedTabRecord(id: pinID.rawValue, spaceID: spaceID.rawValue, title: "Pin", url: "https://pin.example", position: "V")
				FavoriteRecord(id: pinID.rawValue, profileID: profileID.rawValue, title: "Pin", url: "https://pin.example", position: "V")
				SyncDeviceRecord(id: a, lastSeen: now.timeIntervalSince1970)
				SyncDeviceRecord(id: b, lastSeen: now.timeIntervalSince1970)

				// A deleted the pin; B, the Favorite the same tab also is.
				DeletionRecord(id: UUID(-32), itemID: pinID.rawValue, itemTable: PinnedTabRecord.tableName, deviceID: a, deletedAt: 1)
				DeletionRecord(id: UUID(-33), itemID: pinID.rawValue, itemTable: FavoriteRecord.tableName, deviceID: b, deletedAt: 2)
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(
				db,
				ownStarterProfileIDs: [],
				deletions: .init(now: now, syncDeletionsAfter: nil)
			)
		}

		#expect(summary.purgedDeletions.isEmpty)
		#expect(try database.read { db in try DeletionRecord.all.fetchAll(db).count } == 2)
	}

	@Test
	func aPurgeWaitsForICloudToHaveWhatItRestsOn() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		try a.store.save(withoutPin(organization), preferences: .init())
		try await a.send()
		try await b.fetch()

		// iCloud can't be asked: nothing goes on what this Mac has alone.
		cloud.isOffline.setValue(true)
		b.now.setValue(Date().addingTimeInterval(31 * 24 * 60 * 60))
		await b.sync.setSyncsDeletions(true)
		#expect(try b.hasRow(pinID))

		cloud.isOffline.setValue(false)
		try await b.send()
		try await b.fetch()
		#expect(try !b.hasRow(pinID))
	}

	/// A space deleted on Macs A and B, with a pin in it, as a snapshot of synced rows.
	private func deletedSpace(now: Date) -> WorkspaceRepair.PurgeSnapshot {
		var snapshot: WorkspaceRepair.PurgeSnapshot = .init()
		let a: UUID = UUID(-40)
		let b: UUID = UUID(-41)
		snapshot.items = [
			ProfileRecord.tableName: [profileID.rawValue],
			SpaceRecord.tableName: [spaceID.rawValue],
			PinnedTabRecord.tableName: [pinID.rawValue],
		]
		snapshot.parents = [spaceID.rawValue: [profileID.rawValue], pinID.rawValue: [spaceID.rawValue]]
		snapshot.sightings = [a: now.timeIntervalSince1970, b: now.timeIntervalSince1970]
		let deletedAt: Double = now.addingTimeInterval(-40 * 24 * 60 * 60).timeIntervalSince1970
		snapshot.deletions = [a, b].map {
			.init(itemID: spaceID.rawValue, itemTable: SpaceRecord.tableName, deviceID: $0, deletedAt: deletedAt)
		}
		return snapshot
	}

	@Test
	func aMacICloudKnowsKeepsAnItemFromGoingEverywhere() {
		let now: Date = .init()
		let item: WorkspaceRepair.PurgeItem = .init(table: SpaceRecord.tableName, id: spaceID.rawValue)
		let policy: WorkspaceRepair.DeletionPolicy = .init(now: now, syncDeletionsAfter: nil)
		let here: WorkspaceRepair.PurgeSnapshot = deletedSpace(now: now)
		#expect(WorkspaceRepair.purgeCandidates(here, policy: policy) == [item])

		// iCloud has a third Mac, seen lately, that this Mac hasn't fetched.
		var iCloud: WorkspaceRepair.PurgeSnapshot = here
		iCloud.sightings[UUID(-42)] = now.timeIntervalSince1970
		#expect(WorkspaceRepair.purgeCandidates(iCloud, policy: policy).isEmpty)

		// One gone longer than a month doesn't count.
		iCloud.sightings[UUID(-42)] = now.addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970
		#expect(WorkspaceRepair.purgeCandidates(iCloud, policy: policy) == [item])
	}

	@Test
	func aUseICloudHasOfSomethingInADeletedSpaceKeepsIt() {
		let now: Date = .init()
		let policy: WorkspaceRepair.DeletionPolicy = .init(now: now, syncDeletionsAfter: 30 * 24 * 60 * 60)

		// Only Mac A deleted it, so only the period can make it go.
		var here: WorkspaceRepair.PurgeSnapshot = deletedSpace(now: now)
		here.deletions.removeLast()
		#expect(WorkspaceRepair.purgeCandidates(here, policy: policy).count == 1)

		// Another Mac added a pin to it and opened it; this Mac hasn't fetched either yet.
		var iCloud: WorkspaceRepair.PurgeSnapshot = here
		let added: UUID = UUID(-43)
		iCloud.items[PinnedTabRecord.tableName]?.insert(added)

		// In a folder of another space, as a conflict can leave it: deleting the space still deletes it.
		iCloud.parents[added] = [spaceID.rawValue, UUID(-47)]
		iCloud.use(added, by: UUID(-44), at: now.timeIntervalSince1970)
		#expect(WorkspaceRepair.purgeCandidates(iCloud, policy: policy).isEmpty)
	}

	@Test
	func aSpaceGoesOnlyWithWhatICloudHasInIt() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let now: Date = .init()
		let a: UUID = UUID(-40)
		let kept: Space.ID = .init(rawValue: UUID(-48))
		try database.write { db in
			try db.seed {
				ProfileRecord(id: profileID.rawValue, name: "Personal", position: "V")
				SpaceRecord(id: spaceID.rawValue, profileID: profileID.rawValue, name: "Home", position: "V")
				SpaceRecord(id: kept.rawValue, profileID: profileID.rawValue, name: "Other", position: "W")
				PinnedTabRecord(id: pinID.rawValue, spaceID: spaceID.rawValue, title: "Pin", url: "https://pin.example", position: "V")
				SyncDeviceRecord(id: a, lastSeen: now.timeIntervalSince1970)
				DeletionRecord(id: UUID(-49), itemID: spaceID.rawValue, itemTable: SpaceRecord.tableName, deviceID: a, deletedAt: 1)
			}
		}
		let item: WorkspaceRepair.PurgeItem = .init(table: SpaceRecord.tableName, id: spaceID.rawValue)

		// Another Mac moved the pin out of the space in iCloud; this Mac hasn't fetched that yet.
		let moved: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(
				db,
				ownStarterProfileIDs: [],
				deletions: .init(now: now, syncDeletionsAfter: nil, confirmed: [item: [spaceID.rawValue]])
			)
		}
		#expect(moved.purgedDeletions.isEmpty)
		#expect(try database.read { db in try PinnedTabRecord.find(pinID.rawValue).fetchOne(db) } != nil)

		// iCloud has the pin in it too: the space goes, with it.
		let purged: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(
				db,
				ownStarterProfileIDs: [],
				deletions: .init(now: now, syncDeletionsAfter: nil, confirmed: [item: [spaceID.rawValue, pinID.rawValue]])
			)
		}
		#expect(purged.purgedDeletions == [spaceID.rawValue])
	}

	@Test
	func aPurgedFoldersOtherChildrenMoveUp() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let now: Date = .init()
		let a: UUID = UUID(-40)
		try database.write { db in
			try db.seed {
				ProfileRecord(id: profileID.rawValue, name: "Personal", position: "V")
				SpaceRecord(id: spaceID.rawValue, profileID: profileID.rawValue, name: "Home", position: "V")
				FolderRecord(id: folderID.rawValue, spaceID: spaceID.rawValue, name: "Reading", position: "V")
				PinnedTabRecord(id: childID.rawValue, spaceID: spaceID.rawValue, folderID: folderID.rawValue, title: "Child", url: "https://child.example", position: "V")
				SyncDeviceRecord(id: a, lastSeen: now.timeIntervalSince1970)
				DeletionRecord(id: UUID(-45), itemID: folderID.rawValue, itemTable: FolderRecord.tableName, deviceID: a, deletedAt: 1)
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [], deletions: .init(now: now, syncDeletionsAfter: nil))
		}

		#expect(summary.purgedDeletions == [folderID.rawValue])
		let child: PinnedTabRecord? = try database.read { db in try PinnedTabRecord.find(childID.rawValue).fetchOne(db) }
		#expect(child != nil)
		#expect(child?.folderID == nil)
	}

	@Test
	func aFavoriteAnotherMacMadeOfAPinThisMacUnpinnedStaysThere() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let deviceID: UUID = try database.write { db in
			let deviceID: UUID = try LocalDeletion.deviceID(db)
			try db.seed {
				ProfileRecord(id: profileID.rawValue, name: "Personal", position: "V")
				SpaceRecord(id: spaceID.rawValue, profileID: profileID.rawValue, name: "Home", position: "V")

				// Unpinned here: the open tab is this Mac's, the pin hidden here.
				RegularTabRecord(id: pinID.rawValue, spaceID: spaceID.rawValue, position: "V")
				DeletionRecord(id: UUID(-46), itemID: pinID.rawValue, itemTable: PinnedTabRecord.tableName, deviceID: deviceID, deletedAt: 1)

				// Another Mac made the pin a Favorite since.
				FavoriteRecord(id: pinID.rawValue, profileID: profileID.rawValue, title: "Pin", url: "https://pin.example", position: "V")
			}
			return deviceID
		}

		_ = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}

		// Kept in iCloud, hidden here only.
		#expect(try database.read { db in try FavoriteRecord.find(pinID.rawValue).fetchOne(db) } != nil)
		let hidden: HiddenItems = try database.read { db in try LocalDeletion.hiddenItems(db) }
		#expect(hidden.contains(pinID.rawValue, in: FavoriteRecord.tableName))
		_ = deviceID
	}

	@Test
	func pinningAnOpenTabBesideADeletedPinInAnotherProfileIsNoMove() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		let work: Profile.ID = .init(rawValue: UUID(-50))
		let workSpace: Space.ID = .init(rawValue: UUID(-51))
		let openID: BrowserCore.Tab.ID = .init(rawValue: UUID(-52))
		let url: URL = URL(string: "https://pin.example")!
		var start: BrowserOrganization = organization
		start.profiles.append(.init(id: work, name: "Work"))
		start.spaces.append(.init(id: workSpace, profileID: work, name: "Desk", unpinnedTabs: [openID]))
		start.tabs.append(.init(id: openID, profileID: work, restoration: .init(title: "Pin", url: url)))
		try store.save(start, preferences: .init())

		// One save deletes the pin in Personal and pins the same page, already open, in Work.
		var changed: BrowserOrganization = withoutPin(start)
		changed.spaces[id: workSpace]?.unpinnedTabs = []
		changed.spaces[id: workSpace]?.savedItems = [.tab(openID)]
		changed.tabs[id: openID]?.savedDestination = .init(title: "Pin", url: url)
		try store.save(changed, preferences: .init())

		// A deletion: hidden here, kept for other Macs.
		#expect(try store.database.read { db in try PinnedTabRecord.find(pinID.rawValue).fetchOne(db) } != nil)
		#expect(try store.database.read { db in try LocalDeletion.hiddenItems(db) }.contains(pinID.rawValue, in: PinnedTabRecord.tableName))
	}

	@Test
	func aDeletionBesideAnIdenticalNewPinInAnotherProfileStaysLocal() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		let work: Profile.ID = .init(rawValue: UUID(-53))
		let workSpace: Space.ID = .init(rawValue: UUID(-54))
		let newID: BrowserCore.Tab.ID = .init(rawValue: UUID(-55))
		var start: BrowserOrganization = organization
		start.profiles.append(.init(id: work, name: "Work"))
		start.spaces.append(.init(id: workSpace, profileID: work, name: "Desk"))
		try store.save(start, preferences: .init())

		// One save deletes the pin in Personal and, unrelated, adds a new identical pin in Work.
		var changed: BrowserOrganization = withoutPin(start)
		changed.spaces[id: workSpace]?.savedItems = [.tab(newID)]
		var copy: BrowserCore.Tab = pinned(newID, "Pin")
		copy = .init(id: newID, profileID: work, savedDestination: copy.savedDestination, restoration: copy.restoration)
		changed.tabs.append(copy)
		try store.save(changed, preferences: .init())

		// No move made it: the deletion stays on this Mac, the pin stays for other Macs.
		#expect(try store.database.read { db in try PinnedTabRecord.find(pinID.rawValue).fetchOne(db) } != nil)
		#expect(try store.database.read { db in try LocalDeletion.hiddenItems(db) }.contains(pinID.rawValue, in: PinnedTabRecord.tableName))
	}

	@Test
	func aTabAMoveCopiedGoesFromEveryMac() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		let work: Profile.ID = .init(rawValue: UUID(-53))
		let workSpace: Space.ID = .init(rawValue: UUID(-54))
		var start: BrowserOrganization = organization
		start.profiles.append(.init(id: work, name: "Work"))
		start.spaces.append(.init(id: workSpace, profileID: work, name: "Desk"))
		try store.save(start, preferences: .init())

		var counter: Int = 200
		let moved: BrowserOrganization = try start.movingSpace(spaceID, toProfile: work) {
			counter += 1
			return .init(rawValue: UUID(counter))
		}
		.updated
		#expect(moved.tabs.contains { $0.movedFrom == [pinID] })
		// Moved on before a save: the copies chain back to the pins the store has.
		let third: Profile.ID = .init(rawValue: UUID(-56))
		var twice: BrowserOrganization = moved
		twice.profiles.append(.init(id: third, name: "Side"))
		twice = try twice.movingSpace(spaceID, toProfile: third) {
			counter += 1
			return .init(rawValue: UUID(counter))
		}
		.updated
		try store.save(twice, preferences: .init())

		#expect(try store.database.read { db in try PinnedTabRecord.find(pinID.rawValue).fetchOne(db) } == nil)
		#expect(try store.database.read { db in try DeletionRecord.all.fetchAll(db) }.allSatisfy { $0.itemID != pinID.rawValue })
	}

	@Test
	func aFavoriteUnpinnedThenPinnedStaysAPin() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		var favorite: BrowserOrganization = withoutPin(organization)
		favorite.profiles[id: profileID]?.favorites = [pinID]
		favorite.tabs.append(pinned(pinID, "Pin"))
		try store.save(favorite, preferences: .init())

		// Unpinned to an open tab: the Favorite is hidden here.
		var open: BrowserOrganization = withoutPin(organization)
		open.spaces[id: spaceID]?.unpinnedTabs = [pinID]
		var tab: BrowserCore.Tab = pinned(pinID, "Pin")
		tab.savedDestination = nil
		open.tabs.append(tab)
		try store.save(open, preferences: .init())
		#expect(try store.database.read { db in try LocalDeletion.hiddenItems(db) }.contains(pinID.rawValue, in: FavoriteRecord.tableName))

		// Pinned again in a later save: the hidden Favorite goes, so no repair prefers it to the pin.
		try store.save(organization, preferences: .init())
		#expect(try store.database.read { db in try FavoriteRecord.find(pinID.rawValue).fetchOne(db) } == nil)
		_ = try store.database.write { db in try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: []) }
		#expect(try store.load()?.organization.tabs[id: pinID] != nil)
		#expect(try store.database.read { db in try PinnedTabRecord.find(pinID.rawValue).fetchOne(db) } != nil)
	}

	@Test
	func aHiddenFoldersOtherChildrenShowWhereItWas() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalDeletionTests-\(UUID().uuidString)")
		defer { TestFolders.removeAtExit(directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try store.save(organization, preferences: .init())

		// This Mac deletes the folder with its pin.
		var deleted: BrowserOrganization = organization
		deleted.spaces[id: spaceID]?.savedItems = [.tab(pinID)]
		deleted.folders.remove(id: folderID)
		deleted.tabs.remove(id: childID)
		try store.save(deleted, preferences: .init())
		#expect(try store.load()?.organization == deleted)

		// Another Mac adds a pin to it.
		let laterID: UUID = UUID(-6)
		try store.database.write { db in
			try PinnedTabRecord.insert {
				PinnedTabRecord(
					id: laterID,
					spaceID: spaceID.rawValue,
					folderID: folderID.rawValue,
					title: "Later",
					url: "https://later.example",
					position: "Z"
				)
			}
			.execute(db)
		}

		let loaded: BrowserOrganization = try #require(try store.load()?.organization)
		#expect(loaded.folders[id: folderID] == nil)
		#expect(loaded.tabs[id: childID] == nil)
		#expect(loaded.spaces[id: spaceID]?.savedItems == [.tab(pinID), .tab(.init(rawValue: laterID))])
	}

	@Test
	func undoingADeletionShowsTheItemAgain() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalDeletionTests-\(UUID().uuidString)")
		defer { TestFolders.removeAtExit(directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try store.save(organization, preferences: .init())

		try store.save(withoutPin(organization), preferences: .init())
		try store.save(organization, preferences: .init())

		#expect(try store.load()?.organization == organization)
		#expect(try store.database.read { db in try DeletionRecord.all.fetchAll(db).count } == 0)
	}

	@Test
	func withoutSyncADeletionDeletes() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalDeletionTests-\(UUID().uuidString)")
		defer { TestFolders.removeAtExit(directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let store: WorkspaceDatabase = try .init(directory: directory)
		try store.save(organization, preferences: .init())

		try store.save(withoutPin(organization), preferences: .init())

		#expect(try store.database.read { db in try PinnedTabRecord.find(pinID.rawValue).fetchOne(db) } == nil)
		#expect(try store.database.read { db in try DeletionRecord.all.fetchAll(db).count } == 0)
	}

	private func store() throws -> (URL, WorkspaceDatabase) {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalDeletionTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return (directory, try .init(directory: directory, separatePreferencesConnection: true))
	}

	@Test
	func aPinMovedToFavoritesStaysAFavorite() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization, preferences: .init())

		// The tab keeps its ID: a move, so the pin it was goes rather than staying hidden.
		var moved: BrowserOrganization = withoutPin(organization)
		moved.profiles[id: profileID]?.favorites = [pinID]
		moved.tabs.append(pinned(pinID, "Pin"))
		try store.save(moved, preferences: .init())

		#expect(try store.load()?.organization == moved)
		#expect(try WorkspaceDatabase(directory: directory).load()?.organization == moved)
	}

	@Test
	func aFavoriteThisMacOpenedAsATabStaysAFavoriteElsewhere() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let favoriteID: UUID = UUID(7)
		try database.write { db in
			let deviceID: UUID = try LocalDeletion.deviceID(db)
			try db.seed {
				ProfileRecord(id: profileID.rawValue, name: "Personal", position: "V")
				SpaceRecord(id: spaceID.rawValue, profileID: profileID.rawValue, name: "Home", position: "V")
				FavoriteRecord(id: favoriteID, profileID: profileID.rawValue, title: "Fav", url: "https://fav.example", position: "V")
				RegularTabRecord(id: favoriteID, spaceID: spaceID.rawValue, position: "V")
				DeletionRecord(id: UUID(8), itemID: favoriteID, itemTable: FavoriteRecord.tableName, deviceID: deviceID, deletedAt: 1)
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}

		#expect(summary.removedDuplicateTabs.isEmpty)
		#expect(try database.read { db in try FavoriteRecord.find(favoriteID).fetchOne(db) } != nil)
	}

	@Test
	func aDeletedSpaceStaysWhileSomethingInItIsUsed() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (Mac, Mac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		// A deletes the whole space, with a second space to keep.
		var kept: BrowserOrganization = organization
		let otherSpace: Space.ID = .init(rawValue: UUID(-9))
		kept.spaces.append(.init(id: otherSpace, profileID: profileID, name: "Other"))
		try a.store.save(kept, preferences: .init())
		var deleted: BrowserOrganization = kept
		deleted.spaces.remove(id: spaceID)
		deleted.folders.remove(id: folderID)
		deleted.tabs.removeAll()
		try a.store.save(deleted, preferences: .init())
		try await a.send()
		try await b.fetch()

		// B opens the pin in it.
		var opened: BrowserOrganization = try #require(try b.store.load()?.organization)
		opened.spaces[id: spaceID]?.selectedTabID = pinID
		try b.store.save(opened, preferences: .init())

		b.now.setValue(Date().addingTimeInterval(31 * 24 * 60 * 60))
		await b.sync.setSyncsDeletions(true)
		#expect(try b.hasRow(pinID))
		#expect(try b.store.load()?.organization.spaces[id: spaceID] != nil)
	}

	@Test
	func aChildShownAboveItsHiddenFolderKeepsItsFolderWhenRenamed() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization, preferences: .init())
		var deleted: BrowserOrganization = organization
		deleted.spaces[id: spaceID]?.savedItems = [.tab(pinID)]
		deleted.folders.remove(id: folderID)
		deleted.tabs.remove(id: childID)
		try store.save(deleted, preferences: .init())
		let laterID: UUID = UUID(-6)
		try store.database.write { db in
			try PinnedTabRecord.insert {
				PinnedTabRecord(
					id: laterID,
					spaceID: spaceID.rawValue,
					folderID: folderID.rawValue,
					title: "Later",
					url: "https://later.example",
					position: "Z"
				)
			}
			.execute(db)
		}

		var renamed: BrowserOrganization = try #require(try store.load()?.organization)
		renamed.tabs[id: .init(rawValue: laterID)]?.customTitle = "Renamed"
		try store.save(renamed, preferences: .init())

		let stored: PinnedTabRecord? = try store.database.read { db in try PinnedTabRecord.find(laterID).fetchOne(db) }
		#expect(stored?.customTitle == "Renamed")
		#expect(stored?.folderID == folderID.rawValue)
	}

	@Test
	func aPinAnotherMacMovedStaysWhereASaveHerePutsIt() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization, preferences: .init())
		let shown: BrowserOrganization = try #require(try store.load()?.organization)

		// Another Mac moves the root pin into a folder of another space.
		let otherSpace: UUID = UUID(-10)
		let otherFolder: UUID = UUID(-11)
		try store.database.write { db in
			try db.seed {
				SpaceRecord(id: otherSpace, profileID: profileID.rawValue, name: "Other", position: "W")
				FolderRecord(id: otherFolder, spaceID: otherSpace, name: "Elsewhere", position: "V")
			}
			try PinnedTabRecord.find(pinID.rawValue)
				.update {
					$0.spaceID = otherSpace
					$0.folderID = #bind(otherFolder)
				}
				.execute(db)
		}

		// A rename here, from what was shown before, never leaves the pin nowhere.
		var renamed: BrowserOrganization = shown
		renamed.tabs[id: pinID]?.customTitle = "Renamed"
		try store.save(renamed, preferences: .init())

		let loaded: BrowserOrganization = try #require(try WorkspaceDatabase(directory: directory).load()?.organization)
		#expect(loaded.tabs[id: pinID]?.customTitle == "Renamed")
		#expect(loaded.location(of: pinID) != nil)
	}

	@Test
	func aSpaceMovedToAnotherProfileMovesItsPinsOnOtherMacs() async throws {
		let cloud: TestCloud = .init()
		let work: Profile.ID = .init(rawValue: UUID(-12))
		var start: BrowserOrganization = organization
		start.profiles.append(.init(id: work, name: "Work"))
		let (a, b): (Mac, Mac) = try await twoMacs(cloud, starting: start)
		defer {
			a.remove()
			b.remove()
		}

		var counter: Int = 100
		let moved: BrowserOrganization = try start.movingSpace(spaceID, toProfile: work) {
			counter += 1
			return .init(rawValue: UUID(counter))
		}
		.updated
		try a.store.save(moved, preferences: .init())
		try await a.send()
		try await b.fetch()

		// The pins are copies in the new profile, not copies beside the old ones.
		let onB: BrowserOrganization = try #require(try b.store.load()?.organization)
		#expect(onB.spaces[id: spaceID]?.profileID == work)
		#expect(onB.tabs[id: pinID] == nil)
		#expect(onB.tabs[id: childID] == nil)
		#expect(onB.tabs.count == moved.tabs.count)
		#expect(try !a.hasRow(pinID))
	}

	@Test
	func aChildRenamedHereAfterAnotherMacRemovedItsFolderStaysShown() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization, preferences: .init())
		let shown: BrowserOrganization = try #require(try store.load()?.organization)

		// Another Mac moves the child out of the folder, then removes the folder.
		try store.database.write { db in
			try PinnedTabRecord.find(childID.rawValue).update { $0.folderID = #bind(nil) }.execute(db)
			try FolderRecord.find(folderID.rawValue).delete().execute(db)
		}

		var renamed: BrowserOrganization = shown
		renamed.tabs[id: childID]?.customTitle = "Renamed"
		try store.save(renamed, preferences: .init())

		let loaded: BrowserOrganization = try #require(try WorkspaceDatabase(directory: directory).load()?.organization)
		#expect(loaded.tabs[id: childID]?.customTitle == "Renamed")
		#expect(loaded.location(of: childID) != nil)
	}

	@Test
	func aPinTurnedIntoAFavoriteBesideOneMovedAwayStays() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		let work: Profile.ID = .init(rawValue: UUID(-12))
		let workSpace: Space.ID = .init(rawValue: UUID(-13))
		let first: BrowserCore.Tab.ID = .init(rawValue: UUID(-20))
		let second: BrowserCore.Tab.ID = .init(rawValue: UUID(-21))
		let copy: BrowserCore.Tab.ID = .init(rawValue: UUID(-22))
		let start: BrowserOrganization = .init(
			profiles: [.init(id: profileID, name: "Personal"), .init(id: work, name: "Work")],
			legacyProfileID: profileID,
			spaces: [
				.init(id: spaceID, profileID: profileID, name: "Home", savedItems: [.tab(first), .tab(second)]),
				.init(id: workSpace, profileID: work, name: "Desk"),
			],
			tabs: [pinned(first, "Same"), pinned(second, "Same")]
		)
		try store.save(start, preferences: .init())

		// One of two identical pins becomes a Favorite here, and the other moves to Work.
		var changed: BrowserOrganization = start
		changed.spaces[id: spaceID]?.savedItems = []
		changed.profiles[id: profileID]?.favorites = [first]
		changed.spaces[id: workSpace]?.savedItems = [.tab(copy)]
		changed.tabs.remove(id: second)
		let url: URL = URL(string: "https://same.example")!
		changed.tabs.append(.init(
			id: copy,
			profileID: work,
			savedDestination: .init(title: "Same", url: url),
			restoration: .init(title: "Same", url: url),
			movedFrom: [second]
		))
		try store.save(changed, preferences: .init())

		let loaded: BrowserOrganization = try #require(try WorkspaceDatabase(directory: directory).load()?.organization)
		#expect(loaded.profiles[id: profileID]?.favorites == [first])
		#expect(loaded.tabs[id: copy] != nil)
		#expect(loaded.tabs[id: second] == nil)
	}
}
