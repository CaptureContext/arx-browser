import BrowserCore
import Foundation

/// What a site publishes about a page for link previews: Open Graph, Twitter cards, or the
/// page's own title and description.
public struct PageDetails: Equatable, Sendable {
	public var title: String?
	public var description: String?
	public var imageURL: URL?

	public init(
		title: String? = nil,
		description: String? = nil,
		imageURL: URL? = nil
	) {
		self.title = title
		self.description = description
		self.imageURL = imageURL
	}

	public var isEmpty: Bool { title == nil && description == nil && imageURL == nil }
}

/// The tab's profile behind a fetch (DEV-1142): the cookies it would send go to the page's own
/// host and nowhere else, read again for every request and redirect.
public struct PageFetchCredentials: Sendable {
	/// The page a card describes. Only requests to its host carry cookies.
	public var pageURL: URL

	/// The cookies the profile would send to an address.
	public var cookies: @Sendable (URL) async -> [HTTPCookie]

	public init(
		pageURL: URL,
		cookies: @escaping @Sendable (URL) async -> [HTTPCookie]
	) {
		self.pageURL = pageURL
		self.cookies = cookies
	}

	/// Whether a request to `url` may carry the profile's cookies: the page's own host, ignoring
	/// case. Stricter than same-site, which would need the public suffix list.
	public func covers(_ url: URL) -> Bool {
		guard
			let host = url.host()?.lowercased(), !host.isEmpty,
			let pageHost = pageURL.host()?.lowercased()
		else { return false }

		return host == pageHost
	}

	/// The `Cookie` header for a request to `url`, or nil when it gets none.
	internal func header(for url: URL) async -> String? {
		guard covers(url) else { return nil }
		let cookies = await cookies(url)
		guard !cookies.isEmpty else { return nil }
		return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
	}
}

/// Fetches a page's details and published picture outside Chromium, with no cache, stored
/// credentials or referrer (DEV-730).
///
/// Without `PageFetchCredentials` no cookie is sent. With them (DEV-1142), requests to the
/// page's own host carry the cookies its profile would send; every other host, a redirect's
/// included, gets none. A reply's cookies are never kept.
///
/// Only http(s) pages without credentials in the address are fetched, redirects stay on
/// http(s), and every response is bounded: the document is read up to its `</head>`, at most
/// 512 KiB, and a picture at most 4 MiB.
public final class PageDetailsFetcher: Sendable {
	public static let maximumDocumentBytes: Int = 512 * 1024
	public static let maximumImageBytes: Int = 4 * 1024 * 1024
	public static let timeout: TimeInterval = 8

	private let session: URLSession

	/// `configure` lets tests route requests through a stub protocol.
	public init(configure: (URLSessionConfiguration) -> Void = { _ in }) {
		let configuration = Self.configuration()
		configure(configuration)
		self.session = URLSession(configuration: configuration, delegate: Guard(credentials: nil), delegateQueue: nil)
	}

	deinit {
		session.invalidateAndCancel()
	}

