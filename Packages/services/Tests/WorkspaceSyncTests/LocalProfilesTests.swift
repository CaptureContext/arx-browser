import BrowserCore
import BrowserHistoryClient
import ConcurrencyExtras
import Foundation
import GRDB
import HistoryDatabase
@testable import SQLiteData
import Testing
@testable import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// "This Mac only" profiles (DEV-981): their rows live in `arx-organization-local.sqlite`, their
/// synced copies stay as they are for the other Macs, and turning sync back on publishes this Mac's
/// copy while keeping what other Macs added.
@Suite(.timeLimit(.minutes(1)))
struct LocalProfilesTests {
	private let synced: Profile.ID = .init(rawValue: UUID(-1))
	private let local: Profile.ID = .init(rawValue: UUID(-2))
	private let syncedSpace: Space.ID = .init(rawValue: UUID(-3))
	private let localSpace: Space.ID = .init(rawValue: UUID(-4))
	private let pinID: BrowserCore.Tab.ID = .init(rawValue: UUID(-5))
	private let openID: BrowserCore.Tab.ID = .init(rawValue: UUID(-6))

	private func organization(localSyncs: Bool) -> BrowserOrganization {
		let url: URL = URL(string: "https://pin.example")!
		return .init(
			profiles: [
				.init(id: synced, name: "Personal"),
				.init(id: local, name: "Work", syncsWithICloud: localSyncs ? nil : false),
			],
			legacyProfileID: synced,
			spaces: [
				.init(id: syncedSpace, profileID: synced, name: "Home"),
				.init(
					id: localSpace,
					profileID: local,
					name: "Desk",
					savedItems: [.tab(pinID)],
					unpinnedTabs: [openID],
					selectedTabID: openID
				),
			],
			tabs: [
				.init(id: pinID, profileID: local, savedDestination: .init(title: "Pin", url: url), restoration: .init(title: "Pin", url: url)),
				.init(id: openID, profileID: local, restoration: .init(title: "Open", url: URL(string: "https://open.example")!)),
			]
		)
	}

	private func store() throws -> (URL, WorkspaceDatabase) {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalProfilesTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return (directory, try .init(directory: directory, separatePreferencesConnection: true))
	}

