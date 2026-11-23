import ChromiumEngine
import Foundation
import Testing

@testable import ChromiumBrowserEngine

/// DEV-877: Chromium's cookies become Foundation's for a WebKit page's store.
@MainActor
internal struct ChromiumSiteCookiesTests {
	private let now: Date = Date(timeIntervalSince1970: 1_800_000_000)

	@Test
	internal func cookiesKeepTheirScopeAndFlags() async throws {
		let cookie = try #require(ChromiumBrowserEngine.httpCookie(
			.init(
				name: "NetflixId",
				value: "v=1",
				domain: ".netflix.com",
				path: "/",
				expires: 1_900_000_000,
				secure: true,
				httpOnly: true,
				sameSite: "none"
			),
			now: now
		))
		#expect(cookie.name == "NetflixId")
		#expect(cookie.value == "v=1")
		#expect(cookie.domain == ".netflix.com")
		#expect(cookie.isSecure)
		#expect(cookie.isHTTPOnly)
		// Foundation caps a cookie's lifetime (400 days), so only its persistence is checked.
		#expect(!cookie.isSessionOnly)
		#expect(cookie.sameSitePolicy == nil)
	}

	@Test
	internal func sessionUnspecifiedAndExpiredCookies() async throws {
		let session = try #require(ChromiumBrowserEngine.httpCookie(
			.init(
				name: "s",
				value: "1",
				domain: "www.netflix.com",
				path: "",
				expires: nil,
				secure: false,
				httpOnly: false,
				sameSite: "unspecified"
			),
			now: now
		))
		#expect(session.isSessionOnly)
		#expect(session.path == "/")
		#expect(session.sameSitePolicy == .sameSiteLax)

		let expired = ChromiumBrowserEngine.httpCookie(
			.init(
				name: "old",
				value: "1",
				domain: ".netflix.com",
				path: "/",
				expires: 1_700_000_000,
				secure: true,
				httpOnly: false,
				sameSite: "strict"
			),
			now: now
		)
		#expect(expired == nil)
		let nameless = ChromiumBrowserEngine.httpCookie(
			.init(name: "", value: "1", domain: ".a.example", path: "/", expires: nil, secure: false, httpOnly: false, sameSite: "lax"),
			now: now
		)
		#expect(nameless == nil)
	}
}
