import BrowserCore
import Foundation
import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// The matching rules of DEV-1216 and applying a merge to one database.
struct WorkspaceMergeTests {
	// iCloud's workspace: Default with Home and Work, Work's pins in a folder.
	private let cloudProfile: UUID = UUID(1)
	private let cloudHome: UUID = UUID(2)
	private let cloudWork: UUID = UUID(3)
	private let cloudFolder: UUID = UUID(4)

	// This Mac's: its own Default with the same spaces, one of them renamed and one more.
	private let localProfile: UUID = UUID(101)
	private let localHome: UUID = UUID(102)
	private let localWork: UUID = UUID(103)
	private let localFolder: UUID = UUID(104)
	private let localSide: UUID = UUID(105)

	private var cloud: WorkspaceMerge.Snapshot {
		.init(
			profiles: [ProfileRecord(id: cloudProfile, name: "Default", searchEngine: "duckduckgo", position: "V", isStarter: true)],
			spaces: [
				SpaceRecord(id: cloudHome, profileID: cloudProfile, name: "Default", icon: "house", position: "V", isStarter: true),
				SpaceRecord(id: cloudWork, profileID: cloudProfile, name: "Work", icon: "briefcase", appearance: "green", position: "W"),
			],
			folders: [FolderRecord(id: cloudFolder, spaceID: cloudWork, name: "Docs", position: "V")],
			pinnedTabs: [
				PinnedTabRecord(id: UUID(10), spaceID: cloudHome, title: "Mail", url: "https://mail.example/", position: "V"),
				PinnedTabRecord(id: UUID(11), spaceID: cloudWork, folderID: cloudFolder, title: "Spec", url: "https://docs.example/spec", position: "V"),
				PinnedTabRecord(id: UUID(12), spaceID: cloudWork, title: "Tracker", url: "https://tracker.example", position: "W"),
			],
			favorites: [FavoriteRecord(id: UUID(20), profileID: cloudProfile, title: "News", url: "https://news.example", position: "V")]
		)
	}

	private var local: WorkspaceMerge.Snapshot {
		.init(
			profiles: [ProfileRecord(id: localProfile, name: "default", searchEngine: "google", position: "V", isStarter: true)],
			spaces: [
				SpaceRecord(id: localHome, profileID: localProfile, name: "Home", icon: "house", position: "V", isStarter: true),
				SpaceRecord(id: localWork, profileID: localProfile, name: " work ", icon: "briefcase", appearance: "blue", position: "W"),
				SpaceRecord(id: localSide, profileID: localProfile, name: "Side", position: "X"),
			],
			folders: [FolderRecord(id: localFolder, spaceID: localWork, name: "docs", position: "V")],
			pinnedTabs: [
				// The same as iCloud's, written differently.
				PinnedTabRecord(id: UUID(110), spaceID: localHome, title: "Mail", url: "HTTPS://Mail.Example", position: "V"),
				PinnedTabRecord(id: UUID(111), spaceID: localWork, folderID: localFolder, title: "Spec", url: "https://docs.example/spec#intro", position: "V"),
				// This Mac's own, kept in its order after iCloud's.
				PinnedTabRecord(id: UUID(112), spaceID: localWork, folderID: localFolder, title: "Notes", url: "https://docs.example/notes", position: "W"),
				PinnedTabRecord(id: UUID(113), spaceID: localWork, title: "Board", url: "https://board.example", position: "X"),
				PinnedTabRecord(id: UUID(114), spaceID: localWork, title: "Chat", url: "https://chat.example", position: "Y"),
			],
			favorites: [
				FavoriteRecord(id: UUID(120), profileID: localProfile, title: "News", url: "https://news.example/", position: "V"),
				FavoriteRecord(id: UUID(121), profileID: localProfile, title: "Weather", url: "https://weather.example", position: "W"),
			]
		)
	}

	// MARK: - Keys

	@Test
	func namesMatchIgnoringCaseAndSpaces() {
		#expect(WorkspaceMerge.nameKey("My Work") == WorkspaceMerge.nameKey("  my work "))
		#expect(WorkspaceMerge.nameKey("Default") == WorkspaceMerge.nameKey("DEFAULT"))
		#expect(WorkspaceMerge.nameKey("MyWork") == WorkspaceMerge.nameKey("my work"))
		#expect(WorkspaceMerge.nameKey("Work") != WorkspaceMerge.nameKey("Works"))
	}

