import BrowserCore
import BrowserWorkspaceClient
import Foundation
import Testing
import WorkspaceDatabase
import _TestSupport

/// The `ARX_SQLITE_WORKSPACE` feature flag (DEV-560): off keeps the JSON file exactly as before; on
/// migrates the file into SQLite once and never writes the file again.
internal struct WorkspaceStorageTests {
	// MARK: - Feature flag

	@Test
	internal func theFlagReadsTheEnvironmentFirstThenDefaults() async throws {
		let suite: String = "WorkspaceStorageTests-\(UUID().uuidString)"
		let defaults: UserDefaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		// On by default (DEV-1143).
		#expect(BrowserWorkspaceClient.Storage(environment: [:], defaults: defaults) == .sqlite)
		#expect(BrowserWorkspaceClient.Storage(environment: ["ARX_SQLITE_WORKSPACE": "1"], defaults: defaults) == .sqlite)
		#expect(BrowserWorkspaceClient.Storage(environment: ["ARX_SQLITE_WORKSPACE": "0"], defaults: defaults) == .json)
		#expect(BrowserWorkspaceClient.Storage(environment: ["ARX_SQLITE_WORKSPACE": "FALSE"], defaults: defaults) == .json)

		defaults.set("no", forKey: "ARX_SQLITE_WORKSPACE")
		#expect(BrowserWorkspaceClient.Storage(environment: [:], defaults: defaults) == .json)
		#expect(BrowserWorkspaceClient.Storage(environment: ["ARX_SQLITE_WORKSPACE": "1"], defaults: defaults) == .sqlite)
	}

	@Test
	internal func flagOffWritesTheFileAndNoDatabase() async throws {
		let world: World = try .init()
		let client: BrowserWorkspaceClient = world.client(.json)
		#expect(try client.loadWithRecovery().organization == nil)

		try client.save(world.organization)

		#expect(FileManager.default.fileExists(atPath: world.file.path))
		#expect(try world.databaseFiles().isEmpty)
		#expect(try world.client(.json).load() == world.organization)
	}

	/// A space selecting a tab it doesn't hold used to refuse the whole save with
	/// "ValidationError error 20"; the save clears that selection instead (DEV-1261).
	@Test(arguments: [BrowserWorkspaceClient.Storage.json, .sqlite])
	internal func saveClearsASelectionTheSpaceDoesNotHold(storage: BrowserWorkspaceClient.Storage) async throws {
		let world: World = try .init()
		let client: BrowserWorkspaceClient = world.client(storage)
		var organization: BrowserOrganization = world.organization
		organization.spaces[0].selectedTabID = .init(rawValue: UUID())
		#expect(throws: BrowserOrganization.ValidationError.self) { try organization.validate() }

		try client.save(organization)

		var repaired: BrowserOrganization = organization
		repaired.spaces[0].selectedTabID = nil
		#expect(try world.client(storage).load() == repaired)
	}

	// MARK: - Migration

	@Test(arguments: [1, 2, 3, 4])
	internal func flagOnMigratesEachJSONVersionAndNeverWritesTheFile(version: Int) async throws {
		let world: World = try .init()
		try world.writeFile(version: version)
		let original: Data = try Data(contentsOf: world.file)

		let client: BrowserWorkspaceClient = world.client(.sqlite)
		let recovery: BrowserWorkspaceClient.Recovery = try client.loadWithRecovery()
		var expected: BrowserOrganization = world.organization
		if version < 3 { expected.legacyProfileID = expected.profiles.first?.id }
		#expect(recovery.organization == expected)
		#expect(!recovery.usedBackup)
		#expect(client.storage == .sqlite)
		#expect(client.hasPersistedLegacyProfileIdentity)
		#expect(try WorkspaceDatabase(directory: world.directory).load()?.migratedFromWorkspaceVersion == version)

		var edited: BrowserOrganization = expected
		edited.spaces[0].name = "Edited in SQLite"
		var preferences: BrowserPreferences = recovery.preferences
		preferences.appTheme = .dark
		try client.save(edited, preferences: preferences, synchronizeSecurityChange: true)

		#expect(try Data(contentsOf: world.file) == original)
		#expect(!FileManager.default.fileExists(atPath: world.backup.path))

		// The next run reads the database, not the file.
		let reopened: BrowserWorkspaceClient.Recovery = try world.client(.sqlite).loadWithRecovery()
		#expect(reopened.organization == edited)
		#expect(reopened.preferences.appTheme == .dark)
	}

