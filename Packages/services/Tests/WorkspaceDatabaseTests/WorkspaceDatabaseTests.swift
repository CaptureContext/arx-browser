import BrowserCore
import Foundation
import Testing
import WorkspaceDatabase
import _SQLiteData
import _TestSupport

internal struct WorkspaceDatabaseTests {
	// MARK: - Round trip

	@Test
	internal func richWorkspaceRoundTripsThroughAReopenedStore() async throws {
		let directory: TemporaryDirectory = try .init()
		try Fixture.organization.validate()
		try Fixture.preferences.validate()
		try directory.open().save(Fixture.organization, preferences: Fixture.preferences)

		let snapshot: WorkspaceDatabase.Snapshot? = try directory.open().load()

		expectNoDifference(snapshot?.organization, Fixture.organization)
		expectNoDifference(snapshot?.preferences, Fixture.preferences)
		#expect(snapshot?.migratedFromWorkspaceVersion == nil)
		try snapshot?.organization.validate()
		try snapshot?.preferences.validate()
	}

	/// DEV-1170: a space saved before Match site had levels keeps it on, and one saved with it off
	/// inherits; off chosen since stays off, and the browser default round trips.
	@Test
	internal func matchSiteChoicesSurviveTheStore() async throws {
		let directory: TemporaryDirectory = try .init()
		var organization = Fixture.organization
		let inbox = organization.spaces[0].id
		let home = organization.spaces[1].id
		organization.spaces[id: inbox]?.appearance = .init(tintHue: 30, matchesSite: false)
		organization.profiles[0].appearance?.matchesSite = true
		var preferences = Fixture.preferences
		preferences.chromeMatchesSite = true
		let database: WorkspaceDatabase = try directory.open()
		try database.save(organization, preferences: preferences)

		let saved = try directory.open().load()
		expectNoDifference(saved?.organization, organization)
		#expect(saved?.preferences.chromeMatchesSite == true)

		// As an earlier build saved them.
		try await database.database.write { db in
			try db.execute(
				sql: "UPDATE space SET appearance = ? WHERE lower(id) = ?",
				arguments: [#"{"matchesSite":false,"tintHue":30}"#, inbox.rawValue.uuidString.lowercased()]
			)
			try db.execute(
				sql: "UPDATE space SET appearance = ? WHERE lower(id) = ?",
				arguments: [#"{"matchesSite":true}"#, home.rawValue.uuidString.lowercased()]
			)
		}
		let loaded = try directory.open().load()
		expectNoDifference(loaded?.organization.spaces[id: inbox]?.appearance, .init(tintHue: 30))
		expectNoDifference(loaded?.organization.spaces[id: home]?.appearance, .init(matchesSite: true))
	}

	/// DEV-1326: the archive interval keeps no choice (the six-hour default) apart from Never
	/// through the store, and a value from a newer build loads as no choice.
	@Test
	internal func archiveIntervalsKeepNoChoiceApartFromNever() async throws {
		let directory: TemporaryDirectory = try .init()
		var organization = Fixture.organization
		let profile = organization.profiles[0].id
		let database: WorkspaceDatabase = try directory.open()
		let column = { () async throws -> String? in
			try await database.database.read { db in
				try String?.fetchOne(
					db,
					sql: "SELECT tabArchiveInterval FROM profile WHERE lower(id) = ?",
					arguments: [profile.rawValue.uuidString.lowercased()]
				) ?? nil
			}
		}

		for interval in [nil, TabArchiveInterval.never, .sixHours] {
			organization.profiles[id: profile]?.tabArchiveInterval = interval
			try database.save(organization, preferences: Fixture.preferences)
			let stored = try await column()
			expectNoDifference(stored, interval?.rawValue)
			expectNoDifference(try directory.open().load()?.organization.profiles[id: profile]?.tabArchiveInterval, interval)
		}

		try await database.database.write { db in
			try db.execute(
				sql: "UPDATE profile SET tabArchiveInterval = 'fortnight' WHERE lower(id) = ?",
				arguments: [profile.rawValue.uuidString.lowercased()]
			)
		}
		let loaded = try directory.open().load()?.organization.profiles[id: profile]
		#expect(loaded?.tabArchiveInterval == nil)
		expectNoDifference(loaded?.effectiveTabArchiveInterval, .sixHours)
	}

	/// DEV-1277: a command bar row saved while the command bar had a choice of looks (DEV-1266),
	/// here or synced from a Mac on an older build, still loads, and the look is ignored.
	@Test
	internal func aCommandBarRowWithTheRemovedLookStillLoads() async throws {
		let directory: TemporaryDirectory = try .init()
		let database: WorkspaceDatabase = try directory.open()
		try database.save(Fixture.organization, preferences: Fixture.preferences)

		try await database.database.write { db in
			try db.execute(
				sql: "UPDATE preference SET value = json_set(value, '$.commandBarAppearance', 'glassy') WHERE id = ?",
				arguments: [PreferenceDomain.commandBar.rawValue]
			)
		}
		let row = try await database.database.read { db in
			try PreferenceRecord.find(PreferenceDomain.commandBar.rawValue).fetchOne(db)
		}
		#expect(row?.value.contains("commandBarAppearance") == true)

		expectNoDifference(try directory.open().load()?.preferences, Fixture.preferences)
	}

	@Test
	internal func defaultPreferencesRoundTrip() async throws {
		let directory: TemporaryDirectory = try .init()
		try directory.open().save(Fixture.organization, preferences: .init())

		expectNoDifference(try directory.open().load()?.preferences, BrowserPreferences())
	}

	@Test
	internal func anEmptyStoreHasNoWorkspace() async throws {
		let directory: TemporaryDirectory = try .init()
		let database: WorkspaceDatabase = try directory.open()

		#expect(try database.load() == nil)
		#expect(try !database.isInitialized)
	}

	@Test
	internal func onlyPortablePreferencesAreSyncedRows() async throws {
		let directory: TemporaryDirectory = try .init()
		let database: WorkspaceDatabase = try directory.open()
		try database.save(Fixture.organization, preferences: Fixture.preferences)

		let (domains, local) = try await database.database.read { db in
			(
				try PreferenceRecord.all.fetchAll(db).map(\.id).sorted(),
				try LocalPreferenceRecord.all.fetchAll(db).map(\.id)
			)
		}
		#expect(domains == PreferenceDomain.allCases.map(\.rawValue).sorted())
		#expect(local.contains("automation"))
		#expect(local.contains("windowPresentations"))
		#expect(local.contains("tabsLastViewed"))
		// Which default Proxy Links rules this Mac offered stays on it (DEV-1003).
		#expect(local.contains("offeredProxyLinkDefaults"))
		// Conflict resolution stays on this Mac until syncing it is decided (DEV-1332).
		#expect(local.contains("shortcutConflictChoices"))
		// Which defaults the person deleted syncs with the routing preferences, so no Mac offers
		// one again (DEV-1113).
		#expect(!local.contains("removedProxyLinkDefaults"))
		#expect(!local.contains("chromeTint"))
		#expect(!local.contains("searchShortcuts"))
	}

	// MARK: - Diff writer

	@Test
	internal func savingTheSameWorkspaceAgainWritesNothing() async throws {
		let directory: TemporaryDirectory = try .init()
		let first: WorkspaceDatabase = try directory.open()
		let initial: WorkspaceDatabase.WriteSummary = try first.save(Fixture.organization, preferences: Fixture.preferences)
		#expect(initial.rowCount > 0)
		#expect(try first.save(Fixture.organization, preferences: Fixture.preferences).rowCount == 0)

		// A new run reads the rows back and still finds nothing to write.
		let second: WorkspaceDatabase = try directory.open()
		let loaded: WorkspaceDatabase.Snapshot = try #require(try second.load())
		expectNoDifference(
			try second.save(loaded.organization, preferences: loaded.preferences),
			.init()
		)
	}

	@Test
	internal func renamingAPinnedTabWritesOneRow() async throws {
		let (database, organization) = try saved()
		var renamed: BrowserOrganization = organization
		renamed.tabs[id: Fixture.docs]?.savedDestination?.title = "Documents"

		expectNoDifference(
			try database.save(renamed, preferences: Fixture.preferences),
			.init(upserted: ["pinnedTab": 1])
		)
	}

	@Test
	internal func browsingInAPinnedTabWritesOnlyItsLocalState() async throws {
		let (database, organization) = try saved()
		var browsed: BrowserOrganization = organization
		browsed.tabs[id: Fixture.docs]?.restoration = .init(title: "Elsewhere", url: Fixture.url("https://elsewhere.example"))

		expectNoDifference(
			try database.save(browsed, preferences: Fixture.preferences),
			.init(upserted: ["tabState": 1])
		)
	}

	@Test
	internal func archivingATabWritesItsEntryAndRemovesItsLocation() async throws {
		let (database, organization) = try saved()
		var archived: BrowserOrganization = organization
		try archived.update { organization in
			let tab: Tab = try #require(organization.tabs[id: Fixture.news])
			organization.spaces[id: Fixture.inbox]?.unpinnedTabs.removeAll { $0 == Fixture.news }
			organization.tabGroups.removeAll()
			organization.splits.removeAll()
			organization.tabs.remove(id: Fixture.news)
			organization.archive.append(
				.init(
					id: .init(rawValue: Fixture.id(-110)),
					groupID: Fixture.id(-111),
					closedAt: Date(timeIntervalSinceReferenceDate: 800_000_300),
					originalSpaceID: Fixture.inbox,
					originalSpaceName: "Inbox",
					originalIndex: 0,
					tab: tab
				)
			)
		}

		expectNoDifference(
			try database.save(archived, preferences: Fixture.preferences),
			.init(
				upserted: ["archiveEntry": 1],
				deleted: ["regularTab": 1, "tabState": 1, "splitGroup": 1, "tabGroup": 1]
			)
		)
		expectNoDifference(try database.load()?.organization, archived)
	}

	@Test
	internal func changingOnePreferenceWritesOneRow() async throws {
		let (database, organization) = try saved()
		var preferences: BrowserPreferences = Fixture.preferences
		preferences.grainEnabled = false

		expectNoDifference(
			try database.save(organization, preferences: preferences),
			.init(upserted: ["preference": 1])
		)
	}

	@Test
	internal func reorderingAListRewritesOnlyTheMovedRow() async throws {
		let (database, organization) = try saved()
		var reordered: BrowserOrganization = organization
		reordered.spaces[id: Fixture.inbox]?.savedItems = [.tab(Fixture.docs), .folder(Fixture.reading)]
		reordered.profiles[id: Fixture.work]?.favorites = [Fixture.mail, Fixture.calendar]

		let summary: WorkspaceDatabase.WriteSummary = try database.save(reordered, preferences: Fixture.preferences)

		#expect(summary.rowCount == 2)
		#expect(summary.upserted.values.reduce(0, +) == 2)
		expectNoDifference(try database.load()?.organization, reordered)
	}

	@Test
	internal func insertingInTheMiddleWritesOnlyTheNewRows() async throws {
		let (database, organization) = try saved()
		let inserted: Tab.ID = .init(rawValue: Fixture.id(-100))
		var edited: BrowserOrganization = organization
		try edited.update { organization in
			organization.tabs.append(Fixture.pinned(inserted, Fixture.work, "New", "https://new.example"))
			organization.spaces[id: Fixture.inbox]?.savedItems.insert(.tab(inserted), at: 1)
		}

		expectNoDifference(
			try database.save(edited, preferences: Fixture.preferences),
			.init(upserted: ["pinnedTab": 1, "tabState": 1])
		)
		expectNoDifference(try database.load()?.organization, edited)
	}

	@Test
	internal func movingTabsAndFoldersBetweenParentsRoundTrips() async throws {
		let (database, organization) = try saved()
		var moved: BrowserOrganization = organization
		try moved.update { organization in

			// The essay leaves its folder for the space root; Articles moves to the root too.
			organization.folders[id: Fixture.reading]?.children = []
			organization.spaces[id: Fixture.inbox]?.savedItems = [
				.tab(Fixture.essay),
				.folder(Fixture.reading),
				.folder(Fixture.articles),
				.tab(Fixture.docs),
			]
		}

		let summary: WorkspaceDatabase.WriteSummary = try database.save(moved, preferences: Fixture.preferences)

		#expect(summary.upserted["pinnedTab"] == 1)
		#expect(summary.upserted["folder"] == 1)
		#expect(summary.deleted.isEmpty)
		expectNoDifference(try database.load()?.organization, moved)
		let rows: (FolderRecord?, PinnedTabRecord?) = try await database.database.read { db in
			(
				try FolderRecord.find(Fixture.articles.rawValue).fetchOne(db),
				try PinnedTabRecord.find(Fixture.essay.rawValue).fetchOne(db)
			)
		}
		#expect(rows.0?.parentFolderID == nil)
		#expect(rows.1?.folderID == nil)
	}

	@Test
	internal func deletingASpaceRemovesItsRows() async throws {
		let (database, organization) = try saved()
		var deleted: BrowserOrganization = organization
		try deleted.update { organization in
			organization.spaces.remove(id: Fixture.home)
			organization.folders.remove(id: Fixture.recipes)
			organization.tabs.remove(id: Fixture.bank)
			organization.tabs.remove(id: Fixture.soup)
		}

		let summary: WorkspaceDatabase.WriteSummary = try database.save(deleted, preferences: Fixture.preferences)

		#expect(summary.deleted == ["space": 1, "folder": 1, "folderState": 1, "pinnedTab": 2, "tabState": 2])
		expectNoDifference(try database.load()?.organization, deleted)
		let pinned: Int = try await database.database.read { db in
			try PinnedTabRecord.where { $0.spaceID.eq(Fixture.home.rawValue) }.fetchCount(db)
		}
		#expect(pinned == 0)
	}

	@Test
	internal func aWriteFromAnotherStoreIsReportedAsChangedOnDisk() async throws {
		let directory: TemporaryDirectory = try .init()
		let first: WorkspaceDatabase = try directory.open()
		try first.save(Fixture.organization, preferences: Fixture.preferences)
		let second: WorkspaceDatabase = try directory.open()
		var other: BrowserOrganization = try #require(try second.load()).organization
		other.profiles[id: Fixture.work]?.name = "Elsewhere"
		try second.save(other, preferences: Fixture.preferences)

		var mine: BrowserOrganization = Fixture.organization
		mine.profiles[id: Fixture.work]?.name = "Mine"
		#expect(throws: WorkspaceDatabase.Failure.changedOnDisk) {
			try first.save(mine, preferences: Fixture.preferences)
		}
		#expect(try directory.open().load()?.organization.profiles[id: Fixture.work]?.name == "Elsewhere")
	}

	@Test
	internal func anUnchangedSaveAfterAnotherWriterIsChangedOnDisk() async throws {
		let directory: TemporaryDirectory = try .init()
		let first: WorkspaceDatabase = try directory.open()
		try first.save(Fixture.organization, preferences: Fixture.preferences)
		let second: WorkspaceDatabase = try directory.open()
		var other: BrowserOrganization = try #require(try second.load()).organization
		other.spaces[id: Fixture.projects]?.name = "Elsewhere"
		try second.save(other, preferences: Fixture.preferences)

		#expect(throws: WorkspaceDatabase.Failure.changedOnDisk) {
			try first.save(Fixture.organization, preferences: Fixture.preferences)
		}
	}

