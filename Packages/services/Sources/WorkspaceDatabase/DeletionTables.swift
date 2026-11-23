import CryptoKit
import Foundation
import _SQLiteData

// MARK: - Deletions that stay local (DEV-980)

/// One Mac's deletion of a synced profile, space, folder, pinned tab or Favorite (ADR 0001,
/// Decisions 1). The item stays in iCloud: the Mac that deleted it hides it, and every other Mac
/// keeps showing it. The repair pass deletes it everywhere once every Mac that syncs has deleted
/// it, or, with "sync deletions after" on, once nobody used it for that long after the first
/// deletion.
@Table("deletion")
public struct DeletionRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("itemID")
	public var itemID: UUID

	/// The item's table, such as ``PinnedTabRecord``'s.
	@Column("itemTable")
	public var itemTable: String

	/// The Mac that deleted it (``StoreInfoKey/deviceID``).
	@Column("deviceID")
	public var deviceID: UUID

	/// Seconds since 1970.
	@Column("deletedAt")
	public var deletedAt: Double

	/// The person chose "Delete from This Mac Only" for a profile or space: the other Macs keep it,
	/// so "sync deletions after" doesn't count this deletion and no Mac marks the item for deletion.
	/// It still counts when every Mac deleted the item. `false` asks the other Macs to remove it, as
	/// every deletion did before (DEV-1336).
	@Column("keepsElsewhere")
	public var keepsElsewhere: Bool

	public init(
		id: UUID,
		itemID: UUID,
		itemTable: String,
		deviceID: UUID,
		deletedAt: Double,
		keepsElsewhere: Bool = false
	) {
		self.id = id
		self.itemID = itemID
		self.itemTable = itemTable
		self.deviceID = deviceID
		self.deletedAt = deletedAt
		self.keepsElsewhere = keepsElsewhere
	}
}

/// When one Mac last used a synced item: opened it (selected a tab or space, expanded a folder)
/// or edited it. Written at most once a day per item and Mac, so a deletion synced after a period
/// spares what someone still uses.
@Table("usage")
public struct UsageRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("itemID")
	public var itemID: UUID

	@Column("itemTable")
	public var itemTable: String

	@Column("deviceID")
	public var deviceID: UUID

	/// Seconds since 1970.
	@Column("lastUsed")
	public var lastUsed: Double

	public init(
		id: UUID,
		itemID: UUID,
		itemTable: String,
		deviceID: UUID,
		lastUsed: Double
	) {
		self.id = id
		self.itemID = itemID
		self.itemTable = itemTable
		self.deviceID = deviceID
		self.lastUsed = lastUsed
	}
}

/// A Mac that syncs the organization, so a deletion every one of them made can go everywhere.
@Table("syncDevice")
public struct SyncDeviceRecord: Equatable, Identifiable, Sendable {
	/// The Mac's ``StoreInfoKey/deviceID``.
	@Column(primaryKey: true)
	public let id: UUID

	/// Seconds since 1970, updated at most once a day.
	@Column("lastSeen")
	public var lastSeen: Double

	public init(
		id: UUID,
		lastSeen: Double
	) {
		self.id = id
		self.lastSeen = lastSeen
	}
}

/// What this Mac deleted, by table.
public struct HiddenItems: Equatable, Sendable {
	public var ids: [String: Set<UUID>]

	public init(ids: [String: Set<UUID>] = [:]) {
		self.ids = ids
	}

	public var isEmpty: Bool { ids.values.allSatisfy(\.isEmpty) }

	public func contains(_ id: UUID, in table: String) -> Bool {
		ids[table]?.contains(id) ?? false
	}
}

/// The synced tables whose rows a deletion here hides instead of deleting.
public enum LocalDeletion {
	public static let itemTables: Set<String> = [
		ProfileRecord.tableName,
		SpaceRecord.tableName,
		FolderRecord.tableName,
		PinnedTabRecord.tableName,
		FavoriteRecord.tableName,
	]

