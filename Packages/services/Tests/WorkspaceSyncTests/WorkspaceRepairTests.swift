import BrowserCore
import Foundation
import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

struct WorkspaceRepairTests {
	private let profileID: UUID = UUID(1)
	private let spaceID: UUID = UUID(2)
	private let otherSpaceID: UUID = UUID(3)

	private func organization() throws -> DatabaseQueue {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		try database.write { db in
			try db.seed {
				ProfileRecord(id: profileID, name: "Personal", position: "V")
				SpaceRecord(id: spaceID, profileID: profileID, name: "Home", position: "V")
				SpaceRecord(id: otherSpaceID, profileID: profileID, name: "Work", position: "W")
			}
		}
		return database
	}

	private func preferences() throws -> DatabaseQueue {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.preferencesMigrator().migrate(database)
		return database
	}

	@Test
	func orphanedAndCrossSpaceParentsGoToTheEndOfTheRoot() throws {
		let database: DatabaseQueue = try organization()
		try database.write { db in
			try db.seed {
				FolderRecord(id: UUID(10), spaceID: spaceID, name: "Root", position: "V")
				FolderRecord(id: UUID(11), spaceID: otherSpaceID, name: "Elsewhere", position: "V")
				FolderRecord(id: UUID(12), spaceID: spaceID, parentFolderID: UUID(99), name: "Orphan", position: "a")
				FolderRecord(id: UUID(13), spaceID: spaceID, parentFolderID: UUID(11), name: "Crossed", position: "b")
				PinnedTabRecord(id: UUID(20), spaceID: spaceID, title: "Root tab", url: "https://a.example", position: "X")
				PinnedTabRecord(id: UUID(21), spaceID: spaceID, folderID: UUID(11), title: "Crossed tab", url: "https://b.example", position: "c")
				PinnedTabRecord(id: UUID(22), spaceID: spaceID, folderID: UUID(10), title: "Fine", url: "https://c.example", position: "V")
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}

		#expect(summary.movedToRoot == [UUID(12), UUID(13), UUID(21)])
		let (folders, tabs) = try database.read { db in
			(try FolderRecord.order(by: \.id).fetchAll(db), try PinnedTabRecord.order(by: \.id).fetchAll(db))
		}
		#expect(folders.map(\.parentFolderID) == [nil, nil, nil, nil])
		#expect(tabs.map(\.folderID) == [nil, nil, UUID(10)])
		// After the root's last key ("X"), in (position, id) order: Orphan, Crossed, Crossed tab.
		#expect(folders[2].position == "Y")
		#expect(folders[3].position == "Z")
		#expect(tabs[1].position == "a")

		let again: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}
		#expect(again.isEmpty)
	}

	@Test
	func aPlacementIsOnlyRepairedWhereICloudAgrees() throws {
		let database: DatabaseQueue = try organization()
		try database.write { db in
			try db.seed {
				FolderRecord(id: UUID(10), spaceID: otherSpaceID, name: "Elsewhere", position: "V")
				FolderRecord(id: UUID(12), spaceID: spaceID, parentFolderID: UUID(99), name: "Waiting", position: "V")
				PinnedTabRecord(id: UUID(20), spaceID: spaceID, folderID: UUID(10), title: "Crossed", url: "https://a.example", position: "W")
			}
		}
		let records: Set<WorkspaceRepair.PlacementRecord> = try database.read { db in
			try WorkspaceRepair.placementRecordsToCheck(db)
		}
		#expect(records == [.folder(UUID(12)), .folder(UUID(99)), .pinnedTab(UUID(20)), .folder(UUID(10))])

		// iCloud has the missing folder, and Elsewhere in the tab's space: both are on their way.
		let pending: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(
				db,
				ownStarterProfileIDs: [],
				remotePlacements: [
					.folder(UUID(12)): .placed(spaceID: spaceID, parentID: UUID(99)),
					.folder(UUID(99)): .placed(spaceID: spaceID, parentID: nil),
					.pinnedTab(UUID(20)): .placed(spaceID: spaceID, parentID: UUID(10)),
					.folder(UUID(10)): .placed(spaceID: spaceID, parentID: nil),
				]
			)
		}
		#expect(pending.isEmpty)

