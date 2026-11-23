import Foundation
import GRDB
import WorkspaceDatabase
import _SQLiteData

// MARK: - Rejoining after a leave (DEV-1148)

/// The rows this Mac kept while it was out of a category, read from the copy taken before its
/// engine resumed, and what a rejoin brings back from them. The engine resumes with its conflict
/// metadata, so edits made on either side while this Mac was away merge field by field as any sync
/// does. Only what purges deleted meanwhile, which the other Macs decided without this Mac, needs
/// the copy: the items this Mac didn't delete itself come back, with what's in them and this Mac's
/// own use of them, and the engine sends them as new.
enum KeptRows {
	/// The schema the copy is attached as on the category's writer while its rejoin runs.
	static let schema: String = "arx_kept"

	/// The table in the copy that keeps, as they were when they went, the rows of `table` a fetch
	/// deleted while the rejoin ran, with what changed since the copy: a space renamed meanwhile, a tab
	/// opened meanwhile.
	static func lostTable(_ table: String) -> String {
		"lost_\(table)"
	}

	/// Keeps, on the writer the copy is attached to, the rows a fetch deletes until the merge: every
	/// synced item deleted (this Mac's own deletions are deletion rows, and a tab moved between pin
	/// and Favorite is told apart when restoring); each row only this Mac has that goes because its
	/// space or folder went, a fetch deleting the space or replacing it, while one deleted with its
	/// parent still there, as a closed tab, isn't kept; and each deletion row the engine itself
	/// deletes, as a purge does, while one this Mac deletes, as an undo does, isn't. The tables it
	/// keeps them in have no constraints, so nothing a trigger writes can fail the fetch's own write.
	///
	/// The deletion rows are kept only on a writer the engine registered its function on
	/// (``isSynchronizingFunction``); without it the merge reads this Mac's deletions from the copy.
	static func watchCascades(_ db: Database) throws {
		let hasSyncFunction: Bool = (try? db.execute(sql: "SELECT \(isSynchronizingFunction)()")) != nil
		let watched: [(String, String?)] = watchedRows + (hasSyncFunction ? [(DeletionRecord.tableName, "\(isSynchronizingFunction)()")] : [])
		for (table, condition) in watched {
			let lost: String = lostTable(table)
			try db.execute(sql: """
				CREATE TABLE IF NOT EXISTS "\(schema)"."\(lost)" AS SELECT * FROM "main"."\(table)" WHERE 0
				""")
			let columns: [String] = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?, 'main')", arguments: [table])
			let names: String = columns.map { "\"\($0)\"" }.joined(separator: ", ")
			let values: String = columns.map { "OLD.\"\($0)\"" }.joined(separator: ", ")
			try db.execute(sql: """
				CREATE TEMP TRIGGER IF NOT EXISTS "\(schema)_\(table)"
				AFTER DELETE ON "main"."\(table)"
				\(condition.map { "WHEN \($0)" } ?? "")
				BEGIN
					DELETE FROM "\(schema)"."\(lost)" WHERE "id" = OLD."id";
					INSERT INTO "\(schema)"."\(lost)" (\(names)) VALUES (\(values));
				END
				""")
		}
	}

	/// Stops logging: before the copy is read, detached and removed.
	static func unwatchCascades(_ db: Database) throws {
		for table in watchedRows.map(\.0) + [DeletionRecord.tableName] {
			try db.execute(sql: #"DROP TRIGGER IF EXISTS "temp"."\#(schema)_\#(table)""#)
		}
	}

	/// The SQL function SQLiteData registers on an engine's writer: true while the engine itself
	/// writes, as when it applies a fetch.
	static let isSynchronizingFunction: String = "sqlitedata_icloud_syncEngineIsSynchronizingChanges"

	/// The synced items, whose every deletion is kept.
	static let syncedTables: [String] = [
		ProfileRecord.tableName,
		SpaceRecord.tableName,
		FolderRecord.tableName,
		PinnedTabRecord.tableName,
		FavoriteRecord.tableName,
	]

	/// Each table watched, and when a deleted row is kept: for the rows only this Mac has, only once
	/// its space or folder went.
	private static let watchedRows: [(String, String?)] = syncedTables.map { ($0, nil) } + [
		(SpaceStateRecord.tableName, parentGone(SpaceRecord.tableName, "id")),
		(FolderStateRecord.tableName, parentGone(FolderRecord.tableName, "id")),
		(RegularTabRecord.tableName, parentGone(SpaceRecord.tableName, "spaceID")),
	]

	private static func parentGone(
		_ parentTable: String,
		_ parentColumn: String
	) -> String {
		#"NOT EXISTS (SELECT 1 FROM "main"."\#(parentTable)" WHERE "id" = OLD."\#(parentColumn)")"#
	}

	/// The kept rows of `category` in `copy`, a copy of its database; `nil` for a category without
	/// purges.
	static func read(
		_ category: SyncCategory,
		from copy: URL,
		deviceID: UUID
	) throws -> (any KeptCategoryRows)? {
		var configuration: Configuration = .init()

		// The copy is this rejoin's own, read once: what a fetch deleted after the copy was taken
		// replaces the copy's rows, and replacing a space mustn't take what's in it.
		configuration.foreignKeysEnabled = false
		let queue: DatabaseQueue = try .init(path: copy.path, configuration: configuration)
		switch category {
		case .organization:
			return try queue.write { db in
				for table in syncedTables where try db.tableExists(lostTable(table)) {
					try db.execute(sql: #"INSERT OR REPLACE INTO "\#(table)" SELECT * FROM "\#(lostTable(table))""#)
				}
				return try KeptOrganization(db, deviceID: deviceID)
			}

		case .archive:
			return try queue.read { db in try KeptArchive(db, deviceID: deviceID) }

		case .preferences, .history:
			return nil
		}
	}
}

/// Kept rows that can be brought back into a category's database.
protocol KeptCategoryRows: Sendable {
	/// Brings back what's missing from `db` and wasn't deleted on this Mac.
	///
	/// - Returns: how many synced rows came back.
	func restore(_ db: Database) throws -> Int
}

/// Profiles and spaces: the items, this Mac's deletions and use of them, and the rows only this Mac
/// has that a fetch's cascade deleted with a space or folder (its state and regular tabs), as
/// ``KeptRows/watchCascades(_:)`` kept them. A fetch can delete a space and bring it back, as when
/// another Mac rejoins meanwhile, so they come back under every space there is.
struct KeptOrganization: KeptCategoryRows {
	var profiles: [ProfileRecord]
	var spaces: [SpaceRecord]
	var folders: [FolderRecord]
	var pinnedTabs: [PinnedTabRecord]
	var favorites: [FavoriteRecord]
	var deviceID: UUID

	/// What this Mac deleted, by the copy: an item it deleted that went everywhere stays gone.
	var deletions: Set<WorkspaceRepair.PurgeItem>

	/// This Mac's deletion rows a fetch deleted during the rejoin, as a purge does, when they were
	/// watched. With them, the copy's deletions give way to the live ones: an undo made since stands.
	var purgedDeletions: Set<WorkspaceRepair.PurgeItem>?
	var uses: [UsageRecord]

	/// The rows only this Mac has that a fetch's cascade deleted, as they were then.
	var spaceStates: [SpaceStateRecord]
	var folderStates: [FolderStateRecord]
	var regularTabs: [RegularTabRecord]

	init(
		_ db: Database,
		deviceID: UUID
	) throws {
		self.profiles = try ProfileRecord.all.fetchAll(db)
		self.spaces = try SpaceRecord.all.fetchAll(db)
		self.folders = try FolderRecord.all.fetchAll(db)
		self.pinnedTabs = try PinnedTabRecord.all.fetchAll(db)
		self.favorites = try FavoriteRecord.all.fetchAll(db)
		self.deviceID = deviceID
		self.deletions = Set(
			try DeletionRecord.where { $0.deviceID.eq(deviceID) }.fetchAll(db)
				.map { WorkspaceRepair.PurgeItem(table: $0.itemTable, id: $0.itemID) }
		)
		let purged: String = KeptRows.lostTable(DeletionRecord.tableName)
		if try db.tableExists(purged) {
			self.purgedDeletions = Set(
				try Row.fetchAll(db, sql: #"SELECT "itemTable", "itemID", "deviceID" FROM "\#(purged)""#).compactMap { row in
					guard
						let device = (row["deviceID"] as String?).flatMap(UUID.init(uuidString:)),
						device == deviceID,
						let table = row["itemTable"] as String?,
						let item = (row["itemID"] as String?).flatMap(UUID.init(uuidString:))
					else { return nil }

					return WorkspaceRepair.PurgeItem(table: table, id: item)
				}
			)
		} else {
			self.purgedDeletions = nil
		}
		self.uses = try UsageRecord.where { $0.deviceID.eq(deviceID) }.fetchAll(db)

		// A copy cut short before it was watched kept none.
		func lost(_ table: String) throws -> [Row] {
			let name: String = KeptRows.lostTable(table)
			guard try db.tableExists(name) else { return [] }

			return try Row.fetchAll(db, sql: #"SELECT * FROM "\#(name)""#)
		}
		func uuid(_ row: Row, _ column: String) -> UUID? {
			(row[column] as String?).flatMap(UUID.init(uuidString:))
		}
		self.spaceStates = try lost(SpaceStateRecord.tableName).compactMap { row in
			uuid(row, "id").map { SpaceStateRecord(id: $0, selectedTabID: uuid(row, "selectedTabID")) }
		}
		self.folderStates = try lost(FolderStateRecord.tableName).compactMap { row in
			uuid(row, "id").map { FolderStateRecord(id: $0, isExpanded: row["isExpanded"] ?? true, ordinal: row["ordinal"] ?? "") }
		}
		self.regularTabs = try lost(RegularTabRecord.tableName).compactMap { row in
			guard let id = uuid(row, "id"), let spaceID = uuid(row, "spaceID") else { return nil }

			return RegularTabRecord(id: id, spaceID: spaceID, customTitle: row["customTitle"], icon: row["icon"], position: row["position"] ?? "")
		}
	}

	func restore(_ db: Database) throws -> Int {
		var restored: Set<UUID> = []

		// This Mac's deletions now, and those a purge took during the rejoin; without that record, the
		// copy's too.
		let live: Set<WorkspaceRepair.PurgeItem> = Set(
			try DeletionRecord.where { $0.deviceID.eq(deviceID) }.fetchAll(db)
				.map { WorkspaceRepair.PurgeItem(table: $0.itemTable, id: $0.itemID) }
		)
		let deleted: Set<WorkspaceRepair.PurgeItem> = live.union(purgedDeletions ?? deletions)
		func isMissing(_ id: UUID, _ table: String, from present: Set<UUID>) -> Bool {
			!present.contains(id) && !deleted.contains(.init(table: table, id: id))
		}

		// Parents first: a child comes back only where its parent is, as deleting the parent deleted it.
		var profileIDs: Set<UUID> = Set(try ProfileRecord.select(\.id).fetchAll(db))
		for profile in profiles where isMissing(profile.id, ProfileRecord.tableName, from: profileIDs) {
			try ProfileRecord.insert { profile }.execute(db)
			profileIDs.insert(profile.id)
			restored.insert(profile.id)
		}

		var spaceIDs: Set<UUID> = Set(try SpaceRecord.select(\.id).fetchAll(db))
		for space in spaces where isMissing(space.id, SpaceRecord.tableName, from: spaceIDs) && profileIDs.contains(space.profileID) {
			try SpaceRecord.insert { space }.execute(db)
			spaceIDs.insert(space.id)
			restored.insert(space.id)
		}

		var folderIDs: Set<UUID> = Set(try FolderRecord.select(\.id).fetchAll(db))
		var waiting: [FolderRecord] = folders.filter { isMissing($0.id, FolderRecord.tableName, from: folderIDs) }

		// A folder's parent may be one of the folders still waiting.
		while true {
			let ready: [FolderRecord] = waiting.filter { folder in
				spaceIDs.contains(folder.spaceID) && (folder.parentFolderID.map(folderIDs.contains) ?? true)
			}
			guard !ready.isEmpty else { break }

			for folder in ready {
				try FolderRecord.insert { folder }.execute(db)
				folderIDs.insert(folder.id)
				restored.insert(folder.id)
			}
			let readyIDs: Set<UUID> = Set(ready.map(\.id))
			waiting.removeAll { readyIDs.contains($0.id) }
		}

		// A tab keeps its ID as a pin and as a Favorite: one there as the other was moved, not purged.
		var pinnedTabIDs: Set<UUID> = Set(try PinnedTabRecord.select(\.id).fetchAll(db))
		let favoriteIDs: Set<UUID> = Set(try FavoriteRecord.select(\.id).fetchAll(db))
		for pin in pinnedTabs where isMissing(pin.id, PinnedTabRecord.tableName, from: pinnedTabIDs) && !favoriteIDs.contains(pin.id) {
			guard spaceIDs.contains(pin.spaceID), pin.folderID.map(folderIDs.contains) ?? true else { continue }

			try PinnedTabRecord.insert { pin }.execute(db)
			pinnedTabIDs.insert(pin.id)
			restored.insert(pin.id)
		}

		for favorite in favorites where isMissing(favorite.id, FavoriteRecord.tableName, from: favoriteIDs) && !pinnedTabIDs.contains(favorite.id) {
			guard profileIDs.contains(favorite.profileID) else { continue }

			try FavoriteRecord.insert { favorite }.execute(db)
			restored.insert(favorite.id)
		}
		var count: Int = restored.count
		let useIDs: Set<UUID> = Set(try UsageRecord.select(\.id).fetchAll(db))
		for use in uses where restored.contains(use.itemID) && !useIDs.contains(use.id) {
			try UsageRecord.insert { use }.execute(db)
			count += 1
		}

		// The rows only this Mac has that a cascade took, under what's there now.
		let spaceStateIDs: Set<UUID> = Set(try SpaceStateRecord.select(\.id).fetchAll(db))
		for state in spaceStates where spaceIDs.contains(state.id) && !spaceStateIDs.contains(state.id) {
			try SpaceStateRecord.insert { state }.execute(db)
		}
		let folderStateIDs: Set<UUID> = Set(try FolderStateRecord.select(\.id).fetchAll(db))
		for state in folderStates where folderIDs.contains(state.id) && !folderStateIDs.contains(state.id) {
			try FolderStateRecord.insert { state }.execute(db)
		}

		// A tab closed since the cascade has no state left: it stays closed.
		let regularTabIDs: Set<UUID> = Set(try RegularTabRecord.select(\.id).fetchAll(db))
		let tabStateIDs: Set<UUID> = Set(try TabStateRecord.select(\.id).fetchAll(db))
		for tab in regularTabs where spaceIDs.contains(tab.spaceID) && !regularTabIDs.contains(tab.id) && tabStateIDs.contains(tab.id) {
			try RegularTabRecord.insert { tab }.execute(db)
		}
		return count
	}
}

/// Tab Archive: its entries and this Mac's deletions of them.
struct KeptArchive: KeptCategoryRows {
	var entries: [ArchiveEntryRecord]

	/// The entries this Mac removed: one that went everywhere stays gone.
	var deletions: Set<UUID>

	init(
		_ db: Database,
		deviceID: UUID
	) throws {
		self.entries = try ArchiveEntryRecord.all.fetchAll(db)
		self.deletions = Set(try ArchiveDeletionRecord.where { $0.deviceID.eq(deviceID) }.fetchAll(db).map(\.itemID))
	}

	func restore(_ db: Database) throws -> Int {
		let present: Set<UUID> = Set(try ArchiveEntryRecord.select(\.id).fetchAll(db))
		var count: Int = 0
		for entry in entries where !present.contains(entry.id) && !deletions.contains(entry.id) {
			try ArchiveEntryRecord.insert { entry }.execute(db)
			count += 1
		}
		return count
	}
}