	/// The ID of a deletion row (with the item's table) or a usage row (`table` `nil`) for `item` and
	/// `device`: the same on every Mac, so the repair can ask iCloud for exactly the rows a purge
	/// relies on, another Mac's included.
	public static func rowID(
		item: UUID,
		table: String?,
		device: UUID
	) -> UUID {
		let name: String = "\(table.map { "deletion:\($0)" } ?? "usage"):\(item.uuidString.lowercased()):\(device.uuidString.lowercased())"
		var bytes: [UInt8] = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))

		// A name-based UUID's version and variant bits.
		bytes[6] = (bytes[6] & 0x0F) | 0x50
		bytes[8] = (bytes[8] & 0x3F) | 0x80
		return UUID(uuid: (
			bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
			bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
		))
	}

	/// This Mac's ID in the store's device-local info, made the first time it's needed.
	public static func deviceID(_ db: Database) throws -> UUID {
		if
			let stored = try StoreInfoRecord.find(StoreInfoKey.deviceID).fetchOne(db),
			let id = UUID(uuidString: stored.value)
		{
			return id
		}

		let id: UUID = .init()
		try StoreInfoRecord.upsert {
			StoreInfoRecord(id: StoreInfoKey.deviceID, value: id.uuidString.lowercased())
		}
		.execute(db)
		return id
	}

	/// The items this Mac deleted, by table, or none before it has an ID. A tab keeps its ID when it
	/// moves between tables, from a pin to a Favorite say, so only the table it left is hidden.
	public static func hiddenItems(_ db: Database) throws -> HiddenItems {
		guard let deviceID = try existingDeviceID(db) else { return .init() }

		var hidden: HiddenItems = .init()
		for deletion in try DeletionRecord.where({ $0.deviceID.eq(deviceID) }).fetchAll(db) {
			hidden.ids[deletion.itemTable, default: []].insert(deletion.itemID)
		}
		return hidden
	}
}

extension OrganizationRows {
	/// These rows without the items this Mac deleted (DEV-980), and without what can't show without
	/// them: a hidden profile's spaces and Favorites, a hidden space's folders, pinned and open
	/// tabs. A hidden folder's children that weren't deleted here, such as a pin another Mac added
	/// to it later, show in the closest folder above it that's shown, or at its space's root.
	/// This Mac's own state for what's left out is left out too.
	public func hiding(_ hidden: HiddenItems) -> Self {
		guard !hidden.isEmpty else { return self }

		var rows: Self = self
		rows.profiles = profiles.filter { !hidden.contains($0.key, in: ProfileRecord.tableName) }
		rows.spaces = spaces.filter { id, space in
			!hidden.contains(id, in: SpaceRecord.tableName) && rows.profiles[space.profileID] != nil
		}
		rows.favorites = favorites.filter { id, favorite in
			!hidden.contains(id, in: FavoriteRecord.tableName) && rows.profiles[favorite.profileID] != nil
		}

		/// The closest folder at or above `id` that's shown, or `nil` for the space's root.
		func shownFolder(_ id: UUID?) -> UUID? {
			var current: UUID? = id
			var visited: Set<UUID> = []
			while let folderID = current, visited.insert(folderID).inserted {
				guard hidden.contains(folderID, in: FolderRecord.tableName) else { return folderID }

				current = folders[folderID]?.parentFolderID
			}
			return nil
		}

		rows.folders = [:]
		for (id, folder) in folders
		where !hidden.contains(id, in: FolderRecord.tableName) && rows.spaces[folder.spaceID] != nil {
			var shown: FolderRecord = folder
			shown.parentFolderID = shownFolder(folder.parentFolderID)
			rows.folders[id] = shown
		}
		rows.pinnedTabs = [:]
		for (id, tab) in pinnedTabs
		where !hidden.contains(id, in: PinnedTabRecord.tableName) && rows.spaces[tab.spaceID] != nil {
			var shown: PinnedTabRecord = tab
			shown.folderID = shownFolder(tab.folderID)
			rows.pinnedTabs[id] = shown
		}
		rows.regularTabs = regularTabs.filter { rows.spaces[$0.value.spaceID] != nil }

		rows.spaceStates = spaceStates.filter { rows.spaces[$0.key] != nil }
		rows.folderStates = folderStates.filter { rows.folders[$0.key] != nil }
		let shownTabs: Set<UUID> = Set(rows.pinnedTabs.keys)
			.union(rows.favorites.keys)
			.union(rows.regularTabs.keys)
		let leftOut: Set<UUID> = Set(pinnedTabs.keys)
			.union(favorites.keys)
			.union(regularTabs.keys)
			.subtracting(shownTabs)
		rows.tabStates = tabStates.filter { !leftOut.contains($0.key) }
		return rows
	}
}