	@Test
	internal func turningTheFlagOffReturnsToTheFileAsItWas() async throws {
		let world: World = try .init()
		try world.writeFile(version: 4)
		let sqlite: BrowserWorkspaceClient = world.client(.sqlite)
		var edited: BrowserOrganization = try #require(try sqlite.load())
		edited.spaces[0].name = "Only in SQLite"
		try sqlite.save(edited)

		let json: BrowserWorkspaceClient = world.client(.json)

		#expect(try json.load() == world.organization)
	}

	@Test
	internal func aDamagedFileMigratesFromItsBackupAndStaysDamaged() async throws {
		let world: World = try .init()
		try world.writeFile(version: 4)
		try FileManager.default.copyItem(at: world.file, to: world.backup)
		let damaged: Data = .init("{\"version\": 4, \"revis".utf8)
		try damaged.write(to: world.file)

		let client: BrowserWorkspaceClient = world.client(.sqlite)
		let recovery: BrowserWorkspaceClient.Recovery = try client.loadWithRecovery()
		#expect(recovery.usedBackup)
		#expect(recovery.organization == world.organization)
		try client.save(world.organization)

		#expect(try Data(contentsOf: world.file) == damaged)
		let siblings: [String] = try FileManager.default.contentsOfDirectory(atPath: world.directory.path)
		#expect(!siblings.contains { $0.contains("damaged") })
	}

