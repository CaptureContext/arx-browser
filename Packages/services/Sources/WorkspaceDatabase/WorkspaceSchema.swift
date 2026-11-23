import Foundation
import _SQLiteData

/// Migrations for the two workspace databases. Never edit a registered migration: add a new one.
/// Synced tables only ever gain tables and nullable or defaulted columns (ADR 0001).
public enum WorkspaceSchema {
	public static func organizationMigrator() -> DatabaseMigrator {
		var migrator: DatabaseMigrator = .init()
		migrator.registerMigration("Create organization tables (DEV-560)") { db in
			try createSyncedOrganizationTables(db)
			try createLocalOrganizationTables(db)
		}
		migrator.registerMigration("Create deletion, usage and device tables (DEV-980)") { db in
			try createDeletionTables(db)
		}
		migrator.registerMigration("Add the sites dark pages stay off on (DEV-1020)") { db in
			try #sql(
				"""
				ALTER TABLE "profile" ADD COLUMN "darkPagesOffSites" TEXT
				"""
			)
			.execute(db)
		}
		migrator.registerMigration("Add merged items and per-Mac profile storage (DEV-1216)") { db in
			try createMergeTables(db)
		}
		migrator.registerMigration("Add the items a joining Mac's merge replaced (DEV-1216)") { db in

			// This Mac's own: saves made before the app reads the merged store are rebased across it.
			try #sql(
				"""
				CREATE TABLE "mergeRemap" (
					"id" TEXT PRIMARY KEY NOT NULL,
					"keptID" TEXT NOT NULL
				) STRICT
				"""
			)
			.execute(db)
		}
		migrator.registerMigration("Add the profile's unread badges (DEV-1258)") { db in
			try #sql(
				"""
				ALTER TABLE "profile" ADD COLUMN "unreadBadges" TEXT
				"""
			)
			.execute(db)
		}
		migrator.registerMigration("Add the icons chosen for tabs (DEV-1251)") { db in

			// Pins and Favorites sync theirs with the row; an open tab's stays on this Mac, as the
			// tab does.
			for table in ["pinnedTab", "favorite", "regularTab"] {
				try db.execute(
					sql: """
					ALTER TABLE "\(table)" ADD COLUMN "icon" TEXT
					"""
				)
			}
		}
		migrator.registerMigration("Add the deletions kept to one Mac (DEV-1336)") { db in
			try #sql(
				"""
				ALTER TABLE "deletion" ADD COLUMN "keepsElsewhere" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
				"""
			)
			.execute(db)
		}
		return migrator
	}

	public static func preferencesMigrator() -> DatabaseMigrator {
		var migrator: DatabaseMigrator = .init()
		migrator.registerMigration("Create preference tables (DEV-560)") { db in
			try createPreferenceTables(db)
		}
		migrator.registerMigration("Create the preferences file's store info (DEV-560)") { db in
			try #sql(
				"""
				CREATE TABLE "preferenceStoreInfo" (
					"id" TEXT PRIMARY KEY NOT NULL,
					"value" TEXT NOT NULL
				) STRICT
				"""
			)
			.execute(db)
		}
		return migrator
	}

	/// `arx-archive.sqlite`: Tab Archive's synced entries and the deletion and device tables its own
	/// zone needs (DEV-983), with their own names, as SQLiteData routes records by type.
	public static func archiveMigrator() -> DatabaseMigrator {
		var migrator: DatabaseMigrator = .init()
		migrator.registerMigration("Create Tab Archive tables (DEV-983)") { db in
			try #sql(
				"""
				CREATE TABLE "archiveEntry" (
					"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
					"groupID" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '00000000-0000-0000-0000-000000000000',
					"closedAt" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
					"spaceID" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '00000000-0000-0000-0000-000000000000',
					"spaceName" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
					"originalIndex" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
					"tabID" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '00000000-0000-0000-0000-000000000000',
					"profileID" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '00000000-0000-0000-0000-000000000000',
					"title" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
					"url" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
					"customTitle" TEXT,
					"automationClientID" TEXT,
					"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT ''
				) STRICT
				"""
			)
			.execute(db)
			try #sql(
				"""
				CREATE TABLE "archiveDeletion" (
					"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
					"itemID" TEXT NOT NULL,
					"deviceID" TEXT NOT NULL,
					"deletedAt" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0
				) STRICT
				"""
			)
			.execute(db)
			try #sql(
				"""
				CREATE INDEX "index_archiveDeletion_on_itemID" ON "archiveDeletion"("itemID")
				"""
			)
			.execute(db)
			try #sql(
				"""
				CREATE TABLE "archiveDevice" (
					"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
					"lastSeen" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0
				) STRICT
				"""
			)
			.execute(db)
			try #sql(
				"""
				CREATE TABLE "archiveState" (
					"id" TEXT PRIMARY KEY NOT NULL,
					"value" TEXT NOT NULL
				) STRICT
				"""
			)
			.execute(db)
		}
		return migrator
	}

	// MARK: - Organization

	private static func createDeletionTables(_ db: Database) throws {
		try #sql(
			"""
			CREATE TABLE "deletion" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"itemID" TEXT NOT NULL,
				"itemTable" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"deviceID" TEXT NOT NULL,
				"deletedAt" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_deletion_on_itemID" ON "deletion"("itemID")
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "usage" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"itemID" TEXT NOT NULL,
				"itemTable" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"deviceID" TEXT NOT NULL,
				"lastUsed" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_usage_on_itemID" ON "usage"("itemID")
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "syncDevice" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"lastSeen" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0
			) STRICT
			"""
		)
		.execute(db)
	}

	private static func createMergeTables(_ db: Database) throws {
		// Synced: the rules of synced tables (no foreign key, `NOT NULL ON CONFLICT REPLACE`).
		try #sql(
			"""
			CREATE TABLE "mergedItem" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"itemTable" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"keptID" TEXT NOT NULL,
				"mergedAt" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0
			) STRICT
			"""
		)
		.execute(db)

		// This Mac's own.
		try #sql(
			"""
			CREATE TABLE "profileStorage" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"storageID" TEXT NOT NULL
			) STRICT
			"""
		)
		.execute(db)
	}

	private static func createSyncedOrganizationTables(_ db: Database) throws {
		try #sql(
			"""
			CREATE TABLE "profile" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"searchEngine" TEXT,
				"appearance" TEXT,
				"tabArchiveInterval" TEXT,
				"remoteSearchSuggestions" INTEGER,
				"showsFullURL" INTEGER,
				"keptLoadedSites" TEXT,
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V',
				"isStarter" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "space" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"profileID" TEXT NOT NULL REFERENCES "profile"("id") ON DELETE CASCADE,
				"name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"icon" TEXT,
				"appearance" TEXT,
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V',
				"isStarter" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_space_on_profileID" ON "space"("profileID")
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "folder" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"spaceID" TEXT NOT NULL REFERENCES "space"("id") ON DELETE CASCADE,
				"parentFolderID" TEXT,
				"name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V'
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_folder_on_spaceID" ON "folder"("spaceID")
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "pinnedTab" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"spaceID" TEXT NOT NULL REFERENCES "space"("id") ON DELETE CASCADE,
				"folderID" TEXT,
				"title" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"url" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'about:blank',
				"iconURL" TEXT,
				"customTitle" TEXT,
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V'
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_pinnedTab_on_spaceID" ON "pinnedTab"("spaceID")
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "favorite" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"profileID" TEXT NOT NULL REFERENCES "profile"("id") ON DELETE CASCADE,
				"title" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"url" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'about:blank',
				"iconURL" TEXT,
				"customTitle" TEXT,
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V'
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_favorite_on_profileID" ON "favorite"("profileID")
			"""
		)
		.execute(db)
	}

	private static func createLocalOrganizationTables(_ db: Database) throws {
		try #sql(
			"""
			CREATE TABLE "storeInfo" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"value" TEXT NOT NULL
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "retiredProfile" (
				"id" TEXT PRIMARY KEY NOT NULL
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "spaceState" (
				"id" TEXT PRIMARY KEY NOT NULL REFERENCES "space"("id") ON DELETE CASCADE,
				"selectedTabID" TEXT
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "folderState" (
				"id" TEXT PRIMARY KEY NOT NULL REFERENCES "folder"("id") ON DELETE CASCADE,
				"isExpanded" INTEGER NOT NULL DEFAULT 1,
				"ordinal" TEXT NOT NULL
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "tabState" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"restorationTitle" TEXT NOT NULL,
				"restorationURL" TEXT NOT NULL,
				"automationClientID" TEXT,
				"ordinal" TEXT NOT NULL
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "regularTab" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"spaceID" TEXT NOT NULL REFERENCES "space"("id") ON DELETE CASCADE,
				"customTitle" TEXT,
				"position" TEXT NOT NULL
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE INDEX "index_regularTab_on_spaceID" ON "regularTab"("spaceID")
			"""
		)
		.execute(db)

		for table in ["archivedTab", "splitGroup", "tabGroup"] {
			try db.execute(
				sql: """
				CREATE TABLE "\(table)" (
					"id" TEXT PRIMARY KEY NOT NULL,
					"value" TEXT NOT NULL,
					"position" TEXT NOT NULL
				) STRICT
				"""
			)
		}
	}

	// MARK: - Preferences

	private static func createPreferenceTables(_ db: Database) throws {
		try #sql(
			"""
			CREATE TABLE "preference" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"value" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '{}'
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "searchShortcut" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"keyword" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"template" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"homepage" TEXT,
				"isEnabled" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V'
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "keyboardShortcut" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"bindings" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]',
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V'
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "routingRule" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"host" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"includesSubdomains" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
				"scheme" TEXT,
				"port" INTEGER,
				"pathPrefix" TEXT,
				"destination" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '{}',
				"isEnabled" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V'
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "proxyLinkRule" (
				"id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
				"name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"sourceHosts" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]',
				"destinationTemplate" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
				"isEnabled" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
				"position" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'V'
			) STRICT
			"""
		)
		.execute(db)

		try #sql(
			"""
			CREATE TABLE "localPreference" (
				"id" TEXT PRIMARY KEY NOT NULL,
				"value" TEXT NOT NULL
			) STRICT
			"""
		)
		.execute(db)
	}
}
