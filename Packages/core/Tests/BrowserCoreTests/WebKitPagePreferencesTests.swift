import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct WebKitPagePreferencesTests {
	@Test
	internal func listedSitesMatchHTTPSHostsAndSubdomains() async throws {
		let preferences = WebKitPagePreferences()
		#expect(preferences.opensInWebKit(URL(string: "https://www.netflix.com/browse")!))
		#expect(preferences.opensInWebKit(URL(string: "https://netflix.com")!))
		#expect(preferences.opensInWebKit(URL(string: "https://open.spotify.com/track/1")!))
		#expect(!preferences.opensInWebKit(URL(string: "http://www.netflix.com")!))
		#expect(!preferences.opensInWebKit(URL(string: "https://accounts.spotify.com")!))
		#expect(!preferences.opensInWebKit(URL(string: "https://notnetflix.com")!))
		#expect(!preferences.opensInWebKit(URL(string: "https://apple.com")!))
		#expect(preferences.opensInWebKit(URL(string: "https://TV.Apple.com./show")!))

		var local = WebKitPagePreferences(sites: [])
		let loopback = URL(string: "http://127.0.0.1:8080/protected-media.html")!
		let added = local.add(loopback)
		#expect(added)
		#expect(local.opensInWebKit(loopback))
		#expect(!local.opensInWebKit(URL(string: "http://example.com")!))

		var off = preferences
		off.isEnabled = false
		#expect(!off.opensInWebKit(URL(string: "https://www.netflix.com")!))
	}

	/// DEV-1188: a listed built-in streaming site's protected video plays only in WebKit, unless the
	/// FairPlay helper keeps it in Chromium; a site the person took off the list or added may play
	/// anywhere.
	@Test
	internal func builtInStreamingSitesPlayProtectedMediaOnlyInWebKit() async throws {
		var preferences = WebKitPagePreferences()
		let netflix = URL(string: "https://www.netflix.com/watch/1")!
		let spotify = URL(string: "https://open.spotify.com/track/1")!
		#expect(preferences.playsProtectedMediaOnlyInWebKit(netflix))
		#expect(preferences.playsProtectedMediaOnlyInWebKit(spotify))
		#expect(!preferences.playsProtectedMediaOnlyInWebKit(URL(string: "http://www.netflix.com/watch/1")!))
		#expect(!preferences.playsProtectedMediaOnlyInWebKit(URL(string: "https://notnetflix.com/")!))

		// Taken off the list, Netflix is the person's choice: its failure asks first.
		preferences.remove(netflix)
		#expect(!preferences.playsProtectedMediaOnlyInWebKit(netflix))
		preferences.add(URL(string: "https://video.example/")!)
		#expect(!preferences.playsProtectedMediaOnlyInWebKit(URL(string: "https://video.example/watch")!))

		// The helper plays Spotify in the tab.
		let bridged = preferences.keepingInChromium(["https://open.spotify.com"])
		#expect(!bridged.playsProtectedMediaOnlyInWebKit(spotify))
		#expect(!bridged.playsProtectedMediaOnlyInWebKit(netflix))
		#expect(bridged.playsProtectedMediaOnlyInWebKit(URL(string: "https://www.disneyplus.com/play/1")!))

		// WebKit pages off: nothing moves.
		preferences.isEnabled = false
		#expect(!preferences.playsProtectedMediaOnlyInWebKit(netflix))
	}

	/// DEV-1211: a streaming site is a built-in streaming service's page, listed or not, or a site
	/// the person listed. Elsewhere, keys made without media are a likely bot check.
	@Test
	internal func streamingSitesAreTheBuiltInServicesAndTheListedSites() async throws {
		var preferences = WebKitPagePreferences()
		let netflix = URL(string: "https://www.netflix.com/watch/1")!
		#expect(preferences.isStreamingSite(netflix))
		#expect(!preferences.isStreamingSite(URL(string: "https://resend.com/")!))
		#expect(!preferences.isStreamingSite(URL(string: "http://www.netflix.com/watch/1")!))

		// Taken off the list, Netflix is still a streaming service.
		preferences.remove(netflix)
		#expect(preferences.isStreamingSite(netflix))

		// A site the person listed, a loopback one included.
		let local = URL(string: "http://localhost:8080/player.html")!
		#expect(!preferences.isStreamingSite(local))
		preferences.add(local)
		#expect(preferences.isStreamingSite(local))
	}

	@Test
	internal func addRemoveDeclineAndRestore() async throws {
		var preferences = WebKitPagePreferences(sites: ["netflix.com"])
		let video = URL(string: "https://www.video.example/watch")!
		preferences.decline(video)
		#expect(preferences.isDeclined(URL(string: "https://www.video.example/other")!))
		let added = preferences.add(video)
		#expect(added)
		#expect(preferences.sites == ["netflix.com", "video.example"])
		#expect(!preferences.isDeclined(video))
		let addedCovered = preferences.add(URL(string: "https://cdn.video.example")!)
		let addedPlain = preferences.add(URL(string: "http://plain.example")!)
		#expect(!addedCovered)
		#expect(!addedPlain)

		let removed = preferences.remove(URL(string: "https://www.netflix.com/title/1")!)
		#expect(removed)
		#expect(preferences.sites == ["video.example"])
		preferences.restoreDefaults()
		#expect(preferences.sites == WebKitPagePreferences.defaultSites + ["video.example"])
	}

	@Test
	internal func typedSitesAreNormalized() async throws {
		#expect(WebKitPagePreferences.site(from: " https://www.Netflix.com/browse ") == "www.netflix.com")
		#expect(WebKitPagePreferences.site(from: "music.apple.com") == "music.apple.com")
		#expect(WebKitPagePreferences.site(from: "localhost") == nil)
		#expect(WebKitPagePreferences.site(from: "") == nil)
		#expect(WebKitPagePreferences.site(from: "bad host.com") == nil)
	}

	@Test
	internal func preferencesRoundTripAndDefaultWhenMissing() async throws {
		var preferences = BrowserPreferences()
		preferences.webKitPages.isEnabled = false
		preferences.webKitPages.sites = ["example.com"]
		let data = try JSONEncoder().encode(preferences)
		expectNoDifference(try JSONDecoder().decode(BrowserPreferences.self, from: data), preferences)

		var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		old["webKitPages"] = nil
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: old)
		)
		expectNoDifference(decoded.webKitPages, WebKitPagePreferences())

		old["webKitPages"] = ["sites": ["HTTPS://Example.com/x", "example.com", "not a site"]]
		let cleaned = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: old)
		)

		// Saved before built-in sites were recorded: every built-in site comes back (DEV-1188).
		#expect(cleaned.webKitPages.sites == ["example.com"] + WebKitPagePreferences.defaultSites)
		#expect(cleaned.webKitPages.isEnabled)
	}

	/// DEV-1188: a built-in site opens in WebKit by default for every person. One added after the
	/// list was saved joins it; one the person took off stays off.
	@Test
	internal func newBuiltInSitesJoinASavedListAndRemovedOnesStayOff() async throws {
		let netflix = URL(string: "https://www.netflix.com/browse")!
		let others = WebKitPagePreferences.defaultSites.filter { $0 != "netflix.com" }

		// Saved by a build whose built-in sites didn't have Netflix yet.
		let older = try Self.decoded([
			"sites": ["video.example"] + others,
			"builtInSites": others,
		])
		#expect(older.sites == ["video.example"] + others + ["netflix.com"])
		#expect(older.opensInWebKit(netflix))

		// The person puts Netflix in Chromium, in the site menu or Settings: it stays there.
		var removed = WebKitPagePreferences()
		let didRemove = removed.remove(netflix)
		#expect(didRemove)
		let reread = try JSONDecoder().decode(WebKitPagePreferences.self, from: JSONEncoder().encode(removed))
		expectNoDifference(reread, removed)
		#expect(!reread.opensInWebKit(netflix))

		// Saved before this build, without Netflix: it comes back once, then sticks as above.
		let legacy = try Self.decoded(["sites": others])
		#expect(legacy.opensInWebKit(netflix))

		// An entry that already covers a built-in site isn't doubled.
		let covering = try Self.decoded(["sites": ["apple.com"], "builtInSites": []])
		#expect(covering.sites.filter { $0.hasSuffix("apple.com") } == ["apple.com"])

		// Restore Defaults brings a removed site back.
		var restored = reread
		restored.restoreDefaults()
		#expect(restored.opensInWebKit(netflix))
	}

	private static func decoded(_ object: [String: Any]) throws -> WebKitPagePreferences {
		try JSONDecoder().decode(WebKitPagePreferences.self, from: JSONSerialization.data(withJSONObject: object))
	}
}
