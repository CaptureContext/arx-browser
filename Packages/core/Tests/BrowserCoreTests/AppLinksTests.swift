import BrowserCore
import Foundation
import Testing

internal struct AppLinksTests {
	private static let work: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
	private static let personal: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)

	private static let claude: AppLinkHandler = .init(
		id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
		name: "Claude",
		scheme: "claude",
		defaultHandling: .systemDefault,
		overrides: [
			.init(profileID: work, handling: .runScript(#"fxclaude open-url work "$1""#)),
			.init(profileID: personal, handling: .runScript(#"fxclaude open-url personal "$1""#)),
		]
	)

	// MARK: - Matching

	@Test
	internal func matchesSchemeHostAndPath() throws {
		var handler = Self.claude
		#expect(handler.matches(try #require(URL(string: "claude://login/callback?code=1"))))
		#expect(handler.matches(try #require(URL(string: "CLAUDE://anything"))))
		#expect(!handler.matches(try #require(URL(string: "codex://login"))))
		#expect(!handler.matches(try #require(URL(string: "https://claude.ai"))))

		handler.host = "login"
		handler.pathPrefix = "/callback"
		#expect(handler.matches(try #require(URL(string: "claude://login/callback?code=1"))))
		#expect(!handler.matches(try #require(URL(string: "claude://login/other"))))
		#expect(!handler.matches(try #require(URL(string: "claude://settings/callback"))))

		handler.isEnabled = false
		#expect(!handler.matches(try #require(URL(string: "claude://login/callback"))))
	}

	@Test
	internal func firstMatchingHandlerWinsAndNoneLeavesTheLinkToChrome() {
		var specific = Self.claude
		specific.id = UUID()
		specific.name = "Claude sign-in"
		specific.host = "login"
		let preferences = AppLinkPreferences(handlers: [specific, Self.claude])

		#expect(preferences.decide(link: "claude://login/x", profileID: nil, isPrivate: false, sourceOrigin: nil)?
			.handler.id == specific.id)
		#expect(preferences.decide(link: "claude://new", profileID: nil, isPrivate: false, sourceOrigin: nil)?
			.handler.id == Self.claude.id)
		#expect(preferences.decide(link: "zoommtg://join", profileID: nil, isPrivate: false, sourceOrigin: nil) == nil)
	}

	// MARK: - Handling

	@Test
	internal func defaultAndPerProfileHandling() {
		#expect(Self.claude.handling(profileID: Self.work, isPrivate: false) == .runScript(#"fxclaude open-url work "$1""#))
		#expect(Self.claude.handling(profileID: Self.personal, isPrivate: false)
			== .runScript(#"fxclaude open-url personal "$1""#))
		let other = Profile.ID(rawValue: UUID())
		#expect(Self.claude.handling(profileID: other, isPrivate: false) == .systemDefault)
		#expect(Self.claude.handling(profileID: nil, isPrivate: false) == .systemDefault)
	}

	@Test
	internal func privateWindowsNeverRunScripts() {
		var handler = Self.claude
		handler.defaultHandling = .runScript("echo default")
		#expect(handler.handling(profileID: Self.work, isPrivate: true) == .systemDefault)
		#expect(handler.handling(profileID: nil, isPrivate: true) == .systemDefault)

		let decision = AppLinkPreferences(handlers: [handler])
			.decide(link: "claude://x", profileID: Self.work, isPrivate: true, sourceOrigin: "https://claude.ai")
		#expect(decision?.handling == .systemDefault)
	}

	// MARK: - Validation

	@Test
	internal func validatesLinksBeforeScriptsSeeThem() throws {
		#expect(try AppLinkValidation.validate("claude://login?code=1", scheme: "claude").absoluteString
			== "claude://login?code=1")
		#expect(throws: AppLinkError.schemeMismatch) {
			try AppLinkValidation.validate("codex://login", scheme: "claude")
		}
		#expect(throws: AppLinkError.controlCharacters) {
			try AppLinkValidation.validate("claude://login\nrm -rf ~", scheme: "claude")
		}
		#expect(throws: AppLinkError.controlCharacters) {
			try AppLinkValidation.validate("claude://login\u{7}", scheme: "claude")
		}
		#expect(throws: AppLinkError.malformed) {
			try AppLinkValidation.validate("claude login", scheme: "claude")
		}
		let long = "claude://x?" + String(repeating: "a", count: AppLinkValidation.maximumLength)
		#expect(throws: AppLinkError.tooLong) {
			try AppLinkValidation.validate(long, scheme: "claude")
		}
		let limit = "claude://x?" + String(repeating: "a", count: AppLinkValidation.maximumLength - 11)
		#expect(try AppLinkValidation.validate(limit, scheme: "claude").absoluteString.utf8.count == 8 * 1024)
	}

	@Test
	internal func invalidLinkFallsBackToOpenAppAndAlwaysAsks() {
		var handler = Self.claude
		handler.alwaysAllowedOrigins = ["https://claude.ai"]
		let long = "claude://x?" + String(repeating: "a", count: AppLinkValidation.maximumLength)
		let decision = AppLinkPreferences(handlers: [handler])
			.decide(link: long, profileID: Self.work, isPrivate: false, sourceOrigin: "https://claude.ai")
		#expect(decision?.failure == .tooLong)
		#expect(decision?.skipsPrompt == false)
	}

	// MARK: - Always allow

	@Test
	internal func alwaysAllowIsPerSiteAndHandler() {
		var handler = Self.claude
		handler.alwaysAllowedOrigins = ["https://claude.ai"]
		let preferences = AppLinkPreferences(handlers: [handler])

		#expect(preferences.decide(link: "claude://x", profileID: Self.work, isPrivate: false,
			sourceOrigin: "https://claude.ai")?.skipsPrompt == true)
		#expect(preferences.decide(link: "claude://x", profileID: Self.work, isPrivate: false,
			sourceOrigin: "https://evil.example")?.skipsPrompt == false)
		#expect(preferences.decide(link: "claude://x", profileID: Self.work, isPrivate: false,
			sourceOrigin: nil)?.skipsPrompt == false)
		#expect(preferences.decide(link: "claude://x", profileID: Self.work, isPrivate: true,
			sourceOrigin: "https://claude.ai")?.skipsPrompt == false)
	}

	@Test
	internal func onlyTrustworthyOriginsAreRemembered() {
		#expect(AppLinkHandler.mayRemember("https://claude.ai"))
		#expect(AppLinkHandler.mayRemember("http://localhost:3000"))
		#expect(AppLinkHandler.mayRemember("http://127.0.0.1:8080"))
		#expect(AppLinkHandler.mayRemember("http://127.4.5.6"))
		#expect(AppLinkHandler.mayRemember("http://[::1]:8080"))
		#expect(!AppLinkHandler.mayRemember("http://127.attacker.example"))
		#expect(!AppLinkHandler.mayRemember("http://128.0.0.1"))
		#expect(!AppLinkHandler.mayRemember("http://[::2]"))
		#expect(!AppLinkHandler.mayRemember("http://claude.ai"))
		#expect(!AppLinkHandler.mayRemember(""))
		#expect(!AppLinkHandler.mayRemember(nil))

		var handler = Self.claude
		handler.alwaysAllowedOrigins = ["http://claude.ai"]
		#expect(!handler.alwaysAllows("http://claude.ai"))
	}

	// MARK: - Definitions

	@Test
	internal func refusesWebSchemesAndDuplicateOverrides() {
		var handler = Self.claude
		handler.scheme = "https"
		#expect(throws: AppLinkError.reservedScheme) { try handler.validate() }
		handler.scheme = "Claude"
		#expect(throws: AppLinkError.invalidScheme) { try handler.validate() }
		handler.scheme = "claude://"
		#expect(throws: AppLinkError.invalidScheme) { try handler.validate() }
		handler.scheme = "claude"
		handler.host = "Login"
		#expect(throws: AppLinkError.invalidHost) { try handler.validate() }
		handler.host = nil
		handler.pathPrefix = "/a b"
		#expect(throws: AppLinkError.invalidPath) { try handler.validate() }
		handler.pathPrefix = nil
		handler.scheme = "x-claude+beta.1"
		#expect(throws: Never.self) { try handler.validate() }
		handler.overrides.append(.init(profileID: Self.work, handling: .systemDefault))
		#expect(throws: AppLinkError.invalidDefinition) { try handler.validate() }
	}

	// MARK: - Persistence

	@Test
	internal func routingPreferencesBeforeAppLinksStillDecode() throws {
		let old = #"{"rules":[],"fallback":{"scope":{"currentSpace":{}},"mode":"littleArx"}}"#
		let preferences = try JSONDecoder().decode(RoutingPreferences.self, from: Data(old.utf8))
		#expect(preferences.appLinks == .init())
		#expect(preferences.fallback == .init(scope: .currentSpace, mode: .littleArx))

		let asked = try JSONDecoder().decode(RoutingPreferences.self, from: Data(#"{"rules":[]}"#.utf8))
		#expect(asked.fallback == nil)
	}

	@Test
	internal func appLinksRoundTripAndUnknownHandlingReadsAsOpenApp() throws {
		var handler = Self.claude
		handler.alwaysAllowedOrigins = ["https://claude.ai"]
		let preferences = RoutingPreferences(appLinks: .init(handlers: [handler]))
		let data = try JSONEncoder().encode(preferences)
		#expect(try JSONDecoder().decode(RoutingPreferences.self, from: data) == preferences)

		let later = #"{"id":"00000000-0000-0000-0000-000000000009","scheme":"claude","defaultHandling":{"kind":"teleport"}}"#
		let decoded = try JSONDecoder().decode(AppLinkHandler.self, from: Data(later.utf8))
		#expect(decoded.defaultHandling == .systemDefault)
		#expect(decoded.isEnabled)
		#expect(decoded.overrides.isEmpty)
	}

	// MARK: - Chosen apps (DEV-862)

	private static let claudeApp: AppLinkApplication = .init(
		path: "/Applications/Claude.app",
		bundleID: "com.anthropic.claudefordesktop",
		name: "Claude",
		bookmark: Data([1, 2, 3])
	)

	@Test
	internal func rulesSavedBeforeTheAppPickerDecodeAsSystemDefault() throws {
		// DEV-857's stored format: no application anywhere.
		let stored = #"""
		{"handlers":[{"id":"00000000-0000-0000-0000-000000000001","name":"Claude","scheme":"claude",
		"defaultHandling":{"kind":"openApp"},
		"overrides":[{"profileID":"00000000-0000-0000-0000-00000000000A","handling":{"kind":"runScript","script":"fxclaude open-url work \"$1\""}},
		{"profileID":"00000000-0000-0000-0000-00000000000B","handling":{"kind":"openApp"}}],
		"alwaysAllowedOrigins":["https://claude.ai"],"isEnabled":true}]}
		"""#
		let preferences = try JSONDecoder().decode(AppLinkPreferences.self, from: Data(stored.utf8))
		let handler = try #require(preferences.handlers.first)
		#expect(handler.application == nil)
		#expect(handler.defaultHandling == .systemDefault)
		#expect(handler.overrides.map(\.handling) == [.runScript(#"fxclaude open-url work "$1""#), .systemDefault])
		#expect(handler.alwaysAllowedOrigins == ["https://claude.ai"])
	}

	@Test
	internal func systemDefaultEncodesAsBefore() throws {
		let data = try JSONEncoder().encode(AppLinkHandling.systemDefault)
		#expect(String(decoding: data, as: UTF8.self) == #"{"kind":"openApp"}"#)
	}

	@Test
	internal func chosenAppsRoundTrip() throws {
		var handler = Self.claude
		handler.application = Self.claudeApp
		handler.defaultHandling = .openApp(Self.claudeApp)
		let copy = AppLinkApplication(
			path: "/Users/me/Workspaces/Claude Work.app",
			bundleID: "com.anthropic.claudefordesktop",
			name: "Claude Work"
		)
		handler.overrides[1].handling = .openApp(copy)
		let data = try JSONEncoder().encode(AppLinkPreferences(handlers: [handler]))
		#expect(try JSONDecoder().decode(AppLinkPreferences.self, from: data).handlers == [handler])
		#expect(handler.applications == [Self.claudeApp, copy])
	}

	@Test
	internal func privateWindowsAndScriptFallbacksOpenTheChosenApp() {
		var handler = Self.claude
		handler.application = Self.claudeApp

		// The default opens System Default on purpose: private windows follow it.
		#expect(handler.handling(profileID: Self.work, isPrivate: true) == .systemDefault)
		handler.defaultHandling = .runScript("true")
		#expect(handler.handling(profileID: Self.work, isPrivate: true) == .openApp(Self.claudeApp))
		#expect(handler.fallback == .openApp(Self.claudeApp))
	}

	@Test
	internal func schemeRulesAndExamples() {
		#expect(AppLinkHandler.schemeProblem("claude") == nil)
		#expect(AppLinkHandler.schemeProblem("1claude") == .invalidScheme)
		#expect(AppLinkHandler.schemeProblem("cla ude") == .invalidScheme)
		#expect(AppLinkHandler.schemeProblem("file") == .reservedScheme)
		#expect(AppLinkHandler.normalizedScheme(" Claude:// ") == "claude")

		#expect(AppLinkHandler.example(scheme: "claude", host: "login", pathPrefix: "/callback") == "claude://login/callback")
		#expect(AppLinkHandler.example(scheme: "Claude://", host: nil, pathPrefix: nil) == "claude://")
		#expect(AppLinkHandler.example(scheme: "claude", host: nil, pathPrefix: "/callback") == "claude://*/callback")
		#expect(AppLinkHandler.example(scheme: "claude", host: nil, pathPrefix: "callback") == "claude:callback")
		#expect(AppLinkHandler.example(scheme: "https", host: nil, pathPrefix: nil) == nil)
		#expect(AppLinkHandler.example(scheme: "", host: "login", pathPrefix: nil) == nil)
	}

	// MARK: - Links no handler takes (DEV-1259)

	@Test
	internal func aLinkNoHandlerTakesIsAskedAboutWithTheSystemApp() throws {
		let preferences = AppLinkPreferences(handlers: [Self.claude])
		let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
		let decision = try #require(preferences.decideUnmatched(link: "linear://issue/DEV-1", appName: "Linear", handlerID: id))
		#expect(decision.handler.id == id)
		#expect(decision.handler.name == "Linear")
		#expect(decision.handler.scheme == "linear")
		#expect(decision.handling == .systemDefault)
		#expect(!decision.isSaved)
		#expect(!decision.skipsPrompt)
		#expect(decision.failure == nil)
		// A saved handler validates as the person's own once Always allow keeps it.
		#expect(throws: Never.self) { try decision.handler.validate() }
		#expect(preferences.decideUnmatched(link: "Linear://x", appName: " ", handlerID: id)?.handler.name == "linear")
	}

	@Test
	internal func onlyLinksForAnotherAppThatNoHandlerTakesAreUnmatched() {
		let preferences = AppLinkPreferences(handlers: [Self.claude])
		#expect(preferences.unmatchedScheme(link: "linear://issue") == "linear")
		#expect(preferences.unmatchedScheme(link: "mailto:me@example.com") == "mailto")
		// A handler takes it: its own decision applies.
		#expect(preferences.unmatchedScheme(link: "claude://x") == nil)
		#expect(preferences.decide(link: "claude://x", profileID: nil, isPrivate: false, sourceOrigin: nil)?.isSaved == true)
		// Web schemes, Chrome's pages and malformed links never become app links.
		#expect(preferences.unmatchedScheme(link: "https://linear.app") == nil)
		#expect(preferences.unmatchedScheme(link: "chrome://settings") == nil)
		#expect(preferences.unmatchedScheme(link: "not a link") == nil)
		#expect(preferences.decideUnmatched(link: "javascript:alert(1)", appName: "X", handlerID: UUID()) == nil)
	}
}
