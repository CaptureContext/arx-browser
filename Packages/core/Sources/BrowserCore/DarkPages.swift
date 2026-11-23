import Foundation

/// When dark pages darken sites that have no dark look of their own (DEV-1020). Blink darkens
/// the page; a site whose `color-scheme` includes dark uses its own dark theme instead. A site
/// with only `prefers-color-scheme` rules gets its theme, with Blink's darkening over it
/// (DEV-1077).
public enum DarkPagesMode: String, CaseIterable, Codable, Sendable {
	case off

	/// While Arx's windows are dark: its theme, or the system's when it follows the system.
	case withTheme
	case always

	/// Whether pages are darkened while Arx's windows are dark or light.
	public func isActive(appearanceIsDark: Bool) -> Bool {
		switch self {
		case .off: false
		case .withTheme: appearanceIsDark
		case .always: true
		}
	}
}

/// What the engine darkens (DEV-1020): whether dark pages are on, and each profile's sites they
/// stay off on. Private profiles take their parent's sites.
public struct DarkPagesConfiguration: Equatable, Sendable {
	public var isActive: Bool
	public var offSites: [Profile.ID: [String]]

	public init(
		isActive: Bool,
		offSites: [Profile.ID: [String]] = [:]
	) {
		self.isActive = isActive
		self.offSites = offSites
	}

	/// Off, as it is while the feature flag is off or the engine can't darken pages.
	public static let off: Self = .init(isActive: false)

	/// The configuration for `mode`, Arx's windows' appearance and the organization's profiles.
	public init(
		mode: DarkPagesMode,
		appearanceIsDark: Bool,
		profiles: some Sequence<Profile>
	) {
		let isActive = mode.isActive(appearanceIsDark: appearanceIsDark)
		self.init(
			isActive: isActive,
			offSites: isActive
			? Dictionary(profiles.compactMap { profile in
				profile.darkPagesOffSites.map { (profile.id, $0) }
			}, uniquingKeysWith: { first, _ in first })
			: [:]
		)
	}

	/// The sites `profile`'s pages stay light on.
	public func offSites(for profile: Profile.ID) -> [String] {
		offSites[profile] ?? []
	}

	/// Whether a page at `url` in `profile` is darkened: an http(s) site that isn't turned off.
	public func darkens(
		_ url: URL,
		in profile: Profile.ID
	) -> Bool {
		guard isActive, KeptLoadedSite.site(of: url) != nil else { return false }

		return !offSites(for: profile).contains { KeptLoadedSite.matches(url, site: $0) }
	}
}

/// The `ARX_DARK_PAGES` feature flag (DEV-1020), read through `FeatureFlag`: on by default
/// (DEV-1143), and `0`, `false`, `no` or `off` turns it off.
public enum DarkPagesFeatureFlag {
	public static let name: String = FeatureFlag.darkPages.name

	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.darkPages.isOn(environment: environment, defaults: defaults)
	}
}
