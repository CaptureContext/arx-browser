import CustomDump
import Foundation
import SQLite3
import Testing
@testable import MigrationAssistant

/// Safari fixtures are made here (DEV-840): `Bookmarks.plist` in Safari's
/// `WebBookmarkType` layout, and `SafariTabs.db` and `History.db` from the table
/// definitions in macOS 27's SafariShared, trimmed to the columns read. No real Safari
/// data is read.
internal struct SafariDataTests {
	// MARK: - Fixtures

	private static func makeHome() -> URL {
		FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
	}

	private static func leaf(
		_ id: String,
		_ title: String,
		_ url: String
	) -> [String: Any] {
		[
			"WebBookmarkType": "WebBookmarkTypeLeaf",
			"WebBookmarkUUID": id,
			"URLString": url,
			"URIDictionary": ["title": title],
		]
	}

	private static func list(
		_ id: String,
		_ title: String,
		_ children: [[String: Any]]
	) -> [String: Any] {
		[
			"WebBookmarkType": "WebBookmarkTypeList",
			"WebBookmarkUUID": id,
			"Title": title,
			"Children": children,
		]
	}

	private static func bookmarks() throws -> Data {
		let root: [String: Any] = [
			"WebBookmarkType": "WebBookmarkTypeList",
			"Title": "",
			"Children": [
				["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
				leaf("root-link", "Loose", "https://loose.example/"),
				list("bar", "BookmarksBar", [
					leaf("b1", "Apple", "https://www.apple.com/"),
					list("bar-folder", "Work", [leaf("b2", "Linear", "https://linear.app/")]),
					leaf("b3", "Script", "javascript:alert(1)"),
				]),
				list("menu", "BookmarksMenu", [
					leaf("m1", "Swift", "https://swift.org/"),
					list("empty", "Empty", []),
				]),
				list("other", "Recipes", [leaf("o1", "Bread", "https://bread.example/")]),
				list("reading", SafariBookmarks.readingList, [leaf("r1", "Article", "https://news.example/a")]),
			],
		]
		return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
	}

	private static let tabsSchema: String = """
	CREATE TABLE bookmarks (
		id INTEGER PRIMARY KEY AUTOINCREMENT, special_id INTEGER DEFAULT 0, parent INTEGER, type INTEGER,
		title TEXT, url TEXT, hidden INTEGER DEFAULT 0, order_index INTEGER NOT NULL,
		external_uuid TEXT UNIQUE, server_id TEXT, deleted INTEGER DEFAULT 0, syncable BOOL DEFAULT 1,
		subtype INTEGER DEFAULT 0
	);
	CREATE TABLE windows (
		id INTEGER PRIMARY KEY, active_tab_group_id INTEGER, active_profile_id INTEGER,
		date_closed REAL DEFAULT NULL, is_last_session INTEGER DEFAULT 0,
		local_tab_group_id INTEGER, private_tab_group_id INTEGER, uuid TEXT NOT NULL UNIQUE
	);
	"""

	/// Two profiles' worth: the default profile with a group and a window, and a Work
	/// profile with its own group, window and history.
	private static let tabs: String = """
	INSERT INTO bookmarks (id, special_id, parent, type, title, order_index, external_uuid, server_id, subtype, hidden) VALUES
		(1, 1, 0, 1, 'BookmarksBar', 0, 'root-bar', NULL, 0, 0),
		(10, 0, 0, 1, 'Trip', 2, 'group-trip', NULL, 0, 0),
		(11, 0, 0, 1, 'Hidden', 3, 'group-hidden', NULL, 0, 1),
		(20, 0, 0, 1, 'Work', 1, 'profile-work', 'server-work', 2, 0),
		(21, 0, 20, 1, '', 0, 'work-groups', NULL, 3, 0),
		(22, 0, 21, 1, 'Sprint', 0, 'group-sprint', NULL, 0, 0),
		(23, 0, 21, 1, 'Empty', 1, 'group-empty', NULL, 0, 0),
		(30, 0, 0, 1, '', 9, 'local-default', NULL, 0, 1),
		(31, 0, 0, 1, '', 10, 'local-work', NULL, 0, 1),
		(32, 0, 0, 1, '', 11, 'local-private', NULL, 0, 1);
	INSERT INTO bookmarks (parent, type, title, url, order_index, external_uuid, deleted) VALUES
		(10, 0, 'Map', 'https://maps.example/', 1, 'tab-map', 0),
		(10, 0, 'Hotel', 'https://hotel.example/', 0, 'tab-hotel', 0),
		(10, 0, 'Gone', 'https://gone.example/', 2, 'tab-gone', 1),
		(11, 0, 'Secret', 'https://hidden.example/', 0, 'tab-hidden', 0),
		(22, 0, 'Board', 'https://linear.app/board', 0, 'tab-board', 0),
		(30, 0, 'News', 'https://news.example/', 0, 'tab-news-1', 0),
		(30, 0, 'News', 'https://news.example/', 1, 'tab-news-2', 0),
		(31, 0, 'Mail', 'https://mail.example/', 0, 'tab-mail', 0),
		(32, 0, 'Private', 'https://private.example/', 0, 'tab-private', 0);
	INSERT INTO windows (id, active_profile_id, date_closed, local_tab_group_id, private_tab_group_id, uuid) VALUES
		(1, NULL, NULL, 30, 32, 'w1'),
		(2, 20, NULL, 31, NULL, 'w2'),
		(3, NULL, 700000000, 30, NULL, 'w3');
	"""

	private static let historySchema: String = """
	CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, visit_count INTEGER NOT NULL DEFAULT 0);
	CREATE TABLE history_visits (
		id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT NULL
	);
	"""

	private static func makeDatabase(
		_ url: URL,
		_ sql: String
	) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let database = try SQLiteDatabase(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
		try database.execute(sql)
	}

	private static func makeSafari(
		home: URL,
		tabs: Bool = true
	) throws -> SafariData.Location {
		let location: SafariData.Location = .init(home: home)
		try FileManager.default.createDirectory(at: location.library, withIntermediateDirectories: true)
		try bookmarks().write(to: location.bookmarks)
		if tabs {
			try makeDatabase(location.container.appending(path: "SafariTabs.db"), tabsSchema + Self.tabs)
		}
		try makeDatabase(
			location.library.appending(path: "History.db"),
			historySchema + """
			INSERT INTO history_items (id, url) VALUES (1, 'https://swift.org/'), (2, 'https://apple.com/');
			INSERT INTO history_visits (history_item, visit_time, title) VALUES
				(1, 100, 'Old title'), (1, 300, 'Swift'), (2, 200, 'Apple');
			"""
		)
		try makeDatabase(
			location.library.appending(path: "Profiles/server-work/History.db"),
			historySchema + """
			INSERT INTO history_items (id, url) VALUES (1, 'https://linear.app/');
			INSERT INTO history_visits (history_item, visit_time, title) VALUES (1, 400, 'Linear');
			"""
		)
		return location
	}

	private static func summary(
		_ records: [MigrationRecord],
		_ category: MigrationCategory
	) -> [String] {
		records
			.filter { $0.category == category && $0.kind == .tab }
			.map { record in
				let place = record.space?.name ?? record.profile?.name ?? ""
				let folders = record.folders.map(\.name).joined(separator: "/")
				return [place, folders, record.title].filter { !$0.isEmpty }.joined(separator: " › ")
			}
	}

	// MARK: - Bookmarks

	@Test
	internal func theFavoritesBarBecomesFavoritesAndTheRestBookmarksWithFolders() throws {
		let records = try SafariBookmarks.records(Self.bookmarks())

		expectNoDifference(Self.summary(records, .favorites), ["Safari › Apple", "Safari › Script"])
		expectNoDifference(Self.summary(records, .bookmarks), [
			"Safari › Loose",
			"Safari › Work › Linear",
			"Safari › Swift",
			"Safari › Recipes › Bread",
			"Safari › Reading List › Article",
		])
		let empty = try #require(records.first { $0.kind == .folder })
		expectNoDifference(empty.folders.map(\.name), ["Empty"])
		#expect(records.first?.kind == .space)
		// A non-web link is kept as a record and refused by validation.
		let script = try #require(records.first { $0.title == "Script" })
		#expect(throws: MigrationIssue.self) { try script.validated(from: .safari).get() }
	}

	@Test
	internal func anUnknownBookmarksFileIsUnreadable() throws {
		let data = try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .xml, options: 0)
		#expect(throws: MigrationFailure.self) { try SafariBookmarks.records(data) }
	}

