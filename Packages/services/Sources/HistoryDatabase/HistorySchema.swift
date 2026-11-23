import Foundation
import _SQLiteData

/// Migrations for `arx-history.sqlite`. Never edit a registered migration: add a new one. Synced
/// tables only ever gain nullable or defaulted columns (ADR 0001).
public enum HistorySchema {
	public static func migrator() -> DatabaseMigrator {
		var migrator: DatabaseMigrator = .init()
		migrator.registerMigration("Create history tables (DEV-984)") { db in
			try createSyncedTables(db)
			try createLocalTables(db)
		}
		return migrator
	}

	private static func createSyncedTables(_ db: Database) throws {
		try #sql(
			"""
			CREATE TABLE "historyVisit" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"profileID" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"url" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"lastVisited" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
				"titledVisit" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT ''
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_historyVisit_on_profileID" ON "historyVisit"("profileID")
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "historyClear" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"profileID" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"before" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
				"after" REAL,
				"host" TEXT,
				"url" TEXT
			) STRICT
			"""
		)
		.execute(db)
	}

	private static func createLocalTables(_ db: Database) throws {
		try #sql(
			"""
			CREATE TABLE "historyEntry" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"profileID" TEXT NOT NULL,
				"url" TEXT NOT NULL,
				"title" TEXT NOT NULL,
				"lastVisited" REAL NOT NULL,
				"visitCount" INTEGER NOT NULL,
				"typedCount" INTEGER NOT NULL,
				"lastSpaceID" TEXT
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_historyEntry_on_profileID" ON "historyEntry"("profileID")
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "historyProfile" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"revision" INTEGER NOT NULL,
				"migratedFromJSON" INTEGER NOT NULL
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "historyRemoval" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"profileID" TEXT NOT NULL,
				"before" REAL NOT NULL,
				"after" REAL,
				"host" TEXT,
				"url" TEXT
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_historyRemoval_on_profileID" ON "historyRemoval"("profileID")
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "historySyncState" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"value" TEXT NOT NULL
			) STRICT
			"""
		)
		.execute(db)
	}
}