extension LocalDeletion {
	/// This Mac's ID, or `nil` before it has one.
	public static func existingDeviceID(_ db: Database) throws -> UUID? {
		try StoreInfoRecord.find(StoreInfoKey.deviceID).fetchOne(db).flatMap { UUID(uuidString: $0.value) }
	}

	/// Shows again what this Mac deleted and a save brings back to the same table, such as an undo.
	internal static func show(_ items: [(table: String, ids: [UUID])], _ db: Database) throws {
		guard items.contains(where: { !$0.ids.isEmpty }), let deviceID = try existingDeviceID(db) else { return }

		for (table, itemIDs) in items {
			for batch in stride(from: 0, to: itemIDs.count, by: 500) {
				let ids: [UUID] = Array(itemIDs[batch ..< min(batch + 500, itemIDs.count)])
				try DeletionRecord
					.where { $0.deviceID.eq(deviceID) && $0.itemTable.eq(table) && $0.itemID.in(ids) }
					.delete()
					.execute(db)
			}
		}
	}

	/// Hides each of `removed` here with a deletion row instead of deleting it.
	///
	/// - Returns: how many deletion rows were written.
	public static func hide(
		_ removed: [(table: String, ids: [UUID])],
		deviceID: UUID,
		now: Date,
		_ db: Database
	) throws -> Int {
		let itemIDs: [UUID] = removed.flatMap(\.ids)
		guard !itemIDs.isEmpty else { return 0 }

		var already: HiddenItems = .init()
		for deletion in try DeletionRecord.where({ $0.deviceID.eq(deviceID) && $0.itemID.in(itemIDs) }).fetchAll(db) {
			already.ids[deletion.itemTable, default: []].insert(deletion.itemID)
		}
		let rows: [DeletionRecord] = removed.flatMap { table, ids in
			ids.filter { !already.contains($0, in: table) }.map { id in
				DeletionRecord(
					id: rowID(item: id, table: table, device: deviceID),
					itemID: id,
					itemTable: table,
					deviceID: deviceID,
					deletedAt: now.timeIntervalSince1970
				)
			}
		}
		for batch in stride(from: 0, to: rows.count, by: 200) {
			let chunk: [DeletionRecord] = Array(rows[batch ..< min(batch + 200, rows.count)])
			try DeletionRecord.insert { chunk }.execute(db)
		}
		return rows.count
	}

	/// The spaces, pinned tabs and Favorites among `ids`, by table, with the profile of each space and
	/// Favorite, as a save counts them. What this Mac deleted is left out: a tab that moved from a
	/// pin to a Favorite keeps its ID, and opening the Favorite isn't a use of the deleted pin.
	internal static func storedItems(
		_ ids: Set<UUID>,
		_ db: Database
	) throws -> [UUID: String] {
		// A "this Mac only" profile's items have synced copies with the same IDs, which its use mustn't
		// reach (DEV-981).
		var local: Set<UUID> = []
		for batch in stride(from: 0, to: ids.count, by: 500) {
			let chunk: [UUID] = Array(Array(ids)[batch ..< min(batch + 500, ids.count)])
			local.formUnion(try LocalProfileRecord.where { $0.id.in(chunk) }.select(\.id).fetchAll(db))
			local.formUnion(try LocalSpaceRecord.where { $0.id.in(chunk) }.select(\.id).fetchAll(db))
			local.formUnion(try LocalPinnedTabRecord.where { $0.id.in(chunk) }.select(\.id).fetchAll(db))
			local.formUnion(try LocalFavoriteRecord.where { $0.id.in(chunk) }.select(\.id).fetchAll(db))
		}
		let itemIDs: [UUID] = Array(ids.subtracting(local))
		let hidden: HiddenItems = try hiddenItems(db)
		var used: [UUID: String] = [:]
		for batch in stride(from: 0, to: itemIDs.count, by: 500) {
			let chunk: [UUID] = Array(itemIDs[batch ..< min(batch + 500, itemIDs.count)])
			for space in try SpaceRecord.where({ $0.id.in(chunk) }).fetchAll(db)
			where !hidden.contains(space.id, in: SpaceRecord.tableName) {
				used[space.id] = SpaceRecord.tableName
				used[space.profileID] = ProfileRecord.tableName
			}
			for tab in try PinnedTabRecord.where({ $0.id.in(chunk) }).fetchAll(db)
			where !hidden.contains(tab.id, in: PinnedTabRecord.tableName) {
				used[tab.id] = PinnedTabRecord.tableName
			}
			for favorite in try FavoriteRecord.where({ $0.id.in(chunk) }).fetchAll(db)
			where !hidden.contains(favorite.id, in: FavoriteRecord.tableName) {
				used[favorite.id] = FavoriteRecord.tableName
				used[favorite.profileID] = ProfileRecord.tableName
			}
		}
		return used
	}