	// MARK: - Tabs

	@Test
	internal func tabGroupsProfilesAndOpenWindowsAreRead() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let url = home.appending(path: "SafariTabs.db")
		try Self.makeDatabase(url, Self.tabsSchema + Self.tabs)
		let contents = try FirefoxPlaces.withCopy(of: url) { try SafariTabs.read($0) }

		expectNoDifference(contents.profiles.map(\.name), ["Work"])
		expectNoDifference(contents.profiles.map(\.identifiers), [["server-work", "profile-work"]])

		// Hidden groups and deleted tabs are left out; the closed window and private tabs too.
		expectNoDifference(contents.groups.map(\.name), ["Trip", "Sprint", "Empty"])
		expectNoDifference(contents.groups[0].tabs.map(\.title), ["Hotel", "Map"])
		expectNoDifference(contents.groups.map(\.profileID), [nil, 20, 20])
		expectNoDifference(contents.windows.map(\.profileID), [nil, 20])
		expectNoDifference(contents.windows.map { $0.tabs.map(\.title) }, [["News", "News"], ["Mail"]])

		let records = SafariTabs.records(contents)
		expectNoDifference(Self.summary(records, .openTabs), [
			"Safari › News",
			"Safari › News",
			"Work › Mail",
			"Trip › Hotel",
			"Trip › Map",
			"Sprint › Board",
		])
		let spaces = records.filter { $0.kind == .space }
		expectNoDifference(spaces.map { "\($0.space?.profile.name ?? "") › \($0.space?.name ?? "")" }, [
			"Safari › Trip",
			"Work › Sprint",
			"Work › Empty",
		])

