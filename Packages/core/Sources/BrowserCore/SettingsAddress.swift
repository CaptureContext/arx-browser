import Foundation

/// Where an `arx://settings/…` or `chrome://settings/…` address leads in Arx (DEV-1189).
///
/// This is the one table for such addresses, however they arrive: typed in the URL bar or the
/// command bar, or a page's link to Chrome's settings (DEV-1188). Chrome's paths map to Arx's
/// equivalent: `content/protectedContent` to Advanced › Protected media, `content/camera` and
/// the other permissions to the profile's site settings, `passwords` to its passwords, and so
/// on. Arx's own paths name a pane and, after it, a row or page: `arx://settings/advanced` or
/// `arx://settings/advanced/protectedMedia`. A path neither knows opens Settings at its top.
///
/// `chrome://downloads`, `chrome://history`, `chrome://extensions` and `chrome://password-manager`
/// lead to Arx's own places for them too. Other `chrome://` pages aren't settings: nil.
public enum SettingsAddress: Hashable, Sendable {
	/// Settings, at its top.
	case top

	/// A place in Settings, by the identity SettingsFeature's `SettingsDestination` reads:
	/// `pane/advanced`, `row/advanced/protectedMedia` or `page/appLinks`.
	case destination(String)

	/// An `arx://settings/<pane>/<row or page>` path. Settings resolves it against its own rows
	/// and pages, ignoring case; one it doesn't know opens the pane.
	case path(pane: String, item: String)

	/// A page or sheet of the profile the address was opened from.
	case profile(ProfileSettings)

	/// Arx's own place for it, outside Settings.
	case command(BrowserCommand)

	public static let arxScheme: String = "arx"
	public static let chromeScheme: String = "chrome"
	public static let host: String = "settings"

	/// Where `url` leads, or nil when it's no settings address.
	public init?(_ url: URL) {
		guard
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let scheme = components.scheme?.lowercased(),
			let host = components.host?.lowercased(),
			components.user == nil,
			components.password == nil,
			components.port == nil
		else { return nil }

		let path: [String] = components.path
			.split(separator: "/")
			.map { $0.lowercased() }

		switch scheme {
		case Self.arxScheme where host == Self.host:
			self = Self.arxSettings(path)

		case Self.chromeScheme where host == Self.host:
			self = Self.chromeSettings(path)

		case Self.chromeScheme:
			// `chrome://password-manager/passwords` and the like: the page decides, not its path.
			guard let address = Self.chromePages[host] else { return nil }
			self = address

		default:
			return nil
		}
	}

	/// Where typed text leads, when it parses as a settings address.
	public init?(string: String) {
		guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
		self.init(url)
	}

	/// Settings' panes, as Arx's own paths name them. They match SettingsFeature's
	/// `SettingsCategory` raw values, lowercased, which its tests check.
	public static let panes: Set<String> = [
		"arx", "general", "profiles", "sync", "assistant", "links", "shortcuts", "appearance",
		"privacy", "developer", "advanced",
	]

	/// Chrome's settings paths, lowercased, and Arx's place for each. A path that isn't listed
	/// takes its longest listed start, so `content/siteDetails` leads where `content` does.
	public static let chromePaths: [String: Self] = [
		// Site settings and permissions: Arx keeps them per profile.
		"content": .profile(.siteSettings),
		"sitedata": .profile(.siteSettings),
		"cookies": .profile(.siteSettings),
		"privacy/cookies": .profile(.siteSettings),
		// Protected content is Arx's Widevine switch, not a site permission.
		"content/protectedcontent": .destination("row/advanced/protectedMedia"),
		// Privacy and security.
		"privacy": .destination("pane/privacy"),
		"security": .destination("pane/privacy"),
		"clearbrowserdata": .profile(.clearBrowsingData),
		// Passwords and autofill.
		"passwords": .profile(.passwords),
		"autofill": .profile(.autofill),
		"payments": .profile(.autofill),
		"addresses": .profile(.autofill),
		// The profile's page holds its search engine, downloads and history.
		"downloads": .profile(.page),
		"search": .profile(.page),
		"searchengines": .profile(.page),
		"people": .destination("pane/profiles"),
		"syncsetup": .destination("row/sync/iCloudSync"),
		// iCloud Sync was a section of the Arx pane until it got Settings › Sync (DEV-1336).
		"arx/icloudsync": .destination("row/sync/iCloudSync"),
		"manageprofile": .destination("pane/profiles"),
		"importdata": .destination("pane/profiles"),
		// Everything else Chrome's settings pages link to.
		"appearance": .destination("pane/appearance"),
		"fonts": .destination("pane/appearance"),
		"accessibility": .destination("pane/appearance"),
		"defaultbrowser": .destination("row/arx/defaultBrowser"),
		"onstartup": .destination("row/advanced/restoreWindows"),
		"languages": .destination("row/general/translation"),
		"performance": .destination("row/general/tabUnloading"),
		"system": .destination("pane/advanced"),
		"handlers": .destination("page/appLinks"),
		"help": .destination("row/general/updates"),
		"about": .destination("pane/arx"),
	]

	/// `chrome://<host>` pages with a place in Arx.
	public static let chromePages: [String: Self] = [
		"downloads": .command(.downloads),
		"history": .command(.showHistory),
		"extensions": .command(.extensions),
		"password-manager": .profile(.passwords),
		"help": .destination("row/general/updates"),
	]

	/// `arx://settings/…`: Chrome's path when it names one exactly, then Arx's own pane and the
	/// row or page in it, then the start of a Chrome path.
	private static func arxSettings(_ path: [String]) -> Self {
		if path.isEmpty { return .top }
		if let address = chromePaths[path.joined(separator: "/")] { return address }
		if panes.contains(path[0]) {
			return path.count == 1
			? .destination("pane/" + path[0])
			: .path(pane: path[0], item: path[1])
		}
		return chromePrefix(path) ?? .top
	}

	/// `chrome://settings/…`: the path, or its longest listed start.
	private static func chromeSettings(_ path: [String]) -> Self {
		if path.isEmpty { return .top }
		return chromePrefix(path) ?? .top
	}

	private static func chromePrefix(_ path: [String]) -> Self? {
		for count in stride(from: path.count, through: 1, by: -1) {
			if let address = chromePaths[path.prefix(count).joined(separator: "/")] { return address }
		}
		return nil
	}
}

/// A profile's own page or sheet, opened for the window's profile (DEV-1189).
public enum ProfileSettings: String, CaseIterable, Hashable, Sendable {
	/// The profile's page in Settings › Profiles.
	case page
	case siteSettings
	case passwords
	case autofill
	case clearBrowsingData
}
