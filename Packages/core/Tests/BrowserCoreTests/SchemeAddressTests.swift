@testable import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1189: typed text with a scheme is an address or a search, as Chrome reads it, and
/// `arx://settings/…` and `chrome://settings/…` lead to Arx's place for them.
internal struct SchemeAddressTests {
	// MARK: - Address or search

	@Test(arguments: [
		"arx://settings",
		"arx://settings/content/protectedContent",
		"ARX://Settings/Advanced",
		"chrome://settings/passwords",
		"chrome://downloads",
		"about:blank",
		"file:///Users/max/Notes.md",
		"view-source:https://example.com",
		"mailto:max@example.com",
		"tel:5551234",
		"slack://open",
		"zoommtg://zoom.us/join?confno=123",
		"anything://at-all",
	])
	internal func addressesWithASchemeOpen(text: String) {
		let address = TypedSchemeAddress.address(text) { _ in false }
		expectNoDifference(address?.url, URL(string: text))
	}

	@Test(arguments: [
		// Plain words with a colon.
		"note:milk",
		"foo:bar",
		"re:invent",
		// A host and port, which the bar opens as a web address instead.
		"example.com:8080",
		"example.com:8080/path",
		"intranet:3000",
		// Words with spaces, and an empty rest.
		"todo: buy milk",
		"slack: open",
		"mailto:",
		// The web's own, which the bar already opens.
		"https://example.com",
		"http://localhost:3000",
		// Script never runs from the bar.
		"javascript:alert(1)",
		"JavaScript://%0Aalert(1)",
		"vbscript:msgbox",
		// The engine opens no typed `data:` page.
		"data:text/plain,hello",
		// Arx and Chromium pages Arx has no place for, and about: pages besides blank.
		"arx://open?url=https://example.com",
		"arx://chat",
		"chrome://flags",
		"chrome://settings:80",
		"about:version",
		// Not a scheme at all.
		"1password:open",
		"-x:y",
		"swift tips",
	])
	internal func plainTextSearches(text: String) {
		#expect(TypedSchemeAddress.address(text) { _ in false } == nil, "\(text)")
	}

	@Test
	internal func aSchemeWithoutSlashesIsAnAddressOnlyWhenAnAppOpensIt() {
		var asked: [String] = []
		let spotify = TypedSchemeAddress.address("spotify:track:4uLU6hMCjMI75M1A2tKUQC") { scheme in
			asked.append(scheme)
			return scheme == "spotify"
		}
		expectNoDifference(spotify?.kind, .app(scheme: "spotify"))
		expectNoDifference(asked, ["spotify"])

		#expect(TypedSchemeAddress.address("note:milk") { $0 == "spotify" } == nil)
		// A host and port stays one even when an app claims the "scheme".
		#expect(TypedSchemeAddress.address("intranet:3000") { _ in true } == nil)
		// Browsers' own schemes and `//` never ask.
		_ = TypedSchemeAddress.address("mailto:a@b.c") { _ in Issue.record("asked"); return false }
		_ = TypedSchemeAddress.address("slack://open") { _ in Issue.record("asked"); return false }
	}

	@Test
	internal func eachAddressSaysWhereItOpens() {
		func kind(_ text: String) -> TypedSchemeAddress.Kind? {
			TypedSchemeAddress.address(text) { _ in false }?.kind
		}
		expectNoDifference(kind("about:blank"), .page)
		expectNoDifference(TypedSchemeAddress.address("ABOUT:Blank") { _ in false }?.url, URL(string: "about:blank"))
		expectNoDifference(kind("file:///tmp/a.txt"), .page)
		expectNoDifference(kind("view-source:https://example.com"), .page)
		expectNoDifference(kind("slack://open"), .app(scheme: "slack"))
		expectNoDifference(kind("MAILTO:max@example.com"), .app(scheme: "mailto"))
		expectNoDifference(kind("arx://settings"), .settings(.top))
		expectNoDifference(kind("chrome://history"), .settings(.command(.showHistory)))

		#expect(TypedSchemeAddress.opensInApp(URL(string: "zoommtg://zoom.us")!))
		#expect(!TypedSchemeAddress.opensInApp(URL(string: "https://zoom.us")!))
		#expect(!TypedSchemeAddress.opensInApp(URL(string: "file:///tmp")!))
		#expect(!TypedSchemeAddress.opensInApp(URL(string: "arx://settings")!))
		#expect(!TypedSchemeAddress.opensInApp(URL(string: "javascript:alert(1)")!))
	}

