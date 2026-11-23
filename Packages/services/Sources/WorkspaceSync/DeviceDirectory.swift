import Foundation
import WorkspaceDatabase
import _SQLiteData

// MARK: - Device directory (DEV-979)

/// A Mac in the iCloud account's device directory: what it syncs, so each Mac can show the others
/// (ADR 0001, decision 1). Each Mac writes only its own row. Its record type is its own: SQLiteData
/// routes a fetched record by type whatever its zone, and `syncDevice`, `archiveDevice` and a future
/// `device` for Tabs from other devices are taken.
@Table("syncDeviceDirectory")
public struct DeviceDirectoryRecord: Equatable, Identifiable, Sendable {
	/// The Mac's ``StoreInfoKey/deviceID``, the one its deletion and use rows carry.
	@Column(primaryKey: true)
	public let id: UUID

	/// The computer name, as the person named the Mac.
	@Column("name")
	public var name: String

	/// Seconds since 1970: the last time this Mac wrote its row, at least daily while it syncs.
	@Column("lastSeen")
	public var lastSeen: Double

	/// The categories it syncs, as a JSON array of ``SyncCategory`` raw values. A paused category is
	/// left out; it still counts for deletions until it's been gone 30 days.
	@Column("categories")
	public var categories: String

	/// The categories it left by turning them off (DEV-1148), as a JSON array of ``SyncCategory`` raw
	/// values: it no longer counts among the Macs that must all delete something in them.
	@Column("leftCategories")
	public var leftCategories: String

	/// The Preferences groups it keeps to itself, as a JSON array of ``PreferenceGroup`` raw values.
	@Column("preferenceGroups")
	public var preferenceGroups: String

	/// Seconds since 1970 when the person chose "Stop syncing this Mac", `nil` while it syncs. A
	/// stopped Mac no longer counts among the Macs that must all delete something.
	@Column("stoppedAt")
	public var stoppedAt: Double?

	/// This Mac's "sync deletions after", in days, or `nil` while it's off (DEV-1337). A purge by
	/// time deletes everywhere, so it only goes ahead when every Mac that still has the item has it
	/// on. A row from a Mac that doesn't write it reads `nil`: that Mac keeps everything.
	@Column("syncDeletionsAfterDays")
	public var syncDeletionsAfterDays: Int?

	public init(
		id: UUID,
		name: String,
		lastSeen: Double,
		categories: String = "[]",
		leftCategories: String = "[]",
		preferenceGroups: String = "[]",
		stoppedAt: Double? = nil,
		syncDeletionsAfterDays: Int? = nil
	) {
		self.id = id
		self.name = name
		self.lastSeen = lastSeen
		self.categories = categories
		self.leftCategories = leftCategories
		self.preferenceGroups = preferenceGroups
		self.stoppedAt = stoppedAt
		self.syncDeletionsAfterDays = syncDeletionsAfterDays
	}
}

/// A Mac in the device directory, as Settings shows it.
public struct SyncDevice: Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var lastSeen: Date
	public var categories: Set<SyncCategory>

	/// The categories it left by turning them off (DEV-1148).
	public var leftCategories: Set<SyncCategory>
	public var preferenceGroups: Set<PreferenceGroup>
	public var stoppedAt: Date?

	/// Its "sync deletions after" in days, `nil` while off or from a Mac that doesn't say (DEV-1337).
	public var syncDeletionsAfterDays: Int?

	/// This Mac's own row.
	public var isThisMac: Bool

	public init(
		id: UUID,
		name: String,
		lastSeen: Date,
		categories: Set<SyncCategory> = [],
		leftCategories: Set<SyncCategory> = [],
		preferenceGroups: Set<PreferenceGroup> = [],
		stoppedAt: Date? = nil,
		syncDeletionsAfterDays: Int? = nil,
		isThisMac: Bool = false
	) {
		self.id = id
		self.name = name
		self.lastSeen = lastSeen
		self.categories = categories
		self.leftCategories = leftCategories
		self.preferenceGroups = preferenceGroups
		self.stoppedAt = stoppedAt
		self.syncDeletionsAfterDays = syncDeletionsAfterDays
		self.isThisMac = isThisMac
	}
}

/// `arx-sync-devices.sqlite`: the device directory, beside the workspace databases. Sync owns it: no
/// workspace store reads or writes it, and its own engine and zone (``zoneName``) run whenever sync is
/// on, apart from the categories the person turns on and off.
public enum DeviceDirectory {
	public static let fileName: String = "arx-sync-devices.sqlite"
	public static let zoneName: String = "devices"

	/// Opens or creates the directory file in `directory` and migrates it.
	public static func open(in directory: URL) throws -> DatabaseQueue {
		var configuration: Configuration = .init()
		configuration.busyMode = .timeout(10)
		let queue: DatabaseQueue = try .init(
			path: directory.appendingPathComponent(fileName).path,
			configuration: configuration
		)
		try migrator().migrate(queue)
		return queue
	}

