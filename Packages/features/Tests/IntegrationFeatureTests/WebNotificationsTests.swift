import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import LittleArxFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-885: a click on a site's notification shows that site's tab in its profile.
@Suite(.dependencies)
@MainActor
internal struct WebNotificationsTests {
	private static let mail = URL(string: "https://mail.example")!
	private static let mailTabID = BrowserCore.Tab.ID(rawValue: UUID(5))
	private static let openedTabID = BrowserCore.Tab.ID(rawValue: UUID(6))

	@Test
	internal func aClickTheSiteDidNotAnswerShowsItsTabInAnotherSpace() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.notificationClicked(click(origin: Self.mail))))
		await store.skipReceivedActions()

		expectNoDifference(store.state.main.sidebar.spaceID, state.workspace.spaces[1].id)
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, Self.mailTabID)
		expectNoDifference(store.state.mediaSourceFocusRequest, state.mediaSourceFocusRequest + 1)
	}

	@Test
	internal func aHandledClickLeavesTheSitesOwnChoice() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
		}

		await store.send(.event(.notificationClicked(click(origin: Self.mail, handled: true))))
	}

	@Test
	internal func aClickForAProfileArxDoesNotHaveDoesNothing() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
		}

		await store.send(.event(.notificationClicked(.init(
			profileID: .init(rawValue: UUID(404)),
			origin: Self.mail,
			isPersistent: true,
			isHandled: false,
			pageIsGone: false
		))))
	}

	@Test
	internal func aClickWhoseTabWasClosedOpensTheOriginInItsProfile() async throws {
		let state = fixture()
		let origin = URL(string: "https://chat.example")!
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.notificationClicked(click(origin: origin, pageIsGone: true))))
		await store.receive(\.ui.routeURLs)
		#expect(store.state.mediaSourceFocusRequest > state.mediaSourceFocusRequest)
	}

	@Test
	internal func withTheChoiceOffOnlyAPageGoneNotificationOpensItsSite() async throws {
		let state = fixture()
		state.settings.$general.withLock { $0.notificationsOpenClosedSites = false }
		let origin = URL(string: "https://chat.example")!
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// A service worker that answered nothing: nothing opens, as in Chrome.
		await store.send(.event(.notificationClicked(click(origin: origin))))
		expectNoDifference(store.state.mediaSourceFocusRequest, state.mediaSourceFocusRequest)

		// A page's notification that outlived it: Chrome opens the site, so Arx does too.
		await store.send(.event(.notificationClicked(click(origin: origin, pageIsGone: true))))
		await store.receive(\.ui.routeURLs)
	}

	@Test
	internal func theSelectedTabWinsOverANewerOneAtTheSameSite() async throws {
		var state = fixture()
		let site = URL(string: "https://capturecontext.dev")!
		#expect(state.main.sidebar.selectedTab?.id == state.workspace.tabs[0].id)
		let found = state.notificationTab(for: click(origin: site), currentURL: { _ in nil })
		expectNoDifference(found?.id, state.workspace.tabs[0].id)

		// Without a selected match, the newest tab of the site in the shown space.
		state.main.sidebar.select(Self.mailTabID)
		let newest = state.notificationTab(for: click(origin: site), currentURL: { _ in nil })
		expectNoDifference(newest?.id, state.workspace.tabs[1].id)
	}

	@Test
	internal func aLoadedTabsCurrentAddressDecidesItsSite() async throws {
		let state = fixture()
		let elsewhere = state.workspace.tabs[1].id
		let found = state.notificationTab(
			for: click(origin: URL(string: "https://news.example:8443")!),
			currentURL: { $0.id == elsewhere ? URL(string: "https://news.example:8443/today") : nil }
		)
		expectNoDifference(found?.id, elsewhere)

		// Another port is another site.
		let other = state.notificationTab(
			for: click(origin: URL(string: "https://news.example")!),
			currentURL: { $0.id == elsewhere ? URL(string: "https://news.example:8443/today") : nil }
		)
		#expect(other == nil)
	}

	@Test
	internal func aServiceWorkersWindowBecomesATabInTheShownSpace() async throws {
		let state = fixture()
		let opened = BrowserCore.Tab(
			id: Self.openedTabID,
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "", url: URL(string: "https://mail.example/inbox/42")!)
		)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { id in
				id == Self.openedTabID ? .init(navigation: .init(url: opened.restoration.url), revision: 1) : nil
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.notificationWindowOpened(opened)))
		await store.skipReceivedActions()

		#expect(store.state.workspace.tabs[id: Self.openedTabID] != nil)
		#expect(store.state.workspace.spaces[0].unpinnedTabs.last == Self.openedTabID)
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, Self.openedTabID)
		expectNoDifference(store.state.mediaSourceFocusRequest, state.mediaSourceFocusRequest + 1)
	}

	@Test
	internal func aWindowWithoutAnEnginePageIsRefused() async throws {
		let state = fixture()
		let opened = BrowserCore.Tab(
			id: Self.openedTabID,
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "", url: Self.mail)
		)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
		}

		await store.send(.event(.notificationWindowOpened(opened)))
	}

	@Test
	internal func aPagesActivationShowsItsTab() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.pageActivationRequested(Self.mailTabID)))
		await store.skipReceivedActions()

		expectNoDifference(store.state.main.sidebar.selectedTab?.id, Self.mailTabID)
		expectNoDifference(store.state.mediaSourceFocusRequest, state.mediaSourceFocusRequest + 1)
	}

	@Test
	internal func aLittleArxsActivationBringsItForward() async throws {
		var state = fixture()
		let page = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Chat", url: URL(string: "https://chat.example")!)
		)
		var little = LittleArxFeature.State(id: UUID(70), spaceID: state.workspace.spaces[0].id, tab: page)
		little.viewer.tab = page
		state.littleWindows.append(little)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.pageActivationRequested(page.id)))
		expectNoDifference(store.state.focusedWindowID, little.id)
		expectNoDifference(store.state.mediaSourceFocusRequest, state.mediaSourceFocusRequest + 1)
	}

	@Test
	internal func noActivationWhileQuitting() async throws {
		var state = fixture()
		state.checkingQuit = true
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
		}

		await store.send(.event(.pageActivationRequested(Self.mailTabID)))
		await store.send(.event(.notificationClicked(click(origin: Self.mail))))
	}

	// MARK: - Fixture

	private func click(
		origin: URL,
		handled: Bool = false,
		pageIsGone: Bool = false
	) -> BrowserNotificationClick {
		.init(
			profileID: .init(rawValue: UUID(0)),
			origin: origin,
			isPersistent: !pageIsGone,
			isHandled: handled,
			pageIsGone: pageIsGone
		)
	}

	/// Work shows two capturecontext.dev tabs; Personal has the mail tab.
	private func fixture() -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		let mail = BrowserCore.Tab(
			id: Self.mailTabID,
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Inbox", url: URL(string: "https://mail.example/inbox")!)
		)
		organization.tabs.append(mail)
		organization.spaces[1].unpinnedTabs = [mail.id]
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item.tab = organization.tabs[0]
		return state
	}
}