	@Test
	internal func theSchemeToAskAnAppAbout() {
		expectNoDifference(TypedSchemeAddress.appScheme("Spotify:track:1"), "spotify")
		expectNoDifference(TypedSchemeAddress.appScheme("slack://open"), "slack")
		expectNoDifference(TypedSchemeAddress.appScheme("mailto:a@b.c"), "mailto")
		for text in ["https://a.b", "arx://settings", "chrome://settings", "about:blank", "file:///", "javascript:x", "a.b:8080", "x y:z", "note"] {
			#expect(TypedSchemeAddress.appScheme(text) == nil, "\(text)")
		}
	}

	// MARK: - Settings addresses

	@Test
	internal func arxSettingsAddresses() {
		func address(_ text: String) -> SettingsAddress? { SettingsAddress(string: text) }

		expectNoDifference(address("arx://settings"), .top)
		expectNoDifference(address("arx://settings/"), .top)
		expectNoDifference(address("arx://settings/advanced"), .destination("pane/advanced"))
		expectNoDifference(address("arx://settings/Advanced/protectedMedia"), .path(pane: "advanced", item: "protectedmedia"))
		expectNoDifference(address("arx://settings/links/appLinks"), .path(pane: "links", item: "applinks"))

		// Chrome's paths work under arx:// too, as Max typed it.
		expectNoDifference(address("arx://settings/content/protectedContent"), .destination("row/advanced/protectedMedia"))
		expectNoDifference(address("arx://settings/content/camera"), .profile(.siteSettings))
		expectNoDifference(address("arx://settings/passwords"), .profile(.passwords))

		// A path neither knows opens Settings at its top.
		expectNoDifference(address("arx://settings/nothing/here"), .top)

		#expect(address("arx://open?url=https://example.com") == nil)
		#expect(address("arx://chat") == nil)
		#expect(address("https://settings/privacy") == nil)
		#expect(address("arx://user:secret@settings") == nil)
	}

	@Test
	internal func chromeSettingsAddressesMapToArx() {
		let expected: [(String, SettingsAddress)] = [
			("chrome://settings", .top),
			("chrome://settings/content/protectedContent", .destination("row/advanced/protectedMedia")),
			("chrome://settings/content/notifications", .profile(.siteSettings)),
			("chrome://settings/content/camera", .profile(.siteSettings)),
			("chrome://settings/content/microphone", .profile(.siteSettings)),
			("chrome://settings/content/siteDetails?site=https%3A%2F%2Fexample.com", .profile(.siteSettings)),
			("chrome://settings/passwords", .profile(.passwords)),
			("chrome://settings/autofill", .profile(.autofill)),
			("chrome://settings/payments", .profile(.autofill)),
			("chrome://settings/privacy", .destination("pane/privacy")),
			("chrome://settings/cookies", .profile(.siteSettings)),
			("chrome://settings/clearBrowserData", .profile(.clearBrowsingData)),
			("chrome://settings/downloads", .profile(.page)),
			("chrome://settings/searchEngines", .profile(.page)),
			("chrome://settings/appearance", .destination("pane/appearance")),
			("chrome://settings/defaultBrowser", .destination("row/arx/defaultBrowser")),
			("chrome://settings/handlers", .destination("page/appLinks")),
			("chrome://settings/somethingNew", .top),
			("chrome://downloads", .command(.downloads)),
			("chrome://history", .command(.showHistory)),
			("chrome://extensions", .command(.extensions)),
			("chrome://password-manager/passwords", .profile(.passwords)),
			("CHROME://SETTINGS/PASSWORDS", .profile(.passwords)),
		]
		for (text, address) in expected {
			expectNoDifference(SettingsAddress(string: text), address, "\(text)")
		}

		// Chromium's other pages aren't settings: the engine shows them.
		#expect(SettingsAddress(string: "chrome://version") == nil)
		#expect(SettingsAddress(string: "chrome://flags") == nil)
	}

	@Test
	internal func chromePathsAreLowercasedKeys() {
		for key in SettingsAddress.chromePaths.keys {
			#expect(key == key.lowercased(), "\(key)")
		}
		for key in SettingsAddress.chromePages.keys {
			#expect(key == key.lowercased(), "\(key)")
		}
	}
}
