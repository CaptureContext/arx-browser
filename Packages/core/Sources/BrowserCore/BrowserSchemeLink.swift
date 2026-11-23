import Foundation

/// A link to another browser's own pages (DEV-1193): Chrome's `chrome://` pages, or Arc's
/// `arc://` ones. Arc is built on Chromium and calls the same pages `arc://`: `arc://settings`,
/// `arc://extensions`, `arc://history`, `arc://password-manager` and the rest, plus a few of its
/// own, such as `arc://boost`.
///
/// Where Arx has a place for one, `SettingsAddress` (DEV-1189) says so: an `arc://` link is read
/// as the `chrome://` link it names, so there's one table for both.
public struct BrowserSchemeLink: Hashable, Sendable {
	/// The browser whose pages a link names.
	public enum Browser: String, CaseIterable, Codable, Hashable, Sendable {
		case chrome
		case arc

		/// The browser's name, as the prompt says it.
		public var name: String {
			switch self {
			case .chrome: "Chrome"
			case .arc: "Arc"
			}
		}
	}

	public let url: URL
	public let browser: Browser

	/// Arx's place for it, nil when only its browser opens it.
	public let place: SettingsAddress?

	/// The browser page it opens, lowercased: `settings`, `extensions`, `downloads`. A choice
	/// remembered for a page holds for every link to it.
	public let page: String

	/// Links longer than this are no browser's pages, and aren't read.
	public static let maximumLength: Int = 8192

	/// Chromium's debug and destructive pages (`ChromeDebugURLs()` and its neighbours): they
	/// crash, hang, kill, exhaust, quit or restart the browser that opens them. Arx never hands
	/// one on, even to a browser that would trust it, and never asks about one. Chromium adds such
	/// pages over time, so a host is refused by what it names, not only by this list.
	public static let refusedPages: Set<String> = ["quit", "restart", "gpuclean", "webuijserror"]

	/// What a debug page's host contains: `crash`, `gpucrash`, `delayeduithreadhang`, `v8-oom`,
	/// `inducebrowsercrashforrealz`, `memory-exhaust`. `crashes` (Chrome's list of crash
	/// reports) is refused too, which costs nothing.
	public static let refusedPageParts: [String] = [
		"crash", "hang", "-oom", "kill", "induce", "memory-", "heapcorruption", "dcheck",
	]

	/// One of Chromium's debug or destructive pages, which Arx refuses.
	public var isRefused: Bool {
		Self.refusedPages.contains(page) || Self.refusedPageParts.contains { page.contains($0) }
	}

	/// The link `url` names, or nil when it isn't a `chrome://` or `arc://` link to a page.
	public init?(_ url: URL) {
		guard
			url.absoluteString.utf8.count <= Self.maximumLength,
			let scheme = url.scheme?.lowercased(),
			let browser = Browser(rawValue: scheme),
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let host = components.host?.lowercased(),
			!host.isEmpty,
			components.user == nil,
			components.password == nil,
			components.port == nil,
			let chrome = Self.chromeForm(of: components)
		else { return nil }

		self.url = url
		self.browser = browser
		self.place = SettingsAddress(chrome)
		self.page = host
	}

	/// The link `string` names, when it parses as one.
	public init?(string: String) {
		guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
		self.init(url)
	}

	/// The `chrome://` link an `arc://` or `chrome://` link names: Arc's pages are Chromium's.
	private static func chromeForm(of components: URLComponents) -> URL? {
		var chrome = components
		chrome.scheme = SettingsAddress.chromeScheme
		return chrome.url
	}
}

extension BrowserSchemeLink {
	/// What Arx does with a link (DEV-1193).
	public enum Decision: Equatable, Sendable {
		/// Arx opens its place for it, without asking.
		case openInArx(SettingsAddress)

		/// The browser it names opens it.
		case openInBrowser(Browser)

		/// A `chrome://` link while Chrome is installed: App Links' built-in handler for Chrome's
		/// pages takes it, with its "Open Google Chrome?" and Open in Arx when Arx has a place.
		case appLinks

		/// Arx has no place for it, and its browser isn't installed: "Arx can't open this".
		case cannotOpen

		/// One of Chromium's debug or destructive pages: nothing opens and nothing asks.
		case refuse
	}

	/// What Arx does with this link.
	///
	/// Arc is retiring, so an `arc://` link with an Arx place opens there with no question, and
	/// anything else goes to Arc. A `chrome://` link goes to App Links while Chrome is installed;
	/// without Chrome, Arx opens its place, if it has one. Chromium's debug and destructive pages
	/// are refused first. `browserIsInstalled` is asked only when the answer matters, and is asked
	/// when the link opens, never remembered.
	public func decision(browserIsInstalled: () -> Bool) -> Decision {
		if isRefused { return .refuse }

		switch (browser, place) {
		case let (.arc, place?):
			return .openInArx(place)

		case (.arc, nil):
			return browserIsInstalled() ? .openInBrowser(.arc) : .cannotOpen

		case let (.chrome, place):
			if browserIsInstalled() { return .appLinks }
			return place.map(Decision.openInArx) ?? .cannotOpen
		}
	}
}
