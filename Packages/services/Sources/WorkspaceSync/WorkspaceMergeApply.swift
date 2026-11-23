import Foundation
import WorkspaceDatabase
import _SQLiteData

extension WorkspaceMerge {
	// MARK: - The joining Mac

	/// Merges this Mac's rows into iCloud's before any of them upload (DEV-1216): its matched items
	/// take iCloud's IDs and values, the rest move into iCloud's profiles, spaces and folders after
	/// what's there, and a taken name gets the Mac's name.
	///
	/// iCloud's copy of each kept item is written here first, with iCloud's values, so this Mac's open
	/// tabs, selection and other state can move to it at once; the first fetch brings the rest. When
	/// those copies upload, iCloud already has them with the same values. The merged profiles'
	/// website data stays: each kept profile becomes this Mac's alias for its storage
	/// (``ProfileStorageRecord``). Run with synced deletions allowed: the merged rows never reached
	/// iCloud, so deleting them sends nothing.
	public static func applyJoining(
		_ matching: Matching,
		cloud: Snapshot,
		_ db: Database
	) throws {
		// iCloud's copies, parents first.
		let keptProfiles: Set<UUID> = Set(matching.profiles.values)
		for profile in cloud.profiles where try keptProfiles.contains(profile.id) && !exists(ProfileRecord.tableName, profile.id, db) {
			try ProfileRecord.insert { profile }.execute(db)
		}
		let keptSpaces: Set<UUID> = Set(matching.spaces.values)
		for space in cloud.spaces where try keptSpaces.contains(space.id) && !exists(SpaceRecord.tableName, space.id, db) {
			try SpaceRecord.insert { space }.execute(db)
		}

		// The kept folders, and every folder a kept folder or pin is in, so they show before the first
		// fetch: an item whose folder is missing doesn't, and a save meanwhile would lose it.
		let cloudFolders: [UUID: FolderRecord] = Dictionary(cloud.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		var neededFolders: [UUID] = []
		var visited: Set<UUID> = []
		let starts: [UUID?] = matching.folders.values.sorted { $0.uuidString < $1.uuidString }.map(Optional.some)
			+ cloud.pinnedTabs.filter { Set(matching.pinnedTabs.values).contains($0.id) }.map(\.folderID)
		for start in starts {
			var chain: [UUID] = []
			var current: UUID? = start
			while let id = current, visited.insert(id).inserted, let folder = cloudFolders[id] {
				chain.append(id)
				current = folder.parentFolderID
			}
			neededFolders += chain.reversed()
		}
		for id in neededFolders {
			guard let folder = cloudFolders[id], try !exists(FolderRecord.tableName, id, db) else { continue }

			try FolderRecord.insert { folder }.execute(db)
		}
		let keptPins: Set<UUID> = Set(matching.pinnedTabs.values)
		for tab in cloud.pinnedTabs where try keptPins.contains(tab.id) && !exists(PinnedTabRecord.tableName, tab.id, db) {
			try PinnedTabRecord.insert { tab }.execute(db)
		}
		let keptFavorites: Set<UUID> = Set(matching.favorites.values)
		for favorite in cloud.favorites where try keptFavorites.contains(favorite.id) && !exists(FavoriteRecord.tableName, favorite.id, db) {
			try FavoriteRecord.insert { favorite }.execute(db)
		}

		try applyMoves(matching, db)
		let pairs: [(table: String, merged: UUID, kept: UUID)] = matching.pairs
		try moveLocalState(pairs, db)

		// The app may save from the workspace it read before this: the store rebases such a save onto
		// the kept items until it reads again.
		for (_, merged, kept) in pairs {
			try MergeRemapRecord.upsert { MergeRemapRecord(id: merged, keptID: kept) }.execute(db)
		}

		// The website data of each merged profile stays here, under the kept profile's ID.
		let aliases: [UUID: UUID] = try ProfileStorageRecord.aliases(db)
		for (merged, kept) in matching.profiles.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
			try setAlias(kept, to: aliases[merged] ?? merged, db)
			try ProfileStorageRecord.find(merged).delete().execute(db)
		}

		// The merged rows, children first. Their use and deletion rows never synced either.
		let ids: [UUID] = pairs.map(\.merged)
		try UsageRecord.where { $0.itemID.in(ids) }.delete().execute(db)
		try DeletionRecord.where { $0.itemID.in(ids) }.delete().execute(db)
		try PinnedTabRecord.where { $0.id.in(Array(matching.pinnedTabs.keys)) }.delete().execute(db)
		try FavoriteRecord.where { $0.id.in(Array(matching.favorites.keys)) }.delete().execute(db)
		try FolderRecord.where { $0.id.in(Array(matching.folders.keys)) }.delete().execute(db)
		try SpaceRecord.where { $0.id.in(Array(matching.spaces.keys)) }.delete().execute(db)
		try ProfileRecord.where { $0.id.in(Array(matching.profiles.keys)) }.delete().execute(db)
	}

