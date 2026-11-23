@testable import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1193: `chrome://` and `arc://` links, where DEV-1189's `SettingsAddress` table puts them,
/// and what Arx does with each.
internal struct BrowserSchemeLinkTests {
	// MARK: - Reading links

	@Test
	internal func chromeLinksTakeTheirPlaceFromTheSettingsTable() throws {
		let link = try #require(BrowserSchemeLink(string: "chrome://settings/content/protectedContent"))
		#expect(link.browser == .chrome)
		#expect(link.page == "settings")
		#expect(link.place == .destination("row/advanced/protectedMedia"))

		#expect(BrowserSchemeLink(string: "chrome://extensions")?.place == .command(.extensions))
		#expect(BrowserSchemeLink(string: "chrome://downloads")?.place == .command(.downloads))
		#expect(BrowserSchemeLink(string: "chrome://history")?.place == .command(.showHistory))
	}

	/// Arc's pages are Chromium's under another name, so its links read through the same table.
	@Test(arguments: [
		("arc://settings", SettingsAddress.top),
		("arc://settings/system", .destination("pane/advanced")),
		("arc://settings/searchEngines", .profile(.page)),
		("arc://settings/help", .destination("row/general/updates")),
		("arc://extensions", .command(.extensions)),
		("arc://history/?q=arx", .command(.showHistory)),
		("arc://password-manager/passwords", .profile(.passwords)),
		("ARC://Settings/Passwords", .profile(.passwords)),
	])
	internal func arcLinksReadAsTheChromeLinksTheyName(text: String, place: SettingsAddress) throws {
		let link = try #require(BrowserSchemeLink(string: text))
		#expect(link.browser == .arc)
		#expect(link.place == place)
		#expect(link.url == URL(string: text))
	}

	@Test(arguments: [
		"chrome://flags",
		"chrome://version",
		"chrome://bookmarks",
		"arc://boost/v2/css/",
		"arc://effect/1",
		"arc://inspect",
	])
	internal func pagesArxDoesntHaveAreTheBrowsersOwn(text: String) throws {
		let link = try #require(BrowserSchemeLink(string: text))
		#expect(link.place == nil)
	}

	@Test(arguments: [
		"https://example.com",
		"arx://settings",
		"chrome:settings",
		"chrome://",
		"chrome://user:secret@settings",
		"chrome://settings:80",
		"slack://open",
	])
	internal func otherLinksAreNone(text: String) {
		#expect(BrowserSchemeLink(string: text) == nil)
	}

	@Test
	internal func longLinksAreNone() {
		let long = "chrome://settings/" + String(repeating: "a", count: BrowserSchemeLink.maximumLength)
		#expect(BrowserSchemeLink(string: long) == nil)
	}

	// MARK: - Decisions

	@Test
	internal func chromeLinksGoToAppLinksWhileChromeIsInstalled() throws {
		let settings = try #require(BrowserSchemeLink(string: "chrome://settings/content/protectedContent"))
		let flags = try #require(BrowserSchemeLink(string: "chrome://flags"))

		#expect(settings.decision { true } == .appLinks)
		#expect(flags.decision { true } == .appLinks)
		// No Chrome: Arx's place at once, or nothing to open it with.
		#expect(settings.decision { false } == .openInArx(.destination("row/advanced/protectedMedia")))
		#expect(flags.decision { false } == .cannotOpen)
	}

	@Test
	internal func arcLinksArxHandlesOpenWithoutAQuestion() throws {
		let link = try #require(BrowserSchemeLink(string: "arc://extensions"))
		#expect(link.decision { Issue.record("not asked"); return true } == .openInArx(.command(.extensions)))
	}

	@Test
	internal func otherArcLinksGoToArcOrCantOpen() throws {
		let arc = try #require(BrowserSchemeLink(string: "arc://boost/v2/css/"))
		#expect(arc.decision { true } == .openInBrowser(.arc))
		#expect(arc.decision { false } == .cannotOpen)
	}