		// iCloud agrees with this Mac: the folder is gone and Elsewhere is in the other space.
		let settled: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(
				db,
				ownStarterProfileIDs: [],
				remotePlacements: [
					.folder(UUID(12)): .placed(spaceID: spaceID, parentID: UUID(99)),
					.folder(UUID(99)): .missing,
					.pinnedTab(UUID(20)): .placed(spaceID: spaceID, parentID: UUID(10)),
					.folder(UUID(10)): .placed(spaceID: otherSpaceID, parentID: nil),
				]
			)
		}
		#expect(settled.movedToRoot == [UUID(12), UUID(20)])
	}

	@Test
	func aSelectionAnotherMacInvalidatedIsCleared() throws {
		let database: DatabaseQueue = try organization()
		try database.write { db in
			try db.seed {
				PinnedTabRecord(id: UUID(20), spaceID: spaceID, title: "Here", url: "https://a.example", position: "V")
				PinnedTabRecord(id: UUID(21), spaceID: otherSpaceID, title: "Moved", url: "https://b.example", position: "V")
				FavoriteRecord(id: UUID(22), profileID: profileID, title: "Favorite", url: "https://c.example", position: "V")
				SpaceStateRecord(id: spaceID, selectedTabID: UUID(21))
				SpaceStateRecord(id: otherSpaceID, selectedTabID: UUID(22))
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}

		// The pin moved to the other space; a Favorite of the space's profile is still valid.
		#expect(summary.clearedSelections == [spaceID])
		let selections: [UUID?] = try database.read { db in
			try SpaceStateRecord.order(by: \.id).select(\.selectedTabID).fetchAll(db)
		}
		#expect(selections == [nil, UUID(22)])
		#expect(try database.write { db in try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: []) }.isEmpty)
	}

	@Test
	func aTabInTwoPlacesKeepsTheFavoriteOrThisMacsRegularTab() throws {
		let database: DatabaseQueue = try organization()
		try database.write { db in
			try db.seed {
				// A pin another Mac made a Favorite, brought back by an offline edit.
				PinnedTabRecord(id: UUID(20), spaceID: spaceID, title: "Back", url: "https://a.example", position: "V")
				FavoriteRecord(id: UUID(20), profileID: profileID, title: "Favorite", url: "https://a.example", position: "V")

				// A pin this Mac unpinned, brought back beside its regular tab: hidden here.
				PinnedTabRecord(id: UUID(21), spaceID: spaceID, title: "Back", url: "https://b.example", position: "W")
				RegularTabRecord(id: UUID(21), spaceID: spaceID, position: "V")
				PinnedTabRecord(id: UUID(22), spaceID: spaceID, title: "Fine", url: "https://c.example", position: "X")
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}

		#expect(summary.removedDuplicateTabs == [UUID(20), UUID(21)])
		let (pins, favorites, regular) = try database.read { db in
			(
				try PinnedTabRecord.order(by: \.id).select(\.id).fetchAll(db),
				try FavoriteRecord.select(\.id).fetchAll(db),
				try RegularTabRecord.select(\.id).fetchAll(db)
			)
		}

		// The pin beside this Mac's regular tab stays in iCloud, hidden here only (DEV-980).
		#expect(pins == [UUID(21), UUID(22)])
		#expect(try database.read { db in try LocalDeletion.hiddenItems(db) }.contains(UUID(21), in: PinnedTabRecord.tableName))
		#expect(favorites == [UUID(20)])
		#expect(regular == [UUID(21)])
		#expect(try database.write { db in try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: []) }.isEmpty)
	}

	@Test
	func aPinBesideAFavoriteWaitsUntilICloudHasBoth() throws {
		let database: DatabaseQueue = try organization()
		try database.write { db in
			try db.seed {
				PinnedTabRecord(id: UUID(20), spaceID: spaceID, title: "Moved", url: "https://a.example", position: "V")
				FavoriteRecord(id: UUID(20), profileID: profileID, title: "Moved", url: "https://a.example", position: "V")
			}
		}
		let records: Set<WorkspaceRepair.PlacementRecord> = try database.read { db in
			try WorkspaceRepair.placementRecordsToCheck(db)
		}
		#expect(records == [.pinnedTab(UUID(20)), .favorite(UUID(20))])

		// The Favorite was turned into this pin, and its deletion hasn't been fetched yet.
		let halfway: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(
				db,
				ownStarterProfileIDs: [],
				remotePlacements: [
					.pinnedTab(UUID(20)): .placed(spaceID: spaceID, parentID: nil),
					.favorite(UUID(20)): .missing,
				]
			)
		}
		#expect(halfway.removedDuplicateTabs.isEmpty)
		#expect(try database.read { try PinnedTabRecord.select(\.id).fetchAll($0) } == [UUID(20)])

		// iCloud has both: the Favorite wins.
		let conflict: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(
				db,
				ownStarterProfileIDs: [],
				remotePlacements: [
					.pinnedTab(UUID(20)): .placed(spaceID: spaceID, parentID: nil),
					.favorite(UUID(20)): .placed(spaceID: nil, parentID: nil),
				]
			)
		}
		#expect(conflict.removedDuplicateTabs == [UUID(20)])
		#expect(try database.read { try PinnedTabRecord.select(\.id).fetchAll($0) }.isEmpty)
	}

	@Test
	func aCycleMovesItsLowestFolderToTheRoot() throws {
		let database: DatabaseQueue = try organization()
		try database.write { db in
			try db.seed {
				FolderRecord(id: UUID(12), spaceID: spaceID, parentFolderID: UUID(11), name: "C", position: "V")
				FolderRecord(id: UUID(11), spaceID: spaceID, parentFolderID: UUID(10), name: "B", position: "V")
				FolderRecord(id: UUID(10), spaceID: spaceID, parentFolderID: UUID(12), name: "A", position: "V")
				FolderRecord(id: UUID(13), spaceID: spaceID, parentFolderID: UUID(13), name: "Self", position: "V")
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [])
		}

		#expect(summary.brokenCycles == [UUID(10)])
		#expect(summary.movedToRoot == [UUID(13)])
		let parents: [UUID?] = try database.read { db in
			try FolderRecord.order(by: \.id).select(\.parentFolderID).fetchAll(db)
		}
		#expect(parents == [nil, UUID(10), UUID(11), nil])
	}

	@Test
	func onlyThisMacsOwnPristineStarterProfileLosesItsSpaces() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let mine: UUID = UUID(5)
		let theirs: UUID = UUID(4)
		try database.write { db in
			try db.seed {
				ProfileRecord(id: theirs, name: "Personal", position: "V", isStarter: true)
				SpaceRecord(id: UUID(40), profileID: theirs, name: "Home", position: "V", isStarter: true)
				ProfileRecord(id: mine, name: "Personal", position: "W", isStarter: true)
				SpaceRecord(id: UUID(50), profileID: mine, name: "Home", position: "V", isStarter: true)
				RegularTabRecord(id: UUID(60), spaceID: UUID(50), position: "V")
			}
		}

		// Another Mac never drops a starter profile it doesn't own.
		let elsewhere: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [theirs])
		}
		#expect(elsewhere.duplicateStarterProfiles.isEmpty)

		// This Mac's own, while a tab is open in it, stays: the tab's page belongs to its profile.
		let withTab: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [mine])
		}
		#expect(withTab.duplicateStarterProfiles.isEmpty)

		// Nor while Tab Archive has something from it.
		try database.write { db in
			try RegularTabRecord.find(UUID(60)).delete().execute(db)
			try db.execute(
				sql: #"INSERT INTO "archivedTab" ("id", "value", "position") VALUES (?, ?, 'V')"#,
				arguments: [UUID(61).uuidString, #"{"profileID":"\#(mine.uuidString)"}"#]
			)
		}
		let withArchive: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [mine])
		}
		#expect(withArchive.duplicateStarterProfiles.isEmpty)

		try database.write { db in try db.execute(sql: #"DELETE FROM "archivedTab""#) }
		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [mine])
		}
		#expect(summary.duplicateStarterProfiles == [mine])
		// The profile stays, with its website data, until the person removes it (DEV-989); its
		// spaces, copies of the kept profile's, go.
		let profiles: Set<UUID> = try database.read { db in try Set(ProfileRecord.select(\.id).fetchAll(db)) }
		#expect(profiles == [theirs, mine])
		let spaces: [UUID] = try database.read { db in try SpaceRecord.select(\.id).fetchAll(db) }
		#expect(spaces == [UUID(40)])
		// Not a starter anymore, so a later Mac's first merge never keeps it over its own.
		let emptied: ProfileRecord? = try database.read { db in try ProfileRecord.find(mine).fetchOne(db) }
		#expect(emptied?.isStarter == false)
	}

	@Test
	func aCustomizedStarterProfileIsNeverDropped() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let theirs: UUID = UUID(4)
		let mine: UUID = UUID(5)
		try database.write { db in
			try db.seed {
				ProfileRecord(id: theirs, name: "Personal", position: "V", isStarter: true)
				SpaceRecord(id: UUID(40), profileID: theirs, name: "Home", position: "V", isStarter: true)
				ProfileRecord(id: mine, name: "Personal", searchEngine: #"{"name":"Kagi"}"#, position: "W", isStarter: true)
				SpaceRecord(id: UUID(50), profileID: mine, name: "Home", position: "V", isStarter: true)
				ProfileRecord(id: UUID(6), name: "Work", position: "X", isStarter: true)
				SpaceRecord(id: UUID(60), profileID: UUID(6), name: "Desk", position: "V", isStarter: true)
				ProfileRecord(id: UUID(3), name: "Work", position: "Y", isStarter: true)
				SpaceRecord(id: UUID(30), profileID: UUID(3), name: "Home", position: "V", isStarter: true)
			}
		}

		// A changed search engine, and a renamed space, each keep this Mac's starter profile.
		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [mine, UUID(6)])
		}
		#expect(summary.duplicateStarterProfiles.isEmpty)
		#expect(try database.read { db in try ProfileRecord.fetchCount(db) } == 4)
	}

	@Test
	func aStarterProfileWithPinsIsNeverDropped() throws {
		let database: DatabaseQueue = try .init()
		try WorkspaceSchema.organizationMigrator().migrate(database)
		let mine: UUID = UUID(4)
		let theirs: UUID = UUID(5)
		try database.write { db in
			try db.seed {
				ProfileRecord(id: mine, name: "Personal", position: "V", isStarter: true)
				SpaceRecord(id: UUID(40), profileID: mine, name: "Home", position: "V", isStarter: true)
				PinnedTabRecord(id: UUID(41), spaceID: UUID(40), title: "Mine", url: "https://m.example", position: "V")
				ProfileRecord(id: theirs, name: "Personal", position: "W", isStarter: true)
				SpaceRecord(id: UUID(50), profileID: theirs, name: "Home", position: "V", isStarter: true)
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairOrganization(db, ownStarterProfileIDs: [mine])
		}

		// Mine has a pin, so it's the one kept even with the lower ID, and it isn't pristine anyway.
		#expect(summary.duplicateStarterProfiles.isEmpty)
		#expect(try database.read { db in try ProfileRecord.fetchCount(db) } == 2)
	}

	@Test
	func duplicateKeywordsKeepTheFirstAndRenameTheRest() throws {
		let database: DatabaseQueue = try preferences()
		try database.write { db in
			try db.seed {
				SearchShortcutRecord(id: "gh", keyword: "gh", name: "GitHub", template: "https://gh.example/?q={query}", position: "W")
				SearchShortcutRecord(id: "gh-legacy", keyword: "GH", name: "GitHub Enterprise", template: "https://ghe.example/?q={query}", position: "V")
				SearchShortcutRecord(id: "gh-2", keyword: "gh-2", name: "Taken", template: "https://t.example/?q={query}", position: "X")
				SearchShortcutRecord(id: "w", keyword: "w", name: "Wikipedia", template: "https://w.example/?q={query}", position: "Y")
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairPreferences(db)
		}

		#expect(summary.disabledSearchShortcuts == ["gh"])
		let rows: [SearchShortcutRecord] = try database.read { db in
			try SearchShortcutRecord.order(by: \.id).fetchAll(db)
		}
		#expect(rows.map(\.keyword) == ["gh-3", "gh-2", "GH", "w"])
		#expect(rows.map(\.isEnabled) == [false, true, true, true])
		// Every keyword is unique ignoring case now, as BrowserPreferences requires.
		#expect(Set(rows.map { $0.keyword.lowercased() }).count == rows.count)
		#expect(try database.write { db in try WorkspaceRepair.repairPreferences(db) }.isEmpty)
	}

	@Test
	func aShortcutTwoCommandsShareStaysWithTheFirstIncludingDefaults() throws {
		let database: DatabaseQueue = try preferences()
		let newTab: KeyboardShortcut = .init(key: "t")
		let custom: KeyboardShortcut = .init(key: "j", modifiers: [.command, .option, .shift, .control])
		#expect(BrowserCommand.newTab.defaultShortcuts == [newTab])

		func json(_ shortcuts: [KeyboardShortcut?]) throws -> String {
			let encoder: JSONEncoder = .init()
			encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
			return String(decoding: try encoder.encode(shortcuts), as: UTF8.self)
		}

		// New Folder took New Tab's ⌘T on one Mac; Downloads took ⌘T too on another; Media has none.
		let newFolderBindings: String = try json([newTab])
		let downloadsBindings: String = try json([custom, newTab])
		let mediaBindings: String = try json([nil])
		let newTabBindings: String = "[]"
		try database.write { db in
			try db.seed {
				KeyboardShortcutRecord(id: BrowserCommand.newFolder.rawValue, bindings: newFolderBindings, position: "V")
				KeyboardShortcutRecord(id: BrowserCommand.downloads.rawValue, bindings: downloadsBindings, position: "W")
				KeyboardShortcutRecord(id: BrowserCommand.media.rawValue, bindings: mediaBindings, position: "X")

				// An empty row: New Tab uses its defaults, as with no row.
				KeyboardShortcutRecord(id: BrowserCommand.newTab.rawValue, bindings: newTabBindings, position: "Y")
			}
		}

		let summary: WorkspaceRepair.Summary = try database.write { db in
			try WorkspaceRepair.repairPreferences(db)
		}

		#expect(
			summary.clearedShortcutBindings
			== [BrowserCommand.downloads.rawValue, BrowserCommand.newTab.rawValue]
		)
		let rows: [String: String] = try database.read { db in
			Dictionary(
				uniqueKeysWithValues: try KeyboardShortcutRecord.fetchAll(db).map { ($0.id, $0.bindings) }
			)
		}
		#expect(rows[BrowserCommand.newFolder.rawValue] == (try json([newTab])))
		#expect(rows[BrowserCommand.downloads.rawValue] == (try json([custom])))
		#expect(rows[BrowserCommand.media.rawValue] == (try json([nil])))
		// New Tab's default is New Folder's now, so New Tab reads as "no shortcut".
		#expect(rows[BrowserCommand.newTab.rawValue] == (try json([nil])))
		#expect(try database.write { db in try WorkspaceRepair.repairPreferences(db) }.isEmpty)
	}

	@Test
	func positionsAfterFollowTheFractionalIndexAlphabet() {
		#expect(WorkspaceRepair.positionAfter(nil) == "V")
		#expect(WorkspaceRepair.positionAfter("V") == "W")
		#expect(WorkspaceRepair.positionAfter("z") == "zV")
		#expect(WorkspaceRepair.positionAfter("zz") == "zzV")
	}
}
