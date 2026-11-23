import CloudKit
import Foundation
import GRDB

/// What iCloud confirmed of a category's rows, read from the engine's record metadata (DEV-1207).
///
/// SQLiteData 1.13 writes a row's `lastKnownServerRecord` as it builds a batch, before sending it, so
/// `hasLastKnownServerRecord` doesn't mean iCloud has the row. Only a record iCloud saved has a change
/// tag. A save CloudKit refuses with most errors (`invalidArguments`, as against a container without
/// Arx's schema, `serverRejectedRequest`, `limitExceeded` and others) is dropped by the library and
/// never sent again, so ``requeueUnconfirmed(_:tables:)`` queues it again at each start.
///
/// This reads the library's metadatabase, attached to the writer by the engine as
/// `sqlitedata_icloud`: a library update must keep `RefusedSaveTests` passing.
enum ServerConfirmation {
	/// The primary keys of `recordType`'s rows that iCloud saved.
	static func confirmedKeys(
		_ db: Database,
		recordType: String
	) throws -> Set<String> {
		var keys: Set<String> = []
		for (key, type, isSaved) in try knownRecords(db) where type == recordType && isSaved {
			keys.insert(key)
		}
		return keys
	}

	/// The rows of `tables` iCloud hasn't saved, as `"<table>:<primary key>"`: rows whose last known
	/// record has no change tag, and rows with none at all, which a save refused with
	/// `serverRejectedRequest` leaves behind (the library clears the record then). Rows the metadata
	/// still lists but `tables` no longer has aren't counted.
	static func unconfirmedRows(
		_ db: Database,
		tables: Set<String>
	) throws -> Set<String> {
		var rows: Set<String> = []
		for (table, keys) in try unconfirmedKeys(db, tables: tables) {
			for key in try existingKeys(db, table: table, keys: keys) {
				rows.insert("\(table):\(key)")
			}
		}
		return rows
	}

	// MARK: - Send attempts (DEV-1209)

	/// Starts noting, on this connection, each row whose last known record the library writes or
	/// clears: it writes the record as it builds a batch with the row, and clears it again for some
	/// refusals (`serverRejectedRequest`), so the row's metadata can look as before. A temporary
	/// trigger sees both. The engine writes through the same connection as Arx, the category's writer.
	///
	/// The trigger runs inside the library's own statements, whose conflict policy replaces any the
	/// trigger names (an upsert's would make `INSERT OR IGNORE` fail), so the table has no constraint
	/// to break and a row already noted is skipped by its `WHERE`, which an index keeps cheap.
	/// ``stopWatchingSendAttempts(_:)`` drops it once nothing is watched.
	static func watchSendAttempts(_ db: Database) throws {
		try db.execute(sql: """
			CREATE TEMP TABLE IF NOT EXISTS "arx_sync_send_attempt" ("row" TEXT NOT NULL);
			CREATE INDEX IF NOT EXISTS temp."arx_sync_send_attempt_row" ON "arx_sync_send_attempt" ("row");
			CREATE TEMP TRIGGER IF NOT EXISTS "arx_sync_send_attempt_noted"
			AFTER UPDATE OF "lastKnownServerRecord" ON "sqlitedata_icloud"."sqlitedata_icloud_metadata"
			BEGIN
				INSERT INTO "arx_sync_send_attempt" ("row")
				SELECT NEW."recordType" || ':' || NEW."recordPrimaryKey"
				WHERE NOT EXISTS (
					SELECT 1 FROM "arx_sync_send_attempt"
					WHERE "row" = NEW."recordType" || ':' || NEW."recordPrimaryKey"
				);
			END;
			""")
	}

	/// Stops noting attempts and forgets them: nothing is watched any more.
	static func stopWatchingSendAttempts(_ db: Database) throws {
		try db.execute(sql: """
			DROP TRIGGER IF EXISTS temp."arx_sync_send_attempt_noted";
			DROP TABLE IF EXISTS temp."arx_sync_send_attempt";
			""")
	}

