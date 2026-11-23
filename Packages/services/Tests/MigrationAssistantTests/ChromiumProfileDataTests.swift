import BrowserCore
import CustomDump
import Foundation
import SQLite3
import Testing
import _TestSupport
@testable import MigrationAssistant

/// Arc's (and Chrome's) history and extensions (DEV-845). Fixtures are made up and shaped
/// like Chromium's files; no browser data is read.
internal struct ChromiumProfileDataTests {
	private static let localState: String = """
	{"profile": {"info_cache": {
		"Default": {"name": "Personal"},
		"Profile 1": {"name": "Work"},
		"Profile 9": {"name": "__ARC_SYSTEM_PROFILE"}
	}}}
	"""

	private static let sidebar: String = """
	{"sidebar": {"containers": [{"global": {}}, {
		"topAppsContainerIDs": [],
		"spaces": ["s1", {
			"id": "s1", "title": "Home",
			"profile": {"default": true},
			"containerIDs": ["pinned", "s1-pinned"]
		}],
		"items": [
			"s1-pinned", {"id": "s1-pinned", "data": {"itemContainer": {}}, "childrenIds": ["t1"]},
			"t1", {"id": "t1", "data": {"tab": {"savedTitle": "News", "savedURL": "https://news.example.org"}}, "childrenIds": []}
		]
	}]}}
	"""

	/// 1 January 2026 00:00:00 UTC in Chromium's microseconds since 1601.
	private static let newYear: Int64 = (1_767_225_600 + 11_644_473_600) * 1_000_000

	private static let preferences: String = """
	{"extensions": {"settings": {
		"aaaabbbbccccddddeeeeffffgggghhhh": {
			"location": 1, "from_webstore": true,
			"manifest": {"name": "Ad Calm", "version": "1.2.3"}
		},
		"bbbbccccddddeeeeffffgggghhhhiiii": {
			"location": 4,
			"manifest": {"name": "My Tool", "version": "0.1"}
		},
		"ccccddddeeeeffffgggghhhhiiiijjjj": {
			"location": 5,
			"manifest": {"name": "Arc Internals", "version": "1"}
		},
		"ddddeeeeffffgggghhhhiiiijjjjkkkk": {
			"location": 1, "from_webstore": true, "was_installed_by_default": true,
			"manifest": {"name": "Docs Offline", "version": "1"}
		},
		"eeeeffffgggghhhhiiiijjjjkkkkllll": {
			"location": 1,
			"manifest": {"name": "__MSG_appName__", "version": "2.0", "default_locale": "en"}
		},
		"not-an-id": {"location": 1, "manifest": {"name": "Broken"}}
	}}}
	"""

	/// Chromium keeps the protected half here: the creation flags say it's from the store.
	private static let securePreferences: String = """
	{"extensions": {"settings": {
		"eeeeffffgggghhhhiiiijjjjkkkkllll": {"creation_flags": 9},
		"ffffgggghhhhiiiijjjjkkkkllllmmmm": {"location": 10, "manifest": {"name": "Hidden", "version": "1"}}
	}}}
	"""

	@Test
	internal func chromiumTimestampsCountMicrosecondsFrom1601() {
		#expect(ChromiumHistory.date(microsecondsSince1601: Self.newYear) == Date(timeIntervalSince1970: 1_767_225_600))
		#expect(ChromiumHistory.date(microsecondsSince1601: 0) == nil)
		#expect(ChromiumHistory.date(microsecondsSince1601: -5) == nil)
	}