	@Test
	func addressesIgnoreSchemeAndHostCaseTrailingSlashAndFragment() {
		let key: (String) -> String = WorkspaceMerge.addressKey
		#expect(key("HTTPS://Example.COM/") == key("https://example.com"))
		#expect(key("https://example.com/path/") == key("https://example.com/path"))
		#expect(key("https://example.com/path#section") == key("https://example.com/path"))
		// The path and query keep their case: they're the site's to compare.
		#expect(key("https://example.com/Path") != key("https://example.com/path"))
		#expect(key("https://example.com/?q=1") != key("https://example.com/?q=2"))
		#expect(key("http://example.com") != key("https://example.com"))
		#expect(key(" not a url ") == "not a url")
	}

	@Test
	func overlapIsStrongWhenMostOfTheSmallerSpacesPinsAreShared() {
		#expect(WorkspaceMerge.isStrongOverlap(common: 2, 2, 10))
		#expect(WorkspaceMerge.isStrongOverlap(common: 3, 5, 4))
		// One pin in common is never enough, nor half.
		#expect(!WorkspaceMerge.isStrongOverlap(common: 1, 1, 1))
		#expect(!WorkspaceMerge.isStrongOverlap(common: 2, 4, 4))
	}

	@Test
	func takenNamesGetTheMacsName() {
		let taken: Set<String> = ["work", "work(macbookair)"]
		#expect(WorkspaceMerge.uniqueName("Side", macName: "MacBook Air", taken: taken) == "Side")
		#expect(WorkspaceMerge.uniqueName("Work", macName: "MacBook Air", taken: ["work"]) == "Work (MacBook Air)")
		#expect(WorkspaceMerge.uniqueName("Work", macName: "MacBook Air", taken: taken) == "Work (MacBook Air 2)")
	}

	// MARK: - Matching

	@Test
	func matchingProfilesSpacesFoldersAndPinsBecomeOneAndTheRestFollowICloudsInThisMacsOrder() {
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: local, cloud: cloud, macName: "MacBook Air")

		#expect(matching.profiles == [localProfile: cloudProfile])
		// The starter space with the starter space whatever its name, then by name.
		#expect(matching.spaces == [localHome: cloudHome, localWork: cloudWork])
		#expect(matching.folders == [localFolder: cloudFolder])
		#expect(matching.pinnedTabs == [UUID(110): UUID(10), UUID(111): UUID(11)])
		#expect(matching.favorites == [UUID(120): UUID(20)])

		// This Mac's own pin in the matched folder goes after iCloud's there; the root ones after
		// iCloud's root, in this Mac's order.
		#expect(matching.pinMoves[UUID(112)] == .init(parentID: cloudWork, folderID: cloudFolder, position: "W"))
		#expect(matching.pinMoves[UUID(113)] == .init(parentID: cloudWork, folderID: nil, position: "X"))
		#expect(matching.pinMoves[UUID(114)] == .init(parentID: cloudWork, folderID: nil, position: "Y"))
		#expect(matching.favoriteMoves[UUID(121)] == .init(parentID: cloudProfile, position: "W"))
		// Side is added after iCloud's spaces.
		#expect(matching.spaceMoves[localSide] == .init(parentID: cloudProfile, position: "X"))
		#expect(matching.spaceNames.isEmpty)