		// The same page twice in a window stays two tabs.
		let news = records.filter { $0.title == "News" }.map(\.sourceItemID)
		expectNoDifference(news, ["default/open/https://news.example/#0", "default/open/https://news.example/#1"])
	}

	@Test
	internal func profileWindowsKeepTheirUnnamedGroupsTabs() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		// A window that showed the default profile and then Work: each profile's ungrouped
		// tabs are a hidden group under that profile, listed in `windows_unnamed_tab_groups`.
		let url = home.appending(path: "SafariTabs.db")
		try Self.makeDatabase(
			url,
			Self.tabsSchema + Self.tabs + """
			CREATE TABLE windows_unnamed_tab_groups (id INTEGER PRIMARY KEY, tab_group_id INTEGER NOT NULL, window_id INTEGER NOT NULL);
			INSERT INTO bookmarks (id, parent, type, title, order_index, external_uuid, subtype, hidden) VALUES
				(140, 20, 1, '', 5, 'unnamed-work', 0, 1),
				(141, 0, 1, '', 12, 'unnamed-default', 0, 1);
			INSERT INTO bookmarks (parent, type, title, url, order_index, external_uuid) VALUES
				(140, 0, 'Docs', 'https://docs.example/', 0, 'tab-docs'),
				(141, 0, 'Weather', 'https://weather.example/', 0, 'tab-weather');
			INSERT INTO windows (id, active_profile_id, date_closed, local_tab_group_id, private_tab_group_id, uuid) VALUES
				(4, 20, NULL, NULL, 32, 'w4');
			INSERT INTO windows_unnamed_tab_groups (tab_group_id, window_id) VALUES (141, 4), (140, 4), (32, 4), (30, 1);
			"""
		)
		let contents = try FirefoxPlaces.withCopy(of: url) { try SafariTabs.read($0) }

		expectNoDifference(contents.windows.map(\.profileID), [nil, 20, nil, 20])
		expectNoDifference(
			contents.windows.map { $0.tabs.map(\.title) },
			[["News", "News"], ["Mail"], ["Weather"], ["Docs"]]
		)

		// Unnamed groups are never named ones, and private tabs stay out.
		expectNoDifference(contents.groups.map(\.name), ["Trip", "Sprint", "Empty"])
		#expect(!contents.windows.flatMap(\.tabs).contains { $0.title == "Private" })
	}

	@Test
	internal func afterSafariQuitsTheRestoredWindowsAreRead() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let url = home.appending(path: "SafariTabs.db")
		try Self.makeDatabase(
			url,
			Self.tabsSchema + Self.tabs + """
			UPDATE windows SET date_closed = 800000000;
			UPDATE windows SET is_last_session = 1 WHERE id = 2;
			"""
		)
		let contents = try FirefoxPlaces.withCopy(of: url) { try SafariTabs.read($0) }
		expectNoDifference(contents.windows.map { $0.tabs.map(\.title) }, [["Mail"]])
	}

	@Test
	internal func aTabsDatabaseWithoutItsTablesHasNothing() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let url = home.appending(path: "SafariTabs.db")
		try Self.makeDatabase(url, "CREATE TABLE other (id INTEGER);")
		let contents = try FirefoxPlaces.withCopy(of: url) { try SafariTabs.read($0) }
		#expect(contents == .init())
	}

	// MARK: - Whole source

	@Test
	internal func theAdapterReadsBookmarksTabsAndEachProfilesHistory() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let location = try Self.makeSafari(home: home)
		let adapter = try #require(MigrationBrowserSources.safari(location))
		#expect(adapter.source.id == .safari)
		#expect(adapter.source.requiresFullDiskAccess)
		expectNoDifference(adapter.source.categories, [.favorites, .bookmarks, .openTabs, .history])

		let snapshot = try await adapter.snapshot()
		let history = snapshot.records.filter { $0.category == .history }
		expectNoDifference(history.map(\.title), ["Swift", "Apple", "Linear"])
		expectNoDifference(history.map(\.profile?.name), ["Safari", "Safari", "Work"])
		expectNoDifference(
			history.map(\.lastVisited),
			[300, 200, 400].map { Date(timeIntervalSinceReferenceDate: $0) }
		)
		#expect(Self.summary(snapshot.records, .openTabs).count == 6)
		#expect(Self.summary(snapshot.records, .favorites).count == 2)

		// Reading again gives the same snapshot, so a review stays valid.
		let again = try await adapter.snapshot()
		#expect(again.id == snapshot.id)
	}

	@Test
	internal func withoutATabsDatabaseOnlyBookmarksAndHistoryAreRead() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let location = try Self.makeSafari(home: home, tabs: false)
		let snapshot = try SafariData.snapshot(location)
		#expect(Self.summary(snapshot.records, .openTabs).isEmpty)
		// Without the profiles in the tabs database, only the default profile's history is found.
		expectNoDifference(snapshot.records.filter { $0.category == .history }.map(\.title), ["Swift", "Apple"])
	}

	@Test
	internal func withoutAccessTheSourceIsOfferedButCantBeRead() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let location: SafariData.Location = .init(home: home)
		#expect(MigrationBrowserSources.safari(location) == nil)

		// The folder exists but its files can't be opened, as without Full Disk Access.
		try FileManager.default.createDirectory(at: location.library, withIntermediateDirectories: true)
		let adapter = try #require(MigrationBrowserSources.safari(location))
		#expect(adapter.source.lastUsed == nil)
		await #expect(throws: MigrationFailure.self) { try await adapter.snapshot() }
	}

	@Test
	internal func safariIsOfferedWithUncheckedSourcesAndListedOtherwise() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		_ = try Self.makeSafari(home: home)
		expectNoDifference(MigrationBrowserSources.adapters(home: home).map(\.source.id.rawValue), [])
		expectNoDifference(MigrationBrowserSources.unsupportedBrowsers(home: home).map(\.id), ["safari"])
		expectNoDifference(
			MigrationBrowserSources.adapters(home: home, includesUnchecked: true).map(\.source.id.rawValue),
			["safari"]
		)
		expectNoDifference(MigrationBrowserSources.unsupportedBrowsers(home: home, includesUnchecked: true), [])
	}

	// MARK: - Access

	@Test
	internal func accessIsWhetherTheFileOpens() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let location: SafariData.Location = .init(home: home)
		let client: FullDiskAccessClient = .checking(location.bookmarks)
		#expect(await client.isGranted() == false)

		_ = try Self.makeSafari(home: home, tabs: false)
		#expect(await client.isGranted())

		let opened: Opened = .init()
		let opening: FullDiskAccessClient = .checking(location.bookmarks, open: { await opened.append($0) })
		await opening.openSettings()
		let urls = await opened.urls
		expectNoDifference(urls.map(\.absoluteString), [
			"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
		])
	}

	private actor Opened {
		internal var urls: [URL] = []

		internal func append(_ url: URL) {
			urls.append(url)
		}
	}
}
