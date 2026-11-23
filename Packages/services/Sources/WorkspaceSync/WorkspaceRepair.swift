import BrowserCore
import Foundation
import WorkspaceDatabase
import _SQLiteData

/// The repair pass of ADR 0001, section 6: deterministic fixes for what per-column last-writer-wins
/// can leave behind. Every Mac computes the same result from the same synced rows, and a repair only
/// writes rows it changes, so repairs converge and a valid workspace is never rewritten.
///
/// Repairs are ordinary local writes, so the sync engine uploads them like any edit.
public enum WorkspaceRepair {
	public struct Summary: Equatable, Sendable {
		/// Folders and pinned tabs whose parent was missing or in another space, now at the end of
		/// their space's root.
		public var movedToRoot: [UUID]

		/// Folders moved to their space's root to break a cycle of parents.
		public var brokenCycles: [UUID]

		/// This Mac's own starter profiles found identical to one from iCloud, whose spaces were
		/// removed. The profile itself stays: the app offers to remove it and erase its website data,
		/// which happens only once the person confirms (DEV-989).
		public var duplicateStarterProfiles: [UUID]

		/// Search shortcuts turned off because another one has the same keyword.
		public var disabledSearchShortcuts: [String]

		/// Commands that lost a keyboard shortcut another command has.
		public var clearedShortcutBindings: [String]

		/// Spaces whose selected tab another Mac deleted or moved away; this Mac's selection cleared.
		public var clearedSelections: [UUID]

		/// Tabs that were in two places at once (a pin brought back beside its Favorite, or beside
		/// this Mac's regular tab): the copy removed.
		public var removedDuplicateTabs: [UUID]

		/// Items deleted on Macs, now deleted everywhere (DEV-980).
		public var purgedDeletions: [UUID]

		/// Items merged into others from Settings (DEV-1216), hidden here now that this Mac's open tabs,
		/// selection and website data moved to the kept ones.
		public var mergedItems: [UUID]

		/// Merged profiles and spaces and the one each was merged into: this Mac moves their history
		/// and Tab Archive entries.
		public var mergedProfiles: [UUID: UUID]
		public var mergedSpaces: [UUID: UUID]

		public init(
			movedToRoot: [UUID] = [],
			brokenCycles: [UUID] = [],
			duplicateStarterProfiles: [UUID] = [],
			disabledSearchShortcuts: [String] = [],
			clearedShortcutBindings: [String] = [],
			clearedSelections: [UUID] = [],
			removedDuplicateTabs: [UUID] = [],
			purgedDeletions: [UUID] = [],
			mergedItems: [UUID] = [],
			mergedProfiles: [UUID: UUID] = [:],
			mergedSpaces: [UUID: UUID] = [:]
		) {
			self.movedToRoot = movedToRoot
			self.brokenCycles = brokenCycles
			self.duplicateStarterProfiles = duplicateStarterProfiles
			self.disabledSearchShortcuts = disabledSearchShortcuts
			self.clearedShortcutBindings = clearedShortcutBindings
			self.clearedSelections = clearedSelections
			self.removedDuplicateTabs = removedDuplicateTabs
			self.purgedDeletions = purgedDeletions
			self.mergedItems = mergedItems
			self.mergedProfiles = mergedProfiles
			self.mergedSpaces = mergedSpaces
		}

		public var isEmpty: Bool { self == .init() }
	}

	// MARK: - Organization

	/// A folder or pinned tab, as a placement repair looks at it, or a Favorite a duplicate repair
	/// needs iCloud to still have.
	public enum PlacementRecord: Hashable, Sendable {
		case folder(UUID)
		case pinnedTab(UUID)

		/// Only ever `.missing` or `.placed(spaceID: nil, parentID: nil)`.
		case favorite(UUID)
	}

	/// Where a folder or pinned tab is: missing, or in a space under a parent folder (or the root).
	public enum Placement: Equatable, Sendable {
		case missing
		case placed(spaceID: UUID?, parentID: UUID?)
	}

	/// Repairs the organization database's synced tables.
	///
	/// - Parameters:
	///   - ownStarterProfileIDs: this Mac's own starter profiles. Only these ever lose their spaces as
	///     duplicates, so a Mac never empties a starter profile another Mac is using.
	///   - remotePlacements: where iCloud has the records ``placementRecordsToCheck(_:)`` named, or
	///     `nil` to trust this Mac's rows. A fetch can stop partway, after a child arrived and before
	///     its parent did, so a placement looks broken here when it isn't: an item is only moved when
	///     iCloud has it, and its parent, where this Mac does, and a cycle is only broken when iCloud
	///     has the same cycle. Anything else waits for a later pass.
	///   - serverKnownProfileIDs: profiles iCloud already has a copy of, from the sync metadata, or
	///     `nil` to treat every profile as known. The surviving starter profile is one of these.
	///   - deletions: when deletions made on Macs go everywhere, or `nil` to leave them all.
	public static func repairOrganization(
		_ db: Database,
		ownStarterProfileIDs: Set<UUID>,
		serverKnownProfileIDs: Set<UUID>? = nil,
		remotePlacements: [PlacementRecord: Placement]? = nil,
		deletions: DeletionPolicy? = nil
	) throws -> Summary {
		var summary: Summary = .init()

		// Merges from Settings (DEV-1216) first: a merged item is hidden here once this Mac's tabs and
		// website data moved, which a purge then counts.
		try WorkspaceMerge.applyMergedItems(db, now: deletions?.now ?? .init(), summary: &summary)
		if let deletions {
			try purgeDeletions(db, policy: deletions, summary: &summary)
		}
		try dropDuplicateStarterProfiles(
			db,
			ownStarterProfileIDs: ownStarterProfileIDs,
			serverKnownProfileIDs: serverKnownProfileIDs,
			summary: &summary
		)
		let local: [PlacementRecord: Placement] = try localPlacements(db)
		try repairPlacements(
			db,
			isSettled: { record in
				guard let remotePlacements else { return true }

				return remotePlacements[record] == (local[record] ?? .missing)
			},
			summary: &summary
		)
		try removeDuplicateTabs(
			db,
			isConfirmed: { id in
				guard let remotePlacements else { return true }

				// Both records in iCloud: a real conflict, not a move a fetch stopped halfway through.
				return [PlacementRecord.pinnedTab(id), .favorite(id)].allSatisfy { record in
					remotePlacements[record].map { $0 != .missing } ?? false
				}
			},
			now: deletions?.now ?? .init(),
			summary: &summary
		)
		try clearInvalidSelections(db, summary: &summary)
		return summary
	}

