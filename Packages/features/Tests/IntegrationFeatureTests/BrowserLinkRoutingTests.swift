import BrowserCore
import BrowserEngineClient
import CustomDump
import DefaultBrowserClient
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// `chrome://` and `arc://` links (DEV-1193): pages' chrome:// links through App Links' built-in
/// handler for Chrome's pages, with Open in Arx where DEV-1189's table has a place; arc:// links
/// to Arx's place or to Arc; and "Arx can't open this".
@Suite(.dependencies)
@MainActor
internal struct BrowserLinkRoutingTests {
	private static let tab = BrowserCore.Tab.ID(rawValue: UUID(3))
	private static let profile = Profile.ID(rawValue: UUID(0))
	private static let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
	private static let arc = URL(fileURLWithPath: "/Applications/Arc.app")

	private static func request(
		_ link: String,
		isPrivate: Bool = false
	) -> BrowserExternalLink {
		.init(
			sourceTabID: tab,
			profileID: profile,
			isPrivate: isPrivate,
			sourceDocumentRevision: 4,
			sourceToken: 7,
			link: link,
			sourceOrigin: "https://www.netflix.com",
			hasUserGesture: true,
			isRedirect: false
		)
	}

	private static func state() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[id: tab]
		state.windowIsOpen = true
		state.settings.$routingPreferences.withLock { $0.appLinks = .init() }
		return state
	}

	/// A client with the given browsers installed, recording what it opens.
	private static func client(
		installed: Set<String>,
		opened: LockIsolated<[(URL, URL)]>,
		opens: Bool = true
	) -> BrowserLinkClient {
		.init(
			application: { identifiers in
				if identifiers == BrowserLinkClient.chromeIdentifiers, installed.contains("chrome") { return chrome }
				if identifiers == BrowserLinkClient.arcIdentifiers, installed.contains("arc") { return arc }
				return nil
			},
			open: { url, application in
				opened.withValue { $0.append((url, application)) }
				return opens
			}
		)
	}

	private static func store(
		_ state: AppFeature.State = state(),
		installed: Set<String>,
		opened: LockIsolated<[(URL, URL)]> = .init([]),
		opens: Bool = true
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.continuousClock = TestClock()
			$0.browserLinks = Self.client(installed: installed, opened: opened, opens: opens)
			$0.appLinks.appName = { _ in nil }
			$0.appLinks.appPath = { _ in nil }
		}
		store.exhaustivity = .off
		return store
	}

	private static let chromeApplication = AppLinkApplication(
		path: chrome.path(percentEncoded: false),
		name: "Google Chrome"
	)

	// MARK: - chrome:// links from pages, with Chrome installed: App Links

	@Test
	internal func aChromeLinkGetsAppLinksPromptWithOpenInArx() async throws {
		let store = Self.store(installed: ["chrome"])

		await store.send(.browserLinks(.pageLink(Self.request("chrome://settings/content/protectedContent"))))
		await store.receive(\.presentAppLink)
		let prompt = try #require(store.state.appLinkPrompt)
		#expect(prompt.windowID == store.state.main.id)
		#expect(prompt.handler.id == AppLinkHandler.chromePagesID)
		#expect(prompt.application?.path == Self.chrome.path(percentEncoded: false))
		#expect(prompt.handling == .openApp(prompt.application))
		#expect(prompt.arxPlace == .destination("row/advanced/protectedMedia"))
		#expect(!prompt.opensInArx)
		#expect(prompt.offersAlwaysAllow)

		// The built-in handler is now one of the person's, for Always allow and Settings.
		let handlers = store.state.settings.routingPreferences.appLinks.handlers
		#expect(handlers.map(\.id) == [AppLinkHandler.chromePagesID])
	}

	@Test
	internal func aChromeLinkArxHasNoPlaceForOffersOnlyChrome() async throws {
		let store = Self.store(installed: ["chrome"])

		await store.send(.browserLinks(.pageLink(Self.request("chrome://flags"))))
		await store.receive(\.presentAppLink)
		#expect(store.state.appLinkPrompt != nil)
		#expect(store.state.appLinkPrompt?.arxPlace == nil)
	}

	@Test
	internal func aRuleSetToOpenInArxAsksOpenInArxAndOffersChromeBeside() async throws {
		let state = Self.state()
		var handler: AppLinkHandler = .chromePages(application: Self.chromeApplication)
		handler.defaultHandling = .openInArx
		state.settings.$routingPreferences.withLock { $0.appLinks = .init(handlers: [handler]) }
		let store = Self.store(state, installed: ["chrome"])

		await store.send(.browserLinks(.pageLink(Self.request("chrome://settings/passwords"))))
		await store.receive(\.presentAppLink)
		#expect(store.state.appLinkPrompt?.opensInArx == true)
		#expect(store.state.appLinkPrompt?.application == Self.chromeApplication)
		// The person's edits stay: the built-in handler isn't added again.
		#expect(store.state.settings.routingPreferences.appLinks.handlers == [handler])

		// A page Arx has no place for opens Chrome, whatever the rule says.
		await store.send(.appLinkPrompt(.ui(.cancel)))
		await store.receive(\.appLinkPrompt.delegate.finished)
		await store.send(.browserLinks(.pageLink(Self.request("chrome://flags"))))
		await store.receive(\.presentAppLink)
		#expect(store.state.appLinkPrompt?.handling == .openApp(Self.chromeApplication))
		#expect(store.state.appLinkPrompt?.opensInArx == false)
	}

	@Test
	internal func openInArxFromThePromptOpensArxsPlaceForThePagesProfile() async throws {
		let request = Self.request("chrome://settings/passwords")
		let decision = try #require(AppLinkPreferences(handlers: [.chromePages(application: Self.chromeApplication)]).decide(
			link: request.link,
			profileID: request.profileID,
			isPrivate: false,
			sourceOrigin: request.sourceOrigin
		))
		let prompt = AppLinkPrompt.State(
			id: UUID(40),
			windowID: UUID(41),
			request: request,
			decision: decision,
			profileName: "Personal",
			appName: nil
		)

		// The prompt itself: Open in Arx hands Arx's place over and ends.
		let promptStore = TestStore(initialState: prompt) { AppLinkPrompt() }
		await promptStore.send(.ui(.openInArx)) { $0.phase = .running }
		await promptStore.receive(\.delegate.openInArx)
		await promptStore.receive(\.delegate.finished)

		// Always allow commits to the main action: Open in Arx waits until it's unticked.
		let ticked = TestStore(initialState: prompt) { AppLinkPrompt() }
		await ticked.send(.ui(.alwaysAllowChanged(true))) { $0.alwaysAllow = true }
		await ticked.send(.ui(.openInArx))
		await ticked.send(.ui(.alwaysAllowChanged(false))) { $0.alwaysAllow = false }
		await ticked.send(.ui(.openInArx)) { $0.phase = .running }
		await ticked.receive(\.delegate.openInArx)
		await ticked.receive(\.delegate.finished)

		// The app: Settings at the page profile's passwords.
		var state = Self.state()
		state.appLinkPrompt = prompt
		let store = Self.store(state, installed: ["chrome"])
		let mainID = store.state.main.id
		await store.send(.appLinkPrompt(.delegate(.openInArx(.profile(.passwords), windowID: mainID, profileID: Self.profile))))
		await store.receive(\.ui.openSettings)
	}

	@Test
	internal func aSavedBuiltInHandlerNeverTakesADebugPage() throws {
		let state = Self.state()
		state.settings.$routingPreferences.withLock {
			$0.appLinks = .init(handlers: [.chromePages(application: Self.chromeApplication)])
		}
		#expect(state.appLinkPresentation(for: Self.request("chrome://quit"), hasSystemApp: true) == nil)
		#expect(state.appLinkPresentation(for: Self.request("chrome://settings/passwords"), hasSystemApp: false) != nil)
	}

	@Test
	internal func pickingAnAppForTheBuiltInHandlerKeepsChrome() {
		let handler: AppLinkHandler = .chromePages(application: Self.chromeApplication)
		let beta = AppLinkApplication(path: "/Applications/Google Chrome Beta.app", name: "Google Chrome Beta")
		let picked = AppLinkEditor.picking(beta, scheme: "googlechrome", for: handler)
		#expect(picked.scheme == AppLinkHandler.chromePagesScheme)
		#expect(picked.application == beta)
		#expect(picked.defaultHandling == .openApp(beta))
	}

	// MARK: - chrome:// links from pages, without Chrome

	@Test
	internal func withoutChromeArxOpensItsPlaceAtOnce() async throws {
		let opened = LockIsolated<[(URL, URL)]>([])
		let store = Self.store(installed: [], opened: opened)

		await store.send(.browserLinks(.pageLink(Self.request("chrome://extensions"))))
		await store.receive(\.ui.openExtensions, Self.profile)
		#expect(store.state.appLinkPrompt == nil)
		#expect(store.state.browserLinkPrompt == nil)
		#expect(opened.value.isEmpty)
	}

	@Test
	internal func withoutChromeAPageArxHasNoPlaceForCantOpen() async throws {
		let store = Self.store(installed: [])

		await store.send(.browserLinks(.pageLink(Self.request("chrome://flags"))))
		#expect(store.state.browserLinkPrompt?.link.page == "flags")
		#expect(store.state.browserLinkPrompt?.source == .page)
		#expect(store.state.appLinkPrompt == nil)
		await store.send(.browserLinkPrompt(.ui(.dismissButtonTapped)))
		await store.receive(\.browserLinkPrompt.delegate.dismissed)
		#expect(store.state.browserLinkPrompt == nil)
	}

	@Test
	internal func debugPagesNeverReachChromeOrAsk() async throws {
		let opened = LockIsolated<[(URL, URL)]>([])
		let store = Self.store(installed: ["chrome", "arc"], opened: opened)

		await store.send(.browserLinks(.pageLink(Self.request("chrome://quit"))))
		await store.send(.browserLinks(.pageLink(Self.request("chrome://delayeduithreadhang"))))
		await store.send(.browserLinks(.outsideLink(URL(string: "arc://crash")!)))
		await store.finish()
		#expect(store.state.appLinkPrompt == nil)
		#expect(store.state.browserLinkPrompt == nil)
		#expect(store.state.settings.routingPreferences.appLinks.handlers.isEmpty)
		#expect(opened.value.isEmpty)
	}

	// MARK: - arc:// links

	@Test
	internal func arcLinksArxHandlesOpenDirectly() async throws {
		let opened = LockIsolated<[(URL, URL)]>([])
		let store = Self.store(installed: ["arc", "chrome"], opened: opened)

		await store.send(.browserLinks(.outsideLink(URL(string: "arc://settings/system")!)))
		await store.receive(\.ui.openSettings)
		await store.receive(\.settings.ui.searchResultChosen)

		await store.send(.browserLinks(.pageLink(Self.request("arc://extensions"))))
		await store.receive(\.ui.openExtensions, Self.profile)
		#expect(store.state.appLinkPrompt == nil)
		#expect(store.state.browserLinkPrompt == nil)
		#expect(opened.value.isEmpty)
	}

	@Test
	internal func otherArcLinksGoToArc() async throws {
		let opened = LockIsolated<[(URL, URL)]>([])
		let store = Self.store(installed: ["arc"], opened: opened)

		await store.send(.browserLinks(.outsideLink(URL(string: "arc://inspect")!)))
		await store.finish()
		#expect(opened.value.map(\.0) == [URL(string: "arc://inspect")!])
		#expect(opened.value.map(\.1) == [Self.arc])
	}

	@Test
	internal func anArcThatDoesntTakeTheLinkSaysArxCantOpenIt() async throws {
		let store = Self.store(installed: ["arc"], opens: false)

		await store.send(.browserLinks(.outsideLink(URL(string: "arc://boost/v2/css/")!)))
		await store.receive(\.browserLinks.browserDidNotOpen)
		#expect(store.state.browserLinkPrompt?.source == .otherApp)
		#expect(store.state.browserLinkPrompt?.link.browser == .arc)
	}

	// MARK: - From other apps

	@Test
	internal func anotherAppsChromeLinkIsNeverArxs() async throws {
		let opened = LockIsolated<[(URL, URL)]>([])
		let store = Self.store(installed: ["chrome"], opened: opened)

		await store.send(.browserLinks(.outsideLink(URL(string: "chrome://settings/passwords")!)))
		await store.finish()
		#expect(store.state.appLinkPrompt == nil)
		#expect(store.state.browserLinkPrompt == nil)
		#expect(opened.value.isEmpty)
	}

	@Test
	internal func arxSettingsFromAnotherAppOpensSettings() async throws {
		let store = Self.store(installed: [])

		await store.send(.browserLinks(.outsideLink(URL(string: "arx://settings/advanced/protectedMedia")!)))
		await store.receive(\.ui.openSettings)
		await store.receive(\.settings.ui.searchResultChosen)

		// An arx:// address that's no settings address does nothing.
		await store.send(.browserLinks(.outsideLink(URL(string: "arx://newtab")!)))
		#expect(store.state.browserLinkPrompt == nil)
	}

	@Test
	internal func aNoticeFromAnotherAppGoesOnTheMainWindowAndOpensIt() async throws {
		var state = Self.state()
		state.windowIsOpen = false
		let store = Self.store(state, installed: [])

		await store.send(.browserLinks(.outsideLink(URL(string: "arc://boost/v2/css/")!)))
		#expect(store.state.windowIsOpen)
		#expect(store.state.browserLinkPrompt?.windowID == store.state.main.id)
		#expect(store.state.browserLinkPrompt?.source == .otherApp)
	}

	@Test(arguments: [
		("arc://extensions", true, true),
		("ARC://settings", false, false),
		("chrome://settings", true, false),
		("arx://open?url=https://example.com", false, true),
		("https://example.com", false, true),
		("slack://open", true, false),
	])
	internal func otherAppsLinksArxTakes(link: String, browserLinks: Bool, takes: Bool) {
		#expect(IncomingURLHandler.takesLink(URL(string: link)!, browserLinks: browserLinks) == takes)
	}

	// MARK: - Where Arx's place opens

	@Test
	internal func libraryAndPanelsOpenInABrowserWindow() async throws {
		var state = Self.state()

		// A Little Arx, a Peek's window or a window that went: the main window.
		#expect(state.browserLinkWindow(UUID(77)) == state.main.id)
		#expect(state.browserLinkWindow(state.main.id) == state.main.id)

		// Closed, the main window opens for it.
		state.windowIsOpen = false
		#expect(state.browserLinkWindow(UUID(77)) == state.main.id)
		#expect(state.windowIsOpen)
	}

	@Test
	internal func historyAndDownloadsOpenInTheMainWindowAndBringItForward() async throws {
		var closed = Self.state()
		closed.windowIsOpen = false
		let store = Self.store(closed, installed: [])

		let focusRequests = store.state.mediaSourceFocusRequest
		await store.send(.browserLinks(.outsideLink(URL(string: "arc://history")!)))
		#expect(store.state.windowIsOpen)
		#expect(store.state.focusedWindowID == store.state.main.id)
		#expect(store.state.mediaSourceFocusRequest == focusRequests + 1)
		await store.receive(\.main.ui.openLibrary, .history)

		await store.send(.browserLinks(.outsideLink(URL(string: "arc://downloads")!)))
		await store.receive(\.ui.openDownloads, store.state.main.id)
	}

	@Test
	internal func historyForAnotherProfileOpensThatProfilesPage() async throws {
		let other = Profile.ID(rawValue: UUID(88))
		var state = Self.state()
		let request = Self.request("chrome://history")
		let decision = try #require(AppLinkPreferences(handlers: [.chromePages(application: Self.chromeApplication)]).decide(
			link: request.link,
			profileID: nil,
			isPrivate: false,
			sourceOrigin: nil
		))
		state.appLinkPrompt = .init(
			id: UUID(60),
			windowID: UUID(61),
			request: request,
			decision: decision,
			profileName: nil,
			appName: nil
		)
		let store = Self.store(state, installed: ["chrome"])

		// From a Little Arx in another profile, whose window went: the main window shows the
		// fixture's profile, so that profile's page in Settings opens instead of its History.
		await store.send(.appLinkPrompt(.delegate(.openInArx(.command(.showHistory), windowID: UUID(61), profileID: other))))
		await store.receive(\.ui.openSettings)
	}

	@Test
	internal func aClosedMainWindowKeepsItsProfileForLinksFromOtherApps() async throws {
		var state = Self.state()
		state.windowIsOpen = false
		let profile = state.main.sidebar.space.profileID
		#expect(state.browserLinkProfileID(state.main.id) == profile)
	}

	@Test
	internal func aFailedHandOffWhoseWindowWentGoesOnTheMainWindow() async throws {
		let store = Self.store(installed: [])
		let link = try #require(BrowserSchemeLink(string: "arc://boost/v2/css/"))
		let gone: BrowserLinkPrompt.Origin = .init(windowID: UUID(99), profileID: Self.profile, source: .page)

		await store.send(.browserLinks(.browserDidNotOpen(link, gone)))
		#expect(store.state.browserLinkPrompt?.windowID == store.state.main.id)
		#expect(store.state.browserLinkPrompt?.origin.profileID == Self.profile)
	}

	@Test
	internal func aNoticeWhoseWindowWentGivesWayToTheNextLink() async throws {
		var state = Self.state()
		let link = try #require(BrowserSchemeLink(string: "arc://inspect"))
		state.browserLinkPrompt = .init(
			id: UUID(50),
			origin: .init(windowID: UUID(51), profileID: Self.profile, source: .page),
			link: link
		)
		let store = Self.store(state, installed: [])

		await store.send(.browserLinks(.pageLink(Self.request("chrome://flags"))))
		#expect(store.state.browserLinkPrompt?.windowID == store.state.main.id)
		#expect(store.state.browserLinkPrompt?.link.page == "flags")
	}
}