	/// An ephemeral session that neither sends nor keeps cookies, caches or credentials of its
	/// own; a profile's cookies are added by hand, request by request.
	public static func configuration() -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.httpCookieAcceptPolicy = .never
		configuration.urlCache = nil
		configuration.urlCredentialStorage = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		configuration.timeoutIntervalForRequest = timeout
		configuration.timeoutIntervalForResource = timeout
		configuration.httpMaximumConnectionsPerHost = 2
		configuration.waitsForConnectivity = false
		configuration.httpAdditionalHeaders = [
			"User-Agent": userAgent,
			"Accept-Language": acceptLanguage,
		]
		return configuration
	}

	/// The page's details, or nil when it can't be fetched or isn't HTML. `credentials` send the
	/// profile's cookies to the page's own host.
	public func details(
		for url: URL,
		credentials: PageFetchCredentials? = nil
	) async -> PageDetails? {
		guard Self.accepts(url) else { return nil }
		var request = URLRequest(url: url)
		request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
		do {
			let (bytes, response) = try await bytes(for: request, credentials: credentials)
			guard
				let response = response as? HTTPURLResponse,
				(200..<300).contains(response.statusCode),
				let finalURL = response.url, Self.accepts(finalURL),
				Self.isHTML(response.mimeType)
			else { return nil }

			var data = Data()
			data.reserveCapacity(64 * 1024)
			for try await byte in bytes {
				data.append(byte)
				if data.count >= Self.maximumDocumentBytes { break }
				if data.count % 4096 == 0, Self.headEnds(in: data) { break }
			}
			let details = Self.parse(Self.text(data, encoding: response.textEncodingName), baseURL: finalURL)
			return details.isEmpty ? nil : details
		} catch {
			return nil
		}
	}

	/// The bytes of a published picture, or nil when it isn't a bounded raster image.
	/// `credentials` send the profile's cookies only when the picture is on the page's own host.
	public func image(
		at url: URL,
		credentials: PageFetchCredentials? = nil
	) async -> Data? {
		guard Self.accepts(url) else { return nil }
		var request = URLRequest(url: url)
		request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
		do {
			let (bytes, response) = try await bytes(for: request, credentials: credentials)
			guard
				let response = response as? HTTPURLResponse,
				(200..<300).contains(response.statusCode),
				let type = response.mimeType?.lowercased(), type.hasPrefix("image/"), type != "image/svg+xml",
				response.expectedContentLength <= Int64(Self.maximumImageBytes)
			else { return nil }

			var data = Data()
			for try await byte in bytes {
				data.append(byte)
				if data.count > Self.maximumImageBytes { return nil }
			}
			return data.isEmpty ? nil : data
		} catch {
			return nil
		}
	}

	/// Starts a request with the profile's cookies when it goes to the page's own host. Its own
	/// guard reads them again for each redirect.
	private func bytes(
		for request: URLRequest,
		credentials: PageFetchCredentials?
	) async throws -> (URLSession.AsyncBytes, URLResponse) {
		var request = request
		if let url = request.url, let header = await credentials?.header(for: url) {
			request.setValue(header, forHTTPHeaderField: "Cookie")
		}
		return try await session.bytes(for: request, delegate: Guard(credentials: credentials))
	}

	// MARK: - Parsing

	/// Reads the details from a document's `<head>`. The first of each kind wins: Open Graph,
	/// then Twitter cards, then the page's own `<title>` and description.
	public static func parse(
		_ html: String,
		baseURL: URL
	) -> PageDetails {
		let head = scanHead(html)

		func first(_ keys: String...) -> String? {
			keys.lazy.compactMap { head.metas[$0].flatMap(clean) }.first
		}

		let image = first("og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src")
			.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
			.flatMap { accepts($0) ? $0 : nil }
		return .init(
			title: first("og:title", "twitter:title").map { bounded($0, 200) } ?? head.title.flatMap(clean).map { bounded($0, 200) },
			description: first("og:description", "twitter:description", "description").map { bounded($0, 300) },
			imageURL: image
		)
	}

	/// What a document's `<head>` holds so far, and whether it ended: a `</head>` or `<body>`
	/// outside comments and script, style, noscript and template bodies, which can hold anything.
	internal static func scanHead(_ html: String) -> (metas: [String: String], title: String?, ended: Bool) {
		var metas: [String: String] = [:]
		var title: String?
		var index = html.startIndex
		while let open = html[index...].firstIndex(of: "<") {
			let rest = html[open...]
			if rest.hasPrefix(caseInsensitive: "</head") || rest.hasPrefix(caseInsensitive: "<body") {
				return (metas, title, true)
			}
			if rest.hasPrefix("<!--") {
				guard let end = rest.range(of: "-->") else { break }
				index = end.upperBound
				continue
			}
			guard let close = tagEnd(in: html, from: open) else { break }
			let tag = html[html.index(after: open)..<close]
			index = html.index(after: close)

			if tag.hasPrefix(caseInsensitive: "meta"), tag.dropFirst(4).first?.isWhitespace == true {
				let attributes = attributes(tag.dropFirst(4))
				guard
					let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
					let content = attributes["content"], metas[key] == nil
				else { continue }
				metas[key] = content
			} else if title == nil, tag.lowercased() == "title" || tag.hasPrefix(caseInsensitive: "title ") {
				guard let end = html[index...].range(of: "</title", options: .caseInsensitive)
				else { break }
				title = String(html[index..<end.lowerBound])
				index = end.upperBound
			} else if let name = rawTextElement(tag) {
				guard let end = html[index...].range(of: "</\(name)", options: .caseInsensitive)
				else { break }
				index = end.upperBound
			}
		}
		return (metas, title, false)
	}

	/// Whether the document read so far ends its `<head>`. The cheap text check only decides
	/// whether the full scan, which skips comments and raw text, is worth running.
	internal static func headEnds(in data: Data) -> Bool {
		let tail = String(decoding: data.suffix(8192 + 7), as: UTF8.self).lowercased()
		guard tail.contains("</head") || tail.contains("<body") else { return false }
		return scanHead(String(decoding: data, as: UTF8.self)).ended
	}

	// MARK: - Private

	internal static let userAgent: String =
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Arx (link preview)"

	private static var acceptLanguage: String {
		let languages = Locale.preferredLanguages.prefix(3)
		guard !languages.isEmpty else { return "en" }
		return languages.enumerated().map { index, language in
			index == 0 ? language : "\(language);q=\(String(format: "%.1f", 1 - Double(index) * 0.2))"
		}.joined(separator: ", ")
	}

	/// http(s) with a host and no credentials.
	internal static func accepts(_ url: URL) -> Bool {
		url.hasWebScheme
		&& !(url.host() ?? "").isEmpty
		&& url.user() == nil
		&& url.password() == nil
		&& url.absoluteString.utf8.count <= 8192
	}

	private static func isHTML(_ type: String?) -> Bool {
		guard let type = type?.lowercased() else { return false }
		return type == "text/html" || type == "application/xhtml+xml"
	}


	private static func text(
		_ data: Data,
		encoding name: String?
	) -> String {
		if let name {
			let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
			if encoding != kCFStringEncodingInvalidId {
				let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
				if let text = String(data: data, encoding: encoding) { return text }
			}
		}
		return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
	}

	/// The index of the `>` that ends a tag opened at `open`, skipping quoted values.
	private static func tagEnd(
		in html: String,
		from open: String.Index
	) -> String.Index? {
		var quote: Character?
		var index = html.index(after: open)
		while index < html.endIndex {
			let character = html[index]
			if let current = quote {
				if character == current { quote = nil }
			} else if character == "\"" || character == "'" {
				quote = character
			} else if character == ">" {
				return index
			}
			index = html.index(after: index)
		}
		return nil
	}

	private static func rawTextElement(_ tag: Substring) -> String? {
		for name in ["script", "style", "noscript", "template"] where tag.hasPrefix(caseInsensitive: name) {
			let next = tag.dropFirst(name.count).first
			if next == nil || next?.isWhitespace == true || next == "/" { return name }
		}
		return nil
	}

	/// A tag's attributes, lowercased names to raw values.
	private static func attributes(_ text: Substring) -> [String: String] {
		var attributes: [String: String] = [:]
		var index = text.startIndex
		func skipSpaces() {
			while index < text.endIndex, text[index].isWhitespace || text[index] == "/" { index = text.index(after: index) }
		}
		while true {
			skipSpaces()
			guard index < text.endIndex else { break }
			let nameStart = index
			while index < text.endIndex, !text[index].isWhitespace, text[index] != "=", text[index] != "/" {
				index = text.index(after: index)
			}
			let name = text[nameStart..<index].lowercased()
			skipSpaces()
			guard index < text.endIndex, text[index] == "=" else {
				if !name.isEmpty { attributes[name] = attributes[name] ?? "" }
				continue
			}
			index = text.index(after: index)
			while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
			guard index < text.endIndex else { break }
			let value: Substring
			if text[index] == "\"" || text[index] == "'" {
				let quote = text[index]
				let start = text.index(after: index)
				let end = text[start...].firstIndex(of: quote) ?? text.endIndex
				value = text[start..<end]
				index = end < text.endIndex ? text.index(after: end) : end
			} else {
				let start = index
				while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
				value = text[start..<index]
			}
			if !name.isEmpty, attributes[name] == nil { attributes[name] = String(value) }
		}
		return attributes
	}

	/// Decodes character references and collapses whitespace; nil when nothing is left.
	internal static func clean(_ text: String) -> String? {
		let decoded = decodeEntities(text)
			.split(whereSeparator: \.isWhitespace)
			.joined(separator: " ")
		return decoded.isEmpty ? nil : decoded
	}

	private static func bounded(
		_ text: String,
		_ limit: Int
	) -> String {
		text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
	}

	private static let namedEntities: [String: String] = [
		"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
		"mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
		"rdquo": "”", "ldquo": "“", "middot": "·", "bull": "•", "copy": "©", "reg": "®", "trade": "™",
	]

	private static func decodeEntities(_ text: String) -> String {
		guard text.contains("&") else { return text }
		var result = ""
		var index = text.startIndex
		while let amp = text[index...].firstIndex(of: "&") {
			result += text[index..<amp]
			let after = text.index(after: amp)
			guard
				let semicolon = text[after...].prefix(12).firstIndex(of: ";"),
				let decoded = decodeEntity(text[after..<semicolon])
			else {
				result.append("&")
				index = after
				continue
			}
			result += decoded
			index = text.index(after: semicolon)
		}
		return result + text[index...]
	}

	private static func decodeEntity(_ name: Substring) -> String? {
		if name.hasPrefix("#") {
			let digits = name.dropFirst()
			let value = digits.first == "x" || digits.first == "X"
			? UInt32(digits.dropFirst(), radix: 16)
			: UInt32(digits, radix: 10)
			return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
		}
		return namedEntities[name.lowercased()]
	}

	/// Keeps redirects on http(s), gives each hop only the cookies its own host may get, and
	/// never answers a site's password prompt.
	private final class Guard: NSObject, URLSessionTaskDelegate, Sendable {
		private let credentials: PageFetchCredentials?

		internal init(credentials: PageFetchCredentials?) {
			self.credentials = credentials
		}

		internal func urlSession(
			_ session: URLSession,
			task: URLSessionTask,
			willPerformHTTPRedirection response: HTTPURLResponse,
			newRequest request: URLRequest
		) async -> URLRequest? {
			guard let url = request.url, PageDetailsFetcher.accepts(url) else { return nil }
			var request = request
			request.setValue(nil, forHTTPHeaderField: "Referer")
			request.setValue(nil, forHTTPHeaderField: "Cookie")
			if let header = await credentials?.header(for: url) {
				request.setValue(header, forHTTPHeaderField: "Cookie")
			}
			return request
		}

		internal func urlSession(
			_ session: URLSession,
			task: URLSessionTask,
			didReceive challenge: URLAuthenticationChallenge
		) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
			challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
			? (.performDefaultHandling, nil)
			: (.cancelAuthenticationChallenge, nil)
		}
	}
}

extension StringProtocol {
	fileprivate func hasPrefix(caseInsensitive prefix: String) -> Bool {
		// `prefix` stops early; `count` would walk the whole document.
		self.prefix(prefix.count).lowercased() == prefix
	}
}
