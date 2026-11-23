import AppUI
import BrowserCore
import Foundation

/// The sites whose favorites add rows to their hover card (DEV-802), and where each reads them.
internal enum SidebarPreviewSite: Equatable, Sendable {
	/// Unread mail from the open Gmail page's own Atom feed, for the account at `/mail/u/<account>/`.
	case gmail(account: Int)

	/// Pages the profile visited on the site, from its history.
	case recentPages(RecentPagesSite)

	/// Live Calendar (DEV-804): today's day, read from Google Calendar's own page for the account
	/// at `/calendar/u/<account>/`.
	case googleCalendar(account: Int)

	internal enum RecentPagesSite: Equatable, Sendable {
		case linear
		case notion
		case figma
	}

	internal init?(url: URL) {
		guard
			url.scheme?.lowercased() == "https",
			let host = url.host()?.lowercased()
		else { return nil }

		if host == "mail.google.com" {
			let components = url.pathComponents
			guard components.count >= 2, components[1] == "mail" else { return nil }
			if components.count >= 4, components[2] == "u", let account = Int(components[3]), account >= 0 {
				self = .gmail(account: account)
			} else {
				self = .gmail(account: 0)
			}
			return
		}
		if host == "calendar.google.com" {
			let components = url.pathComponents
			guard components.count >= 2, components[1] == "calendar" else { return nil }
			if components.count >= 4, components[2] == "u", let account = Int(components[3]), account >= 0 {
				self = .googleCalendar(account: account)
			} else {
				self = .googleCalendar(account: 0)
			}
			return
		}
		if let site = RecentPagesSite(host: host) {
			self = .recentPages(site)
			return
		}
		return nil
	}
}

extension SidebarPreviewSite.RecentPagesSite {
	internal init?(host: String) {
		switch host {
		case "linear.app": self = .linear
		case "notion.so", "www.notion.so": self = .notion
		case "figma.com", "www.figma.com": self = .figma
		default:
			guard host.hasSuffix(".notion.site") else { return nil }
			self = .notion
		}
	}

	/// The page a history address names, or nil for the site's home, settings and other screens.
	/// Visits to one page under different addresses share a key.
	internal func pageKey(_ url: URL) -> String? {
		guard
			url.scheme?.lowercased() == "https",
			let host = url.host()?.lowercased(),
			Self(host: host) == self
		else { return nil }

		let parts = url.pathComponents.filter { $0 != "/" }
		switch self {
		case .linear:
			// linear.app/<workspace>/<kind>/<id>[/<slug>]
			guard
				parts.count >= 3,
				["issue", "project", "document", "view", "initiative"].contains(parts[1])
			else { return nil }
			return parts.prefix(3).joined(separator: "/").lowercased()

		case .notion:
			// A Notion page's address ends in its 32-digit ID, after its title.
			guard let last = parts.last else { return nil }
			let id = String(last.suffix(32))
			guard id.count == 32, id.allSatisfy(\.isHexDigit) else { return nil }
			return id.lowercased()

		case .figma:
			// figma.com/<kind>/<file key>/<name>
			guard
				parts.count >= 2,
				["file", "design", "board", "proto", "slides", "deck", "make", "site"].contains(parts[0])
			else { return nil }
			return parts[1]
		}
	}

	/// Drops the site's name from the end of a page title ("Roadmap – Figma" is "Roadmap").
	internal func pageTitle(_ title: String) -> String {
		let name = switch self {
		case .linear: "Linear"
		case .notion: "Notion"
		case .figma: "Figma"
		}
		var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
		for separator in [" – ", " - ", " | ", " — "] where title.hasSuffix(separator + name) {
			title = String(title.dropLast(separator.count + name.count))
				.trimmingCharacters(in: .whitespacesAndNewlines)
			break
		}
		return title
	}

