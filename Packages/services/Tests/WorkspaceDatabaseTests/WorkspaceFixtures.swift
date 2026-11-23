import BrowserCore
import Foundation
import WorkspaceDatabase
import _TestSupport

/// A directory under the system's temporary folder, removed when the test ends. Tests never open a
/// real Arx workspace.
internal final class TemporaryDirectory {
	internal let url: URL

	internal init() throws {
		self.url = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceDatabaseTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: url)
	}

	internal func open() throws -> WorkspaceDatabase {
		try .init(directory: url)
	}
}

/// Fixed IDs, negative so they never meet generated ones.
internal enum Fixture {
	internal static func id(_ value: Int) -> UUID {
		UUID(value)
	}

	internal static let work: Profile.ID = .init(rawValue: id(-1))
	internal static let personal: Profile.ID = .init(rawValue: id(-2))
	internal static let retired: Profile.ID = .init(rawValue: id(-3))

	internal static let inbox: Space.ID = .init(rawValue: id(-11))
	internal static let home: Space.ID = .init(rawValue: id(-12))
	internal static let projects: Space.ID = .init(rawValue: id(-13))

	internal static let reading: Folder.ID = .init(rawValue: id(-21))
	internal static let articles: Folder.ID = .init(rawValue: id(-22))
	internal static let recipes: Folder.ID = .init(rawValue: id(-23))

	internal static let mail: Tab.ID = .init(rawValue: id(-31))
	internal static let calendar: Tab.ID = .init(rawValue: id(-32))
	internal static let docs: Tab.ID = .init(rawValue: id(-33))
	internal static let essay: Tab.ID = .init(rawValue: id(-34))
	internal static let paper: Tab.ID = .init(rawValue: id(-35))
	internal static let search: Tab.ID = .init(rawValue: id(-36))
	internal static let news: Tab.ID = .init(rawValue: id(-37))
	internal static let soup: Tab.ID = .init(rawValue: id(-38))
	internal static let music: Tab.ID = .init(rawValue: id(-39))
	internal static let bank: Tab.ID = .init(rawValue: id(-40))

	internal static func url(_ text: String) -> URL {
		URL(string: text)!
	}

	internal static func pinned(
		_ id: Tab.ID,
		_ profileID: Profile.ID,
		_ title: String,
		_ url: String,
		customTitle: String? = nil
	) -> Tab {
		.init(
			id: id,
			profileID: profileID,
			savedDestination: .init(title: title, url: self.url(url), iconURL: self.url("\(url)/favicon.ico")),
			restoration: .init(title: "\(title) now", url: self.url("\(url)/current")),
			customTitle: customTitle
		)
	}

	internal static func regular(
		_ id: Tab.ID,
		_ profileID: Profile.ID,
		_ title: String,
		_ url: String,
		automationClientID: UUID? = nil
	) -> Tab {
		.init(
			id: id,
			profileID: profileID,
			restoration: .init(title: title, url: self.url(url)),
			automationClientID: automationClientID
		)
	}

