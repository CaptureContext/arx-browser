import BrowserCore
import SwiftUI

/// A split pane's address (DEV-993): the whole URL without its scheme, the host first and
/// always shown, and the rest after it, cut off at the end when the pane is too narrow.
public struct PaneAddress: View {
	public let url: URL

	public init(url: URL) {
		self.url = url
	}

	public var body: some View {
		let (host, rest) = Self.parts(for: url)
		HStack(spacing: 0) {
			Text(verbatim: host)
				.foregroundStyle(BrowserTheme.text)
				.lineLimit(1)
				.layoutPriority(1)
			if !rest.isEmpty {
				Text(verbatim: rest)
					.lineLimit(1)
					.truncationMode(.tail)
			}
		}
		.accessibilityElement(children: .combine)
	}

	/// The host, then everything after it: port, path, query and fragment. A site's front page
	/// has no trailing slash. A diagnostic page reads as the address bar shows it, and a local file
	/// is its path with the home folder as `~`. An address without a host, such as `about:blank`,
	/// is all host, so none of it is cut off first.
	public static func parts(for url: URL) -> (host: String, rest: String) {
		if let diagnostic = DiagnosticPage.displayAddress(for: url) { return (diagnostic, "") }
		if let path = url.localFileDisplayPath { return (path, "") }
		guard let bare = url.host(percentEncoded: false), !bare.isEmpty else {
			let text = url.absoluteString
			let scheme = (url.scheme ?? "") + ":"
			return (text.hasPrefix(scheme) ? String(text.dropFirst(scheme.count)) : text, "")
		}

		// An IPv6 address keeps its brackets, so a port after it can't read as part of it.
		let host = bare.contains(":") ? "[" + bare + "]" : bare

		var rest = ""
		if let port = url.port { rest += ":\(port)" }
		let path = url.path(percentEncoded: true)
		if path != "/" || url.query(percentEncoded: true) != nil || url.fragment(percentEncoded: true) != nil {
			rest += path
		}
		if let query = url.query(percentEncoded: true) { rest += "?" + query }
		if let fragment = url.fragment(percentEncoded: true) { rest += "#" + fragment }
		return (host, rest)
	}
}