	@Test
	internal func historyReadsVisitedPagesNewestFirstAndLeavesHiddenOnesOut() throws {
		let folder = try Self.temporaryFolder()
		defer { try? FileManager.default.removeItem(at: folder) }

		let url = folder.appending(path: "History")
		try Self.writeHistory(to: url)
		let profile: MigrationSourceProfile = .init(id: "Default", name: "Personal")
		let records = try FirefoxPlaces.withCopy(of: url, logSuffixes: ["-journal", "-wal"]) {
			try ChromiumHistory.records($0, profile: profile)
		}

		expectNoDifference(
			records,
			[
				.init(
					sourceItemID: "history:Default/https://b.example.org/",
					category: .history,
					title: "B",
					url: "https://b.example.org/",
					profile: profile,
					lastVisited: Date(timeIntervalSince1970: 1_767_225_660),
					visitCount: 1,
					typedCount: 0
				),
				.init(
					sourceItemID: "history:Default/https://a.example.org/",
					category: .history,
					title: "A",
					url: "https://a.example.org/",
					profile: profile,
					lastVisited: Date(timeIntervalSince1970: 1_767_225_600),
					// Visit and typed counts seed the command bar's ranking (DEV-1015).
					visitCount: 3,
					typedCount: 2
				),
			]
		)
	}

