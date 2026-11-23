import Foundation
import Testing
import _SQLiteData
@testable import WorkspaceDatabase

/// Saves across a joining Mac's merge (DEV-1216): what the person changed lands on the kept items.
internal struct MergeRemapTests {
	private let work: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
	private let home: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
	private let folder: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
	private let keptPin: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
	private let localWork: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
	private let localPin: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!

	@Test
	internal func aMoveFromBeforeTheMergeTakesTheWholeNewPlace() throws {
		// The merge made this Mac's root pin iCloud's, which is in a folder.
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let profile: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
		try database.write { db in
			try ProfileRecord.insert { ProfileRecord(id: profile, name: "Default", position: "V") }.execute(db)
			try SpaceRecord.insert {
				SpaceRecord(id: work, profileID: profile, name: "Work", position: "V")
				SpaceRecord(id: home, profileID: profile, name: "Home", position: "W")
			}
			.execute(db)
			try FolderRecord.insert { FolderRecord(id: folder, spaceID: work, name: "Docs", position: "V") }.execute(db)
			try PinnedTabRecord.insert {
				PinnedTabRecord(id: keptPin, spaceID: work, folderID: folder, title: "Spec", url: "https://docs.example/spec", position: "V")
			}
			.execute(db)
		}
		var old: OrganizationRows = .init()
		old.pinnedTabs[localPin] = PinnedTabRecord(id: localPin, spaceID: localWork, title: "Spec", url: "https://docs.example/spec", position: "V")
		var new: OrganizationRows = old

		// The person moved it to Home's root.
		new.pinnedTabs[localPin] = PinnedTabRecord(id: localPin, spaceID: home, title: "Spec", url: "https://docs.example/spec", position: "X")

		let rebased: (new: OrganizationRows, old: OrganizationRows) = try database.read { db in
			try OrganizationRows.rebased(new, old, across: [localPin: keptPin, localWork: work], db)
		}
		let moved: PinnedTabRecord? = rebased.new.pinnedTabs[keptPin]
		#expect(moved?.spaceID == home)
		#expect(moved?.folderID == nil)
		#expect(moved?.position == "X")
		// The base is the stored row: the diff writes the move.
		#expect(rebased.old.pinnedTabs[keptPin]?.folderID == folder)
	}

	@Test
	internal func aPinMadeAFavoriteKeepsTheStoredTitleAndAddress() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let profile: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
		try database.write { db in
			try ProfileRecord.insert { ProfileRecord(id: profile, name: "Default", position: "V") }.execute(db)
			try SpaceRecord.insert { SpaceRecord(id: work, profileID: profile, name: "Work", position: "V") }.execute(db)

			// iCloud's pin, which this Mac's became.
			try PinnedTabRecord.insert {
				PinnedTabRecord(id: keptPin, spaceID: work, title: "Spec", url: "https://docs.example/spec", customTitle: "iCloud's", position: "V")
			}
			.execute(db)
		}
		var old: OrganizationRows = .init()
		old.pinnedTabs[localPin] = PinnedTabRecord(id: localPin, spaceID: localWork, title: "Spec", url: "https://docs.example/spec#old", position: "V")
		var new: OrganizationRows = old

		// The person made it a Favorite, changing nothing else.
		new.pinnedTabs[localPin] = nil
		new.favorites[localPin] = FavoriteRecord(id: localPin, profileID: profile, title: "Spec", url: "https://docs.example/spec#old", position: "W")

		let rebased: (new: OrganizationRows, old: OrganizationRows) = try database.read { db in
			try OrganizationRows.rebased(new, old, across: [localPin: keptPin], db)
		}
		let favorite: FavoriteRecord? = rebased.new.favorites[keptPin]
		#expect(favorite?.url == "https://docs.example/spec")
		#expect(favorite?.customTitle == "iCloud's")
		#expect(favorite?.position == "W")
		#expect(rebased.old.pinnedTabs[keptPin]?.customTitle == "iCloud's")
	}

	@Test
	internal func aThisMacOnlyProfileIsNeverRebasedOntoItsSyncedCopy() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let local: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!

		// Its synced copy, from before it went "this Mac only", is older.
		try database.write { db in
			try ProfileRecord.insert { ProfileRecord(id: local, name: "Old", searchEngine: "old", position: "V") }.execute(db)
		}
		var old: OrganizationRows = .init()
		old.profiles[local] = ProfileRecord(id: local, name: "Work", searchEngine: "mine", position: "V")
		old.localProfileIDs = [local]
		var new: OrganizationRows = old
		new.profiles[local] = ProfileRecord(id: local, name: "Work 2", searchEngine: "mine", position: "V")

		let rebased: (new: OrganizationRows, old: OrganizationRows) = try database.read { db in
			try OrganizationRows.rebased(new, old, across: [localPin: keptPin], db)
		}
		#expect(rebased.new.profiles[local] == new.profiles[local])
		#expect(rebased.old.profiles[local] == old.profiles[local])
	}
}
