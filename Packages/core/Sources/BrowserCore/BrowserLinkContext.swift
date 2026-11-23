import Foundation

/// One explicit renderer context-menu target. Never persisted or exposed to MCP.
/// The source remains distinct from the link and from a tab's saved pin URL.
public struct BrowserLinkContext: Equatable, Sendable {
	/// Chromium's `url::kMaxURLChars`, the engine's bound for a menu's link (DEV-853).
	public static let maximumURLBytes: Int = 2 * 1024 * 1024

	public let token: UInt64
	public let tabID: Tab.ID
	public let profileID: Profile.ID
	public let sessionRevision: UInt64
	public let documentRevision: UInt64
	public let isPrivate: Bool
	public let item: LinkCopyItem
	public let x: Double
	public let y: Double

	public init(
		token: UInt64,
		tabID: Tab.ID,
		profileID: Profile.ID,
		sessionRevision: UInt64,
		documentRevision: UInt64,
		isPrivate: Bool,
		item: LinkCopyItem,
		x: Double,
		y: Double
	) {
		self.token = token
		self.tabID = tabID
		self.profileID = profileID
		self.sessionRevision = sessionRevision
		self.documentRevision = documentRevision
		self.isPrivate = isPrivate
		self.item = item
		self.x = x
		self.y = y
	}

	/// What the menu offers for this link with these proxy link rules. Every link gets a menu
	/// (DEV-853).
	public func availability(rules: [ProxyLinkRule]) -> LinkMenuAvailability {
		.init(item.url, rules: rules)
	}

	/// Any scheme, port or credentials, as in Chromium. Items decide what they offer.
	public func validate() throws {
		guard
			token > 0,
			sessionRevision > 0,
			documentRevision > 0,
			x.isFinite,
			y.isFinite,
			x >= 0,
			y >= 0,
			item.url.scheme?.isEmpty == false,
			item.url.absoluteString.utf8.count <= Self.maximumURLBytes,
			item.title.utf8.count <= 4096,
			!item.title.contains("\0")
		else { throw LinkTransformationError.invalidURL }
	}
}

/// Which link menu items one link offers. Like Chromium's `IsCommandIdEnabled`,
/// the menu shows for every link and each item decides on its own (DEV-853).
/// Each flag matches what the item's own backend accepts.
public struct LinkMenuAvailability: Equatable, Sendable {
	/// Open in New Tab, New Window, Private Window, Peek and Little Arx, and
	/// Copy Original Link as Markdown: addresses Arx opens, http and https on any port.
	public var opens: Bool

	/// Download Linked File: http and https without a username or password,
	/// which Chromium's download start refuses.
	public var downloads: Bool

	/// Copy Clean Link: http and https on the default port, without credentials.
	public var cleans: Bool

	/// Copy Proxy Link, its Markdown form and Share Proxy Link: http and https on the
	/// default port, on a site an enabled proxy link rule matches (DEV-1262). A username and
	/// password are dropped first.
	public var proxies: Bool

	/// Copy Link reads "Copy Email Address" for a `mailto:` link, as in Chromium.
	public var isEmailAddress: Bool

	public init(
		opens: Bool,
		downloads: Bool,
		cleans: Bool,
		proxies: Bool,
		isEmailAddress: Bool
	) {
		self.opens = opens
		self.downloads = downloads
		self.cleans = cleans
		self.proxies = proxies
		self.isEmailAddress = isEmailAddress
	}

	public init(
		_ url: URL,
		rules: [ProxyLinkRule]
	) {
		let scheme = url.scheme?.lowercased()
		let isWeb = (scheme == "http" || scheme == "https") && url.host(percentEncoded: false)?.isEmpty == false
		let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let hasCredentials = components?.user != nil || components?.password != nil
		self.init(
			opens: isWeb,
			downloads: isWeb && !hasCredentials,
			cleans: isWeb && (try? LinkTransformer.validate(url)) != nil,
			proxies: isWeb && LinkTransformer.proxies(url, rules: rules),
			isEmailAddress: scheme == "mailto"
		)
	}

	/// The copy modes this link offers, in menu order. Copy Link is always there.
	public var copyModes: [LinkCopyMode] {
		LinkCopyMode.allCases.filter { mode in
			switch mode {
			case .original: true
			case .clean: cleans
			case .markdownOriginal: opens
			case .proxy, .markdownProxy: proxies
			}
		}
	}
}
