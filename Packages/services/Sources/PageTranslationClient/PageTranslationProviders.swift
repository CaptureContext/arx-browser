import BrowserCore
import Foundation
import Translation

/// How a segment's runs travel through Apple's Translation (DEV-996). Each run is a piece of one
/// `AttributedString` marked with its own `arx-run:<index>` link, which the translation keeps on
/// the words it became; runs kept as they are also skip translation. The words under each mark
/// go back to that run, so a sentence is translated whole and its link stays on its own words.
public enum AppleTranslationRuns {
	private static let scheme: String = "arx-run"

	public static func attributed(_ runs: [PageTranslationScripts.Run]) -> AttributedString {
		var text = AttributedString()
		for (index, run) in runs.enumerated() {
			var piece = AttributedString(run.text)
			piece.link = URL(string: "\(scheme):\(index)")
			if !run.translate { piece.translation.skipsTranslation = true }
			text.append(piece)
		}
		return text
	}

	/// Each run's translation from the translated text, and their order when it moved them
	/// (`PageTranslationScripts.arrange`). Nil when nothing came back.
	public static func texts(
		from translated: AttributedString,
		runs: [PageTranslationScripts.Run]
	) -> PageTranslationScripts.Arrangement? {
		var chunks: [PageTranslationScripts.Placement] = []
		for run in translated.runs {
			var index: Int?
			if
				let link = run.link,
				link.scheme == scheme,
				let marked = Int(link.absoluteString.dropFirst(scheme.count + 1)),
				runs.indices.contains(marked)
			{
				index = marked
			}
			chunks.append(.init(run: index, text: String(translated[run.range].characters)))
		}
		return PageTranslationScripts.arrange(chunks, runs: runs)
	}
}

/// Google Translate without an API key (DEV-996): the endpoint Google's own Translate Element
/// sends a page's HTML to, `translate.googleapis.com/translate_a/t` with `client=gtx` and
/// `format=html`. It isn't a documented API and may change or refuse. The page's text goes to
/// Google, which is why it's a choice the person makes; no cookies or Arx identity go with it.
public enum GoogleTranslation {
	public static let endpoint: URL = .init(string: "https://translate.googleapis.com/translate_a/t")!

	/// Characters sent in one request; Google's page script sends about as much.
	public static let maximumRequestCharacters: Int = 5000

	/// A segment as HTML, as Google's own page script sends it: the block's plain text as it
	/// is, each run in an inline element (a link, emphasis) in `<a i=N>`, and each run kept in
	/// `<code i=N>`, which Google leaves as it is. The markers come back around the words they
	/// became; Google moves markers on plain text about as if they were links, so it gets none.
	public static func html(_ runs: [PageTranslationScripts.Run]) -> String {
		runs.enumerated().map { index, run in
			if run.translate, run.plain { return escape(run.text) }
			let tag = run.translate ? "a" : "code"
			return "<\(tag) i=\(index)>\(escape(run.text))</\(tag)>"
		}.joined()
	}

	/// Each run's translation from Google's HTML, as `AppleTranslationRuns.texts` does: text
	/// inside a run's marker is that run's; each stretch of text outside every marker goes to
	/// the next plain run, in reading order, and beyond the last one belongs to no run.
	public static func texts(
		from html: String,
		runs: [PageTranslationScripts.Run]
	) -> PageTranslationScripts.Arrangement? {
		var chunks: [PageTranslationScripts.Placement] = []
		var current: Int?
		var plain = runs.indices.filter { runs[$0].translate && runs[$0].plain }[...]
		var stretch: Int?
		var inStretch = false
		var rest = Substring(html)
		let opening = /<(a|code|span)[^>]*\bi=(\d+)[^>]*>/
		let closing = /<\/(a|code|span)>/
		while !rest.isEmpty {
			if let match = rest.prefixMatch(of: opening) {
				current = Int(match.output.2).flatMap { runs.indices.contains($0) ? $0 : nil }
				inStretch = false
				rest = rest[match.range.upperBound...]
			} else if let match = rest.prefixMatch(of: closing) {
				current = nil
				inStretch = false
				rest = rest[match.range.upperBound...]
			} else if let match = rest.prefixMatch(of: /<[^>]*>/) {
				// Any other tag Google added is dropped.
				rest = rest[match.range.upperBound...]
			} else {
				let end = rest.firstIndex(of: "<") ?? rest.endIndex
				var run = current
				if run == nil {
					if !inStretch {
						stretch = plain.popFirst()
						inStretch = true
					}
					run = stretch
				}
				chunks.append(.init(run: run, text: unescape(String(rest[..<end]))))
				rest = rest[end...]
			}
		}
		return PageTranslationScripts.arrange(chunks, runs: runs)
	}