	/// The profile's latest visits to pages on this site, newest first, one per page.
	internal func recentPages(
		in history: BrowsingHistorySnapshot?,
		excluding favorite: URL
	) -> [SidebarSitePreview.Item] {
		guard let history else { return [] }
		let favoriteKey = pageKey(favorite)
		var seen: Set<String> = []
		var items: [SidebarSitePreview.Item] = []
		for entry in history.entries.sorted(by: { $0.lastVisited > $1.lastVisited }) {
			guard
				let key = pageKey(entry.url),
				key != favoriteKey,
				seen.insert(key).inserted
			else { continue }
			let title = pageTitle(entry.title)
			items.append(.init(
				id: key,
				title: title.isEmpty ? entry.url.absoluteString : title,
				date: entry.lastVisited
			))
			if items.count == SidebarSitePreview.limit { break }
		}
		return items
	}
}

/// Where a favorite's site rows come from.
internal enum SidebarSiteSource: Equatable, Sendable {
	/// Read from the favorite's open page in its own profile.
	case mail(account: Int)

	/// Already read from the profile's history.
	case ready(SidebarSitePreview)

	/// Live Calendar (DEV-804): the favorite shows today's day instead of its card.
	case calendar(account: Int)
}

extension AppFeature.State {
	/// What a favorite's hover card adds for its site, or nil when the tab isn't a favorite, its
	/// site has nothing to add, or the option is off. Only the favorite's own profile is read, and
	/// never in a private window. Calendars need the `ARX_LIVE_CALENDAR` feature flag
	/// (`liveCalendar`) as well as their option, and not to have been disabled on their card.
	internal func sidebarSiteSource(
		in windowID: UUID,
		tabID: UUID,
		sources: HoverPreviewSources,
		liveCalendar: Bool = false
	) -> SidebarSiteSource? {
		let window = windowID == main.id ? (windowIsOpen ? main : nil) : windows[id: windowID]
		guard let window, !window.isClosing, !window.isPrivate else { return nil }
		guard
			let tab = workspace.tabs[id: .init(rawValue: tabID)],
			workspace.profiles[id: tab.profileID]?.favorites.contains(tab.id) == true,
			// The favorite's saved site, so a page it wandered to doesn't change what it previews.
			let site = SidebarPreviewSite(url: tab.savedDestination?.url ?? tab.restoration.url)
		else { return nil }

		switch site {
		case let .gmail(account):
			return sources.mail ? .mail(account: account) : nil

		case let .googleCalendar(account):
			guard
				liveCalendar,
				sources.calendars,
				!sources.disabledCalendars.contains(tabID)
			else { return nil }
			return .calendar(account: account)

		case let .recentPages(site):
			guard sources.recentPages else { return nil }
			return .ready(.init(
				kind: .recentPages,
				items: site.recentPages(in: history.snapshots[tab.profileID], excluding: tab.restoration.url)
			))
		}
	}
}

// MARK: - Gmail

/// Unread mail for Gmail favorites, read from Gmail's own Atom feed by the open page itself, so
/// the request carries only that profile's cookies and goes only to Google. Kept in memory for a
/// minute.
@MainActor
internal final class SidebarMailPreviews {
	internal static let shared: SidebarMailPreviews = .init()

	internal static let lifetime: Duration = .seconds(60)

	/// The feed lists at most 20 messages; anything far larger isn't one.
	internal static let maximumFeedBytes: Int = 131_072

	private struct Entry {
		internal var account: Int
		internal var readAt: ContinuousClock.Instant
		internal var preview: SidebarSitePreview
	}

	private var entries: [BrowserCore.Tab.ID: Entry]

	private init() {
		self.entries = [:]
	}

	internal func preview(
		for tabID: BrowserCore.Tab.ID,
		account: Int,
		clients: SidebarPreviewClients
	) async -> SidebarSitePreview? {
		// Only an open Gmail page can read its feed: nothing loads a page for a preview.
		guard
			let snapshot = clients.snapshot(tabID),
			let url = snapshot.navigation.url,
			case .gmail = SidebarPreviewSite(url: url)
		else {
			entries[tabID] = nil
			return .init(kind: .mail, needsOpenPage: true)
		}
		if
			let entry = entries[tabID],
			entry.account == account,
			entry.readAt.duration(to: .now) < Self.lifetime
		{ return entry.preview }

		guard
			let value = await clients.readScript(tabID, Self.feedScript(account: account)),
			let preview = Self.preview(fromScriptValue: value)
		else { return nil }

		entries[tabID] = .init(account: account, readAt: .now, preview: preview)
		return preview
	}