	public static func migrator() -> DatabaseMigrator {
		var migrator: DatabaseMigrator = .init()
		migrator.registerMigration("v1-device-directory") { db in

			// As the other synced tables: a primary key, no other unique constraint, and defaults a
			// record missing a field falls back to.
			try db.execute(sql: """
				CREATE TABLE "syncDeviceDirectory" (
					"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
					"name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
					"lastSeen" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
					"categories" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]',
					"preferenceGroups" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]',
					"stoppedAt" REAL
				) STRICT
				""")
		}

		// A leave per category (DEV-1148). A row from a Mac without it left nothing.
		migrator.registerMigration("v2-left-categories") { db in
			try db.execute(sql: """
				ALTER TABLE "syncDeviceDirectory"
				ADD COLUMN "leftCategories" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]'
				""")
		}

		// Each Mac's "sync deletions after" (DEV-1337). A row from a Mac without it says off.
		migrator.registerMigration("v3-sync-deletions-after") { db in
			try db.execute(sql: """
				ALTER TABLE "syncDeviceDirectory" ADD COLUMN "syncDeletionsAfterDays" INTEGER
				""")
		}
		return migrator
	}

	/// Every Mac in the directory, this one marked.
	public static func devices(
		_ db: Database,
		thisMac: UUID?
	) throws -> [SyncDevice] {
		try DeviceDirectoryRecord.all.fetchAll(db).map { row in
			SyncDevice(
				id: row.id,
				name: row.name,
				lastSeen: Date(timeIntervalSince1970: row.lastSeen),
				categories: Set(decode(row.categories).compactMap(SyncCategory.init(rawValue:))),
				leftCategories: leftCategories(row),
				preferenceGroups: Set(decode(row.preferenceGroups).compactMap(PreferenceGroup.init(rawValue:))),
				stoppedAt: row.stoppedAt.map(Date.init(timeIntervalSince1970:)),
				syncDeletionsAfterDays: row.syncDeletionsAfterDays,
				isThisMac: row.id == thisMac
			)
		}
	}

	/// The Macs that left `category`: they stopped syncing, or turned it off (DEV-1148). They don't
	/// count for its purges.
	public static func departedDevices(
		_ db: Database,
		from category: SyncCategory
	) throws -> Set<UUID> {
		Set(
			try DeviceDirectoryRecord.all.fetchAll(db)
				.filter { $0.stoppedAt != nil || leftCategories($0).contains(category) }
				.map(\.id)
		)
	}

	/// The Macs whose rows say "sync deletions after" is on (DEV-1337). Every other Mac, one that
	/// says off or doesn't say, keeps what's removed elsewhere.
	public static func devicesSyncingDeletions(_ db: Database) throws -> Set<UUID> {
		Set(try DeviceDirectoryRecord.all.fetchAll(db).filter { $0.syncDeletionsAfterDays != nil }.map(\.id))
	}

	/// The categories a row says its Mac left.
	public static func leftCategories(_ row: DeviceDirectoryRecord) -> Set<SyncCategory> {
		Set(decode(row.leftCategories).compactMap(SyncCategory.init(rawValue:)))
	}

	/// Writes this Mac's row when what it says changed, or once a day.
	///
	/// - Returns: whether the row changed.
	@discardableResult
	public static func write(
		_ db: Database,
		id: UUID,
		name: String,
		categories: Set<SyncCategory>,
		leftCategories: Set<SyncCategory>,
		preferenceGroups: Set<PreferenceGroup>,
		stoppedAt: Date?,
		syncDeletionsAfterDays: Int? = nil,
		now: Date
	) throws -> Bool {
		let row: DeviceDirectoryRecord = .init(
			id: id,
			name: name,
			lastSeen: now.timeIntervalSince1970,
			categories: encode(categories.map(\.rawValue)),
			leftCategories: encode(leftCategories.map(\.rawValue)),
			preferenceGroups: encode(preferenceGroups.map(\.rawValue)),
			stoppedAt: stoppedAt?.timeIntervalSince1970,
			syncDeletionsAfterDays: syncDeletionsAfterDays
		)
		if let stored = try DeviceDirectoryRecord.find(id).fetchOne(db) {
			var unchanged: DeviceDirectoryRecord = row
			unchanged.lastSeen = stored.lastSeen
			let today: Double = Calendar.current.startOfDay(for: now).timeIntervalSince1970
			if stored == unchanged, stored.lastSeen >= today { return false }
		}
		try DeviceDirectoryRecord.upsert { row }.execute(db)
		return true
	}

	/// A set of categories as a row stores it: sorted, so the same set always reads the same.
	public static func encode(_ categories: Set<SyncCategory>) -> String {
		encode(categories.map(\.rawValue))
	}

	private static func encode(_ values: [String]) -> String {
		let data: Data = (try? JSONEncoder().encode(values.sorted())) ?? Data("[]".utf8)
		return String(decoding: data, as: UTF8.self)
	}

	private static func decode(_ text: String) -> [String] {
		(try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
	}
}