	/// Records the use of each of `used` (item ID to its table) by this Mac, at most once a day, or
	/// again the same day when a Mac deleted the item since this Mac's last recorded use, so a use
	/// after a deletion always counts.
	///
	/// - Returns: how many usage rows were written.
	internal static func recordUse(
		_ used: [UUID: String],
		deviceID: UUID,
		now: Date,
		_ db: Database
	) throws -> Int {
		guard !used.isEmpty else { return 0 }

		let today: Double = Calendar.current.startOfDay(for: now).timeIntervalSince1970
		let itemIDs: [UUID] = Array(used.keys)
		let existing: [UUID: UsageRecord] = try Dictionary(
			UsageRecord.where { $0.deviceID.eq(deviceID) && $0.itemID.in(itemIDs) }.fetchAll(db).map { ($0.itemID, $0) },
			uniquingKeysWith: { first, _ in first }
		)
		var lastDeleted: [UUID: Double] = [:]
		for deletion in try DeletionRecord.where({ $0.itemID.in(itemIDs) }).fetchAll(db) {
			lastDeleted[deletion.itemID] = max(lastDeleted[deletion.itemID] ?? 0, deletion.deletedAt)
		}
		var rows: [UsageRecord] = []
		for (itemID, table) in used {
			if var row = existing[itemID] {
				guard row.lastUsed < today || (lastDeleted[itemID] ?? 0) >= row.lastUsed else { continue }

				row.lastUsed = now.timeIntervalSince1970
				rows.append(row)
			} else {
				rows.append(.init(
					id: rowID(item: itemID, table: nil, device: deviceID),
					itemID: itemID,
					itemTable: table,
					deviceID: deviceID,
					lastUsed: now.timeIntervalSince1970
				))
			}
		}
		for batch in stride(from: 0, to: rows.count, by: 200) {
			let chunk: [UsageRecord] = Array(rows[batch ..< min(batch + 200, rows.count)])
			try UsageRecord.upsert { chunk }.execute(db)
		}
		return rows.count
	}

	/// Marks this Mac's deletion rows of each of `roots` that it hid, and of everything in it as `base`
	/// has it, as kept elsewhere (DEV-1336): a profile's spaces and Favorites, a space's folders and
	/// pinned tabs.
	///
	/// - Returns: the roots this Mac has hidden, which need no marking again.
	internal static func keepElsewhere(
		_ roots: Set<UUID>,
		in base: OrganizationRows,
		_ db: Database
	) throws -> Set<UUID> {
		guard let deviceID = try existingDeviceID(db) else { return [] }

		let hidden: HiddenItems = try hiddenItems(db)
		let hiddenRoots: Set<UUID> = roots.filter { id in
			hidden.contains(id, in: ProfileRecord.tableName) || hidden.contains(id, in: SpaceRecord.tableName)
		}
		guard !hiddenRoots.isEmpty else { return [] }

		var items: Set<UUID> = hiddenRoots
		let spaces: Set<UUID> = Set(base.spaces.filter { items.contains($0.key) || items.contains($0.value.profileID) }.keys)
		items.formUnion(spaces)
		items.formUnion(base.favorites.filter { hiddenRoots.contains($0.value.profileID) }.keys)
		items.formUnion(base.folders.filter { spaces.contains($0.value.spaceID) }.keys)
		items.formUnion(base.pinnedTabs.filter { spaces.contains($0.value.spaceID) }.keys)
		let ids: [UUID] = Array(items)
		for batch in stride(from: 0, to: ids.count, by: 500) {
			let chunk: [UUID] = Array(ids[batch ..< min(batch + 500, ids.count)])
			try DeletionRecord
				.where { $0.deviceID.eq(deviceID) && $0.itemID.in(chunk) && !$0.keepsElsewhere }
				.update { $0.keepsElsewhere = true }
				.execute(db)
		}
		return hiddenRoots
	}
}
