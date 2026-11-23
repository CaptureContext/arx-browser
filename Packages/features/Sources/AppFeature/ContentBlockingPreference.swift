import BrowserCore

/// Settings › General › Content blocking, as the engine takes it (DEV-884).
internal struct ContentBlockingPreference: Equatable, Sendable {
	internal var isOn: Bool
	internal var blocksCookieBanners: Bool
}