	@Test
	internal func aWorkspaceCreatedSinceAnEmptyLoadIsChangedOnDisk() async throws {
		let directory: TemporaryDirectory = try .init()
		let first: WorkspaceDatabase = try directory.open()
		#expect(try first.load() == nil)
		try directory.open().save(Fixture.organization, preferences: Fixture.preferences)

		var mine: BrowserOrganization = Fixture.organization
		mine.profiles[id: Fixture.work]?.name = "Mine"
		#expect(throws: WorkspaceDatabase.Failure.changedOnDisk) {
			try first.save(mine, preferences: Fixture.preferences)
		}
		#expect(try directory.open().load()?.organization == Fixture.organization)
	}

	@Test
	internal func oneDatabaseWithoutTheOtherIsAPartialStore() async throws {
		let organizationLost: TemporaryDirectory = try .init()
		try organizationLost.open().save(Fixture.organization, preferences: Fixture.preferences)
		try FileManager.default.removeItem(at: organizationLost.url.appendingPathComponent(WorkspaceDatabase.organizationFileName))
		#expect(throws: WorkspaceDatabase.Failure.partialStore) { try organizationLost.open().load() }

		let preferencesLost: TemporaryDirectory = try .init()
		try preferencesLost.open().save(Fixture.organization, preferences: Fixture.preferences)
		try FileManager.default.removeItem(at: preferencesLost.url.appendingPathComponent(WorkspaceDatabase.preferencesFileName))
		#expect(throws: WorkspaceDatabase.Failure.partialStore) { try preferencesLost.open().load() }

		// Writing into the half that's left fails too, rather than replacing the survivor.
		#expect(throws: WorkspaceDatabase.Failure.partialStore) {
			try organizationLost.open().save(Fixture.organization, preferences: .init())
		}
		#expect(throws: WorkspaceDatabase.Failure.partialStore) {
			try organizationLost.open().migrate(
				organization: Fixture.organization,
				preferences: .init(),
				fromWorkspaceVersion: 4,
				sourceRevision: 0
			)
		}
		#expect(throws: WorkspaceDatabase.Failure.partialStore) {
			try preferencesLost.open().save(Fixture.organization, preferences: .init())
		}
	}

	@Test
	internal func anOlderPreferencesFileRestoredAloneIsAPartialStore() async throws {
		let directory: TemporaryDirectory = try .init()
		let database: WorkspaceDatabase = try directory.open()
		try database.save(Fixture.organization, preferences: Fixture.preferences)
		let preferencesFile: URL = directory.url.appendingPathComponent(WorkspaceDatabase.preferencesFileName)
		let older: Data = try Data(contentsOf: preferencesFile)
		var preferences: BrowserPreferences = Fixture.preferences
		preferences.appTheme = .light
		#expect(try database.save(Fixture.organization, preferences: preferences).rowCount > 0)
		try database.database.close()

		try older.write(to: preferencesFile)

		#expect(throws: WorkspaceDatabase.Failure.partialStore) { try directory.open().load() }
	}

	@Test
	internal func anUnchangedSaveOverAMismatchedPairIsAPartialStore() async throws {
		let directory: TemporaryDirectory = try .init()
		let database: WorkspaceDatabase = try directory.open()
		try database.save(Fixture.organization, preferences: Fixture.preferences)
		try await database.database.write { db in
			try db.execute(sql: "UPDATE preferenceStoreInfo SET value = 'elsewhere' WHERE id = 'storeID'")
		}

		#expect(throws: WorkspaceDatabase.Failure.partialStore) {
			try database.save(Fixture.organization, preferences: Fixture.preferences)
		}
	}

	@Test
	internal func aPreferencesFileFromAnotherStoreIsAPartialStore() async throws {
		let first: TemporaryDirectory = try .init()
		let second: TemporaryDirectory = try .init()
		try first.open().save(Fixture.organization, preferences: Fixture.preferences)
		try second.open().save(Fixture.organization, preferences: Fixture.preferences)
		let name: String = WorkspaceDatabase.preferencesFileName
		try FileManager.default.removeItem(at: first.url.appendingPathComponent(name))
		try FileManager.default.copyItem(at: second.url.appendingPathComponent(name), to: first.url.appendingPathComponent(name))

		#expect(throws: WorkspaceDatabase.Failure.partialStore) { try first.open().load() }
	}

	// MARK: - Migration

	@Test
	internal func migrationRecordsItsSourceAndRunsOnce() async throws {
		let directory: TemporaryDirectory = try .init()
		let database: WorkspaceDatabase = try directory.open()
		try database.migrate(
			organization: Fixture.organization,
			preferences: Fixture.preferences,
			fromWorkspaceVersion: 2,
			sourceRevision: 41
		)

		let snapshot: WorkspaceDatabase.Snapshot? = try directory.open().load()
		#expect(snapshot?.migratedFromWorkspaceVersion == 2)
		expectNoDifference(snapshot?.organization, Fixture.organization)
		let sourceRevision: String? = try await database.database.read { db in
			try StoreInfoRecord.find(StoreInfoKey.sourceRevision).fetchOne(db)?.value
		}
		#expect(sourceRevision == "41")

		#expect(throws: WorkspaceDatabase.Failure.alreadyInitialized) {
			try database.migrate(
				organization: Fixture.organization,
				preferences: Fixture.preferences,
				fromWorkspaceVersion: 4,
				sourceRevision: 0
			)
		}
	}

	@Test
	internal func aFailedMigrationLeavesTheStoreEmpty() async throws {
		let directory: TemporaryDirectory = try .init()
		let database: WorkspaceDatabase = try directory.open()

		// The last table a migration writes refuses its rows, after every other row went in.
		try await database.database.write { db in
			try db.execute(sql: "CREATE TEMPORARY TRIGGER refuse BEFORE INSERT ON localPreference BEGIN SELECT RAISE(ABORT, 'refused'); END")
		}

		#expect(throws: (any Error).self) {
			try database.migrate(
				organization: Fixture.organization,
				preferences: Fixture.preferences,
				fromWorkspaceVersion: 4,
				sourceRevision: 1
			)
		}
		#expect(try !database.isInitialized)
		let rows: (Int, Int) = try await database.database.read { db in
			(try ProfileRecord.all.fetchCount(db), try PreferenceRecord.all.fetchCount(db))
		}
		#expect(rows == (0, 0))
	}

	// MARK: - Helpers

	private func saved() throws -> (WorkspaceDatabase, BrowserOrganization) {
		let directory: TemporaryDirectory = try .init()
		let database: WorkspaceDatabase = try directory.open()
		try database.save(Fixture.organization, preferences: Fixture.preferences)

		// The store keeps its files open, so the directory outlives this scope through it.
		retained.append(directory)
		return (database, Fixture.organization)
	}

	private let retained: Retained = .init()
}

/// Keeps temporary directories alive for a test's duration.
private final class Retained: @unchecked Sendable {
	private var directories: [TemporaryDirectory] = []

	internal func append(_ directory: TemporaryDirectory) {
		directories.append(directory)
	}
}
