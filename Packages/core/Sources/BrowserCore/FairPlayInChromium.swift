import Foundation

/// FairPlay in Chromium tabs (DEV-1144): sites whose protected media plays in a Chromium tab
/// instead of moving to a WebKit page. The page keeps running in Chromium; a script in its
/// main world answers its Encrypted Media Extensions calls with FairPlay, and Arx's FairPlay
/// helper plays the stream with AVFoundation, driven by the page's own controls.
public enum FairPlayInChromium {
	/// The `ARX_FAIRPLAY_IN_CHROMIUM` feature flag, on by default (DEV-1143).
	public static let featureFlag: String = FeatureFlag.fairPlayInChromium.name

	/// The sites that play this way: exact, serialized https origins. Only Spotify's web
	/// player for now. Netflix and Disney+ serve FairPlay through MediaSource, not HLS, so they
	/// need a video path of their own and stay in WebKit pages.
	public static let origins: [String] = [
		"https://open.spotify.com",
	]

	/// Read through `FeatureFlag`: the environment first, then user defaults. `0`, `false`, `no`
	/// or `off` turns it off; anything else, or nothing, leaves it on.
	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.fairPlayInChromium.isOn(environment: environment, defaults: defaults)
	}

	/// The bridged origin of `url`, if it's one: the page's scheme, host and port, exactly.
	public static func origin(of url: URL) -> String? {
		guard
			url.scheme?.lowercased() == "https",
			let host = url.host(percentEncoded: false)?.lowercased()
		else { return nil }

		let port = url.port.map { $0 == 443 ? "" : ":\($0)" } ?? ""
		let origin = "https://" + host + port
		return origins.contains(origin) ? origin : nil
	}
}

/// The Widevine answer's engine side (DEV-1144). The engine reads it once at launch, from the
/// environment or else Arx's defaults, under this name; the app writes Settings' switch there.
/// Arx loads no Widevine either way.
public enum WidevineAnswer {
	public static let featureFlag: String = "ARX_WIDEVINE_ANSWER"

	/// What Arx's defaults hold for the switch: the engine changes only on the exact `off`.
	public static func defaultsValue(_ isOn: Bool) -> String {
		isOn ? "on" : "off"
	}
}

extension WebKitPagePreferences {
	/// The bridged origins that stay in Chromium tabs under these preferences: all of `origins`
	/// with "FairPlay in the tab", none with "Open in a WebKit page".
	public func bridgedOrigins(_ origins: [String]) -> [String] {
		protectedMedia == .fairPlayInTab ? origins : []
	}

	/// These preferences with exact `origins` kept in Chromium, so their pages stay there: no move
	/// on open, typed address or followed link. Every other page a listed site covers still opens
	/// in WebKit, such as `accounts.spotify.com` under a `spotify.com` entry.
	public func keepingInChromium(_ origins: [String]) -> Self {
		var preferences = self
		preferences.chromiumOrigins.formUnion(origins)
		return preferences
	}
}
