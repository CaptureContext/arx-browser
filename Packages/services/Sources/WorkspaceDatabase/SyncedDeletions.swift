import Foundation
import GRDB

/// Who may delete synced rows that have a parent while iCloud sync runs (DEV-1207).
///
/// SQLiteData 1.13 deletes a row here, as a user deletion it then sends to iCloud, when CloudKit
/// refuses its save with `referenceViolation`. It takes that to mean the parent was deleted on the
/// server, but CloudKit also says it when the parent's own save failed in the same batch, as every
/// save does against a container without Arx's schema: on 18 November 2026 the cascade took every
/// space, folder, pinned tab and Favorite. With ``install(_:tables:)`` on the connection an engine
/// writes through, a delete of such a row goes through only while the engine applies a fetch or while
/// Arx writes through ``allowing(_:)`` (``DatabaseWriter/writeAllowingSyncedDeletions(_:)``); any
/// other is skipped, with its cascade, and nothing is queued for iCloud.
public enum SyncedDeletions {
	/// Whether the current write is Arx's own, which may delete synced rows.
	@TaskLocal
	public static var areAllowed: Bool = false

	/// Runs `body` as Arx's own write. Call it inside the write's closure: the guard reads it on the
	/// connection's queue.
	public static func allowing<T>(_ body: () throws -> T) rethrows -> T {
		try $areAllowed.withValue(true, operation: body)
	}

	/// The organization's synced tables a refused parent can take: those with a parent.
	public static let organizationTables: [String] = [
		SpaceRecord.tableName,
		FolderRecord.tableName,
		PinnedTabRecord.tableName,
		FavoriteRecord.tableName,
	]

	static let functionName: String = "arx_synced_deletions_allowed"

	/// SQLiteData's function on an engine's writer: true while the engine itself writes, as when it
	/// applies a fetch.
	static let isSynchronizingFunction: String = "sqlitedata_icloud_syncEngineIsSynchronizingChanges"

	/// Guards `tables` on this connection until it closes. The connection must have an engine, whose
	/// function the guard reads.
	public static func install(
		_ db: Database,
		tables: [String]
	) throws {
		db.add(function: DatabaseFunction(functionName, argumentCount: 0, pure: false) { _ in areAllowed })
		for table in tables {
			try db.execute(sql: """
				CREATE TEMP TRIGGER IF NOT EXISTS "arx_guard_delete_\(table)"
				BEFORE DELETE ON "main"."\(table)"
				WHEN NOT \(isSynchronizingFunction)() AND NOT \(functionName)()
				BEGIN
					SELECT RAISE(IGNORE);
				END
				""")
		}
	}
}

extension DatabaseWriter {
	/// `write(_:)` as Arx's own write, which may delete synced rows (``SyncedDeletions``).
	public func writeAllowingSyncedDeletions<T>(_ updates: (Database) throws -> T) throws -> T {
		try write { db in
			try SyncedDeletions.allowing { try updates(db) }
		}
	}

	/// `write(_:)` as Arx's own write, which may delete synced rows (``SyncedDeletions``).
	public func writeAllowingSyncedDeletions<T: Sendable>(
		_ updates: @escaping @Sendable (Database) throws -> T
	) async throws -> T {
		try await write { db in
			try SyncedDeletions.allowing { try updates(db) }
		}
	}
}