	/// Google's code for a language where it differs from Apple's.
	public static func code(_ language: String) -> String {
		switch language {
		case "zh-Hans", "zh": "zh-CN"
		case "zh-Hant": "zh-TW"
		case "nb": "no"
		default: language
		}
	}

	/// The languages Google translates into, as base codes, for Choose Another Language.
	public static let languages: [String] = TranslationProvider.google.targetLanguages

	/// The request for some segments' HTML: a form POST with one `q` per segment.
	public static func request(
		_ html: [String],
		source: String,
		target: String
	) -> URLRequest {
		var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
		components.queryItems = [
			.init(name: "client", value: "gtx"),
			.init(name: "sl", value: code(source)),
			.init(name: "tl", value: code(target)),
			.init(name: "format", value: "html"),
		]
		var request = URLRequest(url: components.url!, timeoutInterval: 20)
		request.httpMethod = "POST"
		request.httpShouldHandleCookies = false
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		request.httpBody = Data(html.map { "q=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
			.joined(separator: "&").utf8)
		return request
	}

	/// Google's answer: one translated string per `q`, or `[text, language]` pairs when the
	/// source was `auto`. Nil when it's neither or the count is wrong.
	public static func decode(
		_ data: Data,
		count: Int
	) -> [String]? {
		guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
			// A single `q` can come back as a bare string.
			if count == 1, let text = try? JSONDecoder().decode(String.self, from: data) { return [text] }
			return nil
		}
		let texts: [String] = array.compactMap { item in
			if let text = item as? String { return text }
			return (item as? [Any])?.first as? String
		}
		return texts.count == count ? texts : nil
	}

	/// Groups segments so each request stays under `maximumRequestCharacters`.
	public static func requests(_ html: [String]) -> [Range<Int>] {
		var ranges: [Range<Int>] = []
		var start = 0
		var characters = 0
		for (index, text) in html.enumerated() {
			if characters + text.count > maximumRequestCharacters, index > start {
				ranges.append(start ..< index)
				start = index
				characters = 0
			}
			characters += text.count
		}
		if start < html.count { ranges.append(start ..< html.count) }
		return ranges
	}

	/// A session that keeps no cookies, cache or credentials.
	public static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieAcceptPolicy = .never
		configuration.httpShouldSetCookies = false
		configuration.urlCache = nil
		configuration.urlCredentialStorage = nil
		return URLSession(configuration: configuration)
	}()

	internal static func escape(_ text: String) -> String {
		text.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}

	internal static func unescape(_ text: String) -> String {
		guard text.contains("&") else { return text }
		var result = ""
		var rest = Substring(text)
		while let amp = rest.firstIndex(of: "&") {
			result += rest[..<amp]
			rest = rest[amp...]
			guard let semicolon = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semicolon) <= 10 else {
				result += "&"
				rest = rest.dropFirst()
				continue
			}
			let entity = rest[rest.index(after: rest.startIndex) ..< semicolon]
			let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
			if let value = named[String(entity)] {
				result += value
			} else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
				result.unicodeScalars.append(scalar)
			} else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
				result.unicodeScalars.append(scalar)
			} else {
				result += "&"
				rest = rest.dropFirst()
				continue
			}
			rest = rest[rest.index(after: semicolon)...]
		}
		return result + rest
	}
}