	/// When the repair pass deletes for good what Macs deleted (DEV-980).
	public struct DeletionPolicy: Equatable, Sendable {
		/// A Mac not seen for this long no longer counts among the Macs that must all delete an item.
		public static let deviceExpiry: TimeInterval = 30 * 24 * 60 * 60

		/// How often the repair looks again while the organization syncs, with nothing else to start it.
		public static let recheckInterval: Duration = .seconds(6 * 60 * 60)

		public var now: Date

		/// "Sync deletions after": an item first deleted longer ago than this, and used by no Mac
		/// since, goes everywhere. `nil` when it's off.
		public var syncDeletionsAfter: TimeInterval?

		/// What iCloud's own rows purge too (``purgeCandidates(_:policy:)`` of the zone as iCloud has
		/// it), each with what it holds there, or `nil` to trust this Mac's rows. A fetch can stop
		/// partway, before a newer use, an undo, another Mac or a pin added to or moved out of a deleted
		/// space arrived, so an item only goes when iCloud's rows say so as well as this Mac's, and when
		/// everything deleting it here would delete is in it in iCloud too.
		public var confirmed: [PurgeItem: Set<UUID>]?

		/// Macs that left the category: they chose "Stop syncing this Mac" (DEV-979) or turned the
		/// category off (DEV-1148). They no longer count among the Macs that must all delete an item,
		/// from the moment their leave reaches the device directory.
		public var departedDevices: Set<UUID>

		/// The Macs with "sync deletions after" on, from the device directory (DEV-1337), or `nil` to
		/// count every Mac as on, as before there was a directory. A purge by time deletes everywhere,
		/// so it only goes ahead when every Mac that still has the item, the ones that didn't delete
		/// it, is among these: a Mac with it off keeps what's removed elsewhere.
		public var devicesSyncingDeletions: Set<UUID>?

		public init(
			now: Date,
			syncDeletionsAfter: TimeInterval?,
			confirmed: [PurgeItem: Set<UUID>]? = nil,
			departedDevices: Set<UUID> = [],
			devicesSyncingDeletions: Set<UUID>? = nil
		) {
			self.now = now
			self.syncDeletionsAfter = syncDeletionsAfter
			self.confirmed = confirmed
			self.departedDevices = departedDevices
			self.devicesSyncingDeletions = devicesSyncingDeletions
		}

		/// The Macs that count among those that must all delete an item: seen in the last
		/// ``deviceExpiry``, and not departed.
		internal func countedDevices(_ snapshot: PurgeSnapshot) -> Set<UUID> {
			let now: Double = now.timeIntervalSince1970
			return Set(snapshot.sightings.filter { $0.value >= now - Self.deviceExpiry }.keys)
				.subtracting(departedDevices)
		}

		/// Whether every counted Mac that still has an item `deleters` deleted syncs deletions, so a
		/// purge by time may take it from them (DEV-1337).
		internal func holdersSyncDeletions(
			_ devices: Set<UUID>,
			deleters: [UUID]
		) -> Bool {
			guard let devicesSyncingDeletions else { return true }

			return devices.subtracting(deleters).isSubset(of: devicesSyncingDeletions)
		}
	}

	/// An item a purge deletes: a tab keeps its ID as a pin and as a Favorite, so the table counts.
	public struct PurgeItem: Hashable, Sendable {
		public var table: String
		public var id: UUID

		public init(
			table: String,
			id: UUID
		) {
			self.table = table
			self.id = id
		}
	}

	/// The synced rows a purge decision reads, from this Mac's database or from iCloud's zone.
	public struct PurgeSnapshot: Equatable, Sendable {
		public struct Deletion: Equatable, Sendable {
			public var itemID: UUID
			public var itemTable: String
			public var deviceID: UUID
			public var deletedAt: Double

			/// "Delete from This Mac Only" (DEV-1336): "sync deletions after" doesn't count it.
			public var keepsElsewhere: Bool

			public init(
				itemID: UUID,
				itemTable: String,
				deviceID: UUID,
				deletedAt: Double,
				keepsElsewhere: Bool = false
			) {
				self.itemID = itemID
				self.itemTable = itemTable
				self.deviceID = deviceID
				self.deletedAt = deletedAt
				self.keepsElsewhere = keepsElsewhere
			}
		}

		public var deletions: [Deletion] = []

		/// Each item's latest use by each Mac.
		public var uses: [UUID: [UUID: Double]] = [:]

		/// Each Mac's last sighting.
		public var sightings: [UUID: Double] = [:]

		/// The profiles, spaces, folders, pinned tabs and Favorites there are, by table.
		public var items: [String: Set<UUID>] = [:]

		/// Each space's profile, Favorite's profile, and folder's or pinned tab's space and parent
		/// folder: what deleting a parent deletes, a space deleting all it holds whatever its folders.
		public var parents: [UUID: Set<UUID>] = [:]

		/// The tables whose rows a deletion hides here instead of deleting: the organization's, or
		/// Tab Archive's (DEV-983).
		public var itemTables: Set<String> = LocalDeletion.itemTables

		public init() {}

		/// Tab Archive's rows (DEV-983): its entries, their deletions and the Macs that sync it. An
		/// entry holds nothing and has no use but being opened, which restores and removes it.
		public static func archive(_ db: Database) throws -> Self {
			var snapshot: Self = .init()
			snapshot.itemTables = [ArchiveEntryRecord.tableName]
			snapshot.items[ArchiveEntryRecord.tableName] = Set(try ArchiveEntryRecord.select(\.id).fetchAll(db))
			for row in try ArchiveDeletionRecord.all.fetchAll(db) {
				snapshot.deletions.append(
					.init(itemID: row.itemID, itemTable: ArchiveEntryRecord.tableName, deviceID: row.deviceID, deletedAt: row.deletedAt)
				)
			}
			for row in try ArchiveDeviceRecord.all.fetchAll(db) {
				snapshot.sightings[row.id] = max(snapshot.sightings[row.id] ?? 0, row.lastSeen)
			}
			return snapshot
		}

