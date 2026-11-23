import BrowserCore
import BrowserWorkspaceClient
import Foundation
import GRDB
@testable import SQLiteData
import Testing
@testable import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// Preferences groups kept on this Mac (DEV-982): an override row holds this Mac's values, the
/// synced rows stay as other Macs leave them, and syncing again keeps this Mac's or takes iCloud's.
/// Another Mac's change is written into the preferences file here, as its engine writes it.
@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct PreferenceGroupsTests {
	private let profileID: Profile.ID = .init(rawValue: UUID(-1))
	private let spaceID: Space.ID = .init(rawValue: UUID(-2))

	private var organization: BrowserOrganization {
		.init(
			profiles: [.init(id: profileID, name: "Personal")],
			legacyProfileID: profileID,
			spaces: [.init(id: spaceID, profileID: profileID, name: "Home")]
		)
	}

	private func preferences(
		keyword: String,
		theme: AppTheme = .system
	) -> BrowserPreferences {
		var preferences: BrowserPreferences = .init()
		preferences.searchShortcuts = [
			.init(name: keyword, keyword: keyword, template: "https://\(keyword).example/?q={query}"),
		]
		preferences.appTheme = theme
		return preferences
	}

	private func temporaryDirectory() throws -> URL {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("PreferenceGroupsTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	/// A store holding `keyword`, with search shortcuts kept on this Mac.
	private func storeKeepingSearchShortcuts(
		in directory: URL,
		shared: String = "shared",
		mine: String = "mine"
	) throws -> WorkspaceDatabase {
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try store.save(organization, preferences: preferences(keyword: shared))
		try store.setPreferenceGroup(
			.searchShortcutsGroup,
			syncs: false,
			keepingThisMac: true,
			organization: organization,
			preferences: preferences(keyword: shared)
		)
		try store.save(organization, preferences: preferences(keyword: mine))
		return store
	}

	/// Another Mac's search shortcut, written as its engine writes it.
	private func receive(
		_ keyword: String,
		in store: WorkspaceDatabase
	) throws {
		try #require(store.preferencesDatabase).write { db in
			try SearchShortcutRecord.upsert {
				SearchShortcutRecord(
					id: keyword,
					keyword: keyword,
					name: keyword,
					template: "https://\(keyword).example/?q={query}",
					position: "z"
				)
			}
			.execute(db)
		}
	}

	private func syncedKeywords(_ store: WorkspaceDatabase) throws -> [String] {
		try #require(store.preferencesDatabase).read { db in
			try SearchShortcutRecord.order(by: \.id).fetchAll(db).map(\.keyword)
		}
	}

	@Test
	func aGroupKeptOnThisMacShowsItsValuesAndLeavesTheSyncedRows() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try storeKeepingSearchShortcuts(in: directory)

		#expect(store.localPreferenceGroups == [.searchShortcutsGroup])
		#expect(try syncedKeywords(store) == ["shared"])
		#expect(try store.load()?.preferences.searchShortcuts.map(\.keyword) == ["mine"])

		// Another group still syncs.
		try store.save(organization, preferences: preferences(keyword: "mine", theme: .dark))
		let appearance: String? = try #require(store.preferencesDatabase).read { db in
			try PreferenceRecord.find(PreferenceDomain.appearance.rawValue).fetchOne(db)?.value
		}
		#expect(appearance?.contains("dark") == true)
	}

	@Test
	func anotherMacsChangeToAKeptGroupArrivesWithoutShowing() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try storeKeepingSearchShortcuts(in: directory)

		try receive("remote", in: store)

		// A save from before the change was read doesn't undo it.
		try store.save(organization, preferences: preferences(keyword: "mine", theme: .light))
		#expect(try syncedKeywords(store) == ["remote", "shared"])

		let loaded: BrowserPreferences = try #require(try store.load()?.preferences)
		#expect(loaded.searchShortcuts.map(\.keyword) == ["mine"])
		try store.save(organization, preferences: loaded)
		#expect(try syncedKeywords(store) == ["remote", "shared"])
	}

	@Test
	func syncingAgainKeepingThisMacsWritesThemOverTheSyncedRows() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try storeKeepingSearchShortcuts(in: directory)
		try receive("remote", in: store)

		let saved: BrowserPreferences = try store.setPreferenceGroup(
			.searchShortcutsGroup,
			syncs: true,
			keepingThisMac: true,
			organization: organization,
			preferences: preferences(keyword: "mine")
		)

		#expect(saved.searchShortcuts.map(\.keyword) == ["mine"])
		#expect(store.localPreferenceGroups.isEmpty)
		// The synced rows the store last read are replaced; one that arrived since stays for the next
		// reload to read, as any fetch's row does.
		#expect(try syncedKeywords(store) == ["mine", "remote"])
		let overrides: Int = try #require(store.preferencesDatabase).read { db in
			try LocalPreferenceRecord.where { $0.id.like("override.%") }.fetchCount(db)
		}
		#expect(overrides == 0)
	}

	@Test
	func syncingAgainWithICloudsValuesTakesTheSyncedRows() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try storeKeepingSearchShortcuts(in: directory)
		try receive("remote", in: store)

		let saved: BrowserPreferences = try store.setPreferenceGroup(
			.searchShortcutsGroup,
			syncs: true,
			keepingThisMac: false,
			organization: organization,
			preferences: preferences(keyword: "mine", theme: .dark)
		)

		#expect(saved.searchShortcuts.map(\.keyword) == ["shared", "remote"])
		// The other groups keep this Mac's edit.
		#expect(saved.appTheme == .dark)
		#expect(try syncedKeywords(store) == ["remote", "shared"])
		#expect(try store.load()?.preferences == saved)
	}

	@Test
	func aSaveThatReadTheStoreBeforeTheChoiceStops() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		try store.save(organization, preferences: preferences(keyword: "shared"))

		// Another process's store, which read the workspace before the choice.
		let other: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		_ = try other.load()

		try store.setPreferenceGroup(
			.searchShortcutsGroup,
			syncs: false,
			keepingThisMac: true,
			organization: organization,
			preferences: preferences(keyword: "shared")
		)

		#expect(throws: WorkspaceDatabase.Failure.changedOnDisk) {
			try other.save(organization, preferences: preferences(keyword: "theirs"))
		}

		// Read again, it keeps the group on this Mac too.
		_ = try other.load()
		#expect(other.localPreferenceGroups == [.searchShortcutsGroup])
		try other.save(organization, preferences: preferences(keyword: "theirs"))
		#expect(try syncedKeywords(store) == ["shared"])
	}

	@Test
	func theChoiceLastsAcrossLaunches() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		_ = try storeKeepingSearchShortcuts(in: directory)

		let relaunched: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		#expect(try relaunched.load()?.preferences.searchShortcuts.map(\.keyword) == ["mine"])
		#expect(relaunched.localPreferenceGroups == [.searchShortcutsGroup])
	}

	@Test
	func repairLeavesAKeptGroupsSyncedRows() throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try storeKeepingSearchShortcuts(in: directory)
		let writer: DatabaseQueue = try #require(store.preferencesDatabase)

		// Two keywords differing only in case, as rows from before the keyword became the ID.
		try writer.write { db in
			try SearchShortcutRecord.insert {
				SearchShortcutRecord(id: "Shared-old", keyword: "SHARED", name: "Old", template: "https://old.example/?q={query}", position: "y")
			}
			.execute(db)
		}

		let kept: WorkspaceRepair.Summary = try writer.write { db in try WorkspaceRepair.repairPreferences(db) }
		#expect(kept.disabledSearchShortcuts.isEmpty)

		try store.setPreferenceGroup(
			.searchShortcutsGroup,
			syncs: true,
			keepingThisMac: false,
			organization: organization,
			preferences: preferences(keyword: "mine")
		)
		let synced: WorkspaceRepair.Summary = try writer.write { db in try WorkspaceRepair.repairPreferences(db) }
		#expect(!synced.disabledSearchShortcuts.isEmpty)
	}

	@Test
	func aKeptGroupIsRepairedBeforeItTakesICloudsValues() async throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let cloud: TestCloud = .init()
		let store: WorkspaceDatabase = try storeKeepingSearchShortcuts(in: directory)
		let writer: DatabaseQueue = try #require(store.preferencesDatabase)
		let sync: WorkspaceSync = try WorkspaceSync(
			organization: store.database,
			preferences: writer,
			settings: SyncSettingsStore(directory: directory),
			cloud: CloudAccess(
				account: { .available("account-a") },
				deleteZone: { try cloud.deleteZone($0) },
				placements: { try cloud.placements($0) },
				recordValues: { try cloud.recordValues($0, $1) },
				zoneRecords: { try cloud.zoneRecords($0, $1) }
			),
			makeEngine: cloud.makeEngine()
		)
		await sync.setEnabled(true)

		// A keyword differing only in case arrived while the group was kept here, and iCloud has it.
		try await writer.write { db in
			try SearchShortcutRecord.insert {
				SearchShortcutRecord(id: "shared-old", keyword: "SHARED", name: "Old", template: "https://old.example/?q={query}", position: "y")
			}
			.execute(db)
		}
		try await sync.engine(.preferences)?.sendChanges()

		#expect(try await sync.repair(.preferences).disabledSearchShortcuts.isEmpty)
		#expect(throws: (any Error).self) {
			try store.setPreferenceGroup(
				.searchShortcutsGroup,
				syncs: true,
				keepingThisMac: false,
				organization: organization,
				preferences: preferences(keyword: "mine"),
				validate: { try $0.validate() }
			)
		}
		#expect(store.localPreferenceGroups == [.searchShortcutsGroup])

		await sync.repairBeforeSyncing(.searchShortcutsGroup)
		let saved: BrowserPreferences = try store.setPreferenceGroup(
			.searchShortcutsGroup,
			syncs: true,
			keepingThisMac: false,
			organization: organization,
			preferences: preferences(keyword: "mine"),
			validate: { try $0.validate() }
		)
		#expect(saved.searchShortcuts.filter(\.isEnabled).map { $0.keyword.lowercased() } == ["shared"])
		#expect(store.localPreferenceGroups.isEmpty)
	}

	@Test
	func theClientRejectsSavesFromBeforeTheChoice() async throws {
		let directory: URL = try temporaryDirectory()
		defer { TestFolders.removeAtExit(directory) }
		let client: BrowserWorkspaceClient = .init(
			file: directory.appendingPathComponent("arx-workspace.json"),
			storage: .sqlite,
			separatePreferencesConnection: true
		)
		_ = try client.loadWithRecovery()
		try client.save(organization, preferences: preferences(keyword: "shared"))
		let older: BrowserWorkspaceClient.SaveTicket = client.reserveSaveTicket()

		let saved: BrowserPreferences = try await client.setPreferenceGroup(
			.searchShortcutsGroup,
			syncs: false,
			keepingThisMac: true,
			organization: organization,
			preferences: preferences(keyword: "mine"),
			ticket: client.reserveSaveTicket()
		)

		#expect(saved.searchShortcuts.map(\.keyword) == ["mine"])
		#expect(client.savedPreferences == saved)
		#expect(try await !client.save(organization, preferences: preferences(keyword: "stale"), ticket: older))
		#expect(client.workspaceDatabase?.localPreferenceGroups == [.searchShortcutsGroup])
	}
}

extension PreferenceGroup {
	/// The group the tests keep on this Mac.
	fileprivate static let searchShortcutsGroup: Self = .searchEngines
}