	// MARK: - Synced profiles, from Settings

	/// Merges synced profiles from Settings › iCloud Sync (DEV-1216): moves the merged profiles'
	/// unmatched items into the kept ones, writes a ``MergedItemRecord`` for each matched item, then
	/// applies them here (``applyMergedItems(_:now:summary:)``). Every other Mac applies them in its
	/// repair pass, and the merged items go everywhere once every Mac has hidden them (DEV-980).
	@discardableResult
	public static func applySynced(
		_ matching: Matching,
		now: Date,
		_ db: Database
	) throws -> WorkspaceRepair.Summary {
		// Which profiles this Mac used is read before their spaces move.
		let used: Set<UUID> = try usedProfiles(Set(matching.profiles.keys).union(matching.profiles.values), db)

		// A space that moves to the kept profile says which it left: on the other Macs, its open tabs
		// are a use of that one, wherever the fetch already put it.
		for id in matching.spaceMoves.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
			guard
				let space = try SpaceRecord.find(id).fetchOne(db),
				matching.profiles[space.profileID] != nil
			else { continue }

			try MergedItemRecord.upsert {
				MergedItemRecord(id: id, itemTable: movedSpaceTable, keptID: space.profileID, mergedAt: now.timeIntervalSince1970)
			}
			.execute(db)
		}
		for (table, merged, kept) in matching.pairs {
			try MergedItemRecord.upsert {
				MergedItemRecord(id: merged, itemTable: table, keptID: kept, mergedAt: now.timeIntervalSince1970)
			}
			.execute(db)
		}
		try applyMoves(matching, db)
		var summary: WorkspaceRepair.Summary = .init()
		try applyMergedItems(db, now: now, usedProfiles: used, summary: &summary)
		return summary
	}

	/// Every merged item and the item it ends up in, by table: following a merge into an item that
	/// was merged itself. Read from ``MergedItemRecord``, leaving out ``movedSpaceTable`` rows.
	public static func mergedTargets(_ db: Database) throws -> [String: [UUID: UUID]] {
		var targets: [String: [UUID: UUID]] = [:]
		for record in try MergedItemRecord.all.fetchAll(db)
		where record.id != record.keptID && LocalDeletion.itemTables.contains(record.itemTable) {
			targets[record.itemTable, default: [:]][record.id] = record.keptID
		}
		for (table, map) in targets {
			var resolved: [UUID: UUID] = [:]
			for start in map.keys {
				// Two Macs can merge the same items in opposite directions at once: the items of such a
				// cycle all end in its lowest ID, which stays.
				var path: [UUID] = [start]
				var current: UUID = start
				var last: UUID
				while true {
					guard let next = map[current] else {
						last = current
						break
					}
					if let index = path.firstIndex(of: next) {
						last = path[index...].min { $0.uuidString < $1.uuidString } ?? next
						break
					}
					path.append(next)
					current = next
				}
				if last != start {
					resolved[start] = last
				}
			}
			targets[table] = resolved
		}
		return targets
	}

	/// Applies the merges recorded in ``MergedItemRecord``, as the repair pass does on every Mac:
	/// for each merged item this Mac still shows, whose kept item it has (the last one, when that
	/// was merged too), what's left in it moves to the kept item, this Mac's open tabs, selection
	/// and state follow, and the merged item is hidden here. A kept profile this Mac never used keeps
	/// the merged one's website data, when this Mac used that; one it used keeps its own, so no page
	/// open in it changes storage.
	///
	/// - Parameters:
	///   - usedProfiles: the profiles this Mac used, read before a merge moved their spaces;
	///     `nil` reads them now.
	internal static func applyMergedItems(
		_ db: Database,
		now: Date,
		usedProfiles: Set<UUID>? = nil,
		summary: inout WorkspaceRepair.Summary
	) throws {
		let targets: [String: [UUID: UUID]] = try mergedTargets(db)
		guard !targets.isEmpty else { return }

		// An item merged in a cycle that ends in it stays: if this Mac hid it for the first of two
		// opposite merges, it shows again (DEV-1216).
		if let deviceID = try StoreInfoRecord.find(StoreInfoKey.deviceID).fetchOne(db).flatMap({ UUID(uuidString: $0.value) }) {
			for record in try MergedItemRecord.all.fetchAll(db)
			where LocalDeletion.itemTables.contains(record.itemTable) && targets[record.itemTable]?[record.id] == nil {
				try DeletionRecord
					.where { $0.itemID.eq(record.id) && $0.itemTable.eq(record.itemTable) && $0.deviceID.eq(deviceID) }
					.delete()
					.execute(db)
			}
		}
		let hidden: HiddenItems = try LocalDeletion.hiddenItems(db)
		let order: [String] = [
			ProfileRecord.tableName,
			SpaceRecord.tableName,
			FolderRecord.tableName,
			PinnedTabRecord.tableName,
			FavoriteRecord.tableName,
		]
		let mergedIDs: Set<UUID> = Set(targets.values.flatMap(\.keys))
		var present: [(table: String, merged: UUID, kept: UUID)] = []
		for table in order {
			for (merged, kept) in (targets[table] ?? [:]).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
				guard
					merged != kept,
					try exists(table, merged, db),
					// A fetch can bring the record before the item it keeps: wait for it.
					try exists(table, kept, db)
				else { continue }

				present.append((table, merged, kept))
			}
		}
		let pairs: [(table: String, merged: UUID, kept: UUID)] = present.filter { !hidden.contains($0.merged, in: $0.table) }

		// A kept item this Mac hid shows again with what merged into it: otherwise both would be gone
		// here.
		let hiddenKept: [(table: String, merged: UUID, kept: UUID)] = pairs.filter { hidden.contains($0.kept, in: $0.table) }
		if !hiddenKept.isEmpty, let deviceID = try StoreInfoRecord.find(StoreInfoKey.deviceID).fetchOne(db).flatMap({ UUID(uuidString: $0.value) }) {
			for pair in hiddenKept {
				try DeletionRecord
					.where { $0.itemID.eq(pair.kept) && $0.itemTable.eq(pair.table) && $0.deviceID.eq(deviceID) }
					.delete()
					.execute(db)
			}
		}
		let profilePairs: [(table: String, merged: UUID, kept: UUID)] = pairs.filter { $0.table == ProfileRecord.tableName }

		// Which website data this Mac keeps is decided before its open tabs move.
		let used: Set<UUID> = try usedProfiles
			?? self.usedProfiles(Set(profilePairs.flatMap { [$0.merged, $0.kept] }), db)

		// Even once hidden here: what another Mac put in a merged item later moves to the kept one.
		for (table, merged, kept) in present {
			try moveLeftovers(table, merged: merged, kept: kept, except: mergedIDs, db)
		}

		// A save that put an open tab in a merged item after it was hidden here: it follows too.
		try moveLocalState(present, db)
		guard !pairs.isEmpty else { return }

		let deviceID: UUID = try LocalDeletion.deviceID(db)

		let aliases: [UUID: UUID] = try ProfileStorageRecord.aliases(db)
		for pair in profilePairs {
			if !used.contains(pair.kept), used.contains(pair.merged) {
				try setAlias(pair.kept, to: aliases[pair.merged] ?? pair.merged, db)
			}
			try ProfileStorageRecord.find(pair.merged).delete().execute(db)
			summary.mergedProfiles[pair.merged] = pair.kept
		}
		for pair in pairs where pair.table == SpaceRecord.tableName {
			summary.mergedSpaces[pair.merged] = pair.kept
		}

		let removed: [(table: String, ids: [UUID])] = order.map { table in
			(table, pairs.filter { $0.table == table }.map(\.merged))
		}
		_ = try LocalDeletion.hide(removed, deviceID: deviceID, now: now, db)
		summary.mergedItems += pairs.map(\.merged)
	}

	// MARK: - Shared

	/// Moves, renames and orders the merged side's unmatched items.
	private static func applyMoves(
		_ matching: Matching,
		_ db: Database
	) throws {
		for (id, position) in matching.profilePositions.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
			try ProfileRecord.find(id).update { $0.position = #bind(position) }.execute(db)
		}
		for (id, name) in matching.profileNames.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
			try ProfileRecord.find(id).update { $0.name = #bind(name) }.execute(db)
		}
		for (id, move) in matching.spaceMoves.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
			try SpaceRecord
				.find(id)
				.update {
					$0.profileID = #bind(move.parentID)
					$0.position = #bind(move.position)
				}
				.execute(db)
		}
		for (id, name) in matching.spaceNames.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
			try SpaceRecord.find(id).update { $0.name = #bind(name) }.execute(db)
		}
		for (id, move) in matching.folderMoves.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
			try FolderRecord
				.find(id)
				.update {
					$0.spaceID = #bind(move.parentID)
					$0.parentFolderID = #bind(move.folderID)
					$0.position = #bind(move.position)
				}
				.execute(db)
		}
		for (id, move) in matching.pinMoves.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
			try PinnedTabRecord
				.find(id)
				.update {
					$0.spaceID = #bind(move.parentID)
					$0.folderID = #bind(move.folderID)
					$0.position = #bind(move.position)
				}
				.execute(db)
		}
		for (id, move) in matching.favoriteMoves.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
			try FavoriteRecord
				.find(id)
				.update {
					$0.profileID = #bind(move.parentID)
					$0.position = #bind(move.position)
				}
				.execute(db)
		}
	}

	/// What's still in a merged profile, space or folder, other than items merged themselves, moves
	/// to the kept one, after what's there: what another Mac added meanwhile, or this Mac hid.
	private static func moveLeftovers(
		_ table: String,
		merged: UUID,
		kept: UUID,
		except mergedIDs: Set<UUID>,
		_ db: Database
	) throws {
		switch table {
		case ProfileRecord.tableName:
			var lastSpace: String? = try SpaceRecord.where { $0.profileID.eq(kept) }.select(\.position).fetchAll(db).max()
			for space in try SpaceRecord.where({ $0.profileID.eq(merged) }).fetchAll(db).sorted(by: ordered)
			where !mergedIDs.contains(space.id) {
				let position: String = WorkspaceRepair.positionAfter(lastSpace)
				lastSpace = position
				try SpaceRecord
					.find(space.id)
					.update {
						$0.profileID = #bind(kept)
						$0.position = #bind(position)
					}
					.execute(db)
			}
			var lastFavorite: String? = try FavoriteRecord.where { $0.profileID.eq(kept) }.select(\.position).fetchAll(db).max()
			for favorite in try FavoriteRecord.where({ $0.profileID.eq(merged) }).fetchAll(db).sorted(by: ordered)
			where !mergedIDs.contains(favorite.id) {
				let position: String = WorkspaceRepair.positionAfter(lastFavorite)
				lastFavorite = position
				try FavoriteRecord
					.find(favorite.id)
					.update {
						$0.profileID = #bind(kept)
						$0.position = #bind(position)
					}
					.execute(db)
			}

		case SpaceRecord.tableName:
			let folderKeys: [String] = try FolderRecord
				.where { $0.spaceID.eq(kept) && $0.parentFolderID.is(nil) }
				.select(\.position)
				.fetchAll(db)
			let pinKeys: [String] = try PinnedTabRecord
				.where { $0.spaceID.eq(kept) && $0.folderID.is(nil) }
				.select(\.position)
				.fetchAll(db)
			var lastRoot: String? = (folderKeys + pinKeys).max()
			for folder in try FolderRecord.where({ $0.spaceID.eq(merged) }).fetchAll(db).sorted(by: ordered)
			where !mergedIDs.contains(folder.id) {
				var position: String = folder.position
				if folder.parentFolderID == nil {
					position = WorkspaceRepair.positionAfter(lastRoot)
					lastRoot = position
				}
				try FolderRecord
					.find(folder.id)
					.update {
						$0.spaceID = #bind(kept)
						$0.position = #bind(position)
					}
					.execute(db)
			}
			for tab in try PinnedTabRecord.where({ $0.spaceID.eq(merged) }).fetchAll(db).sorted(by: ordered)
			where !mergedIDs.contains(tab.id) {
				var position: String = tab.position
				if tab.folderID == nil {
					position = WorkspaceRepair.positionAfter(lastRoot)
					lastRoot = position
				}
				try PinnedTabRecord
					.find(tab.id)
					.update {
						$0.spaceID = #bind(kept)
						$0.position = #bind(position)
					}
					.execute(db)
			}

		case FolderRecord.tableName:
			guard let keptFolder = try FolderRecord.find(kept).fetchOne(db) else { return }

			let folderKeys: [String] = try FolderRecord.where { $0.parentFolderID.eq(kept) }.select(\.position).fetchAll(db)
			let pinKeys: [String] = try PinnedTabRecord.where { $0.folderID.eq(kept) }.select(\.position).fetchAll(db)
			var last: String? = (folderKeys + pinKeys).max()
			for folder in try FolderRecord.where({ $0.parentFolderID.eq(merged) }).fetchAll(db).sorted(by: ordered)
			where !mergedIDs.contains(folder.id) {
				let position: String = WorkspaceRepair.positionAfter(last)
				last = position
				try FolderRecord
					.find(folder.id)
					.update {
						$0.spaceID = #bind(keptFolder.spaceID)
						$0.parentFolderID = #bind(kept)
						$0.position = #bind(position)
					}
					.execute(db)
			}
			for tab in try PinnedTabRecord.where({ $0.folderID.eq(merged) }).fetchAll(db).sorted(by: ordered)
			where !mergedIDs.contains(tab.id) {
				let position: String = WorkspaceRepair.positionAfter(last)
				last = position
				try PinnedTabRecord
					.find(tab.id)
					.update {
						$0.spaceID = #bind(keptFolder.spaceID)
						$0.folderID = #bind(kept)
						$0.position = #bind(position)
					}
					.execute(db)
			}

		default:
			return
		}
	}

	/// This Mac's own rows that name a merged item now name the kept one: open tabs and selection of
	/// a space, a folder's expansion, a tab's restoration state, and tab IDs in split views, tab
	/// groups and the old Tab Archive rows.
	private static func moveLocalState(
		_ pairs: [(table: String, merged: UUID, kept: UUID)],
		_ db: Database
	) throws {
		for (table, merged, kept) in pairs {
			switch table {
			case SpaceRecord.tableName:
				var last: String? = try RegularTabRecord.where { $0.spaceID.eq(kept) }.select(\.position).fetchAll(db).max()
				for tab in try RegularTabRecord.where({ $0.spaceID.eq(merged) }).fetchAll(db)
					.sorted(by: { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }) {
					let position: String = last == nil ? tab.position : WorkspaceRepair.positionAfter(last)
					last = max(last ?? "", position)
					try RegularTabRecord
						.find(tab.id)
						.update {
							$0.spaceID = #bind(kept)
							$0.position = #bind(position)
						}
						.execute(db)
				}
				try moveStateRow(table: SpaceStateRecord.tableName, from: merged, to: kept, db)

			case FolderRecord.tableName:
				try moveStateRow(table: FolderStateRecord.tableName, from: merged, to: kept, db)

			case PinnedTabRecord.tableName, FavoriteRecord.tableName:
				try SpaceStateRecord
					.where { $0.selectedTabID.eq(merged) }
					.update { $0.selectedTabID = #bind(kept) }
					.execute(db)
				try moveStateRow(table: TabStateRecord.tableName, from: merged, to: kept, db)

			default:
				break
			}

			// Tab, space and profile IDs in this Mac's JSON rows.
			for jsonTable in ["archivedTab", "splitGroup", "tabGroup"] {
				for (old, new) in [
					(merged.uuidString, kept.uuidString),
					(merged.uuidString.lowercased(), kept.uuidString.lowercased()),
				] {
					try db.execute(
						sql: """
						UPDATE "main"."\(jsonTable)" SET "value" = replace("value", ?, ?) WHERE instr("value", ?) > 0
						""",
						arguments: [old, new, old]
					)
				}
			}
		}
	}

	/// Moves a state row keyed by the item's ID, unless the kept item has one of its own.
	private static func moveStateRow(
		table: String,
		from merged: UUID,
		to kept: UUID,
		_ db: Database
	) throws {
		let mergedKey: String = merged.uuidString.lowercased()
		let keptKey: String = kept.uuidString.lowercased()
		let keptHasOne: Bool = try Bool.fetchOne(
			db,
			sql: #"SELECT EXISTS (SELECT 1 FROM "main"."\#(table)" WHERE "id" = ?)"#,
			arguments: [keptKey]
		) ?? false
		if keptHasOne {
			try db.execute(sql: #"DELETE FROM "main"."\#(table)" WHERE "id" = ?"#, arguments: [mergedKey])
		} else {
			try db.execute(sql: #"UPDATE "main"."\#(table)" SET "id" = ? WHERE "id" = ?"#, arguments: [keptKey, mergedKey])
		}
	}

	private static func setAlias(
		_ profile: UUID,
		to storage: UUID,
		_ db: Database
	) throws {
		if profile == storage {
			try ProfileStorageRecord.find(profile).delete().execute(db)
		} else {
			try ProfileStorageRecord.upsert { ProfileStorageRecord(id: profile, storageID: storage) }.execute(db)
		}
	}

	/// The ``MergedItemRecord/itemTable`` of a space a merge moved to the kept profile, whose
	/// ``MergedItemRecord/keptID`` is the profile it left.
	public static let movedSpaceTable: String = "movedSpace"

	/// The profiles among `ids` this Mac uses: with website data aliased to them, open tabs here in
	/// their spaces (a space a merge moved counts for the profile it left), or a use it recorded
	/// (DEV-980). Their pages may be open, so their storage never changes.
	private static func usedProfiles(
		_ ids: Set<UUID>,
		_ db: Database
	) throws -> Set<UUID> {
		guard !ids.isEmpty else { return [] }

		let deviceID: UUID? = try StoreInfoRecord.find(StoreInfoKey.deviceID).fetchOne(db).flatMap { UUID(uuidString: $0.value) }
		let aliases: [UUID: UUID] = try ProfileStorageRecord.aliases(db)
		var movedFrom: [UUID: UUID] = [:]
		for record in try MergedItemRecord.where({ $0.itemTable.eq(movedSpaceTable) }).fetchAll(db) {
			movedFrom[record.id] = record.keptID
		}
		var used: Set<UUID> = []
		for id in ids {
			let spaceIDs: [UUID] = try SpaceRecord.where { $0.profileID.eq(id) }.select(\.id).fetchAll(db)
				.filter { movedFrom[$0].map { $0 == id } ?? true }
				+ movedFrom.filter { $0.value == id }.map(\.key)
			let isUsed: Bool = try aliases[id] != nil
				|| RegularTabRecord.where({ $0.spaceID.in(spaceIDs) }).fetchCount(db) > 0
				|| deviceID.map { deviceID in
					try UsageRecord.where { $0.itemID.eq(id) && $0.deviceID.eq(deviceID) }.fetchCount(db) > 0
				} ?? false
			if isUsed {
				used.insert(id)
			}
		}
		return used
	}

	private static func exists(
		_ table: String,
		_ id: UUID,
		_ db: Database
	) throws -> Bool {
		try Bool.fetchOne(
			db,
			sql: #"SELECT EXISTS (SELECT 1 FROM "main"."\#(table)" WHERE "id" = ?)"#,
			arguments: [id.uuidString.lowercased()]
		) ?? false
	}

}
