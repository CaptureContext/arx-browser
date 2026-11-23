import Foundation

/// Whether unread badges show on tabs and Favorites (DEV-1258), as one level chooses it. The
/// browser default is always set; a profile, a site or a tab chooses one or inherits (nil).
///
/// It covers the unread count and dot (DEV-907) only: the WebKit mark and the media speaker are
/// the tab's state, not something new, and always show. Hide removes the mark entirely.
public enum UnreadBadgeVisibility: String, CaseIterable, Codable, Hashable, Sendable {
	case show
	case hide

	public init(shows: Bool) {
		self = shows ? .show : .hide
	}

	public var shows: Bool { self == .show }

	/// The most specific level that chooses wins: the tab over the site, the site over the
	/// profile, the profile over the browser default, as the accent color resolves (DEV-1117).
	public static func resolve(
		tab: Self?,
		site: Self?,
		profile: Self?,
		browser: Self
	) -> Self {
		tab ?? site ?? profile ?? browser
	}
}

/// The site and tab levels of `UnreadBadgeVisibility` (DEV-1258). Both stay on this Mac: they're
/// device-local `BrowserPreferences` fields, as the hidden sites before them were (DEV-907).
public struct UnreadBadgeOverrides: Equatable, Hashable, Sendable {
	/// By ``Tab/unreadBadgeHost(of:)``: the host without "www.".
	public var sites: [String: UnreadBadgeVisibility]

	/// By the open tab; a tab that's gone leaves its entry until the next change prunes it.
	public var tabs: [Tab.ID: UnreadBadgeVisibility]

	public init(
		sites: [String: UnreadBadgeVisibility] = [:],
		tabs: [Tab.ID: UnreadBadgeVisibility] = [:]
	) {
		self.sites = sites
		self.tabs = tabs
	}

	/// The site level for `url`'s host, or nil to inherit.
	public func site(of url: URL) -> UnreadBadgeVisibility? {
		Tab.unreadBadgeHost(of: url).flatMap { sites[$0] }
	}

	/// What `tab` gets without its own choice: its site's, its profile's, or the browser default.
	public func inherited(
		by tab: Tab,
		profile: UnreadBadgeVisibility?,
		browser: UnreadBadgeVisibility
	) -> UnreadBadgeVisibility {
		UnreadBadgeVisibility.resolve(tab: nil, site: site(of: tab.restoration.url), profile: profile, browser: browser)
	}

	/// What `tab` shows: its own choice, or what it inherits.
	public func resolved(
		_ tab: Tab,
		profile: UnreadBadgeVisibility?,
		browser: UnreadBadgeVisibility
	) -> UnreadBadgeVisibility {
		tabs[tab.id] ?? inherited(by: tab, profile: profile, browser: browser)
	}

	/// The sites with a choice, by host.
	public var sortedSites: [(host: String, visibility: UnreadBadgeVisibility)] {
		sites.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
	}
}

extension BrowserPreferences {
	/// The site and tab levels (DEV-1258). A view over fields stored separately, so the workspace
	/// file keeps its format.
	public var unreadBadgeOverrides: UnreadBadgeOverrides {
		get { .init(sites: unreadBadgeSites, tabs: unreadBadgeTabs) }
		set {
			unreadBadgeSites = newValue.sites
			unreadBadgeTabs = newValue.tabs
		}
	}
}
