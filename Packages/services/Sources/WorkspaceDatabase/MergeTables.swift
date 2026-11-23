import Foundation
import _SQLiteData

// MARK: - Merging what matches (DEV-1216)

/// A synced item merged into another of the same profile, space, folder, pinned tab or Favorite,
/// from Settings › iCloud Sync's "Merge 'Default' and 'Default'…". Synced, so every Mac moves its own
/// open tabs, selection and website data to the kept item, then hides the merged one as its own
/// deletion (DEV-980); the repair pass deletes it everywhere once every Mac has.
///
/// The ID is the merged item's: an item is merged at most once.
@Table("mergedItem")
public struct MergedItemRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	/// The merged item's table, such as ``SpaceRecord``'s.
	@Column("itemTable")
	public var itemTable: String

	/// The item it was merged into, in the same table.
	@Column("keptID")
	public var keptID: UUID

	/// Seconds since 1970.
	@Column("mergedAt")
	public var mergedAt: Double

	public init(
		id: UUID,
		itemTable: String,
		keptID: UUID,
		mergedAt: Double
	) {
		self.id = id
		self.itemTable = itemTable
		self.keptID = keptID
		self.mergedAt = mergedAt
	}
}

/// Where this Mac keeps a profile's website data, when it isn't under the profile's own ID: a
/// profile merged into iCloud's keeps this Mac's cookies and storage under the kept profile's ID, as
/// an alias, never a copy (DEV-1216). Never synced: each Mac has its own.
@Table("profileStorage")
public struct ProfileStorageRecord: Equatable, Identifiable, Sendable {
	/// The profile.
	@Column(primaryKey: true)
	public let id: UUID

	/// The ID its website data is kept under on this Mac.
	@Column("storageID")
	public var storageID: UUID

	public init(
		id: UUID,
		storageID: UUID
	) {
		self.id = id
		self.storageID = storageID
	}

	/// Every alias on this Mac, by profile. Empty before the table exists.
	public static func aliases(_ db: Database) throws -> [UUID: UUID] {
		let exists: Bool = try Bool.fetchOne(
			db,
			sql: #"SELECT EXISTS (SELECT 1 FROM "main"."sqlite_master" WHERE "type" = 'table' AND "name" = 'profileStorage')"#
		) ?? false
		guard exists else { return [:] }

		var aliases: [UUID: UUID] = [:]
		for row in try ProfileStorageRecord.all.fetchAll(db) where row.id != row.storageID {
			aliases[row.id] = row.storageID
		}
		return aliases
	}
}