	@Test
	internal func historyWithoutItsTableIsEmpty() throws {
		let folder = try Self.temporaryFolder()
		defer { try? FileManager.default.removeItem(at: folder) }

		let url = folder.appending(path: "History")
		let database = try SQLiteDatabase(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
		try database.execute("CREATE TABLE meta (key TEXT, value TEXT);")
		#expect(try ChromiumHistory.records(database, profile: .init(id: "Default", name: "Personal")).isEmpty)
	}

	@Test
	internal func extensionsAreListedWithoutTheBrowsersOwnOrDefaultOnes() {
		let profile: MigrationSourceProfile = .init(id: "Default", name: "Personal")
		let listed = ChromiumExtensionSettings.extensions(
			preferences: Data(Self.preferences.utf8),
			securePreferences: Data(Self.securePreferences.utf8),
			profile: profile,
			localizedName: { id, version, key, locale in
				id == "eeeeffffgggghhhhiiiijjjjkkkkllll" && version == "2.0" && key == "appName" && locale == "en"
				? "Reader"
				: nil
			}
		)

		expectNoDifference(
			listed,
			[
				.init(id: "aaaabbbbccccddddeeeeffffgggghhhh", name: "Ad Calm", fromWebStore: true, version: "1.2.3", profile: profile),
				.init(id: "bbbbccccddddeeeeffffgggghhhhiiii", name: "My Tool", fromWebStore: false, version: "0.1", profile: profile),
				.init(id: "eeeeffffgggghhhhiiiijjjjkkkkllll", name: "Reader", fromWebStore: true, version: "2.0", profile: profile),
			]
		)
		#expect(listed.map(\.installsFromStore) == [true, false, true])
	}

	@Test
	internal func aPlaceholderNameComesFromTheExtensionsMessages() {
		#expect(ChromiumExtensionSettings.messageKey("__MSG_appName__") == "appName")
		#expect(ChromiumExtensionSettings.messageKey("Plain") == nil)
		let messages = Data(#"{"APPNAME": {"message": " Reader "}}"#.utf8)
		#expect(ChromiumExtensionSettings.message("appName", in: messages) == "Reader")
		#expect(ChromiumExtensionSettings.message("other", in: messages) == nil)
	}

	@Test
	internal func unreadablePreferencesListNothing() {
		let listed = ChromiumExtensionSettings.extensions(
			preferences: Data("not json".utf8),
			securePreferences: nil,
			profile: .init(id: "Default", name: "Personal")
		)
		#expect(listed.isEmpty)
	}

	@Test
	internal func arcOffersHistoryAndExtensionsPerProfileWithoutItsSystemProfile() async throws {
		let home = try Self.temporaryFolder()
		defer { try? FileManager.default.removeItem(at: home) }

		let arc = home.appending(path: "Library/Application Support/Arc", directoryHint: .isDirectory)
		let userData = arc.appending(path: "User Data", directoryHint: .isDirectory)
		for directory in ["Default", "Profile 1", "Profile 9"] {
			try FileManager.default.createDirectory(
				at: userData.appending(path: directory, directoryHint: .isDirectory),
				withIntermediateDirectories: true
			)
		}
		try Data(Self.sidebar.utf8).write(to: arc.appending(path: "StorableSidebar.json"))
		try Data(Self.localState.utf8).write(to: userData.appending(path: "Local State"))
		try Self.writeHistory(to: userData.appending(path: "Default/History"))
		try Self.writeHistory(to: userData.appending(path: "Profile 9/History"))
		try Data(Self.preferences.utf8).write(to: userData.appending(path: "Profile 1/Preferences"))
		try Data(Self.preferences.utf8).write(to: userData.appending(path: "Profile 9/Preferences"))

		// The placeholder name resolves from the installed extension's own messages.
		let messages = userData.appending(path: "Profile 1/Extensions/eeeeffffgggghhhhiiiijjjjkkkkllll/2.0/_locales/en")
		try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
		try Data(#"{"appName": {"message": "Reader"}}"#.utf8).write(to: messages.appending(path: "messages.json"))

		let adapter = try #require(MigrationBrowserSources.adapters(home: home).first { $0.source.id.rawValue == "arc" })
		#expect(adapter.source.categories == [.favorites, .bookmarks, .openTabs, .history, .extensions])

		let snapshot = try await adapter.snapshot()
		let history = snapshot.records.filter { $0.category == .history }
		expectNoDifference(history.map(\.profile?.id), ["Default", "Default"])

		let extensions: [MigrationIssue.Extension] = snapshot.issues.compactMap { issue in
			guard case let .reinstallManually(value) = issue.reason else { return nil }
			return value
		}
		expectNoDifference(extensions.map(\.profile?.id), ["Profile 1", "Profile 1", "Profile 1"])
		expectNoDifference(extensions.map(\.name), ["Ad Calm", "My Tool", "Reader"])
		#expect(snapshot.issues.allSatisfy { $0.category == .extensions })

		// History and preferences change with every visit while Arc runs; the sidebar's
		// snapshot ID is kept so an import isn't refused for it.
		let sidebarOnly = try ArcSidebar.snapshot(
			sidebar: Data(Self.sidebar.utf8),
			localState: Data(Self.localState.utf8)
		)
		#expect(snapshot.id == sidebarOnly.id)
	}

	@Test
	internal func chromeOffersHistoryButNotExtensions() async throws {
		let home = try Self.temporaryFolder()
		defer { try? FileManager.default.removeItem(at: home) }

		let chrome = home.appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: chrome.appending(path: "Default"), withIntermediateDirectories: true)
		try Data(Self.localState.utf8).write(to: chrome.appending(path: "Local State"))
		try Self.writeHistory(to: chrome.appending(path: "Default/History"))
		try Data(Self.preferences.utf8).write(to: chrome.appending(path: "Default/Preferences"))

		let adapter = try #require(MigrationBrowserSources.adapters(home: home).first { $0.source.id.rawValue == "chrome" })
		#expect(adapter.source.categories.contains(.history))
		#expect(!adapter.source.categories.contains(.extensions))

		let snapshot = try await adapter.snapshot()
		#expect(snapshot.records.count { $0.category == .history } == 2)
		#expect(snapshot.issues.isEmpty)
	}

	@Test
	internal func aPlanMakesTheProfilesStoreExtensionsGoTo() {
		let work: MigrationSourceProfile = .init(id: "Profile 1", name: "Work")
		let preview: MigrationPreview = .init(
			sourceID: .init(rawValue: "arc"),
			snapshotID: "s",
			destination: MigrationFixtures.destination,
			categories: [
				.init(
					category: .extensions,
					issues: [
						.init(
							sourceItemID: "Profile 1/a",
							category: .extensions,
							reason: .reinstallManually(.init(id: "a", name: "A", fromWebStore: true, profile: work))
						),
						.init(
							sourceItemID: "Profile 1/b",
							category: .extensions,
							reason: .reinstallManually(.init(id: "b", name: "B", fromWebStore: true, profile: work))
						),
						.init(
							sourceItemID: "x",
							category: .extensions,
							reason: .reinstallManually(.init(id: "x", name: "X", fromWebStore: false, profile: .init(id: "Default", name: "Personal")))
						),
					]
				),
			]
		)

		expectNoDifference(preview.extensionProfiles, [work])
		let plan: MigrationPlan = .init(id: .init(rawValue: UUID()), preview: preview)
		expectNoDifference(plan.categories, [.extensions])
		expectNoDifference(plan.profiles, [work])
	}

	/// A profile with only store extensions still gets a row in the mapping.
	@Test
	internal func aProfileWithOnlyExtensionsIsOfferedForMapping() async throws {
		let work: MigrationSourceProfile = .init(id: "Profile 1", name: "Work")
		let source: MigrationSource = .init(
			id: .init(rawValue: "arc"),
			kind: .externalBrowser,
			name: "Arc",
			categories: [.extensions]
		)
		let adapter: MigrationSourceAdapter = .init(source: source) {
			.init(
				id: "s",
				records: [],
				issues: [
					.init(
						sourceItemID: "Profile 1/a",
						category: .extensions,
						reason: .reinstallManually(.init(id: "a", name: "A", fromWebStore: true, profile: work))
					),
				]
			)
		}
		let client: MigrationAssistantClient = .running(adapters: [adapter], writer: FixtureDestination().writer)
		let preview = try await client.inspect(source.id, [.extensions], MigrationFixtures.destination)
		expectNoDifference(preview.profiles, [work])
	}

	/// An extension that ships only its default locale's messages, not English, still gets its
	/// name: the lookup reads `_locales/<default_locale>`, not `_locales/Optional("zz")`.
	@Test
	internal func aPlaceholderNameResolvesFromTheExtensionsDefaultLocale() throws {
		let userData = try Self.temporaryFolder()
		defer { try? FileManager.default.removeItem(at: userData) }

		let id: String = "eeeeffffgggghhhhiiiijjjjkkkkllll"
		let preferences: String = """
		{"extensions": {"settings": {
			"\(id)": {
				"location": 1,
				"manifest": {"name": "__MSG_appName__", "version": "2.0", "default_locale": "zz"}
			}
		}}}
		"""
		let profileFolder = userData.appending(path: "Default", directoryHint: .isDirectory)
		let messages = profileFolder.appending(path: "Extensions/\(id)/2.0/_locales/zz", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
		try Data(preferences.utf8).write(to: profileFolder.appending(path: "Preferences"))
		try Data(#"{"appName": {"message": "Lecteur"}}"#.utf8).write(to: messages.appending(path: "messages.json"))

		let snapshot = try MigrationBrowserSources.chromiumProfileData(
			adding: .init(id: "chrome", records: []),
			profiles: [.init(id: "Default", name: "Personal")],
			history: false,
			directory: { userData.appending(path: $0, directoryHint: .isDirectory) }
		)

		let names: [String] = snapshot.issues.compactMap { issue in
			guard case let .reinstallManually(value) = issue.reason else { return nil }
			return value.name
		}
		expectNoDifference(names, ["Lecteur"])
	}

	// MARK: - Fixtures

	private static func temporaryFolder() throws -> URL {
		let folder = FileManager.default.temporaryDirectory
			.appending(path: "arx-chromium-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return folder
	}

	/// Chromium's `urls` table, with a hidden redirect and a page never visited.
	private static func writeHistory(to url: URL) throws {
		let database = try SQLiteDatabase(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
		try database.execute(
			"""
			CREATE TABLE urls (
				id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
				visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
				last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL
			);
			INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES
				('https://a.example.org/', 'A', 3, 2, \(newYear), 0),
				('https://b.example.org/', 'B', 1, 0, \(newYear + 60_000_000), 0),
				('https://redirect.example.org/', 'R', 1, 0, \(newYear + 120_000_000), 1),
				('https://never.example.org/', 'N', 0, 0, 0, 0);
			"""
		)
	}
}
