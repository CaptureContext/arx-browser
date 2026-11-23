import Foundation
import _SQLiteData

// MARK: - Saves across a joining Mac's merge (DEV-1216)

/// An item a joining Mac's merge replaced with iCloud's (DEV-1216): this Mac's own profile, space,
/// folder, pinned tab or Favorite, deleted, and the item it became. Never synced.
///
/// The app may still hold the workspace from before the merge, with an edit on its way to the store.
/// Until it reads the store again, each save is rebased across the merge (``OrganizationRows/rebased(across:onto:)``),
/// so the edit lands on the kept items instead of the deleted ones, and nothing the merge wrote is
/// undone. `WorkspaceSync` forgets the rows at its next launch, when no store holds a workspace from
/// before the merge: any store may load while another still has an edit on its way.
@Table("mergeRemap")
public struct MergeRemapRecord: Equatable, Identifiable, Sendable {
	/// The replaced item.
	@Column(primaryKey: true)
	public let id: UUID

	/// The item it became.
	@Column("keptID")
	public var keptID: UUID

	public init(
		id: UUID,
		keptID: UUID
	) {
		self.id = id
		self.keptID = keptID
	}

	/// Forgets every replaced item, at a launch.
	public static func forget(_ db: Database) throws {
		guard try !remap(db).isEmpty else { return }

		try MergeRemapRecord.delete().execute(db)
	}

	/// Every replaced item and the item it became. Empty before the table exists.
	public static func remap(_ db: Database) throws -> [UUID: UUID] {
		let exists: Bool = try Bool.fetchOne(
			db,
			sql: #"SELECT EXISTS (SELECT 1 FROM "main"."sqlite_master" WHERE "type" = 'table' AND "name" = 'mergeRemap')"#
		) ?? false
		guard exists else { return [:] }

		var remap: [UUID: UUID] = [:]
		for row in try MergeRemapRecord.all.fetchAll(db) where row.id != row.keptID {
			remap[row.id] = row.keptID
		}
		return remap
	}
}