	@Test(arguments: [
		"chrome://quit", "chrome://restart/", "chrome://crash/gpu/use-after-free", "chrome://kill", "arc://hang",
		"CHROME://Inducebrowsercrashforrealz", "chrome://delayeduithreadhang/", "chrome://uithreadhang",
		"chrome://v8-oom", "chrome://blink-oom/worker", "chrome://memory-pressure-critical", "chrome://gpuclean",
		"chrome://inducebrowserheapcorruption", "chrome://webuijserror",
	])
	internal func chromiumsDebugPagesAreRefusedEvenWithTheBrowserInstalled(text: String) throws {
		let link = try #require(BrowserSchemeLink(string: text))
		#expect(link.isRefused)
		#expect(link.decision { Issue.record("not asked"); return true } == .refuse)
	}

	@Test(arguments: ["chrome://flags", "chrome://version", "chrome://bookmarks", "chrome://inspect", "chrome://gpu", "arc://boost/v2/css/"])
	internal func ordinaryPagesAreNotRefused(text: String) throws {
		#expect(try #require(BrowserSchemeLink(string: text)).isRefused == false)
	}

	// MARK: - App Links' built-in handler for Chrome's pages

	private static let chrome = AppLinkApplication(
		path: "/Applications/Google Chrome.app",
		bundleID: "com.google.Chrome",
		name: "Google Chrome"
	)

	@Test
	internal func theBuiltInHandlerTakesChromeLinksAndOpensChrome() throws {
		let handler: AppLinkHandler = .chromePages(application: Self.chrome)
		#expect(handler.isBuiltIn)
		#expect(handler.defaultHandling == .openApp(Self.chrome))
		#expect(throws: Never.self) { try handler.validate() }

		let preferences = AppLinkPreferences().including(handler)
		let decision = try #require(preferences.decide(
			link: "chrome://settings/passwords",
			profileID: nil,
			isPrivate: false,
			sourceOrigin: "https://example.com"
		))
		#expect(decision.handler.id == AppLinkHandler.chromePagesID)
		#expect(decision.handling == .openApp(Self.chrome))
	}

	@Test
	internal func aSavedBuiltInHandlerStaysAsThePersonLeftIt() throws {
		var edited: AppLinkHandler = .chromePages(application: Self.chrome)
		edited.defaultHandling = .openInArx
		edited.alwaysAllowedOrigins = ["https://www.netflix.com"]
		let preferences = AppLinkPreferences(handlers: [edited]).including(.chromePages(application: Self.chrome))
		#expect(preferences.handlers == [edited])
		#expect(throws: Never.self) { try preferences.validate() }
	}

	@Test
	internal func onlyTheBuiltInHandlerTakesChromeOrOpensArx() {
		let own = AppLinkHandler(id: UUID(), name: "Mine", scheme: "chrome")
		#expect(throws: AppLinkError.reservedScheme) { try own.validate() }
		let arx = AppLinkHandler(id: UUID(), name: "Claude", scheme: "claude", defaultHandling: .openInArx)
		#expect(throws: AppLinkError.invalidDefinition) { try arx.validate() }
	}

	@Test
	internal func theBuiltInHandlerKeepsChromesScheme() {
		var moved: AppLinkHandler = .chromePages(application: Self.chrome)
		moved.scheme = "googlechrome"
		#expect(throws: AppLinkError.invalidDefinition) { try moved.validate() }
	}

		@Test
	internal func openInArxRoundTripsAndReadsAsOpenAppInOlderShapes() throws {
		let data = try JSONEncoder().encode(AppLinkHandling.openInArx)
		#expect(try JSONDecoder().decode(AppLinkHandling.self, from: data) == .openInArx)
		// A kind this Arx doesn't know still reads as Open app, which runs nothing.
		let later = Data(#"{"kind":"somethingNew"}"#.utf8)
		#expect(try JSONDecoder().decode(AppLinkHandling.self, from: later) == .systemDefault)
	}
}