	@Test
	internal func anUnknownVersionFailsWithoutMigrating() async throws {
		let world: World = try .init()
		try Data("{\"version\": 9}".utf8).write(to: world.file)

		#expect(throws: BrowserWorkspaceClient.Failure.unsupportedVersion(9)) {
			try world.client(.sqlite).loadWithRecovery()
		}
		#expect(try WorkspaceDatabase(directory: world.directory).isInitialized == false)
	}

	@Test
	internal func aFirstLaunchCreatesTheWorkspaceInTheDatabase() async throws {
		let world: World = try .init()
		let client: BrowserWorkspaceClient = world.client(.sqlite)
		#expect(try client.loadWithRecovery().organization == nil)

		try client.save(world.organization)

		#expect(!FileManager.default.fileExists(atPath: world.file.path))
		#expect(try world.client(.sqlite).load() == world.organization)
		#expect(try WorkspaceDatabase(directory: world.directory).load()?.migratedFromWorkspaceVersion == nil)
	}

	@Test
	internal func aDatabaseThatCantBeCreatedFallsBackToTheFileForTheRun() async throws {
		let world: World = try .init()
		try world.writeFile(version: 4)
		let original: Data = try Data(contentsOf: world.file)

		// A folder that can't take new files can't hold a new database.
		try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: world.directory.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: world.directory.path) }

		let client: BrowserWorkspaceClient = world.client(.sqlite)
		#expect(try client.load() == world.organization)
		#expect(client.storage == .json)
		#expect(client.databaseFailure != nil)
		#expect(try Data(contentsOf: world.file) == original)
	}

	/// DEV-1143: SQLite is the default, so a first launch after the update migrates the file. A
	/// migration that fails leaves the file as it was and the run on it, saving there as before.
	@Test
	internal func aMigrationThatFailsAtTheDefaultFallsBackToTheFile() async throws {
		let suite: String = "WorkspaceStorageTests-\(UUID().uuidString)"
		let defaults: UserDefaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let storage: BrowserWorkspaceClient.Storage = .init(environment: [:], defaults: defaults)
		#expect(storage == .sqlite)

		let world: World = try .init()
		try world.writeFile(version: 4)
		let original: Data = try Data(contentsOf: world.file)

		// A folder where the save lock goes: the store opens, but the migration can't take the lock.
		try FileManager.default.createDirectory(
			at: world.directory.appendingPathComponent(WorkspaceDatabase.lockFileName),
			withIntermediateDirectories: false
		)

		let client: BrowserWorkspaceClient = world.client(storage)
		#expect(try client.load() == world.organization)
		#expect(client.storage == .json)
		#expect(client.databaseFailure != nil)
		#expect(try Data(contentsOf: world.file) == original)
		#expect(WorkspaceDatabase.contents(of: world.directory) == .empty)

		// The run keeps saving to the file.
		try client.save(world.organization)
		#expect(try world.client(.json).load() == world.organization)
		#expect(WorkspaceDatabase.contents(of: world.directory) == .empty)
	}

	@Test
	internal func aFirstAttemptsOwnLeftoversStillFallBackToTheFile() async throws {
		let world: World = try .init()
		try world.writeFile(version: 4)

		// As if a first attempt failed after creating the preferences file and before the organization
		// file: nothing can be written beside them now, and neither holds a workspace.
		let preferences: URL = world.directory.appendingPathComponent(WorkspaceDatabase.preferencesFileName)
		try Data().write(to: preferences)
		#expect(WorkspaceDatabase.contents(of: world.directory) == .empty)
		try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: world.directory.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: world.directory.path) }

		let client: BrowserWorkspaceClient = world.client(.sqlite)
		#expect(try client.load() == world.organization)
		#expect(client.storage == .json)
	}

	@Test
	internal func aWorkspaceInTheDatabaseIsReportedByItsContents() async throws {
		let world: World = try .init()
		try world.writeFile(version: 4)
		#expect(WorkspaceDatabase.contents(of: world.directory) == .empty)
		_ = try world.client(.sqlite).loadWithRecovery()

		#expect(WorkspaceDatabase.contents(of: world.directory) == .workspace)
	}

	@Test
	internal func anExistingDatabaseThatCantOpenFailsRatherThanReadTheOlderFile() async throws {
		let world: World = try .init()
		try world.writeFile(version: 4)

		// A directory where the database file belongs can't be opened as a database.
		try FileManager.default.createDirectory(
			at: world.directory.appendingPathComponent(WorkspaceDatabase.organizationFileName),
			withIntermediateDirectories: true
		)

		let client: BrowserWorkspaceClient = world.client(.sqlite)
		#expect(throws: (any Error).self) { try client.load() }
	}

	@Test
	internal func aLostOrganizationDatabaseIsNeverRemigratedOverSurvivingPreferences() async throws {
		let world: World = try .init()
		try world.writeFile(version: 4)
		let client: BrowserWorkspaceClient = world.client(.sqlite)
		_ = try client.loadWithRecovery()
		var preferences: BrowserPreferences = .init()
		preferences.appTheme = .dark
		try client.save(world.organization, preferences: preferences)
		try FileManager.default.removeItem(at: world.directory.appendingPathComponent(WorkspaceDatabase.organizationFileName))

		#expect(throws: BrowserWorkspaceClient.Failure.unsupportedOrganization) {
			try world.client(.sqlite).loadWithRecovery()
		}
	}

	@Test
	internal func aSurvivingPreferencesFileThatCantOpenFailsRatherThanReadTheOlderFile() async throws {
		let world: World = try .init()
		try world.writeFile(version: 4)

		// Only a directory where the preferences database belongs survives; it can't open.
		try FileManager.default.createDirectory(
			at: world.directory.appendingPathComponent(WorkspaceDatabase.preferencesFileName),
			withIntermediateDirectories: true
		)

		#expect(throws: (any Error).self) { try world.client(.sqlite).load() }
	}

	@Test
	internal func aBackupsAssistantGrantsAreRevokedBeforeTheyReachTheDatabase() async throws {
		let world: World = try .init()
		var preferences: BrowserPreferences = .init()
		preferences.automation.isEnabled = true
		try BrowserWorkspaceClient(file: world.file, securitySynchronizer: { _ in }).save(world.organization, preferences: preferences)
		try FileManager.default.copyItem(at: world.file, to: world.backup)
		try Data("{".utf8).write(to: world.file)

		_ = try world.client(.sqlite).loadWithRecovery()

		let stored: WorkspaceDatabase.Snapshot? = try WorkspaceDatabase(directory: world.directory).load()
		#expect(stored?.preferences.automation.isEnabled == false)
	}

	@Test
	internal func exportNeverReplacesTheDatabase() async throws {
		let world: World = try .init()
		let client: BrowserWorkspaceClient = world.client(.sqlite)
		_ = try client.loadWithRecovery()
		try client.save(world.organization)

		for file in WorkspaceDatabase.files(in: world.directory) {
			#expect(throws: BrowserWorkspaceClient.Failure.changedOnDisk) {
				try client.export(world.organization, to: file)
			}
		}
		#expect(try world.client(.sqlite).load() == world.organization)
	}
}