	private func count(_ table: String, schema: String = "main", _ store: WorkspaceDatabase) throws -> Int {
		try store.database.read { db in
			try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(schema)\".\"\(table)\"") ?? 0
		}
	}

	@Test
	func aThisMacOnlyProfileIsWrittenToTheLocalFileOnly() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		let organization: BrowserOrganization = organization(localSyncs: false)
		try store.save(organization, preferences: .init())

		#expect(try count(ProfileRecord.tableName, store) == 1)
		#expect(try count(SpaceRecord.tableName, store) == 1)
		#expect(try count(PinnedTabRecord.tableName, store) == 0)
		#expect(try count(ProfileRecord.tableName, schema: "local", store) == 1)
		#expect(try count(PinnedTabRecord.tableName, schema: "local", store) == 1)
		#expect(try count(RegularTabRecord.tableName, schema: "local", store) == 1)
		#expect(try WorkspaceDatabase(directory: directory).load()?.organization == organization)
	}

	@Test
	func turningAProfileLocalLeavesItsSyncedCopyAsItIs() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: true), preferences: .init())
		#expect(try count(PinnedTabRecord.tableName, store) == 1)

		var turned: BrowserOrganization = organization(localSyncs: false)
		try store.save(turned, preferences: .init())

		// Nothing synced is deleted or hidden: the other Macs keep their copy.
		#expect(try count(ProfileRecord.tableName, store) == 2)
		#expect(try count(PinnedTabRecord.tableName, store) == 1)
		#expect(try count(DeletionRecord.tableName, store) == 0)
		// Its open tabs and selection are this Mac's own: they move.
		#expect(try count(RegularTabRecord.tableName, store) == 0)
		#expect(try count(RegularTabRecord.tableName, schema: "local", store) == 1)
		#expect(try WorkspaceDatabase(directory: directory).load()?.organization == turned)

		// Edits here reach the local copy only.
		turned.spaces[id: localSpace]?.name = "Renamed here"
		try store.save(turned, preferences: .init())
		let syncedName: String? = try store.database.read { db in
			try SpaceRecord.find(localSpace.rawValue).fetchOne(db)?.name
		}
		#expect(syncedName == "Desk")
	}

	@Test
	func anotherMacsEditToTheSyncedCopyDoesntShow() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: true), preferences: .init())
		try store.save(organization(localSyncs: false), preferences: .init())

		try store.database.write { db in
			try SpaceRecord.find(localSpace.rawValue).update { $0.name = "From another Mac" }.execute(db)
		}

		#expect(try store.load()?.organization.spaces[id: localSpace]?.name == "Desk")
	}

	@Test
	func turningItBackOnPublishesThisMacsCopyAndKeepsOtherMacsAdditions() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: true), preferences: .init())
		var local: BrowserOrganization = organization(localSyncs: false)
		try store.save(local, preferences: .init())

		// While local: renamed and its pin deleted here; another Mac adds a space to it.
		local.spaces[id: localSpace]?.name = "Renamed here"
		local.spaces[id: localSpace]?.savedItems = []
		local.tabs.remove(id: pinID)
		try store.save(local, preferences: .init())
		let added: UUID = UUID(-7)
		try store.database.write { db in
			try SpaceRecord.insert {
				SpaceRecord(id: added, profileID: self.local.rawValue, name: "Added elsewhere", position: "Z")
			}
			.execute(db)
		}

		var back: BrowserOrganization = local
		back.profiles[id: self.local]?.syncsWithICloud = nil
		try store.save(back, preferences: .init())

		let loaded: BrowserOrganization = try #require(try WorkspaceDatabase(directory: directory, separatePreferencesConnection: true).load()?.organization)
		#expect(loaded.spaces[id: localSpace]?.name == "Renamed here")
		#expect(loaded.tabs[id: pinID] == nil)
		#expect(loaded.spaces[id: .init(rawValue: added)] != nil)
		#expect(loaded.profiles[id: self.local]?.isThisMacOnly == false)
		// The pin deleted while local is hidden here, as any deletion, and stays on other Macs.
		#expect(try count(PinnedTabRecord.tableName, store) == 1)
		#expect(try store.database.read { db in try LocalDeletion.hiddenItems(db) }.contains(pinID.rawValue, in: PinnedTabRecord.tableName))
		#expect(try count(ProfileRecord.tableName, schema: "local", store) == 0)
	}

	@Test
	func turningAProfileLocalWhileRemovingSomethingDeletesNothingSynced() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: true), preferences: .init())

		// One save turns it local and removes its pin.
		var turned: BrowserOrganization = organization(localSyncs: false)
		turned.spaces[id: localSpace]?.savedItems = []
		turned.tabs.remove(id: pinID)
		try store.save(turned, preferences: .init())

		#expect(try count(PinnedTabRecord.tableName, store) == 1)
		#expect(try count(DeletionRecord.tableName, store) == 0)
		#expect(try store.load()?.organization == turned)
	}

	@Test
	func aLocalSpaceAnotherMacMovedAwayStillShowsOnlyAsItIsHere() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: true), preferences: .init())
		let turned: BrowserOrganization = organization(localSyncs: false)
		try store.save(turned, preferences: .init())

		// Another Mac moves the synced copy of the local space to the synced profile and pins in it.
		try store.database.write { db in
			try SpaceRecord.find(localSpace.rawValue).update { $0.profileID = synced.rawValue }.execute(db)
			try PinnedTabRecord.insert {
				PinnedTabRecord(id: UUID(-10), spaceID: localSpace.rawValue, title: "Remote", url: "https://remote.example", position: "Z")
			}
			.execute(db)
		}

		#expect(try store.load()?.organization == turned)
	}

	@Test
	func turningItBackOnKeepsASpaceMovedToAnotherProfileMeanwhile() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: true), preferences: .init())
		var local: BrowserOrganization = organization(localSyncs: false)
		try store.save(local, preferences: .init())

		// While local, its space moves to the synced profile here, with its pin.
		local.spaces[id: localSpace] = .init(
			id: localSpace,
			profileID: synced,
			name: "Desk",
			savedItems: [.tab(pinID)]
		)
		local.tabs = .init(uniqueElements: local.tabs.compactMap { (tab: BrowserCore.Tab) -> BrowserCore.Tab? in
			guard tab.id == pinID else { return nil }

			return .init(id: pinID, profileID: synced, savedDestination: tab.savedDestination, restoration: tab.restoration)
		})
		let movedAway: BrowserOrganization = local
		try store.save(movedAway, preferences: .init())

		var back: BrowserOrganization = movedAway
		back.profiles[id: self.local]?.syncsWithICloud = nil
		try store.save(back, preferences: .init())

		let loaded: BrowserOrganization = try #require(try WorkspaceDatabase(directory: directory, separatePreferencesConnection: true).load()?.organization)
		#expect(loaded.spaces[id: localSpace]?.profileID == synced)
		#expect(loaded.tabs[id: pinID] != nil)
		#expect(try !store.database.read { db in try LocalDeletion.hiddenItems(db) }.contains(localSpace.rawValue, in: SpaceRecord.tableName))
	}

	@Test
	func removingALocalProfileKeepsItsSyncedCopyHidden() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: true), preferences: .init())
		try store.save(organization(localSyncs: false), preferences: .init())

		var removed: BrowserOrganization = organization(localSyncs: false)
		removed.profiles.remove(id: local)
		removed.spaces.remove(id: localSpace)
		removed.tabs.removeAll()
		try store.save(removed, preferences: .init())

		#expect(try WorkspaceDatabase(directory: directory, separatePreferencesConnection: true).load()?.organization == removed)
		#expect(try count(ProfileRecord.tableName, store) == 2)
		#expect(try store.database.read { db in try LocalDeletion.hiddenItems(db) }.contains(local.rawValue, in: ProfileRecord.tableName))
	}

	@Test
	func aRemovedLocalProfilesHistoryStaysLocal() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalProfilesTests-\(UUID().uuidString)")
		defer { TestFolders.removeAtExit(directory) }
		let history: HistoryDatabase = try .init(directory: directory)
		let now: Date = .init()
		try history.database.write { db in
			try HistoryDatabase.setMirrorWindow(db, days: 30, now: now)
			try HistoryDatabase.setLocalProfiles(db, [local.rawValue], syncing: [synced.rawValue], now: now)

			// Gone from the workspace: not local any more, and not syncing either.
			try HistoryDatabase.setLocalProfiles(db, [], syncing: [synced.rawValue], now: now)
			#expect(try HistoryDatabase.localProfiles(db) == [local.rawValue])
			// Turned back on: syncs again.
			try HistoryDatabase.setLocalProfiles(db, [], syncing: [synced.rawValue, local.rawValue], now: now)
			#expect(try HistoryDatabase.localProfiles(db).isEmpty)
		}
	}

	@Test
	func aSpaceMovedIntoALocalProfileAndDeletedThereStaysGone() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		var organization: BrowserOrganization = organization(localSyncs: false)
		try store.save(organization, preferences: .init())

		// The synced profile's space moves into the local profile, then is deleted there.
		organization.spaces[id: syncedSpace] = .init(id: syncedSpace, profileID: local, name: "Home")
		try store.save(organization, preferences: .init())
		organization.spaces.remove(id: syncedSpace)
		try store.save(organization, preferences: .init())

		let loaded: BrowserOrganization? = try WorkspaceDatabase(directory: directory, separatePreferencesConnection: true).load()?.organization
		#expect(loaded?.spaces[id: syncedSpace] == nil)
		// Other Macs keep it.
		#expect(try count(SpaceRecord.tableName, store) == 1)
	}

	@Test
	func aLocalFileRestoredFromBeforeItsFirstSaveIsAPartialStore() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: false), preferences: .init())
		try store.database.write { db in
			try LocalStoreInfoRecord.find(StoreInfoKey.revision).delete().execute(db)
		}

		#expect(throws: WorkspaceDatabase.Failure.partialStore) {
			_ = try store.load()
		}
	}

	@Test
	func aSpaceDeletedWhileLocalStaysGoneWhenAnotherMacMovesItsCopy() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: true), preferences: .init())
		var local: BrowserOrganization = organization(localSyncs: false)
		try store.save(local, preferences: .init())
		local.spaces.remove(id: localSpace)
		local.tabs.removeAll()
		try store.save(local, preferences: .init())

		// Another Mac moves the synced copy to the synced profile.
		try store.database.write { db in
			try SpaceRecord.find(localSpace.rawValue).update { $0.profileID = synced.rawValue }.execute(db)
		}

		#expect(try store.load()?.organization.spaces[id: localSpace] == nil)
	}

	@Test
	func aFavoriteTurnedIntoAPinWhileLocalIsAMoveWhenItsBackOn() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		var start: BrowserOrganization = organization(localSyncs: true)
		start.spaces[id: localSpace]?.savedItems = []
		start.profiles[id: local]?.favorites = [pinID]
		try store.save(start, preferences: .init())
		var local: BrowserOrganization = start
		local.profiles[id: self.local]?.syncsWithICloud = false
		try store.save(local, preferences: .init())

		// While local, the Favorite becomes a pin.
		local.profiles[id: self.local]?.favorites = []
		local.spaces[id: localSpace]?.savedItems = [.tab(pinID)]
		try store.save(local, preferences: .init())
		var back: BrowserOrganization = local
		back.profiles[id: self.local]?.syncsWithICloud = nil
		try store.save(back, preferences: .init())

		#expect(try count(FavoriteRecord.tableName, store) == 0)
		#expect(try count(PinnedTabRecord.tableName, store) == 1)
		#expect(try WorkspaceDatabase(directory: directory, separatePreferencesConnection: true).load()?.organization == back)
	}

	@Test
	func aSpaceMovedToAnotherLocalProfileStaysShadowedWhenItsSourceReconnects() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		let other: Profile.ID = .init(rawValue: UUID(-11))
		var organization: BrowserOrganization = organization(localSyncs: true)
		organization.profiles.append(.init(id: other, name: "Side", syncsWithICloud: false))
		try store.save(organization, preferences: .init())
		organization.profiles[id: local]?.syncsWithICloud = false
		try store.save(organization, preferences: .init())

		// Its space moves to the other local profile; then it syncs again; then the space is deleted.
		organization.spaces[id: localSpace] = .init(id: localSpace, profileID: other, name: "Desk")
		organization.tabs.removeAll()
		try store.save(organization, preferences: .init())
		organization.profiles[id: local]?.syncsWithICloud = nil
		try store.save(organization, preferences: .init())
		organization.spaces.remove(id: localSpace)
		try store.save(organization, preferences: .init())

		#expect(try WorkspaceDatabase(directory: directory, separatePreferencesConnection: true).load()?.organization.spaces[id: localSpace] == nil)
	}

	@Test
	func aLostLocalFileIsAPartialStore() throws {
		let (directory, store): (URL, WorkspaceDatabase) = try store()
		defer { TestFolders.removeAtExit(directory) }
		try store.save(organization(localSyncs: false), preferences: .init())
		try store.database.close()
		try store.preferencesDatabase?.close()
		try store.archiveDatabase?.close()
		try FileManager.default.removeItem(at: directory.appendingPathComponent(WorkspaceDatabase.localFileName))

		#expect(throws: WorkspaceDatabase.Failure.partialStore) {
			_ = try WorkspaceDatabase(directory: directory)
		}
	}

	@Test
	func aThisMacOnlyProfilesHistoryIsNeverMirroredOrTakenIn() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalProfilesTests-\(UUID().uuidString)")
		defer { TestFolders.removeAtExit(directory) }
		let history: HistoryDatabase = try .init(directory: directory)
		let now: Date = .init()
		let entry: BrowsingHistoryEntry = .init(
			id: UUID(-8),
			url: URL(string: "https://visited.example")!,
			title: "Visited",
			lastVisited: now
		)
		try history.database.write { db in
			try HistoryDatabase.setMirrorWindow(db, days: 30, now: now)
			try HistoryDatabase.setLocalProfiles(db, [local.rawValue], syncing: [synced.rawValue], now: now)
			try HistoryDatabase.mirror(db, profileID: local, entries: [entry], now: now)
			try HistoryDatabase.mirror(db, profileID: synced, entries: [entry], now: now)
		}

		let mirrored: Set<UUID> = try history.database.read { db in
			Set(try HistoryVisitRecord.fetchAll(db).map(\.profileID))
		}
		#expect(mirrored == [synced.rawValue])

		// Another Mac's copy of its history isn't taken in either.
		try history.database.write { db in
			try HistoryVisitRecord.insert {
				HistoryVisitRecord(
					id: UUID(-9),
					profileID: local.rawValue,
					url: "https://elsewhere.example",
					title: "Elsewhere",
					lastVisited: now.timeIntervalSinceReferenceDate
				)
			}
			.execute(db)
		}
		let taken: [Profile.ID: SyncedHistory] = try history.database.read { db in try HistoryDatabase.synced(db) }
		#expect(taken[local] == nil)
	}

	@Test
	func anOlderHandoffNeverMirrorsAProfileThatWentLocal() async throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("LocalProfilesTests-\(UUID().uuidString)")
		defer { TestFolders.removeAtExit(directory) }
		let history: HistoryDatabase = try .init(directory: directory)
		let now: Date = .init()
		try await history.database.write { db in
			try HistoryDatabase.setMirrorWindow(db, days: 30, now: now)
		}

		// The profile went "this Mac only"; the workspace says so now.
		let current: LockIsolated<ProfileSync> = .init(.init(local: [local], syncing: [synced]))
		let store: BrowserHistoryDatabaseStore = .init(
			history: history,
			legacyDirectory: directory.appendingPathComponent("History"),
			now: { now },
			localProfiles: { current.value }
		)
		_ = try await store.record(local, url: URL(string: "https://private.example")!, title: "Private", date: now)

		// A handoff made before the change arrives late, still saying it syncs.
		await store.setLocalProfiles(.init(local: [], syncing: [local, synced]))

		let mirrored: Set<UUID> = try await history.database.read { db in
			Set(try HistoryVisitRecord.fetchAll(db).map(\.profileID))
		}
		#expect(!mirrored.contains(local.rawValue))
		let recorded: Set<UUID> = try await history.database.read { db in try HistoryDatabase.localProfiles(db) }
		#expect(recorded == [local.rawValue])
	}
}
