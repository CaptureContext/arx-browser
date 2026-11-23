import BrowserPagePreviewClient
import CustomDump
import Foundation
import Synchronization
import Testing

/// DEV-730: site details for pages that aren't loaded, fetched without cookies. DEV-1142: with
/// the tab's profile, its cookies go to the page's own host only.
internal struct PageDetailsFetcherTests {
	// MARK: - Parsing

	@Test
	internal func openGraphWinsOverTwitterAndThePagesOwn() {
		let html = """
		<!doctype html><html><head>
		<title>Own title</title>
		<meta name="description" content="Own description">
		<meta name="twitter:description" content="Card description">
		<meta property="og:description" content="Graph &amp; description">
		<meta property='og:title' content='Graph title'>
		<meta property="og:image" content="/images/card.png">
		</head><body><meta property="og:image" content="https://evil.example/late.png"></body></html>
		"""
		expectNoDifference(
			PageDetailsFetcher.parse(html, baseURL: URL(string: "https://example.com/a/b")!),
			.init(
				title: "Graph title",
				description: "Graph & description",
				imageURL: URL(string: "https://example.com/images/card.png")
			)
		)
	}

	@Test
	internal func fallsBackToThePagesOwnTitleAndDescription() {
		let html = """
		<html><head><TITLE>
		  Plain   page &#8212; site
		</TITLE><META NAME=description CONTENT="Line one
		line two"></head>
		"""
		expectNoDifference(
			PageDetailsFetcher.parse(html, baseURL: URL(string: "https://example.com")!),
			.init(title: "Plain page — site", description: "Line one line two", imageURL: nil)
		)
	}

	@Test
	internal func ignoresTagsInsideScriptsCommentsAndAfterTheHead() {
		let html = """
		<head>
		<!-- <meta property="og:title" content="Commented"> -->
		<script>const s = '<meta property="og:title" content="Scripted">';</script>
		<meta property="og:image" content="javascript:alert(1)">
		</head>
		<meta property="og:title" content="Body">
		"""
		#expect(PageDetailsFetcher.parse(html, baseURL: URL(string: "https://example.com")!).isEmpty)
	}

	@Test
	internal func boundsLongText() throws {
		let html = #"<head><meta property="og:description" content="\#(String(repeating: "a", count: 1_000))"></head>"#
		let details = PageDetailsFetcher.parse(html, baseURL: URL(string: "https://example.com")!)
		#expect(try #require(details.description).count == 300)
	}

	// MARK: - Fetching