	/// Runs in the page's developer world: it fetches the feed from the page's own origin, with
	/// the page's cookies, and returns its text. It reads nothing else on the page.
	internal static func feedScript(account: Int) -> String {
		"""
		const response = await fetch("/mail/u/\(account)/feed/atom", { credentials: "same-origin", cache: "no-store" });
		if (!response.ok || new URL(response.url).origin !== location.origin) return null;
		const type = response.headers.get("content-type") || "";
		if (!type.includes("xml")) return null;
		const text = await response.text();
		return text.length > \(maximumFeedBytes) ? null : text;
		"""
	}

	/// The script's JSON value is the feed's text, or null.
	internal static func preview(fromScriptValue value: String) -> SidebarSitePreview? {
		guard
			let text = try? JSONDecoder().decode(String?.self, from: Data(value.utf8)),
			let feed = GmailAtomFeed(Data(text.utf8))
		else { return nil }
		return feed.preview
	}
}

/// Gmail's unread-mail Atom 0.3 feed: a full count and up to 20 entries.
internal struct GmailAtomFeed: Equatable, Sendable {
	internal struct Message: Equatable, Sendable {
		internal var id: String
		internal var title: String
		internal var author: String?
		internal var date: Date?
	}

	internal var fullCount: Int?
	internal var messages: [Message]

	internal init(
		fullCount: Int?,
		messages: [Message]
	) {
		self.fullCount = fullCount
		self.messages = messages
	}

	internal init?(_ data: Data) {
		let reader = Reader()
		let parser = XMLParser(data: data)
		parser.shouldResolveExternalEntities = false
		parser.delegate = reader
		guard parser.parse(), reader.isFeed else { return nil }
		self.fullCount = reader.fullCount
		self.messages = reader.messages
	}

	internal var preview: SidebarSitePreview {
		.init(
			kind: .mail,
			items: messages.prefix(SidebarSitePreview.limit).enumerated().map { index, message in
				.init(
					id: message.id.isEmpty ? String(index) : message.id,
					title: message.title,
					detail: message.author,
					date: message.date
				)
			},
			total: fullCount ?? messages.count
		)
	}

	private final class Reader: NSObject, XMLParserDelegate {
		internal var isFeed: Bool = false
		internal var fullCount: Int?
		internal var messages: [Message] = []

		private var path: [String] = []
		private var text: String = ""
		private var message: Message?

		internal func parser(
			_ parser: XMLParser,
			didStartElement element: String,
			namespaceURI: String?,
			qualifiedName: String?,
			attributes: [String: String] = [:]
		) {
			if path.isEmpty, element == "feed" { isFeed = true }
			path.append(element)
			text = ""
			if element == "entry", path.count == 2 {
				message = .init(id: "", title: "", author: nil, date: nil)
			}
		}

		internal func parser(
			_ parser: XMLParser,
			foundCharacters string: String
		) {
			text += string
		}

		internal func parser(
			_ parser: XMLParser,
			didEndElement element: String,
			namespaceURI: String?,
			qualifiedName: String?
		) {
			let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
			switch (path.count, element) {
			case (2, "fullcount"):
				fullCount = Int(value)
			case (3, "title"):
				message?.title = value
			case (3, "id"):
				message?.id = value
			case (3, "issued"):
				// The time it arrived; a modified time read earlier wins.
				let current = message?.date
				message?.date = current ?? Self.date(value)
			case (3, "modified"):
				let current = message?.date
				message?.date = Self.date(value) ?? current
			case (4, "name") where path[2] == "author":
				message?.author = value.isEmpty ? nil : value
			case (4, "email") where path[2] == "author":
				let current = message?.author
				if current == nil, !value.isEmpty { message?.author = value }
			case (2, "entry"):
				if let message { messages.append(message) }
				message = nil
			default:
				break
			}
			path.removeLast()
			text = ""
		}

		private static func date(_ value: String) -> Date? {
			try? Date(value, strategy: .iso8601)
		}
	}
}