extension OrganizationRows {
	/// A save made from the workspace as it was before a merge, rebased across it: `new` (what the
	/// caller saves) and `old` (what it last read) with the replaced items' IDs as the kept ones, and
	/// each synced row the caller changed as the row in the store with only the changed fields
	/// applied. So the diff writes the person's edit and nothing else: not the merged-away values the
	/// merge replaced with iCloud's, nor the places the merge moved items to.
	public static func rebased(
		_ new: Self,
		_ old: Self,
		across remap: [UUID: UUID],
		_ db: Database
	) throws -> (new: Self, old: Self) {
		guard !remap.isEmpty else { return (new, old) }

		var new: Self = new.remapped(remap)
		var old: Self = old.remapped(remap)

		// "This Mac only" profiles and what's in them keep their own rows in the local file, which the
		// merge never touches: their synced copies here aren't theirs to rebase onto (DEV-981).
		let localProfiles: Set<UUID> = new.localProfileIDs.union(old.localProfileIDs)
		let localSpaces: Set<UUID> = Set(
			(Array(new.spaces.values) + Array(old.spaces.values)).filter { localProfiles.contains($0.profileID) }.map(\.id)
		)
		let local: Set<UUID> = localProfiles
			.union(localSpaces)
			.union((Array(new.folders.values) + Array(old.folders.values)).filter { localSpaces.contains($0.spaceID) }.map(\.id))
			.union((Array(new.pinnedTabs.values) + Array(old.pinnedTabs.values)).filter { localSpaces.contains($0.spaceID) }.map(\.id))
			.union((Array(new.favorites.values) + Array(old.favorites.values)).filter { localProfiles.contains($0.profileID) }.map(\.id))

		func rebase<Record: Equatable>(
			_ newRows: inout [UUID: Record],
			_ oldRows: inout [UUID: Record],
			fetch: (UUID) throws -> Record?,
			fields: [(inout Record, Record, Record) -> Void]
		) throws {
			for (id, row) in newRows where !local.contains(id) {
				guard
					let before = oldRows[id],
					before != row,
					var current = try fetch(id)
				else { continue }

				let stored: Record = current
				for field in fields {
					field(&current, before, row)
				}
				newRows[id] = current
				oldRows[id] = stored
			}
		}

		try rebase(
			&new.profiles,
			&old.profiles,
			fetch: { try ProfileRecord.find($0).fetchOne(db) },
			fields: [
				field(\.name), field(\.searchEngine), field(\.appearance), field(\.tabArchiveInterval),
				field(\.remoteSearchSuggestions), field(\.showsFullURL), field(\.keptLoadedSites),
				field(\.darkPagesOffSites), field(\.unreadBadges), field(\.position), field(\.isStarter),
			]
		)
		try rebase(
			&new.spaces,
			&old.spaces,
			fetch: { try SpaceRecord.find($0).fetchOne(db) },
			fields: [placement(\.profileID, \.position), field(\.name), field(\.icon), field(\.appearance), field(\.isStarter)]
		)
		try rebase(
			&new.folders,
			&old.folders,
			fetch: { try FolderRecord.find($0).fetchOne(db) },
			fields: [placement(\.spaceID, \.parentFolderID, \.position), field(\.name)]
		)
		try rebase(
			&new.pinnedTabs,
			&old.pinnedTabs,
			fetch: { try PinnedTabRecord.find($0).fetchOne(db) },
			fields: [
				placement(\.spaceID, \.folderID, \.position), field(\.title), field(\.url), field(\.iconURL),
				field(\.customTitle), field(\.icon),
			]
		)
		try rebase(
			&new.favorites,
			&old.favorites,
			fetch: { try FavoriteRecord.find($0).fetchOne(db) },
			fields: [placement(\.profileID, \.position), field(\.title), field(\.url), field(\.iconURL), field(\.customTitle), field(\.icon)]
		)

		// A pin the caller made a Favorite, or the other way round: the tab keeps the stored item's
		// title and address, with only what the caller changed, in its new place.
		typealias Metadata = (title: String, url: String, iconURL: String?, customTitle: String?, icon: String?)
		func merged(_ stored: Metadata, _ before: Metadata, _ after: Metadata) -> Metadata {
			(
				after.title != before.title ? after.title : stored.title,
				after.url != before.url ? after.url : stored.url,
				after.iconURL != before.iconURL ? after.iconURL : stored.iconURL,
				after.customTitle != before.customTitle ? after.customTitle : stored.customTitle,
				after.icon != before.icon ? after.icon : stored.icon
			)
		}
		for (id, favorite) in new.favorites where !local.contains(id) && old.favorites[id] == nil {
			guard
				let before = old.pinnedTabs[id],
				let stored = try PinnedTabRecord.find(id).fetchOne(db)
			else { continue }

			let value: Metadata = merged(
				(stored.title, stored.url, stored.iconURL, stored.customTitle, stored.icon),
				(before.title, before.url, before.iconURL, before.customTitle, before.icon),
				(favorite.title, favorite.url, favorite.iconURL, favorite.customTitle, favorite.icon)
			)
			new.favorites[id] = .init(
				id: id,
				profileID: favorite.profileID,
				title: value.title,
				url: value.url,
				iconURL: value.iconURL,
				customTitle: value.customTitle,
				icon: value.icon,
				position: favorite.position
			)
			old.pinnedTabs[id] = stored
		}
		for (id, pin) in new.pinnedTabs where !local.contains(id) && old.pinnedTabs[id] == nil {
			guard
				let before = old.favorites[id],
				let stored = try FavoriteRecord.find(id).fetchOne(db)
			else { continue }

			let value: Metadata = merged(
				(stored.title, stored.url, stored.iconURL, stored.customTitle, stored.icon),
				(before.title, before.url, before.iconURL, before.customTitle, before.icon),
				(pin.title, pin.url, pin.iconURL, pin.customTitle, pin.icon)
			)
			new.pinnedTabs[id] = .init(
				id: id,
				spaceID: pin.spaceID,
				folderID: pin.folderID,
				title: value.title,
				url: value.url,
				iconURL: value.iconURL,
				customTitle: value.customTitle,
				icon: value.icon,
				position: pin.position
			)
			old.favorites[id] = stored
		}
		return (new, old)
	}

	/// Sets a field of `current` to `new`'s when the caller changed it from `old`.
	private static func field<Record, Value: Equatable>(
		_ path: WritableKeyPath<Record, Value>
	) -> (inout Record, Record, Record) -> Void {
		{ current, old, new in
			if new[keyPath: path] != old[keyPath: path] {
				current[keyPath: path] = new[keyPath: path]
			}
		}
	}

	/// Where an item is, as one: when the caller moved it, all of its new place, since a new space with
	/// the stored folder could name a folder in another space.
	private static func placement<Record, Parent: Equatable>(
		_ parent: WritableKeyPath<Record, Parent>,
		_ position: WritableKeyPath<Record, String>
	) -> (inout Record, Record, Record) -> Void {
		{ current, old, new in
			guard new[keyPath: parent] != old[keyPath: parent] || new[keyPath: position] != old[keyPath: position] else { return }

			current[keyPath: parent] = new[keyPath: parent]
			current[keyPath: position] = new[keyPath: position]
		}
	}

