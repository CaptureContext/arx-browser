import Foundation

/// Text typed in the URL bar or the command bar that's an address with a scheme other than
/// http(s) (DEV-1189): `arx://settings`, `chrome://settings/passwords`, `about:blank`,
/// `file:///…`, `mailto:…`, or an app's own, such as `slack://open` or `zoommtg://…`.
///
/// Plain words still search, as in Chrome. `scheme:rest` is an address only when browsers
/// know the scheme, `//` follows it, or an app on this Mac opens it. So `note:milk` searches
/// while `spotify:track:…` opens Spotify. `example.com:8080` is a host and port, not a scheme.
/// `arx://` and `chrome://` are addresses only where Arx has a place for them
/// (`SettingsAddress`), and `about:` only for `about:blank`. `javascript:` and `data:` are never
/// opened from the bar.
public enum TypedSchemeAddress {
	/// What `text` is, when it starts with a scheme.
	public enum Kind: Equatable, Sendable {
		/// A page Arx's engine shows: `about:blank`, `file:` or `view-source:`.
		case page

		/// A place in Arx, by `SettingsAddress`.
		case settings(SettingsAddress)

		/// Another app's link, which goes to App Links.
		case app(scheme: String)
	}

	/// Schemes that are addresses without `//`.
	public static let knownSchemes: Set<String> = [
		"about", "facetime", "facetime-audio", "file", "mailto", "sms", "tel", "view-source",
	]

	/// Schemes whose addresses Arx's engine shows as pages.
	public static let pageSchemes: Set<String> = ["about", "file", "view-source"]

	/// Schemes the bar never opens: `javascript:` and `vbscript:` would run script in the page, and
	/// the engine opens no `data:` page a person navigates to.
	public static let refusedSchemes: Set<String> = ["data", "javascript", "vbscript"]

	/// The address `text` names and what it is, or nil when it's no such address. `hasApp`
	/// answers whether an app on this Mac opens a scheme; it's asked only for `scheme:rest`
	/// text whose scheme browsers don't know.
	public static func address(
		_ text: String,
		hasApp: (String) -> Bool
	) -> (url: URL, kind: Kind)? {
		let text: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			text.utf8.count <= maximumLength,
			!text.contains(where: \.isWhitespace),
			let (scheme, rest) = parts(text),
			!["http", "https"].contains(scheme),
			!refusedSchemes.contains(scheme),
			let url = URL(string: text, encodingInvalidCharacters: false),
			url.scheme != nil
		else { return nil }

		switch scheme {
		case SettingsAddress.arxScheme, SettingsAddress.chromeScheme:
			return SettingsAddress(url).map { (url, .settings($0)) }

		case "about":
			// The engine opens `about:blank` as written exactly so, whatever case was typed.
			guard rest.lowercased() == "blank", let blank = URL(string: "about:blank") else { return nil }
			return (blank, .page)

		default:
			let isAddress: Bool = rest.hasPrefix("//")
				|| knownSchemes.contains(scheme)
				|| (!isPort(rest) && hasApp(scheme))
			guard isAddress else { return nil }

			return (url, pageSchemes.contains(scheme) ? .page : .app(scheme: scheme))
		}
	}

	/// The scheme of `text`, lowercased, when it may be another app's: the one to ask an app
	/// for before `address(_:hasApp:)` reads it, and to name in its row. Nil for text that can't
	/// be an app's link.
	public static func appScheme(_ text: String) -> String? {
		let text: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			!text.contains(where: \.isWhitespace),
			let (scheme, rest) = parts(text),
			!["http", "https", SettingsAddress.arxScheme, SettingsAddress.chromeScheme].contains(scheme),
			!pageSchemes.contains(scheme),
			!refusedSchemes.contains(scheme),
			rest.hasPrefix("//") || knownSchemes.contains(scheme) || !isPort(rest)
		else { return nil }

		return scheme
	}

	/// Whether `url` belongs to another app rather than a page or a place in Arx.
	public static func opensInApp(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased() else { return false }
		return !["http", "https", SettingsAddress.arxScheme, SettingsAddress.chromeScheme].contains(scheme)
			&& !pageSchemes.contains(scheme)
			&& !refusedSchemes.contains(scheme)
	}

	/// The longest text read as an address, as for App Links.
	internal static let maximumLength: Int = 8 * 1024

	/// The lowercased scheme and what follows its colon, when `text` starts with a URI scheme
	/// followed by more.
	private static func parts(_ text: String) -> (scheme: String, rest: Substring)? {
		guard
			let colon = text.firstIndex(of: ":"),
			let first = text.first,
			first.isASCII,
			first.isLetter
		else { return nil }

		let scheme: Substring = text[..<colon]
		let rest: Substring = text[text.index(after: colon)...]
		guard
			!rest.isEmpty,
			scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
		else { return nil }

		return (scheme.lowercased(), rest)
	}

	/// `8080` or `8080/path`: the port after a host, as in `example.com:8080`.
	private static func isPort(_ rest: Substring) -> Bool {
		let digits = rest.prefix { $0.isASCII && $0.isNumber }
		guard !digits.isEmpty else { return false }

		let after = rest.dropFirst(digits.count)
		return after.isEmpty || "/?#".contains(after.first ?? " ")
	}
}