		/// This Mac's rows.
		public init(_ db: Database) throws {
			for row in try DeletionRecord.all.fetchAll(db) {
				deletions.append(.init(
					itemID: row.itemID,
					itemTable: row.itemTable,
					deviceID: row.deviceID,
					deletedAt: row.deletedAt,
					keepsElsewhere: row.keepsElsewhere
				))
			}
			for row in try UsageRecord.all.fetchAll(db) {
				use(row.itemID, by: row.deviceID, at: row.lastUsed)
			}
			for row in try SyncDeviceRecord.all.fetchAll(db) {
				sightings[row.id] = max(sightings[row.id] ?? 0, row.lastSeen)
			}
			for row in try ProfileRecord.all.fetchAll(db) {
				items[ProfileRecord.tableName, default: []].insert(row.id)
			}
			for row in try SpaceRecord.all.fetchAll(db) {
				items[SpaceRecord.tableName, default: []].insert(row.id)
				parents[row.id] = [row.profileID]
			}
			for row in try FavoriteRecord.all.fetchAll(db) {
				items[FavoriteRecord.tableName, default: []].insert(row.id)
				parents[row.id] = [row.profileID]
			}
			for row in try FolderRecord.all.fetchAll(db) {
				items[FolderRecord.tableName, default: []].insert(row.id)
				parents[row.id] = Set([row.spaceID] + [row.parentFolderID].compactMap(\.self))
			}
			for row in try PinnedTabRecord.all.fetchAll(db) {
				items[PinnedTabRecord.tableName, default: []].insert(row.id)
				parents[row.id] = Set([row.spaceID] + [row.folderID].compactMap(\.self))
			}
		}

		public mutating func use(
			_ itemID: UUID,
			by deviceID: UUID,
			at time: Double
		) {
			uses[itemID, default: [:]][deviceID] = max(uses[itemID]?[deviceID] ?? 0, time)
		}

		/// Each parent's children, the other way round from ``parents``.
		internal var children: [UUID: [UUID]] {
			var children: [UUID: [UUID]] = [:]
			for (child, parents) in parents {
				for parent in parents {
					children[parent, default: []].append(child)
				}
			}
			return children
		}

		/// `id` and everything in it, as deleting it would delete, by ``children``.
		internal static func itemAndContents(
			_ id: UUID,
			children: [UUID: [UUID]]
		) -> [UUID] {
			var result: [UUID] = []
			var pending: [UUID] = [id]
			var visited: Set<UUID> = []
			while let next = pending.popLast() {
				guard visited.insert(next).inserted else { continue }

				result.append(next)
				pending.append(contentsOf: children[next] ?? [])
			}
			return result
		}
	}

	/// What the repair would delete for good: each item that every Mac seen in the last
	/// ``DeletionPolicy/deviceExpiry`` deleted, or, with "sync deletions after" on, one first deleted
	/// longer ago than that and used by no Mac since, it or anything in it. A deletion made with
	/// "Delete from This Mac Only" (DEV-1336) counts only towards every Mac having deleted it. Every
	/// Mac reaches the same answer from the same synced rows, give or take the time.
	public static func purgeCandidates(
		_ snapshot: PurgeSnapshot,
		policy: DeletionPolicy
	) -> Set<PurgeItem> {
		guard !snapshot.deletions.isEmpty else { return [] }

		let now: Double = policy.now.timeIntervalSince1970
		let devices: Set<UUID> = policy.countedDevices(snapshot)
		var candidates: Set<PurgeItem> = []
		var children: [UUID: [UUID]]?
		let byItem: [PurgeItem: [PurgeSnapshot.Deletion]] = .init(grouping: snapshot.deletions) {
			.init(table: $0.itemTable, id: $0.itemID)
		}
		for (item, rows) in byItem {
			guard
				snapshot.itemTables.contains(item.table),
				snapshot.items[item.table]?.contains(item.id) == true
			else { continue }

			let deletedEverywhere: Bool = !devices.isEmpty && devices.isSubset(of: rows.map(\.deviceID))
			let unusedSince: Bool = policy.syncDeletionsAfter.map { after in
				guard let earliest = rows.filter({ !$0.keepsElsewhere }).map(\.deletedAt).min() else { return false }

				// A Mac that still has it and doesn't sync deletions keeps it (DEV-1337).
				guard policy.holdersSyncDeletions(devices, deleters: rows.map(\.deviceID)) else { return false }

				// Only an old enough deletion is worth looking through what's in it.
				guard now - earliest >= after else { return false }

				let index: [UUID: [UUID]] = children ?? snapshot.children
				children = index
				return lastUse(of: item.id, snapshot, children: index) <= earliest
			} ?? false
			if deletedEverywhere || unusedSince {
				candidates.insert(item)
			}
		}
		return candidates
	}

	/// The latest use of `id`, or of anything in it, by any Mac.
	private static func lastUse(
		of id: UUID,
		_ snapshot: PurgeSnapshot,
		children: [UUID: [UUID]]
	) -> Double {
		PurgeSnapshot.itemAndContents(id, children: children)
			.compactMap { snapshot.uses[$0]?.values.max() }
			.max() ?? 0
	}

	/// A profile or space another Mac removed from iCloud (DEV-1336): this Mac shows it with a warning
	/// until it removes it too, or someone keeps it.
	public struct DeletionMark: Equatable, Sendable {
		/// The Mac whose removal counts first.
		public var deviceID: UUID
		public var removedAt: Date

		/// When "sync deletions after" deletes it here, or `nil` when nothing will: the setting is off
		/// here, or someone used it since it was removed.
		public var deletesAt: Date?

		public init(
			deviceID: UUID,
			removedAt: Date,
			deletesAt: Date?
		) {
			self.deviceID = deviceID
			self.removedAt = removedAt
			self.deletesAt = deletesAt
		}
	}

