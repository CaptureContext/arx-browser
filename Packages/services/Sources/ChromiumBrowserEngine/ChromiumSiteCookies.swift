import BrowserCore
import ChromiumEngine
import Foundation

extension ChromiumBrowserEngine {
	/// DEV-877. The cookies a site would receive in a profile, from the tab's own Chromium page
	/// when it has one, as `HTTPCookie` values for a WebKit store. Empty when the engine can't
	/// read them.
	public func siteCookies(
		profile: Profile.ID,
		tab: Tab.ID?,
		url: URL
	) async -> [HTTPCookie] {
		let page = tab.flatMap { chromiumPage($0) }
		let key = profile.chromiumProfile(legacy: legacyProfileID)
		let cookies = await runtime.siteCookies(for: url, page: page, profile: key) ?? []
		return cookies.compactMap { Self.httpCookie($0) }
	}

	/// A Chromium cookie as Foundation's, or nil for one that's expired or incomplete.
	internal static func httpCookie(
		_ cookie: ChromiumSiteCookie,
		now: Date = Date()
	) -> HTTPCookie? {
		guard !cookie.name.isEmpty, !cookie.domain.isEmpty else { return nil }

		var properties: [HTTPCookiePropertyKey: Any] = [
			.name: cookie.name,
			.value: cookie.value,
			.domain: cookie.domain,
			.path: cookie.path.isEmpty ? "/" : cookie.path,
		]
		if cookie.secure { properties[.secure] = "TRUE" }
		if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
		if let expires = cookie.expires {
			let date = Date(timeIntervalSince1970: expires)
			guard date > now else { return nil }
			properties[.expires] = date
		}
		switch cookie.sameSite {
		case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue

		case "none": break

		// Chromium treats an unspecified SameSite as Lax.
		default: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
		}
		return HTTPCookie(properties: properties)
	}
}
