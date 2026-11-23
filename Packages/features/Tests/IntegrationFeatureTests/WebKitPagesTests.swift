import AppLinkClient
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// WebKit pages for protected video (DEV-877): the fallback prompt, its answers, the sidebar's
/// engine mark, the site menu's Open in WebKit and Settings' list.
@Suite(.dependencies)
@MainActor
internal struct WebKitPagesTests {
	private static let tab = BrowserCore.Tab.ID(rawValue: UUID(3))
	private static let profile = Profile.ID(rawValue: UUID(0))

	private static func request(
		_ address: String = "https://www.video.example/watch/1",
		reason: ProtectedMediaRequest.Reason = .playbackFailed
	) -> ProtectedMediaRequest {
		.init(tabID: tab, profileID: profile, url: URL(string: address)!, reason: reason)
	}

	private static func state() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[id: tab]
		state.settings.$webKitPages.withLock { $0 = .init(sites: ["netflix.com"]) }
		return state
	}

	@Test
	internal func promptOnlyForUndeclinedChromiumPagesOnScreen() async throws {
		let state = Self.state()
		let prompt = try #require(state.webKitPrompt(for: Self.request(), engine: .chromium, id: UUID(9)))
		#expect(prompt.windowID == state.main.id)
		#expect(prompt.host == "video.example")

		#expect(state.webKitPrompt(for: Self.request(), engine: .webKit, id: UUID(9)) == nil)
		// DEV-1188: a listed site's page in Chromium is one the router kept there, Netflix after
		// Back for one; its failed video falls back to WebKit with a prompt, never silently.
		let netflix = try #require(
			state.webKitPrompt(for: Self.request("https://www.netflix.com"), engine: .chromium, id: UUID(9))
		)
		#expect(netflix.kind == .offer)
		#expect(state.webKitPrompt(for: Self.request("http://video.example"), engine: .chromium, id: UUID(9)) == nil)
		let elsewhere = ProtectedMediaRequest(tabID: .init(rawValue: UUID(4)), profileID: Self.profile, url: Self.request().url)
		#expect(state.webKitPrompt(for: elsewhere, engine: .chromium, id: UUID(9)) == nil)

		state.settings.$webKitPages.withLock { $0.decline(Self.request().url) }
		#expect(state.webKitPrompt(for: Self.request(), engine: .chromium, id: UUID(9)) == nil)
		state.settings.$webKitPages.withLock { $0 = .init(isEnabled: false, sites: []) }
		#expect(state.webKitPrompt(for: Self.request(), engine: .chromium, id: UUID(9)) == nil)
	}

	/// DEV-1211, Max's rule: a streaming site falls back to WebKit with a prompt, and a likely bot
	/// check stays quiet. Keys made with no media wanting them ask only on a built-in streaming
	/// service (listed or not) or a listed site; media that can't play asks anywhere.
	@Test
	internal func keysWithoutMediaAskOnlyOnStreamingSites() async throws {
		let state = Self.state()
		let botCheck = Self.request("https://resend.com/", reason: .keysWithoutMedia)
		#expect(state.webKitPrompt(for: botCheck, engine: .chromium, id: UUID(9)) == nil)
		// The same site's media that can't play asks.
		let player = Self.request("https://resend.com/", reason: .playbackFailed)
		#expect(state.webKitPrompt(for: player, engine: .chromium, id: UUID(9)) != nil)

		// Netflix's player stops before it loads media: listed, or taken off the list, it asks.
		let netflix = Self.request("https://www.netflix.com/watch/1", reason: .keysWithoutMedia)
		#expect(state.webKitPrompt(for: netflix, engine: .chromium, id: UUID(9)) != nil)
		state.settings.$webKitPages.withLock { _ = $0.remove(netflix.url) }
		#expect(state.webKitPrompt(for: netflix, engine: .chromium, id: UUID(9)) != nil)

		// A site the person listed asks too.
		state.settings.$webKitPages.withLock { _ = $0.add(URL(string: "https://www.video.example/")!) }
		let listed = Self.request(reason: .keysWithoutMedia)
		#expect(state.webKitPrompt(for: listed, engine: .chromium, id: UUID(9)) != nil)
	}

	@Test
	internal func aPromptNobodyCanSeeGivesWayToTheNextOne() async throws {
		var state = Self.state()
		let other = ProtectedMediaRequest(tabID: .init(rawValue: UUID(4)), profileID: Self.profile, url: Self.request().url)

		// A prompt on the window showing its tab holds back the next one.
		state.webKitPrompt = state.webKitPrompt(for: Self.request(), engine: .chromium, id: UUID(8))
		#expect(!state.isStale(try #require(state.webKitPrompt)))
		#expect(state.webKitPrompt(for: Self.request(), engine: .chromium, id: UUID(9)) == nil)

		// Its tab left the window (closed, or another shown): the prompt can't be seen any more.
		state.webKitPrompt = .init(id: UUID(8), windowID: state.main.id, request: other)
		#expect(state.isStale(try #require(state.webKitPrompt)))
		let next = try #require(state.webKitPrompt(for: Self.request(), engine: .chromium, id: UUID(9)))
		#expect(next.id == UUID(9))

		// Its window closed.
		state.webKitPrompt = .init(id: UUID(8), windowID: UUID(77), request: Self.request())
		#expect(state.isStale(try #require(state.webKitPrompt)))
		#expect(state.webKitPrompt(for: Self.request(), engine: .chromium, id: UUID(9)) != nil)
	}

	@Test
	internal func withWebKitPagesOffOnlyListedSitesHearWhyTheyCantPlay() async throws {
		let state = Self.state()
		state.settings.$webKitPages.withLock { $0.isEnabled = false }
		let netflix = Self.request("https://www.netflix.com/watch/1")

		let notice = try #require(state.webKitPrompt(for: netflix, engine: .chromium, id: UUID(9)))
		#expect(notice.kind == .unavailable(app: nil))
		#expect(notice.windowID == state.main.id)
		// An unlisted site that asks may only be probing.
		#expect(state.webKitPrompt(for: Self.request(), engine: .chromium, id: UUID(9)) == nil)

		state.settings.$webKitPages.withLock { $0.decline(netflix.url) }
		#expect(state.webKitPrompt(for: netflix, engine: .chromium, id: UUID(9)) == nil)
	}

	@Test
	internal func withWebKitPagesOffSpotifyOffersItsApp() async throws {
		let state = Self.state()
		state.settings.$webKitPages.withLock { $0 = .init(isEnabled: false) }
		let opened = LockIsolated<[URL]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.pageEngines.engine = { _ in .chromium }
			$0.appLinks.appName = { $0.scheme == "spotify" ? "Spotify" : nil }
			$0.appLinks.appPath = { _ in "/Applications/Spotify.app" }
			$0.appLinks.openApp = { url, _ in
				opened.withValue { $0.append(url) }
				return .opened
			}
		}
		store.exhaustivity = .off
		let track = Self.request("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
		let app = WebKitPrompt.SiteApp(
			name: "Spotify",
			url: URL(string: "spotify:track:4uLU6hMCjMI75M1A2tKUQC")!,
			path: "/Applications/Spotify.app"
		)

		await store.send(.webKitPages(.protectedMediaRequested(track)))
		#expect(store.state.webKitPrompt?.kind == .unavailable(app: app))

		await store.send(.webKitPrompt(.ui(.dontAskAgainChanged(true))))
		await store.send(.webKitPrompt(.ui(.openAppButtonTapped)))
		await store.receive(\.webKitPrompt.delegate.answered)
		await store.finish()
		#expect(store.state.webKitPrompt == nil)
		#expect(opened.value == [app.url])
		// WebKit pages stay off; Don't ask again holds for the app too.
		#expect(store.state.settings.webKitPages == .init(isEnabled: false, declinedSites: ["open.spotify.com"]))
		await store.send(.webKitPages(.protectedMediaRequested(track)))
		#expect(store.state.webKitPrompt == nil)
	}

	@Test
	internal func withWebKitPagesOffAndNoAppTheNoticeOnlyCloses() async throws {
		let state = Self.state()
		state.settings.$webKitPages.withLock { $0 = .init(isEnabled: false) }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.pageEngines.engine = { _ in .chromium }
			$0.appLinks.appName = { _ in nil }
		}
		store.exhaustivity = .off

		await store.send(.webKitPages(.protectedMediaRequested(Self.request("https://open.spotify.com/"))))
		#expect(store.state.webKitPrompt?.kind == .unavailable(app: nil))
		await store.send(.webKitPrompt(.ui(.openAppButtonTapped)))
		#expect(store.state.webKitPrompt != nil)

		await store.send(.webKitPrompt(.ui(.stayButtonTapped)))
		await store.receive(\.webKitPrompt.delegate.answered)
		#expect(store.state.webKitPrompt == nil)
	}

	@Test
	internal func openInWebKitListsTheSiteAndMovesThePage() async throws {
		let moves = LockIsolated<[(BrowserCore.Tab.ID, PageEngine)]>([])
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.pageEngines.engine = { _ in .chromium }
			$0.pageEngines.move = { id, engine, _ in
				moves.withValue { $0.append((id, engine)) }
				return true
			}
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(url: Self.request().url), revision: 1) }
		}
		store.exhaustivity = .off

		await store.send(.webKitPages(.protectedMediaRequested(Self.request())))
		#expect(store.state.webKitPrompt?.request == Self.request())
		// A second request while one is showing doesn't replace it.
		await store.send(.webKitPages(.protectedMediaRequested(Self.request("https://other.example"))))
		#expect(store.state.webKitPrompt?.request == Self.request())

		await store.send(.webKitPrompt(.ui(.openInWebKitButtonTapped)))
		await store.receive(\.webKitPrompt.delegate.answered)
		await store.finish()
		#expect(store.state.webKitPrompt == nil)
		#expect(store.state.settings.webKitPages.sites == ["netflix.com", "video.example"])
		#expect(moves.value.map(\.0) == [Self.tab])
		#expect(moves.value.map(\.1) == [.webKit])
	}

	@Test
	internal func anOfferForAPageThatMovedOnDoesNothing() async throws {
		let moves = LockIsolated<Int>(0)
		var state = Self.state()
		state.webKitPrompt = .init(id: UUID(9), windowID: state.main.id, request: Self.request())
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.pageEngines.move = { _, _, _ in
				moves.withValue { $0 += 1 }
				return true
			}
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(url: URL(string: "https://elsewhere.example")!), revision: 2) }
		}
		store.exhaustivity = .off

		await store.send(.webKitPrompt(.ui(.openInWebKitButtonTapped)))
		await store.receive(\.webKitPrompt.delegate.answered)
		await store.finish()
		#expect(store.state.webKitPrompt == nil)
		#expect(store.state.settings.webKitPages.sites == ["netflix.com"])
		#expect(moves.value == 0)
	}

	@Test
	internal func stayCanRememberDontAskAgain() async throws {
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.pageEngines.engine = { _ in .chromium }
		}
		store.exhaustivity = .off

		await store.send(.webKitPages(.protectedMediaRequested(Self.request())))
		await store.send(.webKitPrompt(.ui(.dontAskAgainChanged(true))))
		await store.send(.webKitPrompt(.ui(.stayButtonTapped)))
		await store.receive(\.webKitPrompt.delegate.answered)
		#expect(store.state.webKitPrompt == nil)
		#expect(store.state.settings.webKitPages.sites == ["netflix.com"])
		#expect(store.state.settings.webKitPages.declinedSites == ["video.example"])

		await store.send(.webKitPages(.protectedMediaRequested(Self.request("https://video.example/other"))))
		#expect(store.state.webKitPrompt == nil)
	}

	@Test
	internal func engineMovesMarkTheSidebarsAndCloseAPromptThatMoved() async throws {
		var state = Self.state()
		state.webKitPrompt = .init(id: UUID(9), windowID: state.main.id, request: Self.request())
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off

		await store.send(.webKitPages(.engineChanged(.init(tabID: Self.tab, engine: .webKit))))
		#expect(store.state.webKitTabs == [Self.tab])
		#expect(store.state.main.sidebar.webKitTabs == [Self.tab])
		#expect(store.state.webKitPrompt == nil)

		await store.send(.webKitPages(.engineChanged(.init(tabID: Self.tab, engine: .chromium))))
		#expect(store.state.webKitTabs.isEmpty)
		#expect(store.state.main.sidebar.webKitTabs.isEmpty)
	}

	@Test
	internal func popupsFromWebKitOpenAsTabsInTheirWindow() async throws {
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off
		let url = URL(string: "https://help.example")!

		await store.send(.webKitPages(.openNewTab(source: Self.tab, url)))
		await store.receive(\.main.ui.openInNewTab)
	}

	/// DEV-1144: for a site Arx's FairPlay helper plays, the site menu's switch is Settings'
	/// Protected media, which would otherwise keep it in Chromium.
	@Test
	internal func siteMenuOpenInWebKitChoosesProtectedMediaForAFairPlaySite() async throws {
		var state = SiteMenuFeature.State()
		state.$webKitPages.withLock { $0 = .init() }
		state.fairPlayOrigins = ["https://open.spotify.com"]
		state.context = .init(url: URL(string: "https://open.spotify.com/album/1")!, tabID: Self.tab, profileID: Self.profile)

		// Listed, but FairPlay in the tab keeps it in Chromium.
		#expect(state.menu?.webKit == .init(isListed: false, isShown: false))
		let store = TestStore(initialState: state) { SiteMenuFeature() } withDependencies: {
			$0.pageEngines.move = { _, _, _ in true }
		}
		store.exhaustivity = .off

		await store.send(.ui(.menu(.setWebKit(true))))
		await store.receive(\.event.engineChanged)
		#expect(store.state.webKitPages.protectedMedia == .webKitPage)
		#expect(store.state.menu?.webKit?.isListed == true)

		await store.send(.ui(.menu(.setWebKit(false))))
		await store.receive(\.event.engineChanged)
		#expect(store.state.webKitPages.protectedMedia == .fairPlayInTab)
		#expect(store.state.menu?.webKit?.isListed == false)
	}

	/// DEV-1151: without the bridge (or after a failed track) the list sends a FairPlay site to
	/// WebKit whatever Protected media says, and the switch shows that; off takes it off the list.
	@Test
	internal func siteMenuShowsAFairPlaySiteTheBridgeCantKeepAsWebKits() async throws {
		var state = SiteMenuFeature.State()
		state.$webKitPages.withLock { $0 = .init() }
		state.fairPlayOrigins = []
		state.context = .init(url: URL(string: "https://open.spotify.com/album/1")!, tabID: Self.tab, profileID: Self.profile)
		#expect(state.webKitPages.protectedMedia == .fairPlayInTab)
		#expect(state.menu?.webKit?.isListed == true)
		let store = TestStore(initialState: state) { SiteMenuFeature() } withDependencies: {
			$0.pageEngines.move = { _, _, _ in true }
		}
		store.exhaustivity = .off

		await store.send(.ui(.menu(.setWebKit(false))))
		#expect(store.state.webKitPages.protectedMedia == .fairPlayInTab)
		#expect(!store.state.webKitPages.sites.contains("open.spotify.com"))
		#expect(store.state.menu?.webKit?.isListed == false)

		// On lists it again and chooses WebKit for when the bridge is back.
		await store.send(.ui(.menu(.setWebKit(true))))
		#expect(store.state.webKitPages.protectedMedia == .webKitPage)
		#expect(store.state.webKitPages.sites.contains("open.spotify.com"))
		#expect(store.state.menu?.webKit?.isListed == true)
	}

	/// DEV-1151: with the bridge, off leaves the list alone: Protected media alone decides, and
	/// the list still holds the site for when the bridge isn't there.
	@Test
	internal func siteMenuOffKeepsAFairPlaySiteListedWhileTheBridgePlaysIt() async throws {
		var state = SiteMenuFeature.State()
		state.$webKitPages.withLock {
			$0 = .init()
			$0.protectedMedia = .webKitPage
		}
		state.fairPlayOrigins = ["https://open.spotify.com"]
		state.context = .init(url: URL(string: "https://open.spotify.com/album/1")!, tabID: Self.tab, profileID: Self.profile)
		#expect(state.menu?.webKit?.isListed == true)
		let store = TestStore(initialState: state) { SiteMenuFeature() } withDependencies: {
			$0.pageEngines.move = { _, _, _ in true }
		}
		store.exhaustivity = .off

		await store.send(.ui(.menu(.setWebKit(false))))
		#expect(store.state.webKitPages.protectedMedia == .fairPlayInTab)
		#expect(store.state.webKitPages.sites.contains("open.spotify.com"))
		#expect(store.state.menu?.webKit?.isListed == false)
	}

	/// DEV-1188: listed Netflix in a Chromium tab says its video plays only in WebKit, and says
	/// nothing once taken off the list; Spotify says so only while the FairPlay helper can't keep it
	/// in Chromium.
	@Test
	internal func siteMenuSaysWhenASitesVideoPlaysOnlyInWebKit() async throws {
		var state = SiteMenuFeature.State()
		state.$webKitPages.withLock { $0 = .init() }
		state.context = .init(url: URL(string: "https://www.netflix.com/title/1")!, tabID: Self.tab, profileID: Self.profile)
		#expect(state.menu?.webKit == .init(isListed: true, isShown: false, playsVideoOnlyInWebKit: true))
		state.$webKitPages.withLock { _ = $0.remove(URL(string: "https://www.netflix.com")!) }
		#expect(state.menu?.webKit == .init(isListed: false, isShown: false, playsVideoOnlyInWebKit: false))

		state.context?.url = URL(string: "https://open.spotify.com/album/1")!
		#expect(state.menu?.webKit?.playsVideoOnlyInWebKit == true)
		state.fairPlayOrigins = ["https://open.spotify.com"]
		#expect(state.menu?.webKit?.playsVideoOnlyInWebKit == false)

		state.context?.url = URL(string: "https://www.video.example/watch")!
		#expect(state.menu?.webKit?.playsVideoOnlyInWebKit == false)
	}

	@Test
	internal func siteMenuOpenInWebKitEditsTheListAndMovesTheTab() async throws {
		let moves = LockIsolated<[PageEngine]>([])
		var state = SiteMenuFeature.State()
		state.$webKitPages.withLock { $0 = .init(sites: ["netflix.com"]) }
		state.context = .init(url: URL(string: "https://www.video.example/watch")!, tabID: Self.tab, profileID: Self.profile)
		#expect(state.menu?.webKit == .init(isListed: false, isShown: false))
		let store = TestStore(initialState: state) { SiteMenuFeature() } withDependencies: {
			$0.pageEngines.move = { _, engine, _ in
				moves.withValue { $0.append(engine) }
				return true
			}
		}
		store.exhaustivity = .off

		await store.send(.ui(.menu(.setWebKit(true))))
		await store.receive(\.event.engineChanged)
		#expect(store.state.webKitPages.sites == ["netflix.com", "video.example"])
		#expect(store.state.menu?.webKit == .init(isListed: true, isShown: true))

		await store.send(.ui(.menu(.setWebKit(false))))
		await store.receive(\.event.engineChanged)
		#expect(store.state.webKitPages.sites == ["netflix.com"])
		#expect(store.state.context?.usesWebKit == false)
		#expect(moves.value == [.webKit, .chromium])

		var plain = store.state
		plain.context?.url = URL(string: "http://plain.example")!
		#expect(plain.menu?.webKit == nil)
	}

	@Test
	internal func settingsEditsTheList() async throws {
		let state = SettingsFeature.State()
		state.$webKitPages.withLock { $0 = .init(sites: ["netflix.com"]) }
		let store = TestStore(initialState: state) { SettingsFeature() }
		store.exhaustivity = .off

		await store.send(.ui(.addWebKitSite("https://Video.example/watch")))
		await store.send(.ui(.addWebKitSite("not a site")))
		#expect(store.state.webKitPages.sites == ["netflix.com", "video.example"])
		await store.send(.ui(.editWebKitSite("video.example", "music.example")))
		#expect(store.state.webKitPages.sites == ["netflix.com", "music.example"])
		await store.send(.ui(.editWebKitSite("music.example", "netflix.com")))
		#expect(store.state.webKitPages.sites == ["netflix.com"])
		await store.send(.ui(.removeWebKitSite("netflix.com")))
		#expect(store.state.webKitPages.sites.isEmpty)
		await store.send(.ui(.restoreWebKitSites))
		#expect(store.state.webKitPages.sites == WebKitPagePreferences.defaultSites)
		await store.send(.ui(.webKitPagesEnabled(false)))
		#expect(!store.state.webKitPages.isEnabled)
	}
}