	/// The profiles and spaces this Mac shows that another Mac removed from iCloud: it has a deletion
	/// row that isn't "Delete from This Mac Only", and this Mac didn't delete it. Nothing goes from a Mac
	/// without being marked there first: ``DeletionMark/deletesAt`` is when ``purgeCandidates(_:policy:)``
	/// deletes it, with "sync deletions after" on here and on every other Mac that still has it, unless
	/// someone used it, or anything in it, since.
	/// A deletion made "this Mac only" goes only once every Mac deleted the item, so it marks nothing.
	public static func deletionMarks(
		_ snapshot: PurgeSnapshot,
		policy: DeletionPolicy,
		thisDevice: UUID?
	) -> [PurgeItem: DeletionMark] {
		let tables: Set<String> = [ProfileRecord.tableName, SpaceRecord.tableName]
		let byItem: [PurgeItem: [PurgeSnapshot.Deletion]] = .init(
			grouping: snapshot.deletions.filter { tables.contains($0.itemTable) }
		) {
			.init(table: $0.itemTable, id: $0.itemID)
		}
		var children: [UUID: [UUID]]?
		let devices: Set<UUID> = policy.countedDevices(snapshot)
		var marks: [PurgeItem: DeletionMark] = [:]
		for (item, rows) in byItem {
			guard
				snapshot.items[item.table]?.contains(item.id) == true,
				!rows.contains(where: { $0.deviceID == thisDevice }),
				let first = rows.filter({ !$0.keepsElsewhere }).min(by: { $0.deletedAt < $1.deletedAt })
			else { continue }

			let deletesAt: Date? = policy.syncDeletionsAfter.flatMap { after in
				// Another Mac that still has it and doesn't sync deletions keeps it here too (DEV-1337).
				guard policy.holdersSyncDeletions(devices, deleters: rows.map(\.deviceID)) else { return nil }

				let index: [UUID: [UUID]] = children ?? snapshot.children
				children = index
				guard lastUse(of: item.id, snapshot, children: index) <= first.deletedAt else { return nil }

				return Date(timeIntervalSince1970: first.deletedAt + after)
			}
			marks[item] = .init(
				deviceID: first.deviceID,
				removedAt: Date(timeIntervalSince1970: first.deletedAt),
				deletesAt: deletesAt
			)
		}
		return marks
	}

	/// Keep on a profile or space marked for deletion (DEV-1336): every Mac's removal of these items
	/// from iCloud becomes a deletion from that Mac only, so no Mac marks them and "sync deletions
	/// after" never deletes them. The Macs that removed them still don't show them.
	///
	/// - Returns: how many deletion rows changed.
	public static func keep(
		_ ids: Set<UUID>,
		_ db: Database
	) throws -> Int {
		let itemIDs: [UUID] = Array(ids)
		var changed: Int = 0
		for batch in stride(from: 0, to: itemIDs.count, by: 500) {
			let chunk: [UUID] = Array(itemIDs[batch ..< min(batch + 500, itemIDs.count)])
			try DeletionRecord
				.where { $0.itemID.in(chunk) && !$0.keepsElsewhere }
				.update { $0.keepsElsewhere = true }
				.execute(db)
			changed += db.changesCount
		}
		return changed
	}

