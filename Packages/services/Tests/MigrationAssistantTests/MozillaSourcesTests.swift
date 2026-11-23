import CustomDump
import Foundation
import SQLite3
import Testing
@testable import MigrationAssistant

/// Firefox and Zen fixtures are made here: `places.sqlite` from Firefox's documented
/// schema (`toolkit/components/places/Database.cpp`, trimmed to the columns read), Zen's
/// older tables from its `ZenWorkspacesStorage` and `ZenPinnedTabsStorage`, and session
/// files in the `mozLz4` container. No real browser profile is read.
internal struct MozillaSourcesTests {
	// MARK: - Fixtures

	private static let placesSchema: String = """
	CREATE TABLE moz_places (
		id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR,
		visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL,
		frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT
	);
	CREATE TABLE moz_bookmarks (
		id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER,
		title LONGVARCHAR, keyword_id INTEGER, folder_type TEXT, dateAdded INTEGER, lastModified INTEGER,
		guid TEXT, syncStatus INTEGER NOT NULL DEFAULT 0, syncChangeCounter INTEGER NOT NULL DEFAULT 1
	);
	INSERT INTO moz_bookmarks (id, type, parent, position, title, guid) VALUES
		(1, 2, 0, 0, '', 'root________'),
		(2, 2, 1, 0, 'menu', 'menu________'),
		(3, 2, 1, 1, 'toolbar', 'toolbar_____'),
		(4, 2, 1, 2, 'tags', 'tags________'),
		(5, 2, 1, 3, 'unfiled', 'unfiled_____'),
		(6, 2, 1, 4, 'mobile', 'mobile______');
	"""

	private static let bookmarks: String = """
	INSERT INTO moz_places (id, url, title, guid) VALUES
		(1, 'https://swift.org/', 'Swift.org', 'p1'),
		(2, 'https://developer.apple.com/', 'Apple Developer', 'p2'),
		(3, 'https://news.example.org/', 'News', 'p3'),
		(4, 'place:sort=8&maxResults=10', 'Most Visited', 'p4');
	INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
		(10, 1, 4, 3, 0, 'Most Visited', 'smart'),
		(11, 1, 1, 3, 1, 'Swift', 'swift'),
		(12, 2, NULL, 3, 2, 'Docs', 'docs'),
		(13, 1, 2, 12, 0, '', 'apple'),
		(14, 3, NULL, 3, 3, '', 'separator'),
		(15, 2, NULL, 3, 4, 'Blank', 'blank'),
		(16, 1, 3, 2, 0, 'News', 'news'),
		(17, 2, NULL, 4, 0, 'reading', 'tag');
	"""

	private static func makeHome() -> URL {
		FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
	}

	/// Writes `profiles.ini` and one profile with the given places statements.
	@discardableResult
	private static func makeProfile(
		home: URL,
		folder: String,
		sql: String,
		files: [String: Data] = [:]
	) throws -> URL {
		let root = home.appending(path: "Library/Application Support/\(folder)", directoryHint: .isDirectory)
		let profile = root.appending(path: "Profiles/abcd.default-release", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
		try """
		[Install4F96D1932A9F858E]
		Default=Profiles/abcd.default-release
		Locked=1

		[Profile0]
		Name=default-release
		IsRelative=1
		Path=Profiles/abcd.default-release

		[General]
		StartWithLastProfile=1
		Version=2
		""".write(to: root.appending(path: "profiles.ini"), atomically: true, encoding: .utf8)
		let database = try SQLiteDatabase(
			profile.appending(path: "places.sqlite"),
			flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
		)
		try database.execute(placesSchema + sql)
		for (path, data) in files {
			let file = profile.appending(path: path)
			try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
			try data.write(to: file)
		}
		return profile
	}

	private static func session(_ json: String) -> Data {
		FirefoxSession.compress(Data(json.utf8))
	}

	private static func snapshot(
		_ browser: MigrationBrowserSources.MozillaBrowser,
		home: URL
	) async throws -> MigrationSnapshot {
		let adapter = try #require(
			MigrationBrowserSources.adapters(home: home, includesUnchecked: true)
				.first { $0.source.id.rawValue == browser.rawValue }
		)
		return try await adapter.snapshot()
	}