	/// Two profiles, three spaces in an order that interleaves them, nested folders, pins, favorites,
	/// regular tabs, a selection, a collapsed folder, the archive, a split and a tab group.
	internal static var organization: BrowserOrganization {
		let archived: Tab = regular(.init(rawValue: id(-50)), work, "Old", "https://old.example")
		return .init(
			profiles: [
				.init(
					id: work,
					name: "Work",
					favorites: [calendar, mail],
					searchEngine: .kagi,
					appearance: .init(theme: .dark, tintHue: 210),
					tabArchiveInterval: .week,
					remoteSearchSuggestions: false,
					showsFullURL: true,
					keptLoadedSites: ["mail.example"],
					darkPagesOffSites: ["figma.com"],
					unreadBadges: .hide
				),
				.init(id: personal, name: "Personal", favorites: [music]),
			],
			legacyProfileID: personal,
			retiredProfileIDs: [retired],
			spaces: [
				.init(
					id: inbox,
					profileID: work,
					name: "Inbox",
					icon: .briefcase,
					appearance: .init(tintHue: 30),
					savedItems: [.folder(reading), .tab(docs)],
					unpinnedTabs: [news, search],
					selectedTabID: search
				),
				.init(
					id: home,
					profileID: personal,
					name: "Home",
					icon: .house,
					savedItems: [.tab(bank), .folder(recipes)]
				),
				.init(id: projects, profileID: work, name: "Projects"),
			],
			folders: [
				.init(id: articles, spaceID: inbox, name: "Articles", children: [.tab(paper)], isExpanded: false),
				.init(id: recipes, spaceID: home, name: "Recipes", children: [.tab(soup)]),
				.init(id: reading, spaceID: inbox, name: "Reading", children: [.tab(essay), .folder(articles)]),
			],
			tabs: [
				regular(search, work, "Search", "https://search.example/?q=sqlite", automationClientID: id(-60)),
				pinned(mail, work, "Mail", "https://mail.example"),
				pinned(calendar, work, "Calendar", "https://calendar.example", customTitle: "Agenda"),
				pinned(docs, work, "Docs", "https://docs.example"),
				pinned(essay, work, "Essay", "https://essay.example"),
				pinned(paper, work, "Paper", "https://paper.example"),
				regular(news, work, "News", "https://news.example"),
				pinned(soup, personal, "Soup", "https://soup.example"),
				pinned(music, personal, "Music", "https://music.example"),
				pinned(bank, personal, "Bank", "https://bank.example"),
			],
			archive: [
				.init(
					id: .init(rawValue: id(-51)),
					groupID: id(-52),
					closedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.25),
					originalSpaceID: inbox,
					originalSpaceName: "Inbox",
					originalIndex: 2,
					tab: archived
				),
			],
			splits: [
				.init(id: .init(rawValue: id(-70)), spaceID: inbox, tabIDs: [news, search], fractions: [0.4, 0.6]),
			],
			tabGroups: [
				.init(id: .init(rawValue: id(-80)), spaceID: inbox, name: "Reading list", tabIDs: [news]),
			]
		)
	}

	/// Changed from the defaults in every kind of row: a domain, a local field, each list.
	internal static var preferences: BrowserPreferences {
		var preferences: BrowserPreferences = .init()
		preferences.darkPages = .withTheme
		preferences.grainIntensity = 0.37
		preferences.chromeTint.hue = 140
		preferences.appTheme = .dark
		preferences.switchesToLinkTabs = true
		preferences.globalLittleArxEnabled = true
		preferences.developerModeEnabled = true
		preferences.lastSidebarWidth = 287.5
		preferences.showsUnreadBadges = false
		preferences.unreadBadgeSites = ["mail.example": .show, "news.example": .hide]
		preferences.unreadBadgeTabs = [
			.init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!): .show,
			.init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!): .hide,
		]
		preferences.tabsLastViewed = [
			Fixture.news: Date(timeIntervalSinceReferenceDate: 800_000_100.5),
			Fixture.search: Date(timeIntervalSinceReferenceDate: 800_000_200.75),
		]
		preferences.searchShortcuts = [
			.init(name: "Wikipedia", keyword: "w", template: "https://en.wikipedia.org/w/index.php?search={query}"),
			.init(name: "Docs", keyword: "Docs", template: "https://docs.example/?q={query}", homepage: url("https://docs.example"), isEnabled: false),
		]
		preferences.keyboardShortcuts = [
			.init(command: .downloads, shortcut: .init(key: "j", modifiers: [.command, .shift])),
			.init(command: .downloads, shortcut: .init(key: "l", modifiers: [.command, .option])),
			.init(command: .newFolder, shortcut: nil),
		]
		preferences.routing.rules = [
			.init(
				id: id(-90),
				name: "Work links",
				host: "corp.example",
				includesSubdomains: true,
				scheme: "https",
				port: 8443,
				pathPrefix: "/wiki",
				destination: .init(scope: .space(inbox), mode: .littleArx),
				isEnabled: false
			),
			.init(id: id(-91), name: "Anything", host: "example.org", destination: .init(scope: .ask)),
		]
		preferences.routing.fallback = .init(scope: .profile(personal))
		preferences.proxyLinkRules = [
			.init(
				id: id(-95),
				name: "Mirror",
				sourceHosts: ["a.example", "b.example"],
				destinationTemplate: "https://mirror.example{path}{query}"
			),
		]
		preferences.removedProxyLinkDefaults = [ProxyLinkRule.defaults[1].id]
		return preferences
	}
}