	@Test
	internal func sendsNoCookiesOrReferrerAndKeepsNothing() async throws {
		let host = Self.host()
		let cookie = try #require(HTTPCookie(properties: [
			.domain: host, .path: "/", .name: "session", .value: "secret", .secure: "TRUE",
		]))
		HTTPCookieStorage.shared.setCookie(cookie)
		defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
		StubProtocol.route(host) { _ in
			.init(
				status: 200,
				headers: ["Content-Type": "text/html; charset=utf-8", "Set-Cookie": "tracker=1; Path=/"],
				body: Data(#"<head><meta property="og:title" content="Hello"></head>"#.utf8)
			)
		}

		let fetcher = Self.fetcher()
		let details = await fetcher.details(for: URL(string: "https://\(host)/page")!)
		_ = await fetcher.details(for: URL(string: "https://\(host)/again")!)

		expectNoDifference(details, .init(title: "Hello"))
		let requests = StubProtocol.requests(host)
		#expect(requests.count == 2)
		for request in requests {
			#expect(request.value(forHTTPHeaderField: "Cookie") == nil)
			#expect(request.value(forHTTPHeaderField: "Referer") == nil)
			#expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Arx") == true)
		}
		let configuration = PageDetailsFetcher.configuration()
		#expect(configuration.httpCookieStorage == nil)
		#expect(!configuration.httpShouldSetCookies)
		#expect(configuration.urlCache == nil)
		#expect(configuration.urlCredentialStorage == nil)
	}

	@Test
	internal func readingDoesNotStopAtHeadOrBodyInsideScriptsOrComments() async {
		let host = Self.host()

		// Past the 4 KiB point where the reader first checks whether the head ended.
		let padding = String(repeating: "x", count: 5_000)
		let html = """
		<html><head>
		<script>const template = "</head><body>"; const pad = "\(padding)";</script>
		<!-- <body> moved below -->
		<style>/* </head> */ body { color: red }</style>
		<meta property="og:title" content="Still in the head">
		<meta property="og:description" content="Found after the decoys">
		</head><body>\(padding)<meta property="og:title" content="Body"></body></html>
		"""
		StubProtocol.route(host) { _ in
			.init(status: 200, headers: ["Content-Type": "text/html"], body: Data(html.utf8))
		}

		let details = await Self.fetcher().details(for: URL(string: "https://\(host)/")!)

		expectNoDifference(details, .init(title: "Still in the head", description: "Found after the decoys"))
	}

	@Test
	internal func refusesPagesThatAreNotWebAddressesOrCarryCredentials() async {
		let fetcher = Self.fetcher()
		#expect(await fetcher.details(for: URL(string: "file:///etc/hosts")!) == nil)
		#expect(await fetcher.details(for: URL(string: "https://user:pass@\(Self.host())/")!) == nil)
		#expect(await fetcher.image(at: URL(string: "data:image/png;base64,AAAA")!) == nil)
	}

	@Test
	internal func refusesWhatIsNotHTMLOrFailed() async {
		let host = Self.host()
		StubProtocol.route(host) { request in
			request.url?.path == "/json"
			? .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
			: .init(
				status: 404,
				headers: ["Content-Type": "text/html"],
				body: Data(#"<meta property="og:title" content="x">"#.utf8)
			)
		}
		let fetcher = Self.fetcher()
		#expect(await fetcher.details(for: URL(string: "https://\(host)/json")!) == nil)
		#expect(await fetcher.details(for: URL(string: "https://\(host)/missing")!) == nil)
	}

	@Test
	internal func imagesAreBoundedAndNeverSVG() async {
		let host = Self.host()
		StubProtocol.route(host) { request in
			switch request.url?.path {
			case "/card.png": .init(status: 200, headers: ["Content-Type": "image/png"], body: Data([1, 2, 3]))
			case "/card.svg": .init(status: 200, headers: ["Content-Type": "image/svg+xml"], body: Data("<svg/>".utf8))
			default:
				.init(
					status: 200,
					headers: ["Content-Type": "image/jpeg"],
					body: Data(count: PageDetailsFetcher.maximumImageBytes + 1)
				)
			}
		}
		let fetcher = Self.fetcher()
		#expect(await fetcher.image(at: URL(string: "https://\(host)/card.png")!) == Data([1, 2, 3]))
		#expect(await fetcher.image(at: URL(string: "https://\(host)/card.svg")!) == nil)
		#expect(await fetcher.image(at: URL(string: "https://\(host)/huge.jpg")!) == nil)
	}

	// MARK: - Pictures (DEV-1142)

	@Test
	internal func readsTheOpenGraphPicture() async {
		let host = Self.host()
		StubProtocol.route(host) { _ in
			.html(#"<head><meta property="og:image" content="https://cdn.example/card.png"><meta property="og:description" content="About"></head>"#)
		}

		let details = await Self.fetcher().details(for: URL(string: "https://\(host)/page")!)

		expectNoDifference(details, .init(description: "About", imageURL: URL(string: "https://cdn.example/card.png")))
	}

	@Test
	internal func fallsBackToTheTwitterPicture() async {
		let host = Self.host()
		StubProtocol.route(host) { _ in
			.html(#"<head><title>Card</title><meta name="twitter:image" content="https://cdn.example/twitter.jpg"></head>"#)
		}

		let details = await Self.fetcher().details(for: URL(string: "https://\(host)/page")!)

		expectNoDifference(details, .init(title: "Card", imageURL: URL(string: "https://cdn.example/twitter.jpg")))
	}

	@Test
	internal func aPageWithoutAPictureKeepsItsTitleAndDescription() async {
		let host = Self.host()
		StubProtocol.route(host) { _ in
			.html(#"<head><title>Plain</title><meta name="description" content="Words only"></head>"#)
		}

		let details = await Self.fetcher().details(for: URL(string: "https://\(host)/page")!)

		expectNoDifference(details, .init(title: "Plain", description: "Words only", imageURL: nil))
	}

	/// A relative picture resolves against the address the page ended up at, not the tab's.
	@Test
	internal func aRelativePictureResolvesAgainstTheRedirectedAddress() async {
		let host = Self.host()
		StubProtocol.route(host) { request in
			request.url?.path == "/old"
			? .redirect(to: "https://\(host)/new/page")
			: .html(#"<head><meta property="og:image" content="card.png"></head>"#)
		}

		let details = await Self.fetcher().details(for: URL(string: "https://\(host)/old")!)

		expectNoDifference(details, .init(imageURL: URL(string: "https://\(host)/new/card.png")))
		#expect(StubProtocol.requests(host).compactMap(\.url?.path) == ["/old", "/new/page"])
	}

	@Test
	internal func followsARedirectToAnotherHost() async {
		let host = Self.host()
		let other = Self.host()
		StubProtocol.route(host) { _ in .redirect(to: "https://\(other)/landing") }
		StubProtocol.route(other) { _ in .html(#"<head><meta property="og:title" content="Landed"></head>"#) }

		let details = await Self.fetcher().details(for: URL(string: "https://\(host)/")!)

		expectNoDifference(details, .init(title: "Landed"))
	}

	@Test
	internal func refusesARedirectOffTheWeb() async {
		let host = Self.host()
		StubProtocol.route(host) { _ in .redirect(to: "file:///etc/hosts") }

		#expect(await Self.fetcher().details(for: URL(string: "https://\(host)/")!) == nil)
	}

	// MARK: - The profile's cookies (DEV-1142)

	@Test
	internal func sendsTheProfilesCookiesToThePagesHostOnly() async {
		let host = Self.host()
		let other = Self.host()
		StubProtocol.route(host) { _ in .redirect(to: "https://\(other)/landing") }
		StubProtocol.route(other) { _ in .html(#"<head><meta property="og:title" content="Landed"></head>"#) }
		let credentials = Self.credentials(page: "https://\(host)/", cookies: [host: "session=page", other: "session=other"])

		let details = await Self.fetcher().details(for: URL(string: "https://\(host)/")!, credentials: credentials)

		expectNoDifference(details, .init(title: "Landed"))
		#expect(StubProtocol.requests(host).map { $0.value(forHTTPHeaderField: "Cookie") } == ["session=page"])
		// The stub's redirect copies the first request's headers; the guard drops them.
		#expect(StubProtocol.requests(other).map { $0.value(forHTTPHeaderField: "Cookie") } == [nil])
	}

	@Test
	internal func readsTheCookiesAgainForARedirectOnThePagesHost() async {
		let host = Self.host()
		StubProtocol.route(host) { request in
			request.url?.path == "/old"
			? .redirect(to: "https://\(host)/new")
			: .html(#"<head><meta property="og:title" content="Signed in"></head>"#)
		}
		let credentials = PageFetchCredentials(pageURL: URL(string: "https://\(host)/old")!) { url in
			[HTTPCookie(properties: [.domain: host, .path: "/", .name: "path", .value: url.path])!]
		}

		let details = await Self.fetcher().details(for: URL(string: "https://\(host)/old")!, credentials: credentials)

		expectNoDifference(details, .init(title: "Signed in"))
		#expect(StubProtocol.requests(host).map { $0.value(forHTTPHeaderField: "Cookie") } == ["path=/old", "path=/new"])
	}

	@Test
	internal func picturesGetTheProfilesCookiesOnlyOnThePagesHost() async {
		let host = Self.host()
		let other = Self.host()
		let png: StubProtocol.Response = .init(status: 200, headers: ["Content-Type": "image/png"], body: Data([1, 2, 3]))
		StubProtocol.route(host) { _ in png }
		StubProtocol.route(other) { _ in png }
		let credentials = Self.credentials(page: "https://\(host)/page", cookies: [host: "session=page", other: "session=other"])
		let fetcher = Self.fetcher()

		#expect(await fetcher.image(at: URL(string: "https://\(host)/card.png")!, credentials: credentials) == Data([1, 2, 3]))
		#expect(await fetcher.image(at: URL(string: "https://\(other)/card.png")!, credentials: credentials) == Data([1, 2, 3]))

		#expect(StubProtocol.requests(host).map { $0.value(forHTTPHeaderField: "Cookie") } == ["session=page"])
		#expect(StubProtocol.requests(other).map { $0.value(forHTTPHeaderField: "Cookie") } == [nil])
	}

	@Test
	internal func aProfileWithoutCookiesForThePageSendsNone() async {
		let host = Self.host()
		StubProtocol.route(host) { _ in .html(#"<head><meta property="og:title" content="Hello"></head>"#) }
		let credentials = Self.credentials(page: "https://\(host)/", cookies: [:])

		_ = await Self.fetcher().details(for: URL(string: "https://\(host)/")!, credentials: credentials)

		#expect(StubProtocol.requests(host).map { $0.value(forHTTPHeaderField: "Cookie") } == [nil])
	}

	@Test
	internal func credentialsCoverThePagesHostOnly() {
		let credentials = Self.credentials(page: "https://Example.com/a", cookies: [:])
		#expect(credentials.covers(URL(string: "https://example.com/b")!))
		#expect(credentials.covers(URL(string: "http://EXAMPLE.com:8080/")!))
		#expect(!credentials.covers(URL(string: "https://www.example.com/")!))
		#expect(!credentials.covers(URL(string: "https://example.com.evil.test/")!))
		#expect(!credentials.covers(URL(string: "https://cdn.example/")!))
	}

	private static func host() -> String {
		"page-details-\(UUID().uuidString.lowercased()).test"
	}

	private static func fetcher() -> PageDetailsFetcher {
		.init { $0.protocolClasses = [StubProtocol.self] }
	}

	/// A profile that would send `cookies[host]` (a `name=value` pair) to each host.
	private static func credentials(
		page: String,
		cookies: [String: String]
	) -> PageFetchCredentials {
		PageFetchCredentials(pageURL: URL(string: page)!) { url in
			guard
				let host = url.host(),
				let pair = cookies[host]?.split(separator: "=", maxSplits: 1), pair.count == 2,
				let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: String(pair[0]), .value: String(pair[1])])
			else { return [] }
			return [cookie]
		}
	}
}

/// Answers requests by host, so parallel tests don't share routes, and records what was sent.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
	internal struct Response: Sendable {
		internal var status: Int
		internal var headers: [String: String]
		internal var body: Data

		internal static func html(_ text: String) -> Self {
			.init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(text.utf8))
		}

		/// A 302 to `location`.
		internal static func redirect(to location: String) -> Self {
			.init(status: 302, headers: ["Location": location], body: Data())
		}
	}

	internal typealias Handler = @Sendable (URLRequest) -> Response

	private static let state: Mutex<(routes: [String: Handler], requests: [String: [URLRequest]])> = .init(([:], [:]))

	internal static func route(
		_ host: String,
		_ handler: @escaping Handler
	) {
		state.withLock { $0.routes[host] = handler }
	}

	internal static func requests(_ host: String) -> [URLRequest] {
		state.withLock { $0.requests[host] ?? [] }
	}

	internal override class func canInit(with request: URLRequest) -> Bool { true }

	internal override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	internal override func startLoading() {
		let host = request.url?.host() ?? ""
		let handler = Self.state.withLock { state -> Handler? in
			state.requests[host, default: []].append(request)
			return state.routes[host]
		}
		guard let handler, let url = request.url else {
			client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
			return
		}
		let response = handler(request)
		let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
		if
			(300..<400).contains(response.status),
			let location = response.headers["Location"].flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL })
		{
			// Like a careless client, the next request keeps every header of this one.
			var next = request
			next.url = location

			// The loading system stops this load and starts the next one, if the delegate lets it.
			client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: http)
			return
		}
		client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: response.body)
		client?.urlProtocolDidFinishLoading(self)
	}

	internal override func stopLoading() {}
}