	// MARK: - Container and profiles

	@Test
	internal func mozLz4RoundTripsAndRejectsOtherFiles() throws {
		let json = Data(#"{"windows": [], "text": "repeated repeated repeated repeated"}"#.utf8)
		expectNoDifference(try FirefoxSession.decompress(FirefoxSession.compress(json)), json)
		#expect(throws: MigrationFailure.self) { try FirefoxSession.decompress(json) }
		var oversized = FirefoxSession.magic
		withUnsafeBytes(of: UInt32.max.littleEndian) { oversized.append(contentsOf: $0) }
		#expect(throws: MigrationFailure.self) { try FirefoxSession.decompress(oversized) }
	}

	@Test
	internal func profilesListTheInstallsDefaultFirst() {
		let root = URL(filePath: "/Firefox", directoryHint: .isDirectory)
		let ini = """
		[Profile1]
		Name=Work
		IsRelative=0
		Path=/Volumes/Data/work

		[Profile0]
		Name=default-release
		IsRelative=1
		Path=Profiles/abcd.default-release
		Default=1

		[Install308046B0AF4A39CB]
		Default=Profiles/abcd.default-release
		"""

		let profiles = FirefoxPlaces.profiles(ini: ini, root: root)

		expectNoDifference(profiles.map(\.name), ["default-release", "Work"])
		expectNoDifference(profiles.map { $0.directory.path(percentEncoded: false) }, [
			"/Firefox/Profiles/abcd.default-release/",
			"/Volumes/Data/work/",
		])
	}

	// MARK: - Firefox

	@Test
	internal func firefoxReadsBookmarksAndOpenTabsFromCopies() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let recovery = Self.session("""
		{"windows": [
			{"tabs": [
				{"entries": [{"url": "https://one.example.org/", "title": "One"}, {"url": "https://two.example.org/", "title": "Two"}], "index": 1, "pinned": true},
				{"entries": [{"url": "https://hidden.example.org/", "title": "Hidden"}], "index": 1, "hidden": true},
				{"entries": [], "index": 0}
			]},
			{"tabs": [
				{"entries": [{"url": "https://one.example.org/", "title": "One again"}], "index": 1}
			]}
		]}
		""")
		let profile = try Self.makeProfile(
			home: home,
			folder: "Firefox",
			sql: Self.bookmarks,
			files: ["sessionstore-backups/recovery.jsonlz4": recovery]
		)

		// A browser that's running holds the database open with recent changes in its log.
		let running = try SQLiteDatabase(profile.appending(path: "places.sqlite"))
		try running.execute("""
		PRAGMA journal_mode = WAL;
		PRAGMA wal_autocheckpoint = 0;
		INSERT INTO moz_places (id, url, title, guid) VALUES (5, 'https://recent.example.org/', 'Recent', 'p5');
		INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (18, 1, 5, 5, 0, 'Recent', 'recent');
		""")

		let snapshot = try await Self.snapshot(.firefox, home: home)
		withExtendedLifetime(running) {}

		let tabs = snapshot.records.filter { $0.kind == .tab }
		expectNoDifference(tabs.filter { $0.category == .bookmarks }.map(\.title), [
			"Most Visited", "Swift", "Apple Developer", "News", "Recent",
		])
		expectNoDifference(tabs.filter { $0.category == .bookmarks }.map { $0.folders.map(\.name) }, [
			[], [], ["Docs"], ["Bookmarks Menu"], ["Other Bookmarks"],
		])
		expectNoDifference(tabs.filter { $0.category == .openTabs }.map(\.title), ["One", "One again"])
		expectNoDifference(tabs.filter { $0.category == .openTabs }.map(\.sourceItemID), [
			"Profiles/abcd.default-release/open/https://one.example.org/#0",
			"Profiles/abcd.default-release/open/https://one.example.org/#1",
		])
		expectNoDifference(Set(tabs.compactMap { $0.space?.name }), ["default-release"])
		expectNoDifference(snapshot.records.filter { $0.kind == .folder }.map { $0.folders.last?.name }, ["Blank"])

		// `place:` queries aren't web pages; validation reports them.
		#expect(throws: MigrationIssue.self) {
			try tabs[0].validated(from: .init(rawValue: "firefox")).get()
		}
	}

	@Test
	internal func firefoxIsOfferedOnlyWithUncheckedSources() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		try Self.makeProfile(home: home, folder: "Firefox", sql: "")
		try Self.makeProfile(home: home, folder: "zen", sql: "")

		expectNoDifference(MigrationBrowserSources.adapters(home: home).map(\.source.id.rawValue), [])
		expectNoDifference(MigrationBrowserSources.unsupportedBrowsers(home: home).map(\.id), ["safari", "firefox", "zen"])
		let unchecked = MigrationBrowserSources.adapters(home: home, includesUnchecked: true)
		expectNoDifference(unchecked.map(\.source.id.rawValue), ["firefox", "zen"])
		expectNoDifference(unchecked.map(\.source.categories), [
			[.bookmarks, .openTabs, .history],
			[.favorites, .bookmarks, .openTabs, .history],
		])
		expectNoDifference(MigrationBrowserSources.unsupportedBrowsers(home: home, includesUnchecked: true), [])
	}

	@Test
	internal func chromiumOpenTabsAreReadOnlyWithUncheckedSources() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let chrome = home.appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
		let sessions = chrome.appending(path: "Default/Sessions", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
		try Data(#"{"profile": {"info_cache": {"Default": {"name": "Personal"}}}}"#.utf8)
			.write(to: chrome.appending(path: "Local State"))
		var file: SessionFileWriter = .init()
		file.windowType(1, type: 0)
		file.tab(1, window: 1, index: 0)
		file.navigation(tab: 1, index: 0, url: "https://open.example.org/", title: "Open")
		file.marker()
		try file.data.write(to: sessions.appending(path: "Session_13400000000000000"))

		let checked = try #require(MigrationBrowserSources.adapters(home: home).first)
		expectNoDifference(checked.source.categories, [.bookmarks, .history])
		let checkedTabs = try await checked.snapshot().records.filter { $0.kind == .tab }
		expectNoDifference(checkedTabs, [])

		let unchecked = try #require(MigrationBrowserSources.adapters(home: home, includesUnchecked: true).first)
		expectNoDifference(unchecked.source.categories, [.bookmarks, .openTabs, .history])
		let uncheckedTabs = try await unchecked.snapshot().records.filter { $0.kind == .tab }
		expectNoDifference(uncheckedTabs.map(\.title), ["Open"])
	}

	// MARK: - Zen

	@Test
	internal func zenSpacesEssentialsPinnedTabsAndFoldersComeFromItsSessionFile() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let sessions = Self.session("""
		{"spaces": [
			{"uuid": "{home}", "name": "Home", "icon": "🏠"},
			{"uuid": "{work}", "name": "Work", "icon": "chrome://browser/skin/zen-icons/selectable/briefcase.svg"}
		],
		"folders": [
			{"id": "f-outer", "name": "Reading", "pinned": true, "workspaceId": "{home}", "collapsed": true},
			{"id": "f-inner", "name": "Later", "pinned": true, "workspaceId": "{home}", "parentId": "f-outer"},
			{"id": "f-empty", "name": "Nothing", "pinned": true, "workspaceId": "{work}", "prevSiblingInfo": {"type": "tab", "id": "p2"}},
			{"id": "f-open", "name": "Unpinned", "workspaceId": "{work}", "prevSiblingInfo": {"type": "start"}}
		],
		"tabs": [
			{"entries": [{"url": "https://mail.example.org/", "title": "Mail"}], "index": 1, "pinned": true, "zenEssential": true, "zenSyncId": "e1", "zenWorkspace": "{home}"},
			{"entries": [{"url": "https://swift.org/", "title": "Swift"}], "index": 1, "pinned": true, "zenSyncId": "p1", "zenWorkspace": "{home}", "groupId": "f-inner", "zenStaticLabel": "Language"},
			{"entries": [{"url": "https://tracker.example.org/", "title": "Tracker"}, {"url": "https://tracker.example.org/issue/1", "title": "Issue 1"}], "index": 2, "pinned": true, "zenSyncId": "p2", "zenWorkspace": "{work}", "_zenPinnedInitialState": {"entry": {"url": "https://tracker.example.org/", "title": "Tracker"}}},
			{"entries": [{"url": "https://open.example.org/", "title": "Open"}], "index": 1, "zenSyncId": "o1", "zenWorkspace": "{work}", "groupId": "f-open"},
			{"entries": [{"url": "https://glance.example.org/", "title": "Glance"}], "index": 1, "zenIsGlance": true, "zenWorkspace": "{work}"},
			{"entries": [{"url": "about:blank", "title": ""}], "index": 1, "zenIsEmpty": true, "zenWorkspace": "{work}"}
		]}
		""")

		// Synced windows are in Zen's own file; an unsynced one is only in Firefox's.
		let recovery = Self.session("""
		{"windows": [
			{"tabs": [{"entries": [{"url": "https://open.example.org/", "title": "Open"}], "index": 1}]},
			{"isZenUnsynced": true, "tabs": [{"entries": [{"url": "https://private.example.org/", "title": "Unsynced"}], "index": 1, "pinned": true}]}
		]}
		""")
		try Self.makeProfile(
			home: home,
			folder: "zen",
			sql: Self.bookmarks,
			files: ["zen-sessions.jsonlz4": sessions, "sessionstore-backups/recovery.jsonlz4": recovery]
		)

		let snapshot = try await Self.snapshot(.zen, home: home)

		expectNoDifference(
			snapshot.records.filter { $0.kind == .space }.compactMap { $0.space?.name },
			["Home", "Work", "Bookmarks"]
		)
		expectNoDifference(
			snapshot.records.filter { $0.kind == .space }.map { $0.space?.icon },
			["🏠", nil, nil]
		)
		let tabs = snapshot.records.filter { $0.kind == .tab && $0.space?.name != "Bookmarks" }
		expectNoDifference(tabs.map(\.title), ["Mail", "Swift", "Tracker", "Open", "Unsynced"])
		expectNoDifference(tabs.map(\.category), [.favorites, .bookmarks, .bookmarks, .openTabs, .openTabs])
		expectNoDifference(tabs[0].profile?.name, "default-release")
		expectNoDifference(tabs[1].customTitle, "Language")

		// The pin returns to where it was pinned and remembers where it is now.
		expectNoDifference(tabs[2].url, "https://tracker.example.org/")
		expectNoDifference(tabs[2].currentURL, "https://tracker.example.org/issue/1")
		expectNoDifference(tabs[1].currentURL, nil)
		expectNoDifference(tabs[1].folders.map(\.name), ["Reading", "Later"])
		expectNoDifference(tabs[1].folders.map(\.isExpanded), [false, true])
		expectNoDifference(tabs.map { $0.space?.name }, [nil, "Home", "Work", "Work", nil])
		expectNoDifference(
			snapshot.records.filter { $0.kind == .folder }.map { $0.folders.map(\.name) },
			[["Unpinned"], ["Nothing"], ["Blank"]]
		)

		// The empty folder stays after the pin it followed; a folder of open tabs, which
		// don't keep folders, is still recreated.
		let work = snapshot.records.filter { $0.space?.name == "Work" && $0.kind != .space }
		expectNoDifference(work.map { $0.kind == .folder ? $0.folders.last?.name ?? "" : $0.title }, [
			"Unpinned", "Tracker", "Nothing", "Open",
		])
		let bookmarks = snapshot.records.filter { $0.kind == .tab && $0.space?.name == "Bookmarks" }
		expectNoDifference(bookmarks.count, 4)
	}

	@Test
	internal func aChainOfEmptyZenFoldersStaysBetweenItsTabs() {
		let tabs: [FirefoxSession.ZenTab] = ["a", "b"].enumerated().map { offset, id in
			.init(id: id, place: .pinned, spaceID: "s", url: "https://\(id).example.org/", title: id.uppercased(), order: Double(offset))
		}
		let folders: [FirefoxSession.ZenFolder] = [
			.init(id: "f4", name: "F4", spaceID: "s", previousSibling: .folder("f3")),
			.init(id: "f1", name: "F1", spaceID: "s", previousSibling: .tab("a")),
			.init(id: "f3", name: "F3", spaceID: "s", previousSibling: .folder("f2")),
			.init(id: "f2", name: "F2", spaceID: "s", previousSibling: .folder("f1")),
		]
		let layout: FirefoxSession.ZenLayout = .init(spaces: [.init(id: "s", name: "Space")], tabs: tabs, folders: folders)

		let records = FirefoxSession.zenRecords(layout, profile: .init(id: "p", name: "Profile"))

		expectNoDifference(
			records.filter { $0.kind != .space }.map { $0.kind == .folder ? $0.folders.last?.name ?? "" : $0.title },
			["A", "F1", "F2", "F3", "F4", "B"]
		)
	}

	@Test
	internal func anEmptyFolderAtTheStartOfItsParentStaysInsideItsPlace() {
		let tabs: [FirefoxSession.ZenTab] = [
			.init(id: "a", place: .pinned, spaceID: "s", url: "https://a.example.org/", title: "A", order: 0),
			.init(id: "b", place: .pinned, spaceID: "s", url: "https://b.example.org/", title: "B", folderID: "f", order: 1),
		]
		let folders: [FirefoxSession.ZenFolder] = [
			.init(id: "e", name: "E", parentID: "f", spaceID: "s", previousSibling: .start),
			.init(id: "f", name: "F", spaceID: "s", previousSibling: .tab("a")),
		]
		let layout: FirefoxSession.ZenLayout = .init(spaces: [.init(id: "s", name: "Space")], tabs: tabs, folders: folders)

		let records = FirefoxSession.zenRecords(layout, profile: .init(id: "p", name: "Profile"))

		expectNoDifference(
			records.filter { $0.kind != .space }.map { $0.kind == .folder ? $0.folders.map(\.name).joined(separator: "/") : $0.title },
			["A", "F/E", "B"]
		)
	}

	/// DEV-651: a folder whose pins are all in a subfolder still ends after them, so an empty
	/// folder that follows it isn't placed inside its tabs.
	@Test
	internal func anEmptyFolderAfterOneWithOnlyNestedPinsFollowsThem() {
		let tabs: [FirefoxSession.ZenTab] = [
			.init(id: "a", place: .pinned, spaceID: "s", url: "https://a.example.org/", title: "A", order: 0),
			.init(id: "n", place: .pinned, spaceID: "s", url: "https://n.example.org/", title: "N", folderID: "inner", order: 1),
			.init(id: "b", place: .pinned, spaceID: "s", url: "https://b.example.org/", title: "B", order: 2),
		]
		let folders: [FirefoxSession.ZenFolder] = [
			.init(id: "empty", name: "Empty", spaceID: "s", previousSibling: .folder("outer")),
			.init(id: "inner", name: "Inner", parentID: "outer", spaceID: "s", previousSibling: .start),
			.init(id: "outer", name: "Outer", spaceID: "s", previousSibling: .tab("a")),
		]
		let layout: FirefoxSession.ZenLayout = .init(spaces: [.init(id: "s", name: "Space")], tabs: tabs, folders: folders)

		let records = FirefoxSession.zenRecords(layout, profile: .init(id: "p", name: "Profile"))

		expectNoDifference(
			records.filter { $0.kind != .space }.map { record in
				let path: String = record.folders.map(\.name).joined(separator: "/")
				return record.kind == .folder ? path : [path, record.title].filter { !$0.isEmpty }.joined(separator: "/")
			},
			["A", "Outer/Inner/N", "Empty", "B"]
		)
	}

	@Test
	internal func olderZenVersionsKeepSpacesAndPinsInPlaces() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		try Self.makeProfile(home: home, folder: "zen", sql: """
		CREATE TABLE zen_workspaces (
			id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, name TEXT NOT NULL, icon TEXT,
			container_id INTEGER, position INTEGER NOT NULL DEFAULT 0, created_at INTEGER, updated_at INTEGER
		);
		CREATE TABLE zen_pins (
			id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, title TEXT NOT NULL, url TEXT,
			container_id INTEGER, workspace_uuid TEXT, position INTEGER NOT NULL DEFAULT 0,
			is_essential BOOLEAN NOT NULL DEFAULT 0, is_group BOOLEAN NOT NULL DEFAULT 0,
			created_at INTEGER, updated_at INTEGER, edited_title BOOLEAN NOT NULL DEFAULT 0,
			is_folder_collapsed BOOLEAN NOT NULL DEFAULT 0, folder_icon TEXT, folder_parent_uuid TEXT
		);
		INSERT INTO zen_workspaces (id, uuid, name, icon, position) VALUES
			(1, '{work}', 'Work', '💼', 1),
			(2, '{home}', 'Home', NULL, 0);
		INSERT INTO zen_pins (id, uuid, title, url, workspace_uuid, position, is_essential, is_group, edited_title, folder_parent_uuid) VALUES
			(1, 'e1', 'Mail', 'https://mail.example.org/', NULL, 0, 1, 0, 0, NULL),
			(2, 'g1', 'Projects', NULL, '{work}', 1, 0, 1, 0, NULL),
			(3, 'p1', 'Board', 'https://board.example.org/', '{work}', 2, 0, 0, 1, 'g1'),
			(4, 'g2', 'Empty', NULL, '{work}', 3, 0, 1, 0, NULL),
			(5, 'p2', 'Docs', 'https://docs.example.org/', '{work}', 4, 0, 0, 0, NULL);
		""", files: [
			"sessionstore-backups/recovery.jsonlz4": Self.session("""
			{"windows": [{"tabs": [
				{"entries": [{"url": "https://board.example.org/", "title": "Board"}], "index": 1, "pinned": true, "attributes": {"zen-workspace-id": "{work}"}},
				{"entries": [{"url": "https://open.example.org/", "title": "Open"}], "index": 1, "attributes": {"zen-workspace-id": "{home}"}}
			]}]}
			"""),
		])

		let snapshot = try await Self.snapshot(.zen, home: home)

		expectNoDifference(
			snapshot.records.filter { $0.kind == .space }.compactMap { $0.space?.name },
			["Home", "Work"]
		)
		let tabs = snapshot.records.filter { $0.kind == .tab }
		expectNoDifference(tabs.map(\.title), ["Mail", "Board", "Docs", "Open"])
		expectNoDifference(tabs.map(\.category), [.favorites, .bookmarks, .bookmarks, .openTabs])
		expectNoDifference(tabs[3].space?.name, "Home")
		let work = snapshot.records.filter { $0.space?.name == "Work" && $0.kind != .space }
		expectNoDifference(work.map { $0.kind == .folder ? $0.folders.last?.name ?? "" : $0.title }, [
			"Board", "Empty", "Docs",
		])
		expectNoDifference(tabs[1].customTitle, "Board")
		expectNoDifference(tabs[1].folders.map(\.name), ["Projects"])
		expectNoDifference(tabs[1].space?.icon, "💼")
	}

	// MARK: - Hand check

	/// Reads the real browsers on this Mac, unchecked sources included, when asked to with
	/// `ARX_MIGRATION_REAL_SOURCES=1`, and prints only counts.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_MIGRATION_REAL_SOURCES"] != nil))
	internal func theRealSourcesParse() async throws {
		// Safari is never read for real: its tests use fixtures only.
		for adapter in MigrationBrowserSources.adapters(includesUnchecked: true) where adapter.source.id != .safari {
			let snapshot = try await adapter.snapshot()
			var counts: [MigrationCategory: Int] = [:]
			for record in snapshot.records where record.kind == .tab {
				counts[record.category, default: 0] += 1
			}
			let spaces = snapshot.records.filter { $0.kind == .space }.count
			let summary = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.rawValue)" }
			print("\(adapter.source.name): \(spaces) spaces, " + summary.joined(separator: ", "))
		}
	}
}
