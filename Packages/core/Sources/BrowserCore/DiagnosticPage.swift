import Foundation

/// Chromium's diagnostic pages that Arx opens in a tab, shown as `arx://` addresses (DEV-898).
///
/// `arx://version` and `arx://gpu` are for everyone, since bug reports need them. The rest are
/// for developers and open only with developer mode on. Typing the `chrome://` form works too.
/// The engine loads them only from a typed address or a restored tab, never from a page, and
/// only these hosts (`Packages/engine/Native/page_menu_bridge.mm`, `DiagnosticPageURL`).
public enum DiagnosticPage: String, CaseIterable, Codable, Hashable, Sendable {
	case version
	case gpu
	case netInternals = "net-internals"
	case processInternals = "process-internals"
	case mediaInternals = "media-internals"
	case serviceWorkerInternals = "serviceworker-internals"
	case webRTCInternals = "webrtc-internals"
	case inspect

	public static let arxScheme: String = "arx"
	public static let engineScheme: String = "chrome"

	/// The page's host in both schemes.
	public var host: String { rawValue }

	public var requiresDeveloperMode: Bool {
		switch self {
		case .version, .gpu: false
		case .netInternals, .processInternals, .mediaInternals, .serviceWorkerInternals, .webRTCInternals, .inspect: true
		}
	}

	public func isAvailable(developerModeEnabled: Bool) -> Bool {
		!requiresDeveloperMode || developerModeEnabled
	}

	/// `arx://gpu`, as the address bar shows it.
	public var address: URL {
		URL(string: Self.arxScheme + "://" + host)!
	}

	/// `chrome://gpu`, as the engine loads it.
	public var engineURL: URL {
		URL(string: Self.engineScheme + "://" + host)!
	}

	/// The page a typed address names, `arx://gpu` or `chrome://gpu`, with any path or fragment
	/// (`arx://net-internals/#dns`), and the engine URL to load. Nil for anything else, including
	/// credentials, a port or a query.
	public static func typed(_ text: String) -> (page: Self, url: URL)? {
		guard
			let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
			let scheme = components.scheme?.lowercased(),
			[arxScheme, engineScheme].contains(scheme),
			let host = components.host?.lowercased(),
			let page = Self(rawValue: host),
			components.user == nil,
			components.password == nil,
			components.port == nil,
			components.query == nil
		else { return nil }

		var engine = components
		engine.scheme = engineScheme
		engine.host = host
		guard let url = engine.url else { return nil }

		return (page, url)
	}

	/// The page an engine URL shows, or nil for any other URL.
	public static func page(for url: URL) -> Self? {
		guard url.scheme?.lowercased() == engineScheme, let host = url.host()?.lowercased()
		else { return nil }

		return Self(rawValue: host)
	}

	/// The `arx://` form of a diagnostic page's engine URL, keeping its path and fragment, or nil
	/// for any other URL. The address bar shows this instead of `chrome://`.
	public static func displayAddress(for url: URL) -> String? {
		guard page(for: url) != nil else { return nil }

		let text = url.absoluteString
		return arxScheme + text.dropFirst(engineScheme.count)
	}
}