		let plan: WorkspaceMerge.Plan = matching.plan
		#expect(plan.addedProfiles.isEmpty)
		#expect(plan.profiles.count == 1)
		let profile: WorkspaceMerge.ProfileMatch = plan.profiles[0]
		#expect(profile.name == "Default")
		#expect(profile.addedSpaces == [.init(id: localSide, name: "Side")])
		#expect(profile.favorites == .init(total: 2, new: 1))
		// iCloud wins: its name and search engine are listed as changes here.
		#expect(profile.settings.map(\.setting) == [.name, .searchEngine])
		let work: WorkspaceMerge.SpaceMatch? = profile.spaces.first { $0.mergedID == localWork }
		#expect(work?.reason == .name)
		#expect(work?.pins == .init(total: 5, new: 3))
		#expect(work?.folders == .init(total: 1, new: 0))
		#expect(work?.settings.map(\.setting) == [.name, .colors])
		#expect(profile.spaces.first { $0.mergedID == localHome }?.reason == .starter)
		#expect(plan.needsReview)
	}

	@Test
	func spacesWithDifferentNamesMatchByPinsInCommon() {
		var local: WorkspaceMerge.Snapshot = local
		local.spaces = local.spaces.map { space in
			var space: SpaceRecord = space
			if space.id == localWork { space.name = "Job" }
			return space
		}

		// Two of Work's pins: iCloud's Spec and Tracker.
		local.pinnedTabs.append(PinnedTabRecord(id: UUID(115), spaceID: localWork, title: "Tracker", url: "https://tracker.example/", position: "Z"))
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: local, cloud: cloud, macName: "Mac")
		#expect(matching.spaces[localWork] == cloudWork)
		#expect(matching.plan.profiles.first?.spaces.first { $0.mergedID == localWork }?.reason == .pins)

		// With only one in common, Job is added instead, as it is.
		local.pinnedTabs.removeAll { $0.id == UUID(115) }
		let unmatched: WorkspaceMerge.Matching = WorkspaceMerge.match(local: local, cloud: cloud, macName: "Mac")
		#expect(unmatched.spaces[localWork] == nil)
		#expect(unmatched.plan.profiles.first?.addedSpaces.map(\.name).contains("Job") == true)
	}

	@Test
	func ofSeveralProfilesWithTheNameTheOneWhoseSpacesOverlapMostMatches() {
		var cloud: WorkspaceMerge.Snapshot = cloud

		// Another Default in iCloud, sorted first, with nothing in common.
		cloud.profiles.append(ProfileRecord(id: UUID(0), name: "Default", position: "A"))
		cloud.spaces.append(SpaceRecord(id: UUID(5), profileID: UUID(0), name: "Elsewhere", position: "V"))
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: local, cloud: cloud, macName: "Mac")
		#expect(matching.profiles == [localProfile: cloudProfile])
	}

	@Test
	func keptSeparateItemsAreAddedWithTheMacsNameWhenTheirNameIsTaken() {
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(
			local: local,
			cloud: cloud,
			macName: "MacBook Air",
			keepingSeparate: [localWork]
		)
		#expect(matching.spaces[localWork] == nil)
		#expect(matching.spaceNames[localWork] == " work  (MacBook Air)")
		#expect(matching.spaceMoves[localWork]?.parentID == cloudProfile)
		#expect(matching.plan.profiles.first?.addedSpaces.first { $0.id == localWork }?.newName == " work  (MacBook Air)")
		// Its pins stay in it.
		#expect(matching.pinMoves[UUID(113)] == nil)

		let separateProfile: WorkspaceMerge.Matching = WorkspaceMerge.match(
			local: local,
			cloud: cloud,
			macName: "MacBook Air",
			keepingSeparate: [localProfile]
		)
		#expect(separateProfile.profiles.isEmpty)
		#expect(separateProfile.profileNames[localProfile] == "default (MacBook Air)")
		#expect(separateProfile.plan.addedProfiles == [.init(id: localProfile, name: "default", newName: "default (MacBook Air)")])
		#expect(separateProfile.profilePositions[localProfile] == "W")
	}

	@Test
	func unmatchedProfilesAreAddedAsTheyAre() {
		var local: WorkspaceMerge.Snapshot = local
		local.profiles.append(ProfileRecord(id: UUID(200), name: "Personal", position: "W"))
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: local, cloud: cloud, macName: "Mac")
		#expect(matching.plan.addedProfiles == [.init(id: UUID(200), name: "Personal")])
		#expect(matching.profilePositions[UUID(200)] == "W")
	}

	@Test
	func anUntouchedStarterMergesWithoutAPreview() {
		let local: WorkspaceMerge.Snapshot = .init(
			profiles: [ProfileRecord(id: localProfile, name: "Default", searchEngine: "duckduckgo", position: "V", isStarter: true)],
			spaces: [SpaceRecord(id: localHome, profileID: localProfile, name: "Default", icon: "house", position: "V", isStarter: true)]
		)
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: local, cloud: cloud, macName: "Mac")
		#expect(matching.profiles == [localProfile: cloudProfile])
		#expect(matching.spaces == [localHome: cloudHome])
		#expect(!matching.plan.needsReview)
	}

	@Test
	func itemsICloudAlreadyHasAreNotMatchedAgain() {
		var local: WorkspaceMerge.Snapshot = cloud
		local.profiles.append(ProfileRecord(id: UUID(200), name: "Personal", position: "W"))
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: local, cloud: cloud, macName: "Mac")
		#expect(matching.profiles.isEmpty)
		#expect(matching.plan.addedProfiles.map(\.id) == [UUID(200)])
	}

	// MARK: - Applying

	private func database(_ snapshot: WorkspaceMerge.Snapshot) throws -> DatabaseQueue {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		try database.writeAllowingSyncedDeletions { db in
			for profile in snapshot.profiles { try ProfileRecord.insert { profile }.execute(db) }
			for space in snapshot.spaces { try SpaceRecord.insert { space }.execute(db) }
			for folder in snapshot.folders { try FolderRecord.insert { folder }.execute(db) }
			for tab in snapshot.pinnedTabs { try PinnedTabRecord.insert { tab }.execute(db) }
			for favorite in snapshot.favorites { try FavoriteRecord.insert { favorite }.execute(db) }
		}
		return database
	}

	@Test
	func aJoiningMacMovesItsRowsIntoICloudsAndKeepsItsStateAndWebsiteData() throws {
		let database: DatabaseQueue = try database(local)
		try database.write { db in
			try db.seed {
				RegularTabRecord(id: UUID(130), spaceID: localWork, position: "V")
				SpaceStateRecord(id: localWork, selectedTabID: UUID(111))
				FolderStateRecord(id: localFolder, isExpanded: false, ordinal: "V")
				TabStateRecord(id: UUID(111), restorationTitle: "Spec", restorationURL: "https://docs.example/spec#intro", ordinal: "V")
			}
		}
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: try database.read { try .init($0) }, cloud: cloud, macName: "Mac")
		try database.writeAllowingSyncedDeletions { db in
			try WorkspaceMerge.applyJoining(matching, cloud: cloud, db)
		}

		let rows: WorkspaceMerge.Snapshot = try database.read { try .init($0) }

		// One profile, iCloud's, with iCloud's values.
		#expect(rows.profiles == [cloud.profiles[0]])
		#expect(Set(rows.spaces.map(\.id)) == [cloudHome, cloudWork, localSide])
		#expect(rows.spaces.first { $0.id == cloudWork } == cloud.spaces[1])
		#expect(rows.spaces.first { $0.id == localSide }?.profileID == cloudProfile)
		// None lost: iCloud's matched pins (the rest arrive with the first fetch) and this Mac's own.
		#expect(Set(rows.pinnedTabs.map(\.id)) == [UUID(10), UUID(11), UUID(112), UUID(113), UUID(114)])
		#expect(rows.pinnedTabs.first { $0.id == UUID(112) }?.folderID == cloudFolder)
		#expect(Set(rows.favorites.map(\.id)) == [UUID(20), UUID(121)])

		try database.read { (db: Database) throws in

			// This Mac's open tab, selection, folder state and restoration state follow.
			#expect(try RegularTabRecord.find(UUID(130)).fetchOne(db)?.spaceID == cloudWork)
			#expect(try SpaceStateRecord.find(cloudWork).fetchOne(db)?.selectedTabID == UUID(11))
			#expect(try FolderStateRecord.find(cloudFolder).fetchOne(db)?.isExpanded == false)
			#expect(try TabStateRecord.find(UUID(11)).fetchOne(db)?.restorationTitle == "Spec")
			// The website data stays: iCloud's profile is an alias for this Mac's.
			#expect(try ProfileStorageRecord.aliases(db) == [cloudProfile: localProfile])
		}
	}

	@Test
	func syncedProfilesMergeFromSettingsAndEveryMacHidesTheMergedOnes() throws {
		// Both Defaults synced: B's is merged into A's, the first in the switcher.
		let a: UUID = UUID(1)
		let b: UUID = UUID(2)
		let database: DatabaseQueue = try database(
			.init(
				profiles: [
					ProfileRecord(id: a, name: "Default", position: "V"),
					ProfileRecord(id: b, name: "Default", position: "W"),
				],
				spaces: [
					SpaceRecord(id: UUID(10), profileID: a, name: "Home", position: "V"),
					SpaceRecord(id: UUID(20), profileID: b, name: "Home", position: "V"),
					SpaceRecord(id: UUID(21), profileID: b, name: "Side", position: "W"),
				],
				pinnedTabs: [
					PinnedTabRecord(id: UUID(30), spaceID: UUID(10), title: "Mail", url: "https://mail.example", position: "V"),
					PinnedTabRecord(id: UUID(40), spaceID: UUID(20), title: "Mail", url: "https://mail.example/", position: "V"),
					PinnedTabRecord(id: UUID(41), spaceID: UUID(20), title: "Chat", url: "https://chat.example", position: "W"),
				]
			)
		)
		let deviceID: UUID = UUID(99)
		try database.write { db in
			try db.seed {
				StoreInfoRecord(id: StoreInfoKey.deviceID, value: deviceID.uuidString.lowercased())

				// This Mac uses B's Default: its tabs are open there.
				RegularTabRecord(id: UUID(50), spaceID: UUID(20), position: "V")
			}
		}
		let local: WorkspaceMerge.Snapshot = try database.read { try .init($0) }
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(
			local: local.only(profiles: [b]),
			cloud: local.only(profiles: [a]),
			macName: "Mac",
			forcedProfiles: [b: a]
		)
		let summary: WorkspaceRepair.Summary = try database.writeAllowingSyncedDeletions { db in
			try WorkspaceMerge.applySynced(matching, now: Date(timeIntervalSince1970: 1_000), db)
		}
		#expect(Set(summary.mergedItems) == [b, UUID(20), UUID(40)])
		#expect(summary.mergedProfiles == [b: a])
		#expect(summary.mergedSpaces == [UUID(20): UUID(10)])

		try database.read { (db: Database) throws in

			// Three merged items, and Side, which says it left B's Default.
			#expect(try MergedItemRecord.all.fetchAll(db).count == 4)
			#expect(try MergedItemRecord.find(UUID(21)).fetchOne(db)?.keptID == b)
			// B's items show no more here: hidden, as deleted on this Mac, until every Mac has.
			let shown: WorkspaceMerge.Snapshot = try .init(db)
			#expect(shown.profiles.map(\.id) == [a])
			#expect(Set(shown.spaces.map(\.id)) == [UUID(10), UUID(21)])
			#expect(Set(shown.pinnedTabs.map(\.id)) == [UUID(30), UUID(41)])
			#expect(try RegularTabRecord.find(UUID(50)).fetchOne(db)?.spaceID == UUID(10))
			// This Mac used B's last, so A's profile keeps B's website data here.
			#expect(try ProfileStorageRecord.aliases(db) == [a: b])
		}

		// The repair pass finds nothing more to do.
		let again: WorkspaceRepair.Summary = try database.writeAllowingSyncedDeletions { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}
		#expect(again.mergedItems.isEmpty)
	}

	/// Two synced Defaults, A's first; B's has Home (Mail, as A's has) and Side.
	private func syncedDefaults() throws -> DatabaseQueue {
		let a: UUID = UUID(1)
		let b: UUID = UUID(2)
		let database: DatabaseQueue = try database(
			.init(
				profiles: [
					ProfileRecord(id: a, name: "Default", position: "V"),
					ProfileRecord(id: b, name: "Default", position: "W"),
				],
				spaces: [
					SpaceRecord(id: UUID(10), profileID: a, name: "Home", position: "V"),
					SpaceRecord(id: UUID(20), profileID: b, name: "Home", position: "V"),
					SpaceRecord(id: UUID(21), profileID: b, name: "Side", position: "W"),
				],
				pinnedTabs: [
					PinnedTabRecord(id: UUID(30), spaceID: UUID(10), title: "Mail", url: "https://mail.example", position: "V"),
					PinnedTabRecord(id: UUID(40), spaceID: UUID(20), title: "Mail", url: "https://mail.example", position: "V"),
				]
			)
		)
		try database.write { db in
			try db.seed { StoreInfoRecord(id: StoreInfoKey.deviceID, value: UUID(99).uuidString.lowercased()) }
		}
		return database
	}

	private func mergeSyncedDefaults(_ database: DatabaseQueue) throws {
		let local: WorkspaceMerge.Snapshot = try database.read { try .init($0) }
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(
			local: local.only(profiles: [UUID(2)]),
			cloud: local.only(profiles: [UUID(1)]),
			macName: "Mac",
			forcedProfiles: [UUID(2): UUID(1)]
		)
		try database.writeAllowingSyncedDeletions { db in
			_ = try WorkspaceMerge.applySynced(matching, now: Date(timeIntervalSince1970: 1_000), db)
		}
	}

	@Test
	internal func theMergedProfilesUseIsReadBeforeItsSpacesMove() throws {
		let database: DatabaseQueue = try syncedDefaults()

		// B is used here only in Side, which moves to A unmatched.
		try database.write { db in try db.seed { RegularTabRecord(id: UUID(50), spaceID: UUID(21), position: "V") } }
		try mergeSyncedDefaults(database)
		try database.read { (db: Database) throws in
			#expect(try ProfileStorageRecord.aliases(db) == [UUID(1): UUID(2)])
			#expect(try RegularTabRecord.find(UUID(50)).fetchOne(db)?.spaceID == UUID(21))
			#expect(try SpaceRecord.find(UUID(21)).fetchOne(db)?.profileID == UUID(1))
		}
	}

	@Test
	internal func aKeptProfileThisMacUsesKeepsItsOwnWebsiteData() throws {
		let database: DatabaseQueue = try syncedDefaults()

		// Both are used here: A was, B has an open tab.
		try database.write { db in
			try db.seed {
				UsageRecord(id: UUID(60), itemID: UUID(1), itemTable: ProfileRecord.tableName, deviceID: UUID(99), lastUsed: 1)
				RegularTabRecord(id: UUID(50), spaceID: UUID(20), position: "V")
			}
		}
		try mergeSyncedDefaults(database)
		try database.read { (db: Database) throws in

			// A's open pages keep their storage: no alias.
			#expect(try ProfileStorageRecord.aliases(db).isEmpty)
			#expect(try RegularTabRecord.find(UUID(50)).fetchOne(db)?.spaceID == UUID(10))
		}
	}

	@Test
	internal func aMergeIntoAnItemMergedSinceEndsInTheLastKeptOne() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		try database.write { db in
			try db.seed {
				StoreInfoRecord(id: StoreInfoKey.deviceID, value: UUID(99).uuidString.lowercased())
				ProfileRecord(id: UUID(1), name: "Default", position: "V")
				SpaceRecord(id: UUID(10), profileID: UUID(1), name: "Home", position: "V")
				SpaceRecord(id: UUID(11), profileID: UUID(1), name: "Home", position: "W")
				SpaceRecord(id: UUID(12), profileID: UUID(1), name: "Home", position: "X")

				// This Mac's tab in C, the first merged: C → B, then B → A arrive together.
				RegularTabRecord(id: UUID(50), spaceID: UUID(12), position: "V")
				MergedItemRecord(id: UUID(12), itemTable: SpaceRecord.tableName, keptID: UUID(11), mergedAt: 1)
				MergedItemRecord(id: UUID(11), itemTable: SpaceRecord.tableName, keptID: UUID(10), mergedAt: 2)
			}
		}
		let summary: WorkspaceRepair.Summary = try database.writeAllowingSyncedDeletions { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}
		#expect(summary.mergedSpaces == [UUID(11): UUID(10), UUID(12): UUID(10)])
		try database.read { (db: Database) throws in
			#expect(try RegularTabRecord.find(UUID(50)).fetchOne(db)?.spaceID == UUID(10))
			#expect(try WorkspaceMerge.mergedTargets(db)[SpaceRecord.tableName] == [UUID(11): UUID(10), UUID(12): UUID(10)])
		}
	}

	@Test
	internal func itemsTwoMacsMergedIntoEachOtherEndInTheLowestID() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		try database.write { db in
			try db.seed {
				StoreInfoRecord(id: StoreInfoKey.deviceID, value: UUID(99).uuidString.lowercased())
				ProfileRecord(id: UUID(1), name: "Default", position: "V")
				SpaceRecord(id: UUID(10), profileID: UUID(1), name: "Home", position: "V")
				SpaceRecord(id: UUID(11), profileID: UUID(1), name: "Home", position: "W")
				RegularTabRecord(id: UUID(50), spaceID: UUID(11), position: "V")
				MergedItemRecord(id: UUID(10), itemTable: SpaceRecord.tableName, keptID: UUID(11), mergedAt: 1)
				MergedItemRecord(id: UUID(11), itemTable: SpaceRecord.tableName, keptID: UUID(10), mergedAt: 1)
			}
		}
		let summary: WorkspaceRepair.Summary = try database.writeAllowingSyncedDeletions { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}
		#expect(summary.mergedItems == [UUID(11)])
		try database.read { (db: Database) throws in
			let shown: WorkspaceMerge.Snapshot = try .init(db)
			#expect(shown.spaces.map(\.id) == [UUID(10)])
			#expect(try RegularTabRecord.find(UUID(50)).fetchOne(db)?.spaceID == UUID(10))
		}
	}

	@Test
	internal func aSpaceTheMergeMovedCountsForTheProfileItLeft() throws {
		// Another Mac merged B's Default into A's; the fetch already moved Side to A.
		let database: DatabaseQueue = try database(
			.init(
				profiles: [
					ProfileRecord(id: UUID(1), name: "Default", position: "V"),
					ProfileRecord(id: UUID(2), name: "Default", position: "W"),
				],
				spaces: [
					SpaceRecord(id: UUID(10), profileID: UUID(1), name: "Home", position: "V"),
					SpaceRecord(id: UUID(21), profileID: UUID(1), name: "Side", position: "W"),
				]
			)
		)
		try database.write { db in
			try db.seed {
				StoreInfoRecord(id: StoreInfoKey.deviceID, value: UUID(99).uuidString.lowercased())
				MergedItemRecord(id: UUID(2), itemTable: ProfileRecord.tableName, keptID: UUID(1), mergedAt: 1)
				MergedItemRecord(id: UUID(21), itemTable: WorkspaceMerge.movedSpaceTable, keptID: UUID(2), mergedAt: 1)

				// This Mac's only open tab was in B's Side.
				RegularTabRecord(id: UUID(50), spaceID: UUID(21), position: "V")
			}
		}
		_ = try database.writeAllowingSyncedDeletions { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}
		try database.read { (db: Database) throws in
			#expect(try ProfileStorageRecord.aliases(db) == [UUID(1): UUID(2)])
		}
	}

	@Test
	internal func theOppositeMergeArrivingLaterShowsTheSurvivorAgain() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		try database.write { db in
			try db.seed {
				StoreInfoRecord(id: StoreInfoKey.deviceID, value: UUID(99).uuidString.lowercased())
				ProfileRecord(id: UUID(1), name: "Default", position: "V")
				SpaceRecord(id: UUID(10), profileID: UUID(1), name: "Home", position: "V")
				SpaceRecord(id: UUID(11), profileID: UUID(1), name: "Home", position: "W")
				RegularTabRecord(id: UUID(50), spaceID: UUID(10), position: "V")
				MergedItemRecord(id: UUID(10), itemTable: SpaceRecord.tableName, keptID: UUID(11), mergedAt: 1)
			}
		}
		let repair: () throws -> WorkspaceRepair.Summary = {
			try database.writeAllowingSyncedDeletions { db in
				try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
			}
		}
		#expect(try repair().mergedItems == [UUID(10)])

		// Another Mac merged the other way at the same time.
		try database.write { db in
			try db.seed { MergedItemRecord(id: UUID(11), itemTable: SpaceRecord.tableName, keptID: UUID(10), mergedAt: 1) }
		}
		#expect(try repair().mergedItems == [UUID(11)])
		try database.read { (db: Database) throws in
			let shown: WorkspaceMerge.Snapshot = try .init(db)
			#expect(shown.spaces.map(\.id) == [UUID(10)])
			#expect(try RegularTabRecord.find(UUID(50)).fetchOne(db)?.spaceID == UUID(10))
		}
	}

	@Test
	internal func aMatchedPinInAFolderOnlyICloudHasShowsBeforeTheFirstFetch() throws {
		var local: WorkspaceMerge.Snapshot = local

		// This Mac's Tracker is at Work's root; iCloud's is in Docs, which this Mac's Work lacks.
		local.folders = []
		local.pinnedTabs = [PinnedTabRecord(id: UUID(116), spaceID: localWork, title: "Spec", url: "https://docs.example/spec", position: "V")]
		let database: DatabaseQueue = try database(local)
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: try database.read { try .init($0) }, cloud: cloud, macName: "Mac")
		#expect(matching.pinnedTabs[UUID(116)] == UUID(11))
		try database.writeAllowingSyncedDeletions { db in
			try WorkspaceMerge.applyJoining(matching, cloud: cloud, db)
		}
		let rows: WorkspaceMerge.Snapshot = try database.read { try .init($0) }
		#expect(rows.folders.map(\.id) == [cloudFolder])
		#expect(rows.pinnedTabs.first { $0.id == UUID(11) }?.folderID == cloudFolder)
	}

	@Test
	internal func anOpenTabSavedIntoAHiddenMergedSpaceFollowsToo() throws {
		let database: DatabaseQueue = try syncedDefaults()
		try mergeSyncedDefaults(database)

		// A save that was on its way puts a tab in B's Home, already hidden here.
		try database.write { db in try db.seed { RegularTabRecord(id: UUID(51), spaceID: UUID(20), position: "V") } }
		_ = try database.writeAllowingSyncedDeletions { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}
		try database.read { (db: Database) throws in
			#expect(try RegularTabRecord.find(UUID(51)).fetchOne(db)?.spaceID == UUID(10))
		}
	}

	@Test
	internal func aMatchedPinsOwnTitleIsListedAndNeedsReview() {
		let local: WorkspaceMerge.Snapshot = .init(
			profiles: [ProfileRecord(id: localProfile, name: "Default", searchEngine: "duckduckgo", position: "V", isStarter: true)],
			spaces: [SpaceRecord(id: localHome, profileID: localProfile, name: "Default", icon: "house", position: "V", isStarter: true)],
			pinnedTabs: [
				PinnedTabRecord(id: UUID(110), spaceID: localHome, title: "Mail", url: "https://mail.example", customTitle: "Inbox", position: "V")
			]
		)
		let plan: WorkspaceMerge.Plan = WorkspaceMerge.match(local: local, cloud: cloud, macName: "Mac").plan
		#expect(plan.profiles.first?.spaces.first?.settings == [.init(itemName: "Mail", setting: .title, from: "Inbox", to: "Mail")])
		#expect(plan.needsReview)
	}

	@Test
	internal func aKeptItemThisMacHidShowsAgainWithWhatMergedIntoIt() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		try database.write { db in
			try db.seed {
				StoreInfoRecord(id: StoreInfoKey.deviceID, value: UUID(99).uuidString.lowercased())
				ProfileRecord(id: UUID(1), name: "Default", position: "V")
				ProfileRecord(id: UUID(2), name: "Default", position: "W")
				SpaceRecord(id: UUID(20), profileID: UUID(2), name: "Home", position: "V")

				// This Mac deleted A's Default; another Mac merged B's into it.
				DeletionRecord(id: UUID(70), itemID: UUID(1), itemTable: ProfileRecord.tableName, deviceID: UUID(99), deletedAt: 1)
				MergedItemRecord(id: UUID(2), itemTable: ProfileRecord.tableName, keptID: UUID(1), mergedAt: 2)
			}
		}
		_ = try database.writeAllowingSyncedDeletions { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}
		try database.read { (db: Database) throws in
			let shown: WorkspaceMerge.Snapshot = try .init(db)
			#expect(shown.profiles.map(\.id) == [UUID(1)])
			#expect(shown.spaces.map(\.profileID) == [UUID(1)])
		}
	}
}