// MARK: - World

/// A workspace file in its own temporary directory, never a real Arx profile.
private final class World {
	internal let directory: URL
	internal let file: URL
	internal let organization: BrowserOrganization

	internal var backup: URL { file.appendingPathExtension("backup") }

	internal init() throws {
		self.directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceStorageTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		self.file = directory.appendingPathComponent("arx-workspace.json")

		let profileID: Profile.ID = .init(rawValue: UUID(-1))
		let spaceID: Space.ID = .init(rawValue: UUID(-2))
		let folderID: Folder.ID = .init(rawValue: UUID(-3))
		let pinnedID: Tab.ID = .init(rawValue: UUID(-4))
		let regularID: Tab.ID = .init(rawValue: UUID(-5))
		let favoriteID: Tab.ID = .init(rawValue: UUID(-6))
		let url: URL = URL(string: "https://example.com/")!
		self.organization = .init(
			profiles: [.init(id: profileID, name: "Default", favorites: [favoriteID])],
			spaces: [
				.init(
					id: spaceID,
					profileID: profileID,
					name: "Home",
					savedItems: [.folder(folderID)],
					unpinnedTabs: [regularID],
					selectedTabID: regularID
				),
			],
			folders: [.init(id: folderID, spaceID: spaceID, name: "Saved", children: [.tab(pinnedID)])],
			tabs: [
				.init(id: pinnedID, profileID: profileID, savedDestination: .init(title: "Pin", url: url), restoration: .init(title: "Pin", url: url)),
				.init(id: regularID, profileID: profileID, restoration: .init(title: "Tab", url: url)),
				.init(id: favoriteID, profileID: profileID, savedDestination: .init(title: "Fav", url: url), restoration: .init(title: "Fav", url: url)),
			]
		)
	}

	deinit {
		try? FileManager.default.removeItem(at: directory)
	}

	internal func client(_ storage: BrowserWorkspaceClient.Storage) -> BrowserWorkspaceClient {
		.init(file: file, storage: storage, securitySynchronizer: { _ in })
	}

	internal func databaseFiles() throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".sqlite") }
	}

	/// A snapshot as each version wrote it: version 1 had no revision, preferences or legacy owner;
	/// version 2 added the revision; version 3 the legacy owner; version 4 is today's.
	internal func writeFile(version: Int) throws {
		guard version == 4 else {
			var organization: [String: Any] = try JSONSerialization.jsonObject(
				with: JSONEncoder().encode(self.organization)
			) as! [String: Any]
			for key in ["archive", "splits", "tabGroups", "retiredProfileIDs"] {
				organization.removeValue(forKey: key)
			}
			if version < 3 { organization.removeValue(forKey: "legacyProfileID") }
			var snapshot: [String: Any] = ["version": version, "organization": organization]
			if version >= 2 { snapshot["revision"] = 7 }
			try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
			return
		}

		try BrowserWorkspaceClient(file: file, securitySynchronizer: { _ in }).save(organization)
	}
}