	/// Deletes each of ``purgeCandidates(_:policy:)`` for good, on every Mac, when iCloud's rows purge
	/// it too. Its deletion rows go with it, and its use unless the tab is still elsewhere. What a
	/// purged folder holds that wasn't deleted, such as a pin another Mac added later, moves up to its
	/// parent.
	private static func purgeDeletions(
		_ db: Database,
		policy: DeletionPolicy,
		summary: inout Summary
	) throws {
		let snapshot: PurgeSnapshot = try .init(db)
		let children: [UUID: [UUID]] = snapshot.children
		let purged: [PurgeItem] = purgeCandidates(snapshot, policy: policy)
			.filter { item in
				guard let confirmed = policy.confirmed else { return true }
				guard let remote = confirmed[item] else { return false }

				// What deleting it here deletes must be in it in iCloud too: a pin another Mac moved out
				// of it, which hasn't arrived, mustn't go with it.
				return Set(PurgeSnapshot.itemAndContents(item.id, children: children)).isSubset(of: remote)
			}
			.sorted { ($0.table, $0.id.uuidString) < ($1.table, $1.id.uuidString) }
		guard !purged.isEmpty else { return }

		for item in purged {
			let id: String = item.id.uuidString.lowercased()
			if item.table == FolderRecord.tableName {
				let parent: String = "(SELECT \"parentFolderID\" FROM \"folder\" WHERE \"id\" = ?)"
				try db.execute(sql: "UPDATE \"pinnedTab\" SET \"folderID\" = \(parent) WHERE \"folderID\" = ?", arguments: [id, id])
				try db.execute(sql: "UPDATE \"folder\" SET \"parentFolderID\" = \(parent) WHERE \"parentFolderID\" = ?", arguments: [id, id])
			}
			try db.execute(sql: "DELETE FROM \"\(item.table)\" WHERE \"id\" = ?", arguments: [id])
			try DeletionRecord
				.where { $0.itemID.eq(item.id) && $0.itemTable.eq(item.table) }
				.delete()
				.execute(db)

			// A tab kept as a Favorite after its pin went keeps its use.
			let elsewhere: Bool = try LocalDeletion.itemTables.subtracting([item.table]).contains { table in
				try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \"\(table)\" WHERE \"id\" = ?)", arguments: [id]) ?? false
			}
			if !elsewhere {
				try UsageRecord.where { $0.itemID.eq(item.id) }.delete().execute(db)
			}
		}
		summary.purgedDeletions = purged.map(\.id)
	}

	/// Repairs Tab Archive's database (DEV-983): deletes for good each entry ``purgeCandidates(_:policy:)``
	/// finds in ``PurgeSnapshot/archive(_:)`` and iCloud confirmed, with its deletion rows.
	public static func repairArchive(
		_ db: Database,
		deletions policy: DeletionPolicy
	) throws -> Summary {
		var summary: Summary = .init()
		let purged: [UUID] = purgeCandidates(try PurgeSnapshot.archive(db), policy: policy)
			.filter { item in policy.confirmed.map { $0[item] != nil } ?? true }
			.map(\.id)
			.sorted { $0.uuidString < $1.uuidString }
		for batch in stride(from: 0, to: purged.count, by: 500) {
			let ids: [UUID] = Array(purged[batch ..< min(batch + 500, purged.count)])
			try ArchiveEntryRecord.where { $0.id.in(ids) }.delete().execute(db)
			try ArchiveDeletionRecord.where { $0.itemID.in(ids) }.delete().execute(db)
		}
		summary.purgedDeletions = purged
		return summary
	}

	/// A tab is in one place: pinned, a Favorite, or open here. SQLiteData brings back a record
	/// deleted elsewhere when it's edited offline, so a pin one Mac turned into a Favorite can return
	/// beside the Favorite, and a pin this Mac unpinned can return beside its regular tab, which
	/// `BrowserOrganization.validate()` rejects. The Favorite wins over the pin, as the move that made
	/// it; this Mac's regular tab wins over a synced copy, which is hidden here only (DEV-980): another
	/// Mac may have made the pin this Mac unpinned into a Favorite since, and keeps it.
	///
	/// A fetch can stop partway through a move between a pin and a Favorite, after the new record
	/// arrived and before the old one's deletion did, so a pin beside a Favorite is only removed when
	/// `isConfirmed` says iCloud has both. A regular tab is this Mac's own and needs no check.
	private static func removeDuplicateTabs(
		_ db: Database,
		isConfirmed: (UUID) -> Bool,
		now: Date,
		summary: inout Summary
	) throws {
		// A pin or Favorite this Mac turned into an open tab stays hidden here and where it was on
		// other Macs (DEV-980).
		func hiddenHere(_ table: String) -> String {
			"""
			"id" NOT IN (
				SELECT "itemID" FROM "deletion" WHERE "itemTable" = '\(table)' AND "deviceID" = (
					SELECT "value" FROM "storeInfo" WHERE "id" = '\(StoreInfoKey.deviceID)'
				)
			)
			"""
		}
		let duplicatePins: [UUID] = try Self.pinsBesideFavorites(db).filter(isConfirmed)
		let pinsBesideRegularTabs: [UUID] = try UUID.fetchAll(
			db,
			sql: """
			SELECT "id" FROM "pinnedTab" WHERE "id" IN (SELECT "id" FROM "regularTab")
			AND \(hiddenHere(PinnedTabRecord.tableName))
			ORDER BY "id"
			"""
		)
		let favoritesBesideRegularTabs: [UUID] = try UUID.fetchAll(
			db,
			sql: """
			SELECT "id" FROM "favorite" WHERE "id" IN (SELECT "id" FROM "regularTab")
			AND \(hiddenHere(FavoriteRecord.tableName))
			ORDER BY "id"
			"""
		)
		guard !(duplicatePins.isEmpty && pinsBesideRegularTabs.isEmpty && favoritesBesideRegularTabs.isEmpty)
		else { return }

		if !duplicatePins.isEmpty {
			try PinnedTabRecord.where { $0.id.in(duplicatePins) }.delete().execute(db)
		}
		if !(pinsBesideRegularTabs.isEmpty && favoritesBesideRegularTabs.isEmpty) {
			_ = try LocalDeletion.hide(
				[
					(table: PinnedTabRecord.tableName, ids: pinsBesideRegularTabs),
					(table: FavoriteRecord.tableName, ids: favoritesBesideRegularTabs),
				],
				deviceID: LocalDeletion.deviceID(db),
				now: now,
				db
			)
		}
		summary.removedDuplicateTabs += Set(duplicatePins + pinsBesideRegularTabs + favoritesBesideRegularTabs)
			.sorted { $0.uuidString < $1.uuidString }
	}

	/// A space's selected tab, which is this Mac's own, must be pinned or open in that space or be a
	/// Favorite of its profile, as `BrowserOrganization.validate()` requires. Another Mac deleting or
	/// moving that tab leaves it invalid here; the selection is cleared, as a local move does.
	private static func clearInvalidSelections(
		_ db: Database,
		summary: inout Summary
	) throws {
		let ids: [UUID] = try UUID.fetchAll(
			db,
			sql: """
			SELECT "spaceState"."id" FROM "spaceState"
			JOIN "space" ON "space"."id" = "spaceState"."id"
			WHERE "spaceState"."selectedTabID" IS NOT NULL
			AND NOT EXISTS (
				SELECT 1 FROM "pinnedTab"
				WHERE "pinnedTab"."id" = "spaceState"."selectedTabID" AND "pinnedTab"."spaceID" = "space"."id"
			)
			AND NOT EXISTS (
				SELECT 1 FROM "regularTab"
				WHERE "regularTab"."id" = "spaceState"."selectedTabID" AND "regularTab"."spaceID" = "space"."id"
			)
			AND NOT EXISTS (
				SELECT 1 FROM "favorite"
				WHERE "favorite"."id" = "spaceState"."selectedTabID" AND "favorite"."profileID" = "space"."profileID"
			)
			ORDER BY "spaceState"."id"
			"""
		)
		guard !ids.isEmpty else { return }

		try SpaceStateRecord
			.where { $0.id.in(ids) }
			.update { $0.selectedTabID = #bind(nil) }
			.execute(db)
		summary.clearedSelections += ids
	}

	/// The records a repair would depend on: items whose parent is missing, in another space or
	/// themselves, their parents, the folders of every cycle, and both records of a pin beside a
	/// Favorite.
	public static func placementRecordsToCheck(_ db: Database) throws -> Set<PlacementRecord> {
		var records: Set<PlacementRecord> = []
		_ = try planPlacements(db, isSettled: { record in
			records.insert(record)
			return false
		})
		for id in try pinsBesideFavorites(db) {
			records.insert(.pinnedTab(id))
			records.insert(.favorite(id))
		}
		return records
	}

	private static func pinsBesideFavorites(_ db: Database) throws -> [UUID] {
		try UUID.fetchAll(
			db,
			sql: """
			SELECT "id" FROM "pinnedTab" WHERE "id" IN (SELECT "id" FROM "favorite") ORDER BY "id"
			"""
		)
	}

	private static func localPlacements(_ db: Database) throws -> [PlacementRecord: Placement] {
		var result: [PlacementRecord: Placement] = [:]
		for folder in try FolderRecord.all.fetchAll(db) {
			result[.folder(folder.id)] = .placed(spaceID: folder.spaceID, parentID: folder.parentFolderID)
		}
		for tab in try PinnedTabRecord.all.fetchAll(db) {
			result[.pinnedTab(tab.id)] = .placed(spaceID: tab.spaceID, parentID: tab.folderID)
		}
		return result
	}

	/// Starter profiles are the profile and space each install makes on first launch. Two Macs that
	/// turn sync on both have one, so iCloud ends up with two of the same name. The one that stays
	/// is the lowest ID iCloud already has. Another loses its spaces only on the Mac that made it, and only when it's pristine
	/// (no Favorites, no pins, only starter spaces) and identical to the kept one: the same settings
	/// and the same spaces, with no regular tabs open in it and nothing in Tab Archive from it on this Mac.
	/// The profile row stays, with its website data, until the person removes it (DEV-989).
	private static func dropDuplicateStarterProfiles(
		_ db: Database,
		ownStarterProfileIDs: Set<UUID>,
		serverKnownProfileIDs: Set<UUID>?,
		summary: inout Summary
	) throws {
		// A "this Mac only" profile is never one, whatever its synced copy looks like (DEV-981).
		let attachesLocal: Bool = try Bool.fetchOne(
			db,
			sql: "SELECT EXISTS (SELECT 1 FROM pragma_database_list WHERE \"name\" = 'local')"
		) ?? false
		let localProfiles: Set<UUID> = attachesLocal
		? Set(try UUID.fetchAll(db, sql: #"SELECT "id" FROM "local"."profile""#))
		: []
		let ownStarterProfileIDs: Set<UUID> = ownStarterProfileIDs.subtracting(localProfiles)
		guard !ownStarterProfileIDs.isEmpty else { return }

		let starters: [ProfileRecord] = try ProfileRecord.where(\.isStarter).fetchAll(db)
		let groups: [String: [ProfileRecord]] = .init(grouping: starters, by: \.name)
		for (_, group) in groups.sorted(by: { $0.key < $1.key }) where group.count > 1 {
			let profileIDs: [UUID] = group.map(\.id)
			let spaces: [SpaceRecord] = try SpaceRecord.where { $0.profileID.in(profileIDs) }.fetchAll(db)
			let spaceIDs: [UUID] = spaces.map(\.id)
			let favoriteOwners: Set<UUID> = try Set(
				FavoriteRecord.where { $0.profileID.in(profileIDs) }.select(\.profileID).fetchAll(db)
			)
			let spacesWithPins: Set<UUID> = try Set(
				FolderRecord.where { $0.spaceID.in(spaceIDs) }.select(\.spaceID).fetchAll(db)
				+ PinnedTabRecord.where { $0.spaceID.in(spaceIDs) }.select(\.spaceID).fetchAll(db)
			)

			func isPristine(_ profile: ProfileRecord) -> Bool {
				guard !favoriteOwners.contains(profile.id) else { return false }

				return spaces
					.filter { $0.profileID == profile.id }
					.allSatisfy { $0.isStarter && !spacesWithPins.contains($0.id) }
			}

			// The one that stays never depends on contents, which two Macs can see differently. It's
			// the lowest ID among those iCloud already has, so a Mac joining with its own starter
			// keeps the one from iCloud: by the time a Mac's own starter is known to iCloud, any
			// other Mac that sees it as known sees it the same way. If the joining Mac's own upload
			// lands before its first fetch, both are known and both may stay: a duplicate the person
			// can delete, rather than a rule under which two Macs joining at once each drop theirs.
			let ordered: [ProfileRecord] = group.sorted { $0.id.uuidString < $1.id.uuidString }
			let known: [ProfileRecord] = ordered.filter { serverKnownProfileIDs?.contains($0.id) ?? true }
			guard let kept = known.first ?? ordered.first else { continue }

			/// What the person could have changed: the profile's synced settings and its spaces'.
			func content(_ profile: ProfileRecord) -> [String] {
				let settings: String = [
					profile.searchEngine,
					profile.appearance,
					profile.tabArchiveInterval,
					profile.remoteSearchSuggestions.map { "\($0)" },
					profile.showsFullURL.map { "\($0)" },
					profile.keptLoadedSites,
					profile.darkPagesOffSites,
					profile.unreadBadges,
				]
				.map { $0 ?? "\u{0}" }
				.joined(separator: "\u{1}")
				let spaceContents: [String] = spaces
					.filter { $0.profileID == profile.id }
					.map { [$0.name, $0.icon ?? "\u{0}", $0.appearance ?? "\u{0}"].joined(separator: "\u{1}") }
					.sorted()
				return [settings] + spaceContents
			}

			for profile in ordered where profile.id != kept.id {
				// Only a copy of the kept profile is dropped: anything the person changed in it, its
				// settings or its spaces, keeps it.
				guard
					isPristine(profile),
					ownStarterProfileIDs.contains(profile.id),
					content(profile) == content(kept)
				else { continue }

				let droppedSpaceIDs: [UUID] = spaces.filter { $0.profileID == profile.id }.map(\.id)

				// Open tabs belong to their profile's pages and data: a profile with any stays.
				guard try RegularTabRecord.where({ $0.spaceID.in(droppedSpaceIDs) }).fetchCount(db) == 0 else {
					continue
				}

				// Nor one with Tab Archive entries here, which only its profile shows: in the archive file,
				// attached to the store's connection as `archive` (DEV-983), or, before that moved them,
				// JSON in this file that names the profile.
				let id: String = profile.id.uuidString.lowercased()
				var archived: Int = try Int.fetchOne(
					db,
					sql: """
					SELECT count(*) FROM "main"."archivedTab" WHERE instr(lower("value"), ?) > 0
					""",
					arguments: [id]
				) ?? 0
				let attachesArchive: Bool = try Bool.fetchOne(
					db,
					sql: "SELECT EXISTS (SELECT 1 FROM pragma_database_list WHERE \"name\" = 'archive')"
				) ?? false
				if attachesArchive {
					archived += try Int.fetchOne(
						db,
						sql: #"SELECT count(*) FROM "archive"."archiveEntry" WHERE "profileID" = ?"#,
						arguments: [id]
					) ?? 0
				}
				guard archived == 0 else { continue }

				guard !droppedSpaceIDs.isEmpty else { continue }

				try SpaceRecord.where { $0.id.in(droppedSpaceIDs) }.delete().execute(db)

				// No longer a starter: another Mac's first merge never keeps it over its own.
				try ProfileRecord.find(profile.id).update { $0.isStarter = false }.execute(db)
				summary.duplicateStarterProfiles.append(profile.id)
			}
		}
	}

	/// Folder and pinned-tab parents must be a folder in the same space, and folders must form a tree.
	/// An item whose parent fails that goes to the end of its space's root; in a cycle, the folder
	/// with the lowest ID goes there.
	private struct PlacementPlan {
		var folders: [FolderRecord]
		var pinnedTabs: [PinnedTabRecord]
		var movedFolders: [UUID]
		var brokenCycles: [UUID]
		var movedTabs: [UUID]
	}

	/// What to move, asking `isSettled` about every record each move depends on.
	private static func planPlacements(
		_ db: Database,
		isSettled: (PlacementRecord) -> Bool
	) throws -> PlacementPlan {
		let folders: [FolderRecord] = try FolderRecord.all.fetchAll(db)
			.sorted { $0.id.uuidString < $1.id.uuidString }
		let pinnedTabs: [PinnedTabRecord] = try PinnedTabRecord.all.fetchAll(db)
			.sorted { $0.id.uuidString < $1.id.uuidString }
		let folderSpaces: [UUID: UUID] = .init(uniqueKeysWithValues: folders.map { ($0.id, $0.spaceID) })

		var parents: [UUID: UUID] = [:]
		var movedFolders: [UUID] = []
		for folder in folders {
			guard let parentID = folder.parentFolderID else { continue }

			if parentID != folder.id, folderSpaces[parentID] == folder.spaceID {
				parents[folder.id] = parentID
			} else {
				// Both asked, so a check lists both records.
				let settled: [Bool] = [isSettled(.folder(folder.id)), isSettled(.folder(parentID))]
				if !settled.contains(false) {
					movedFolders.append(folder.id)
				}
			}
		}

		var brokenCycles: [UUID] = []
		while let cycle = firstCycle(in: parents, order: folders.map(\.id)) {
			let lowest: UUID = cycle.min { $0.uuidString < $1.uuidString }!
			parents[lowest] = nil
			let settled: [Bool] = cycle.map { isSettled(.folder($0)) }
			if !settled.contains(false) {
				brokenCycles.append(lowest)
			}
		}

		let movedTabs: [UUID] = pinnedTabs
			.filter { tab in
				guard
					let folderID = tab.folderID,
					folderSpaces[folderID] != tab.spaceID
				else { return false }

				let settled: [Bool] = [isSettled(.pinnedTab(tab.id)), isSettled(.folder(folderID))]
				return !settled.contains(false)
			}
			.map(\.id)

		return .init(
			folders: folders,
			pinnedTabs: pinnedTabs,
			movedFolders: movedFolders,
			brokenCycles: brokenCycles,
			movedTabs: movedTabs
		)
	}

	private static func repairPlacements(
		_ db: Database,
		isSettled: (PlacementRecord) -> Bool,
		summary: inout Summary
	) throws {
		let plan: PlacementPlan = try planPlacements(db, isSettled: isSettled)
		let (folders, pinnedTabs) = (plan.folders, plan.pinnedTabs)
		let (movedFolders, brokenCycles, movedTabs) = (plan.movedFolders, plan.brokenCycles, plan.movedTabs)
		guard !(movedFolders.isEmpty && brokenCycles.isEmpty && movedTabs.isEmpty) else { return }

		// New keys go after everything already at each space's root, in a fixed order.
		let toRoot: Set<UUID> = .init(movedFolders + brokenCycles + movedTabs)
		var lastRootKey: [UUID: String] = [:]
		func noteRoot(
			_ spaceID: UUID,
			_ position: String
		) {
			if let current = lastRootKey[spaceID], current >= position { return }
			lastRootKey[spaceID] = position
		}
		for folder in folders where folder.parentFolderID == nil && !toRoot.contains(folder.id) {
			noteRoot(folder.spaceID, folder.position)
		}
		for tab in pinnedTabs where tab.folderID == nil && !toRoot.contains(tab.id) {
			noteRoot(tab.spaceID, tab.position)
		}

		struct Item {
			var id: UUID
			var spaceID: UUID
			var position: String
			var isFolder: Bool
		}

		let items: [Item] = (
			folders
				.filter { toRoot.contains($0.id) }
				.map { Item(id: $0.id, spaceID: $0.spaceID, position: $0.position, isFolder: true) }
			+ pinnedTabs
				.filter { toRoot.contains($0.id) }
				.map { Item(id: $0.id, spaceID: $0.spaceID, position: $0.position, isFolder: false) }
		)
		.sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }

		for item in items {
			let key: String = positionAfter(lastRootKey[item.spaceID])
			lastRootKey[item.spaceID] = key
			if item.isFolder {
				try FolderRecord
					.find(item.id)
					.update {
						$0.parentFolderID = #bind(nil)
						$0.position = #bind(key)
					}
					.execute(db)
			} else {
				try PinnedTabRecord
					.find(item.id)
					.update {
						$0.folderID = #bind(nil)
						$0.position = #bind(key)
					}
					.execute(db)
			}
		}

		summary.movedToRoot += (movedFolders + movedTabs).sorted { $0.uuidString < $1.uuidString }
		summary.brokenCycles += brokenCycles
	}

	/// The first cycle reached from `order`'s folders by following parents, if any.
	private static func firstCycle(
		in parents: [UUID: UUID],
		order: [UUID]
	) -> [UUID]? {
		var finished: Set<UUID> = []
		for start in order where !finished.contains(start) {
			var path: [UUID] = []
			var onPath: Set<UUID> = []
			var current: UUID? = start
			while let node = current, !finished.contains(node) {
				if onPath.contains(node) {
					return Array(path.drop { $0 != node })
				}
				path.append(node)
				onPath.insert(node)
				current = parents[node]
			}
			finished.formUnion(path)
		}
		return nil
	}

	/// A key after `lower` in the base-62 alphabet of phase 1's `FractionalIndex`, the same as its
	/// `key(between: lower, and: nil)`.
	internal static func positionAfter(_ lower: String?) -> String {
		let digits: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
		let values: [Int] = (lower ?? "").map { digits.firstIndex(of: $0) ?? 0 }

		func after(_ lower: ArraySlice<Int>) -> [Int] {
			guard let first = lower.first else { return [digits.count / 2] }

			if first < digits.count - 1 { return [first + 1] }
			return [first] + after(lower.dropFirst())
		}

		return String(after(values[...]).map { digits[$0] })
	}

	// MARK: - Preferences

	/// Whether ``repairPreferences(_:)`` would change anything: it runs in a savepoint that's always
	/// rolled back, so nothing changes and nothing is queued for iCloud.
	public static func preferencesNeedRepair(
		_ db: Database,
		including included: Set<PreferenceGroup> = []
	) throws -> Bool {
		var needsRepair: Bool = false
		try db.inSavepoint {
			needsRepair = try !repairPreferences(db, including: included).isEmpty
			return .rollback
		}
		return needsRepair
	}

	/// Repairs the preferences database's synced tables, except those of groups kept on this Mac
	/// (DEV-982): this Mac doesn't read them, and writing them would send this Mac's repair of other
	/// Macs' values to every Mac. Their choice is read in `db`'s transaction, so one made meanwhile
	/// counts.
	///
	/// - Parameters:
	///   - included: groups kept local to repair anyway, as before one takes iCloud's values.
	public static func repairPreferences(
		_ db: Database,
		including included: Set<PreferenceGroup> = []
	) throws -> Summary {
		var summary: Summary = .init()
		let local: Set<PreferenceGroup> = try PreferenceGroup.local(db).subtracting(included)
		if !local.contains(.searchEngines) {
			try disableDuplicateKeywords(db, summary: &summary)
		}
		if !local.contains(.shortcuts) {
			try clearDuplicateBindings(db, summary: &summary)
		}
		return summary
	}

	/// A search shortcut's ID is its lowercased keyword, so two Macs adding the same keyword already
	/// make one record. Rows from before that rule, or written by hand, can still differ only in case,
	/// which `BrowserPreferences` rejects even when one is off. The first by `(position, id)` keeps
	/// the keyword; each other one is turned off and renamed `keyword-2`, `keyword-3`… (the first
	/// free), never deleted.
	private static func disableDuplicateKeywords(
		_ db: Database,
		summary: inout Summary
	) throws {
		let shortcuts: [SearchShortcutRecord] = try SearchShortcutRecord.all.fetchAll(db)
			.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
		let existing: Set<String> = .init(shortcuts.map { $0.keyword.lowercased() })
		var taken: Set<String> = []
		for shortcut in shortcuts {
			let keyword: String = shortcut.keyword.lowercased()
			if taken.insert(keyword).inserted { continue }

			var suffix: Int = 2
			while taken.contains("\(keyword)-\(suffix)") || existing.contains("\(keyword)-\(suffix)") {
				suffix += 1
			}
			let renamed: String = "\(shortcut.keyword)-\(suffix)"
			taken.insert(renamed.lowercased())
			try SearchShortcutRecord
				.find(shortcut.id)
				.update {
					$0.keyword = #bind(renamed)
					$0.isEnabled = false
				}
				.execute(db)
			summary.disabledSearchShortcuts.append(shortcut.id)
		}
	}

	/// Two commands with the same keyboard shortcut, as `BrowserPreferences` reads them: a command's
	/// own row, else its defaults. Commands with a row go first, by `(position, id)`, and the first to
	/// have a shortcut keeps it; then commands without one, whose conflicting defaults are given up in
	/// a new row. A command that loses an entry keeps its others, or gets `[null]` ("no shortcut")
	/// when none are left, the only form with a `null` `validateKeyboardShortcuts()` accepts.
	///
	/// ADR 0001 says the later binding wins; the library keeps per-column times only in its own
	/// metadata, so a deterministic order on synced columns stands in for "later".
	private static func clearDuplicateBindings(
		_ db: Database,
		summary: inout Summary
	) throws {
		let rows: [KeyboardShortcutRecord] = try KeyboardShortcutRecord.all.fetchAll(db)
			.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
		let decoder: JSONDecoder = .init()
		var taken: Set<KeyboardShortcut> = []
		var own: [String: [KeyboardShortcut?]] = [:]
		var repaired: [(id: String, shortcuts: [KeyboardShortcut?], position: String?)] = []
		for row in rows {
			guard
				let entries = try? decoder.decode([KeyboardShortcut?].self, from: Data(row.bindings.utf8)),
				// No entries is the column's default: the command uses its defaults, as with no row.
				!entries.isEmpty
			else { continue }

			var kept: [KeyboardShortcut] = []
			var lost: Bool = false
			for case let shortcut? in entries {
				if taken.insert(shortcut).inserted {
					kept.append(shortcut)
				} else {
					lost = true
				}
			}
			let shortcuts: [KeyboardShortcut?] = lost ? optionalShortcuts(kept) : entries
			own[row.id] = shortcuts
			if lost {
				repaired.append((row.id, shortcuts, nil))
			}
		}

		let bindings: [ShortcutBinding] = own
			.sorted { $0.key < $1.key }
			.flatMap { id, shortcuts in
				guard let command = BrowserCommand(rawValue: id) else { return [ShortcutBinding]() }

				return shortcuts.map { ShortcutBinding(command: command, shortcut: $0) }
			}
		var lastPosition: String? = rows.map(\.position).max()
		for command in BrowserCommand.allCases where own[command.rawValue] == nil {
			let defaults: [KeyboardShortcut] = bindings.shortcuts(for: command)
			let kept: [KeyboardShortcut] = defaults.filter { !taken.contains($0) }
			taken.formUnion(kept)
			guard kept.count < defaults.count else { continue }

			if rows.contains(where: { $0.id == command.rawValue }) {
				// Its row holds `[]`: update it rather than add another.
				repaired.append((command.rawValue, optionalShortcuts(kept), nil))
				continue
			}
			let position: String = positionAfter(lastPosition)
			lastPosition = position
			repaired.append((command.rawValue, optionalShortcuts(kept), position))
		}

		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		for (id, shortcuts, position) in repaired {
			let json: String = String(decoding: try encoder.encode(shortcuts), as: UTF8.self)
			if let position {
				try KeyboardShortcutRecord.insert {
					KeyboardShortcutRecord(id: id, bindings: json, position: position)
				}
				.execute(db)
			} else {
				try KeyboardShortcutRecord
					.find(id)
					.update { $0.bindings = #bind(json) }
					.execute(db)
			}
			summary.clearedShortcutBindings.append(id)
		}
	}

	/// A command's shortcuts as stored: the shortcuts, or `[nil]` for none.
	private static func optionalShortcuts(_ shortcuts: [KeyboardShortcut]) -> [KeyboardShortcut?] {
		shortcuts.isEmpty ? [nil] : shortcuts.map(Optional.some)
	}
}
