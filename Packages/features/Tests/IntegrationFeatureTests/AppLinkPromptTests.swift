import AppLinkClient
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Arx's prompt for a page's link to another app (DEV-857).
@Suite(.dependencies)
@MainActor
internal struct AppLinkPromptTests {
	private static let work = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
	private static let windowID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F0")!
	private static let script = #"fxclaude open-url work "$1""#

	private static let handler = AppLinkHandler(
		id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
		name: "Claude",
		scheme: "claude",
		defaultHandling: .systemDefault,
		overrides: [.init(profileID: work, handling: .runScript(script))]
	)

	private static func request(
		_ link: String = "claude://login/callback?code=1",
		profileID: Profile.ID = work,
		isPrivate: Bool = false,
		origin: String? = "https://claude.ai"
	) -> BrowserExternalLink {
		.init(
			sourceTabID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!),
			profileID: profileID,
			isPrivate: isPrivate,
			sourceDocumentRevision: 4,
			sourceToken: 7,
			link: link,
			sourceOrigin: origin,
			hasUserGesture: false,
			isRedirect: true
		)
	}

	private static func prompt(
		_ request: BrowserExternalLink = request(),
		handler: AppLinkHandler = handler
	) throws -> AppLinkPrompt.State {
		let decision = try #require(AppLinkPreferences(handlers: [handler]).decide(
			link: request.link,
			profileID: request.profileID,
			isPrivate: request.isPrivate,
			sourceOrigin: request.sourceOrigin
		))
		return .init(
			id: UUID(0),
			windowID: windowID,
			request: request,
			decision: decision,
			profileName: "Work",
			appName: "Claude"
		)
	}

	/// A request from the fixture's tab shown in the main window, so Arx can place its prompt.
	private static func shownRequest(
		_ link: String,
		origin: String? = "https://linear.app"
	) -> BrowserExternalLink {
		.init(
			sourceTabID: .init(rawValue: UUID(3)),
			profileID: .init(rawValue: UUID(0)),
			isPrivate: false,
			sourceDocumentRevision: 4,
			sourceToken: 7,
			link: link,
			sourceOrigin: origin,
			hasUserGesture: true,
			isRedirect: false
		)
	}

	/// The fixture with its tab shown in an open main window.
	private static func shownState() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[id: .init(rawValue: UUID(3))]
		state.windowIsOpen = true
		return state
	}

	// MARK: - Handling

	@Test
	internal func workProfileLandsInItsScriptWithTheLinkAsOneArgument() async throws {
		let ran = LockIsolated<[AppLinkScript]>([])
		let initial = try Self.prompt()
		let store = TestStore(initialState: initial) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.runScript = { script in
				ran.withValue { $0.append(script) }
				return .succeeded(log: nil)
			}
		}
		#expect(store.state.landingName == "Claude Work")
		#expect(store.state.script == Self.script)

		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.scriptFinished)
		await store.receive(\.delegate.finished)
		expectNoDifference(ran.value, [.init(
			script: Self.script,
			link: "claude://login/callback?code=1",
			scheme: "claude",
			profileID: Self.work.rawValue.uuidString,
			profileName: "Work",
			sourceOrigin: "https://claude.ai"
		)])
	}

	@Test
	internal func defaultHandlingOpensTheApp() async throws {
		let other = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)
		let opened = LockIsolated<[URL]>([])
		let initial = try Self.prompt(Self.request(profileID: other))
		let store = TestStore(initialState: initial) { AppLinkPrompt() }
			withDependencies: {
				$0.appLinks.openApp = { url, application in
					#expect(application == nil)
					opened.withValue { $0.append(url) }
					return .opened
				}
			}
		#expect(store.state.script == nil)

		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.appOpened)
		await store.receive(\.delegate.finished)
		#expect(opened.value == [URL(string: "claude://login/callback?code=1")!])
	}

	@Test
	internal func privateWindowOpensTheAppAndNeverRunsTheScript() async throws {
		var handler = Self.handler
		handler.defaultHandling = .runScript("echo default")
		let prompt = try Self.prompt(Self.request(isPrivate: true), handler: handler)
		#expect(prompt.handling == .systemDefault)
		#expect(prompt.profileName == nil)
		#expect(prompt.landingName == "Claude")

		// runScript stays unimplemented: reaching it fails the test.
		let store = TestStore(initialState: prompt) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.openApp = { _, _ in .opened }
		}
		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.appOpened)
		await store.receive(\.delegate.finished)
	}

	@Test
	internal func invalidLinkNeverReachesTheScript() async throws {
		let prompt = try Self.prompt(Self.request("claude://login/callback?code=" + String(repeating: "a", count: 9_000)))
		#expect(prompt.failure == .tooLong)
		#expect(prompt.script == nil)
		#expect(!prompt.offersAlwaysAllow)

		let store = TestStore(initialState: prompt) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.openApp = { _, _ in .opened }
		}
		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.appOpened)
		await store.receive(\.delegate.finished)
	}

	// MARK: - Failures

	@Test
	internal func failedScriptShowsItsErrorWithOpenAppAsFallback() async throws {
		let log = URL(filePath: "/tmp/claude.log")
		let initial = try Self.prompt()
		let store = TestStore(initialState: initial) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.runScript = { _ in .failed(status: 2, message: "no workspace", log: log) }
			$0.appLinks.openApp = { _, _ in .opened }
		}
		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.scriptFinished) {
			$0.phase = .failed(.script(status: 2, message: "no workspace", log: log))
		}

		// Confirm again does nothing: only Open app or Cancel.
		await store.send(.ui(.confirm))
		await store.send(.ui(.openApp)) { $0.phase = .running }
		await store.receive(\.appOpened)
		await store.receive(\.delegate.finished)
	}

	@Test
	internal func timedOutScriptFallsBackToOpenApp() async throws {
		let initial = try Self.prompt()
		let store = TestStore(initialState: initial) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.runScript = { _ in .timedOut(log: nil) }
			$0.appLinks.openApp = { _, _ in .didNotOpen }
		}
		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.scriptFinished) { $0.phase = .failed(.timedOut(log: nil)) }
		await store.send(.ui(.openApp)) { $0.phase = .running }
		await store.receive(\.appOpened) { $0.phase = .failed(.appDidNotOpen) }
		await store.send(.ui(.cancel))
		await store.receive(\.delegate.finished)
	}

	// MARK: - Chosen apps (DEV-862)

	private static let claudeWork = AppLinkApplication(
		path: "/Users/me/Workspaces/Claude Work.app",
		bundleID: "com.anthropic.claudefordesktop",
		name: "Claude Work"
	)

	@Test
	internal func chosenAppOpensTheLink() async throws {
		let other = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)
		var handler = Self.handler
		handler.application = Self.claudeWork
		handler.defaultHandling = .openApp(Self.claudeWork)
		let opened = LockIsolated<[AppLinkApplication?]>([])
		let initial = try Self.prompt(Self.request(profileID: other), handler: handler)
		#expect(initial.application == Self.claudeWork)
		#expect(initial.appName == "Claude Work")

		let store = TestStore(initialState: initial) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.openApp = { _, application in
				opened.withValue { $0.append(application) }
				return .opened
			}
		}
		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.appOpened)
		await store.receive(\.delegate.finished)
		#expect(opened.value == [Self.claudeWork])
	}

	@Test
	internal func missingAppSaysSoAndOffersSystemDefaultOnlyWhenAsked() async throws {
		let other = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)
		var handler = Self.handler
		handler.defaultHandling = .openApp(Self.claudeWork)
		let opened = LockIsolated<[AppLinkApplication?]>([])
		let initial = try Self.prompt(Self.request(profileID: other), handler: handler)
		let store = TestStore(initialState: initial) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.openApp = { _, application in
				opened.withValue { $0.append(application) }
				return application == nil ? .opened : .applicationMissing
			}
		}

		// System Default isn't available before the chosen app turned out to be missing.
		await store.send(.ui(.openWithSystemDefault))
		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.appOpened) { $0.phase = .failed(.applicationMissing(Self.claudeWork)) }

		// Nothing fell back on its own.
		#expect(opened.value == [Self.claudeWork])

		await store.send(.ui(.openWithSystemDefault)) { $0.phase = .running }
		await store.receive(\.appOpened)
		await store.receive(\.delegate.finished)
		#expect(opened.value == [Self.claudeWork, nil])
	}

	@Test
	internal func failedScriptFallsBackToTheHandlersApp() async throws {
		var handler = Self.handler
		handler.application = Self.claudeWork
		handler.defaultHandling = .openApp(Self.claudeWork)
		let opened = LockIsolated<[AppLinkApplication?]>([])
		let initial = try Self.prompt(handler: handler)
		#expect(initial.script == Self.script)
		#expect(initial.appName == "Claude Work")
		let store = TestStore(initialState: initial) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.runScript = { _ in .failed(status: 1, message: "", log: nil) }
			$0.appLinks.openApp = { _, application in
				opened.withValue { $0.append(application) }
				return .opened
			}
		}
		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.scriptFinished) { $0.phase = .failed(.script(status: 1, message: "", log: nil)) }
		await store.send(.ui(.openApp)) { $0.phase = .running }
		await store.receive(\.appOpened)
		await store.receive(\.delegate.finished)
		#expect(opened.value == [Self.claudeWork])
	}

	@Test
	internal func cancelWhileRunningIsIgnored() async throws {
		var state = try Self.prompt()
		state.phase = .running
		let store = TestStore(initialState: state) { AppLinkPrompt() }
		await store.send(.ui(.cancel))
		await store.send(.ui(.openApp))
	}

	// MARK: - Always allow

	@Test
	internal func alwaysAllowRemembersTheSiteForThisHandler() async throws {
		let initial = try Self.prompt()
		let store = TestStore(initialState: initial) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.runScript = { _ in .succeeded(log: nil) }
		}
		await store.send(.ui(.alwaysAllowChanged(true))) { $0.alwaysAllow = true }
		await store.send(.ui(.confirm)) { $0.phase = .running }
		await store.receive(\.delegate.alwaysAllow)
		await store.receive(\.scriptFinished)
		await store.receive(\.delegate.finished)
	}

	@Test
	internal func alwaysAllowNeedsAKnownSite() async throws {
		let initial = try Self.prompt(Self.request(origin: nil))
		let store = TestStore(initialState: initial) { AppLinkPrompt() }
		await store.send(.ui(.alwaysAllowChanged(true)))
		#expect(!store.state.alwaysAllow)
	}

	@Test
	internal func allowedSiteLandsWithoutAskingAndAsksOnlyOnFailure() async throws {
		var handler = Self.handler
		handler.alwaysAllowedOrigins = ["https://claude.ai"]
		let prompt = try Self.prompt(handler: handler)
		#expect(prompt.skipsPrompt)

		let store = TestStore(initialState: prompt) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.runScript = { _ in .failed(status: 1, message: "", log: nil) }
		}
		#expect(store.state.isPresented)
		await store.send(.start) { $0.phase = .running }
		#expect(!store.state.isPresented)
		await store.receive(\.scriptFinished) { $0.phase = .failed(.script(status: 1, message: "", log: nil)) }
		#expect(store.state.isPresented)
	}

	@Test
	internal func appFeatureRemembersAlwaysAllowInRoutingPreferences() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [Self.handler]) }
		var prompt = try Self.prompt()
		prompt.alwaysAllow = true
		state.appLinkPrompt = prompt
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.appLinks.runScript = { _ in .succeeded(log: nil) }
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 4) }
			$0.browserEngine.externalLinkIsCurrent = { _, token in token == 7 }
		}
		store.exhaustivity = .off

		await store.send(.appLinkPrompt(.ui(.confirm)))
		await store.receive(\.appLinkPrompt.scriptFinished)
		await store.receive(\.appLinkPrompt.delegate.finished)
		#expect(store.state.appLinkPrompt == nil)
		#expect(store.state.settings.routingPreferences.appLinks.handlers.first?.alwaysAllowedOrigins
			== ["https://claude.ai"])
	}

	@Test
	internal func appFeatureKeepsWhereAChosenAppMoved() async throws {
		let other = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)
		var handler = Self.handler
		handler.application = Self.claudeWork
		handler.defaultHandling = .openApp(Self.claudeWork)
		var moved = Self.claudeWork
		moved.path = "/Users/me/Elsewhere/Claude Work.app"
		moved.bookmark = Data([9])

		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [handler]) }
		state.appLinkPrompt = try Self.prompt(Self.request(profileID: other), handler: handler)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.appLinks.openApp = { [moved] _, _ in .openedMoved(moved) }
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 4) }
			$0.browserEngine.externalLinkIsCurrent = { _, token in token == 7 }
		}
		store.exhaustivity = .off

		await store.send(.appLinkPrompt(.ui(.confirm)))
		await store.receive(\.appLinkPrompt.appOpened)
		await store.receive(\.appLinkPrompt.delegate.applicationMoved)
		await store.receive(\.appLinkPrompt.delegate.finished)
		let saved = try #require(store.state.settings.routingPreferences.appLinks.handlers.first)
		#expect(saved.application == moved)
		#expect(saved.defaultHandling == .openApp(moved))
		#expect(saved.overrides.map(\.handling) == [.runScript(Self.script)])
	}

	@Test
	internal func appFeaturePresentsAndLeavesUnmatchedLinksToChrome() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [Self.handler]) }
		#expect(state.appLinkPrompt(
			for: .init(link: Self.request("zoommtg://join"), windowID: Self.windowID), id: UUID(0), appName: nil
		) == nil)

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.appLinks.appName = { _ in "Claude" }
			$0.appLinks.appPath = { _ in "/Applications/Claude.app" }
		}
		store.exhaustivity = .off
		await store.send(.presentAppLink(.init(link: Self.request(), windowID: Self.windowID)))
		let prompt = try #require(store.state.appLinkPrompt)
		#expect(prompt.windowID == Self.windowID)
		#expect(prompt.phase == .asking)
		#expect(prompt.handling == .runScript(Self.script))
		// The portrait prompt shows the icon of the app Open opens (DEV-872).
		#expect(prompt.appPath == "/Applications/Claude.app")
	}

	@Test
	internal func pageThatMovedOnCannotLandOrOpen() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [Self.handler]) }
		var prompt = try Self.prompt()
		prompt.alwaysAllow = true
		state.appLinkPrompt = prompt

		// runScript and openApp stay unimplemented: reaching either fails the test.
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 2, documentRevision: 5) }
		}
		store.exhaustivity = .off

		await store.send(.appLinkPrompt(.ui(.confirm)))
		#expect(store.state.appLinkPrompt?.phase == .sourceChanged)
		#expect(store.state.appLinkPrompt?.alwaysAllow == false)
		await store.send(.appLinkPrompt(.ui(.openApp)))
		#expect(store.state.appLinkPrompt?.phase == .sourceChanged)
		#expect(store.state.settings.routingPreferences.appLinks.handlers.first?.alwaysAllowedOrigins == [])

		await store.send(.appLinkPrompt(.ui(.cancel)))
		await store.receive(\.appLinkPrompt.delegate.finished)
		#expect(store.state.appLinkPrompt == nil)
	}

	@Test
	internal func frameThatAskedAndWentAwayCannotLand() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.appLinkPrompt = try Self.prompt()

		// The main document is the same; only the subframe's guard fails.
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 4) }
			$0.browserEngine.externalLinkIsCurrent = { _, _ in false }
		}
		store.exhaustivity = .off
		await store.send(.appLinkPrompt(.ui(.confirm)))
		#expect(store.state.appLinkPrompt?.phase == .sourceChanged)
	}

	@Test
	internal func plainHTTPSitesAreNeverRemembered() throws {
		let prompt = try Self.prompt(Self.request(origin: "http://claude.ai"))
		#expect(!prompt.offersAlwaysAllow)
	}

	@Test
	internal func privateWindowsNeverRememberASite() throws {
		let prompt = try Self.prompt(Self.request(isPrivate: true))
		#expect(!prompt.offersAlwaysAllow)
	}

	@Test
	internal func alreadyAllowedSiteThatMovedOnRunsNothingAndSaysSo() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		var handler = Self.handler
		handler.alwaysAllowedOrigins = ["https://claude.ai"]
		state.appLinkPrompt = try Self.prompt(handler: handler)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off
		await store.send(.appLinkPrompt(.start))
		#expect(store.state.appLinkPrompt?.phase == .sourceChanged)
		#expect(store.state.appLinkPrompt?.isPresented == true)
	}

	@Test
	internal func linksWhileAHandlerRunsAreTakenAndDropped() async throws {
		var state = Self.shownState()
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [Self.handler]) }
		var prompt = try Self.prompt()
		prompt.phase = .running
		state.appLinkPrompt = prompt

		// Chrome's dialog never asks instead (DEV-1259): Arx takes the link and drops it.
		let presentation = try #require(state.appLinkPresentation(for: Self.shownRequest("claude://x"), hasSystemApp: true))
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off
		await store.send(.presentAppLink(presentation))
		#expect(store.state.appLinkPrompt == prompt)
	}

	/// The engine keeps one source token per page: taking a second link from the running
	/// prompt's page would make its Open app fallback say the page moved on.
	@Test
	internal func linksFromTheRunningPromptsOwnPageStayWithChrome() throws {
		var state = Self.shownState()
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [Self.handler]) }
		let request = Self.shownRequest("claude://x")
		let decision = try #require(state.settings.routingPreferences.appLinks.decide(
			link: request.link, profileID: request.profileID, isPrivate: false, sourceOrigin: request.sourceOrigin
		))
		var prompt = AppLinkPrompt.State(
			id: UUID(9), windowID: Self.windowID, request: request, decision: decision, profileName: nil, appName: "Claude"
		)
		prompt.phase = .running
		state.appLinkPrompt = prompt
		#expect(state.appLinkPresentation(for: Self.shownRequest("claude://y"), hasSystemApp: true) == nil)
	}

	// MARK: - Links no handler takes (DEV-1259)

	@Test
	internal func aLinkNoHandlerTakesGetsArxsPromptForTheSystemApp() async throws {
		let state = Self.shownState()
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [Self.handler]) }
		let request = Self.shownRequest("linear://issue/DEV-1")

		// Before DEV-1259 Arx declined it, and Chrome's "Open Linear.app?" dialog asked.
		let presentation = try #require(state.appLinkPresentation(for: request, hasSystemApp: true))

		// No app on this Mac opens it: Chrome neither asks nor opens anything either.
		#expect(state.appLinkPresentation(for: request, hasSystemApp: false) == nil)
		// Web links are never app links.
		#expect(state.appLinkPresentation(for: Self.shownRequest("https://linear.app"), hasSystemApp: true) == nil)

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.appLinks.appName = { _ in "Linear" }
			$0.appLinks.appPath = { _ in "/Applications/Linear.app" }
			$0.appLinks.openApp = { _, _ in .opened }
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 4) }
			$0.browserEngine.externalLinkIsCurrent = { _, token in token == 7 }
		}
		store.exhaustivity = .off
		await store.send(.presentAppLink(presentation))
		let prompt = try #require(store.state.appLinkPrompt)
		#expect(prompt.phase == .asking)
		#expect(!prompt.isSaved)
		#expect(prompt.appName == "Linear")
		#expect(prompt.appPath == "/Applications/Linear.app")
		#expect(prompt.handling == .systemDefault)
		#expect(prompt.application == nil)
		#expect(prompt.offersAlwaysAllow)

		// Remembering the answer saves the app link, with the site always allowed.
		await store.send(.appLinkPrompt(.ui(.alwaysAllowChanged(true))))
		await store.send(.appLinkPrompt(.ui(.confirm)))
		await store.receive(\.appLinkPrompt.delegate.saveHandler)
		await store.receive(\.appLinkPrompt.appOpened)
		await store.receive(\.appLinkPrompt.delegate.finished)
		#expect(store.state.appLinkPrompt == nil)
		let handlers = store.state.settings.routingPreferences.appLinks.handlers
		#expect(handlers.count == 2)
		let saved = try #require(handlers.last)
		#expect(saved.name == "Linear")
		#expect(saved.scheme == "linear")
		#expect(saved.defaultHandling == .systemDefault)
		#expect(saved.alwaysAllowedOrigins == ["https://linear.app"])
		// The next link from the site opens without asking.
		let next = try #require(store.state.settings.routingPreferences.appLinks.decide(
			link: "linear://issue/DEV-2",
			profileID: request.profileID,
			isPrivate: false,
			sourceOrigin: "https://linear.app"
		))
		#expect(next.skipsPrompt)
	}

	@Test
	internal func aLinkNoHandlerTakesWithoutRememberingSavesNothing() async throws {
		let state = Self.shownState()
		state.settings.$routingPreferences.withLock { $0.appLinks = .init() }
		let request = Self.shownRequest("linear://issue/DEV-1")
		let presentation = try #require(state.appLinkPresentation(for: request, hasSystemApp: true))
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.appLinks.appName = { _ in "Linear" }
			$0.appLinks.appPath = { _ in "/Applications/Linear.app" }
			$0.appLinks.openApp = { url, application in
				#expect(url.absoluteString == "linear://issue/DEV-1")
				#expect(application == nil)
				return .opened
			}
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 4) }
			$0.browserEngine.externalLinkIsCurrent = { _, _ in true }
		}
		store.exhaustivity = .off
		await store.send(.presentAppLink(presentation))
		await store.send(.appLinkPrompt(.ui(.confirm)))
		await store.receive(\.appLinkPrompt.appOpened)
		await store.receive(\.appLinkPrompt.delegate.finished)
		#expect(store.state.settings.routingPreferences.appLinks.handlers.isEmpty)
	}

	@Test
	internal func rememberingNeverTransfersToAHandlerSavedMeanwhile() async throws {
		var state = Self.shownState()
		let request = Self.shownRequest("linear://issue/DEV-1")
		let decision = try #require(AppLinkPreferences().decideUnmatched(link: request.link, appName: "Linear", handlerID: UUID(9)))
		var prompt = AppLinkPrompt.State(
			id: UUID(9), windowID: Self.windowID, request: request, decision: decision, profileName: nil, appName: "Linear"
		)
		prompt.alwaysAllow = true
		state.appLinkPrompt = prompt

		// Saved while the prompt was open, with a script the prompt never showed.
		let existing = AppLinkHandler(id: UUID(1), name: "Linear Work", scheme: "linear", defaultHandling: .runScript("true"))
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [existing]) }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.appLinks.openApp = { _, _ in .opened }
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 4) }
			$0.browserEngine.externalLinkIsCurrent = { _, _ in true }
		}
		store.exhaustivity = .off
		await store.send(.appLinkPrompt(.ui(.confirm)))
		await store.receive(\.appLinkPrompt.delegate.saveHandler)
		let handlers = store.state.settings.routingPreferences.appLinks.handlers
		#expect(handlers == [existing])
	}

	@Test
	internal func rememberingNeverGoesToASwitchedOffHandler() async throws {
		var state = Self.shownState()
		let request = Self.shownRequest("linear://issue/DEV-1")
		let decision = try #require(AppLinkPreferences().decideUnmatched(link: request.link, appName: "Linear", handlerID: UUID(9)))
		var prompt = AppLinkPrompt.State(
			id: UUID(9), windowID: Self.windowID, request: request, decision: decision, profileName: nil, appName: "Linear"
		)
		prompt.alwaysAllow = true
		state.appLinkPrompt = prompt
		let off = AppLinkHandler(id: UUID(1), name: "Linear Off", scheme: "linear", isEnabled: false)
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [off]) }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.appLinks.openApp = { _, _ in .opened }
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 4) }
			$0.browserEngine.externalLinkIsCurrent = { _, _ in true }
		}
		store.exhaustivity = .off
		await store.send(.appLinkPrompt(.ui(.confirm)))
		await store.receive(\.appLinkPrompt.delegate.saveHandler)
		let preferences = store.state.settings.routingPreferences.appLinks
		#expect(preferences.handlers.map(\.id) == [UUID(1), UUID(9)])
		#expect(preferences.handlers.first?.alwaysAllowedOrigins == [])
		// The site's next link opens without asking.
		#expect(preferences.decide(
			link: "linear://issue/DEV-2", profileID: request.profileID, isPrivate: false, sourceOrigin: "https://linear.app"
		)?.skipsPrompt == true)
	}

	// MARK: - Copy Link

	@Test
	internal func copyLinkCopiesAndKeepsThePromptOpen() async throws {
		let copied = LockIsolated<[String]>([])
		let clock = TestClock()
		let initial = try Self.prompt()
		let store = TestStore(initialState: initial) { AppLinkPrompt() } withDependencies: {
			$0.appLinks.copyLink = { link in copied.withValue { $0.append(link) } }
			$0.continuousClock = clock
		}
		await store.send(.ui(.copyLink)) { $0.copied = true }
		await clock.advance(by: .seconds(2))
		await store.receive(\.copiedExpired) { $0.copied = false }
		#expect(copied.value == ["claude://login/callback?code=1"])
		#expect(store.state.phase == .asking)
	}

	@Test
	internal func showScriptOnRequest() async throws {
		let initial = try Self.prompt()
		let store = TestStore(initialState: initial) { AppLinkPrompt() }
		await store.send(.ui(.toggleScript)) { $0.showsScript = true }
		await store.send(.ui(.toggleScript)) { $0.showsScript = false }
	}
}
