import Foundation

/// The colors a page declares for the browser around it (DEV-1101).
public struct PageColors: Equatable, Sendable {
	/// The page's `<meta name="theme-color">`. The engine picks the tag whose `media` matches the
	/// page's light or dark scheme, as Safari and Chrome do.
	public var theme: ChromePalette.RGB?

	/// The background the page's CSS gives its document, behind its top edge.
	public var background: ChromePalette.RGB?

	public init(
		theme: ChromePalette.RGB? = nil,
		background: ChromePalette.RGB? = nil
	) {
		self.theme = theme
		self.background = background
	}

	public static let none: Self = .init()

	/// From an engine's colors as `0xAARRGGBB`. Browsers draw a theme color opaque, so its alpha
	/// is ignored, and a fully transparent one counts as none. A background that isn't opaque
	/// isn't what the page shows over the engine's own base color, so it counts as none.
	public init(
		themeARGB: UInt32?,
		backgroundARGB: UInt32?
	) {
		self.init(
			theme: themeARGB.flatMap { $0 >> 24 == 0 ? nil : ChromePalette.RGB(argb: $0) },
			background: backgroundARGB.flatMap { $0 >> 24 == 0xFF ? ChromePalette.RGB(argb: $0) : nil }
		)
	}

	/// The color Match site follows: the declared theme color, else the background.
	public var preferred: ChromePalette.RGB? { theme ?? background }
}

extension ChromePalette.RGB {
	/// The red, green and blue of `0xAARRGGBB`, in gamma-encoded sRGB; the alpha is dropped.
	public init(argb: UInt32) {
		self.init(
			red: Double((argb >> 16) & 0xFF) / 255,
			green: Double((argb >> 8) & 0xFF) / 255,
			blue: Double(argb & 0xFF) / 255
		)
	}
}

/// The `ARX_MATCH_SITE_BACKGROUND` feature flag (DEV-1101): a space can choose Match site, and its
/// chrome then takes the color of the page it shows. On by default (DEV-1143).
public enum MatchSiteBackground {
	public static let featureFlag: String = FeatureFlag.matchSiteBackground.name

	/// Read through `FeatureFlag`: `0`, `false`, `no` or `off` turns it off; anything else, or
	/// nothing, leaves it on.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.matchSiteBackground.isOn(environment: environment, defaults: defaults)
	}

	/// The color a shown page offers the chrome, or nil when it has none to offer: a page that
	/// isn't an ordinary web page (blank, Settings, a local file), one that failed to load, or one
	/// the engine unloaded. A PDF reports no colors.
	public static func color(of navigation: BrowserNavigation) -> ChromePalette.RGB? {
		guard
			navigation.showsWebPage,
			navigation.errorCode == nil,
			!navigation.isUnloaded
		else { return nil }
		return navigation.colors.preferred
	}

	/// The color the chrome around the shown panes takes: the active pane's, while every pane
	/// shows the same site. Panes showing different sites keep the space's own color, since no
	/// one page's color stands for the window.
	public static func color(
		panes: [BrowserNavigation],
		active: Int
	) -> ChromePalette.RGB? {
		let sites: [String?] = panes.map { site(of: $0.url) }
		guard
			panes.indices.contains(active),
			let site = sites[active],
			sites.allSatisfy({ $0 == site })
		else { return nil }
		return color(of: panes[active])
	}

	/// The host without a leading `www.`, so a site and its `www` address count as one.
	private static func site(of url: URL?) -> String? {
		guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
		return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
	}
}