	/// Forgets the attempts noted so far.
	static func forgetSendAttempts(_ db: Database) throws {
		try db.execute(sql: #"DELETE FROM temp."arx_sync_send_attempt""#)
	}

	/// The rows a send tried since ``forgetSendAttempts(_:)``, as `"<table>:<primary key>"`.
	static func sendAttempts(_ db: Database) throws -> Set<String> {
		Set(try String.fetchAll(db, sql: #"SELECT "row" FROM temp."arx_sync_send_attempt""#))
	}

	/// Queues again the save of every row of `tables` iCloud never saved (``unconfirmedRows(_:tables:)``),
	/// as SQLiteData's own first upload does: by writing each row's primary key to itself.
	///
	/// - Returns: the rows queued, as `"<table>:<primary key>"`.
	@discardableResult
	static func requeueUnconfirmed(
		_ db: Database,
		tables: Set<String>
	) throws -> Set<String> {
		var rows: Set<String> = []
		for (table, keys) in try unconfirmedKeys(db, tables: tables) {
			for batch in batches(keys) {
				try db.execute(
					sql: #"UPDATE "main"."\#(table)" SET "id" = "id" WHERE "id" IN (\#(marks(batch.count)))"#,
					arguments: StatementArguments(batch)
				)
			}
			for key in try existingKeys(db, table: table, keys: keys) {
				rows.insert("\(table):\(key)")
			}
		}
		return rows
	}

	/// The primary keys of each table's rows iCloud hasn't saved, read from the metadata alone.
	private static func unconfirmedKeys(
		_ db: Database,
		tables: Set<String>
	) throws -> [(table: String, keys: [String])] {
		var keys: [String: [String]] = [:]
		for (key, type, isSaved) in try knownRecords(db) where tables.contains(type) && !isSaved {
			keys[type, default: []].append(key)
		}
		return keys.sorted(by: { $0.key < $1.key }).map { (table: $0.key, keys: $0.value) }
	}

	/// Which of `keys` are rows of `table` now.
	private static func existingKeys(
		_ db: Database,
		table: String,
		keys: [String]
	) throws -> [String] {
		var existing: [String] = []
		for batch in batches(keys) {
			existing += try String.fetchAll(
				db,
				sql: #"SELECT "id" FROM "main"."\#(table)" WHERE "id" IN (\#(marks(batch.count)))"#,
				arguments: StatementArguments(batch)
			)
		}
		return existing
	}

	/// SQLite's limit on bound values is far above 500; a batch keeps each statement small.
	private static func batches(_ keys: [String]) -> [[String]] {
		stride(from: 0, to: keys.count, by: 500).map { start in
			Array(keys[start ..< min(start + 500, keys.count)])
		}
	}

	private static func marks(_ count: Int) -> String {
		Array(repeating: "?", count: count).joined(separator: ", ")
	}

	/// Each live row's primary key, record type and whether iCloud saved its last known record. A row
	/// without one isn't saved.
	private static func knownRecords(_ db: Database) throws -> [(key: String, type: String, isSaved: Bool)] {
		let rows: [Row] = try Row.fetchAll(
			db,
			sql: """
			SELECT "recordPrimaryKey", "recordType", "lastKnownServerRecord"
			FROM "sqlitedata_icloud"."sqlitedata_icloud_metadata"
			WHERE NOT "_isDeleted"
			"""
		)
		return rows.compactMap { row in
			guard
				let key = row["recordPrimaryKey"] as String?,
				let type = row["recordType"] as String?
			else { return nil }

			guard let data = row["lastKnownServerRecord"] as Data? else { return (key, type, false) }
			guard let isSaved = isSaved(data) else { return nil }

			return (key, type, isSaved)
		}
	}

	/// Whether the record archived in `data` is one iCloud saved: it has a change tag. Under tests the
	/// library's mock database keeps its tag beside the record's system fields, under
	/// `_recordChangeTag`, which a live record's archive doesn't have.
	private static func isSaved(_ data: Data) -> Bool? {
		guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }

		coder.requiresSecureCoding = true
		defer { coder.finishDecoding() }
		guard let record = CKRecord(coder: coder) else { return nil }

		return record.recordChangeTag != nil
			|| coder.decodeObject(of: NSNumber.self, forKey: "_recordChangeTag") != nil
	}
}