	private static func placement<Record>(
		_ parent: WritableKeyPath<Record, UUID>,
		_ folder: WritableKeyPath<Record, UUID?>,
		_ position: WritableKeyPath<Record, String>
	) -> (inout Record, Record, Record) -> Void {
		{ current, old, new in
			guard
				new[keyPath: parent] != old[keyPath: parent]
					|| new[keyPath: folder] != old[keyPath: folder]
					|| new[keyPath: position] != old[keyPath: position]
			else { return }

			current[keyPath: parent] = new[keyPath: parent]
			current[keyPath: folder] = new[keyPath: folder]
			current[keyPath: position] = new[keyPath: position]
		}
	}

	/// These rows with the replaced items' IDs, wherever they appear, as the kept ones.
	internal func remapped(_ remap: [UUID: UUID]) -> Self {
		func id(_ value: UUID) -> UUID { remap[value] ?? value }
		func optional(_ value: UUID?) -> UUID? { value.map(id) }
		func keyed<Record>(_ rows: [UUID: Record], _ transform: (Record) -> Record) -> [UUID: Record] {
			Dictionary(rows.map { (id($0.key), transform($0.value)) }, uniquingKeysWith: { first, _ in first })
		}
		func text(_ value: String) -> String {
			remap.reduce(value) { value, pair in
				value
					.replacingOccurrences(of: pair.key.uuidString, with: pair.value.uuidString)
					.replacingOccurrences(of: pair.key.uuidString.lowercased(), with: pair.value.uuidString.lowercased())
			}
		}

		var rows: Self = self
		rows.profiles = keyed(profiles) { row in
			.init(
				id: id(row.id),
				name: row.name,
				searchEngine: row.searchEngine,
				appearance: row.appearance,
				tabArchiveInterval: row.tabArchiveInterval,
				remoteSearchSuggestions: row.remoteSearchSuggestions,
				showsFullURL: row.showsFullURL,
				keptLoadedSites: row.keptLoadedSites,
				darkPagesOffSites: row.darkPagesOffSites,
				unreadBadges: row.unreadBadges,
				position: row.position,
				isStarter: row.isStarter
			)
		}
		rows.spaces = keyed(spaces) { row in
			.init(
				id: id(row.id),
				profileID: id(row.profileID),
				name: row.name,
				icon: row.icon,
				appearance: row.appearance,
				position: row.position,
				isStarter: row.isStarter
			)
		}
		rows.folders = keyed(folders) { row in
			.init(id: id(row.id), spaceID: id(row.spaceID), parentFolderID: optional(row.parentFolderID), name: row.name, position: row.position)
		}
		rows.pinnedTabs = keyed(pinnedTabs) { row in
			.init(
				id: id(row.id),
				spaceID: id(row.spaceID),
				folderID: optional(row.folderID),
				title: row.title,
				url: row.url,
				iconURL: row.iconURL,
				customTitle: row.customTitle,
				icon: row.icon,
				position: row.position
			)
		}
		rows.favorites = keyed(favorites) { row in
			.init(
				id: id(row.id),
				profileID: id(row.profileID),
				title: row.title,
				url: row.url,
				iconURL: row.iconURL,
				customTitle: row.customTitle,
				icon: row.icon,
				position: row.position
			)
		}
		rows.retiredProfiles = keyed(retiredProfiles) { .init(id: id($0.id)) }
		rows.spaceStates = keyed(spaceStates) { .init(id: id($0.id), selectedTabID: optional($0.selectedTabID)) }
		rows.folderStates = keyed(folderStates) { .init(id: id($0.id), isExpanded: $0.isExpanded, ordinal: $0.ordinal) }
		rows.tabStates = keyed(tabStates) { row in
			.init(
				id: id(row.id),
				restorationTitle: row.restorationTitle,
				restorationURL: row.restorationURL,
				automationClientID: row.automationClientID,
				ordinal: row.ordinal
			)
		}
		rows.regularTabs = keyed(regularTabs) { row in
			.init(id: id(row.id), spaceID: id(row.spaceID), customTitle: row.customTitle, icon: row.icon, position: row.position)
		}
		rows.archivedTabs = archivedTabs.mapValues { entry in
			var entry: ArchiveEntryRecord = entry
			entry.spaceID = id(entry.spaceID)
			entry.profileID = id(entry.profileID)
			entry.tabID = id(entry.tabID)
			return entry
		}
		rows.splitGroups = splitGroups.mapValues { .init(id: $0.id, value: text($0.value), position: $0.position) }
		rows.tabGroups = tabGroups.mapValues { .init(id: $0.id, value: text($0.value), position: $0.position) }

		// The legacy profile stays as it is: it names Chromium's Default directory, which a merged
		// profile's alias may point at, whether or not the profile is still there.
		rows.localProfileIDs = Set(localProfileIDs.map(id))
		rows.shadowedIDs = Set(shadowedIDs.map(id))
		return rows
	}
}
