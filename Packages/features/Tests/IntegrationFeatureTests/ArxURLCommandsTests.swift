import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-929: `arx://` addresses and Shortcuts actions.
@Suite(.dependencies)
@MainActor
internal struct ArxURLCommandsTests {
	private static let page = URL(string: "https://example.com/inbox")!

	@Test
	internal func openInANamedSpaceGoesToThatSpace() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.arxURLCommand(.open(Self.page, space: "personal", profile: nil))))
		await store.receive(\.ui.openURLInSpace)
	}

	@Test
	internal func openInAProfileRoutesThere() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.arxURLCommand(.open(Self.page, space: nil, profile: "Default"))))
		await store.receive(\.ui.routeURLs)
	}

	@Test
	internal func anUnknownSpaceOrProfileDoesNothing() async throws {
		let store = TestStore(initialState: fixture()) { AppFeature() }

		await store.send(.ui(.arxURLCommand(.open(Self.page, space: "Nowhere", profile: nil))))
		await store.send(.ui(.arxURLCommand(.open(Self.page, space: nil, profile: "Nobody"))))
		await store.send(.ui(.arxURLCommand(.littleArx(nil, space: "Nowhere"))))
		await store.send(.ui(.arxURLCommand(.switchSpace("Nowhere"))))
	}

	@Test
	internal func switchSpaceShowsItInTheMainWindow() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.arxURLCommand(.switchSpace("Personal"))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.main.sidebar.spaceID, state.workspace.spaces[1].id)
		expectNoDifference(store.state.focusedWindowID, state.main.id)
	}

	@Test
	internal func littleArxOpensInTheNamedSpace() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.arxURLCommand(.littleArx(Self.page, space: "Work"))))
		await store.receive(\.ui.openLittleArx)
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		return state
	}
}

/// DEV-929: a page's `arx://` link asks first.
@Suite(.dependencies)
@MainActor
internal struct ArxLinkConfirmationTests {
	@Test
	internal func aPagesLinkWaitsForConfirmation() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		let current = LockIsolated(true)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(url: URL(string: "https://page.example")!), revision: 1, documentRevision: 1) }
			$0.browserEngine.externalLinkIsCurrent = { _, _ in current.value }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.arxLinkFromPage(link("arx://open?url=https%3A%2F%2Fexample.com&space=Personal", from: organization.tabs[0]))))
		let confirmation = try #require(store.state.arxLinkConfirmation)
		expectNoDifference(confirmation.command, .open(URL(string: "https://example.com")!, space: "Personal", profile: nil))
		expectNoDifference(confirmation.source, "https://page.example")
		expectNoDifference(confirmation.windowID, state.main.id)

		// Cancel drops it; nothing opens.
		await store.send(.ui(.cancelArxLink(confirmation.id)))
		#expect(store.state.arxLinkConfirmation == nil)

		// A page that navigated away before the answer opens nothing.
		await store.send(.event(.arxLinkFromPage(link("arx://little", from: organization.tabs[0]))))
		let stale = try #require(store.state.arxLinkConfirmation)
		current.setValue(false)
		await store.send(.ui(.confirmArxLink(stale.id)))
		#expect(store.state.arxLinkConfirmation == nil)
		current.setValue(true)

		await store.send(.event(.arxLinkFromPage(link("arx://space?name=Personal", from: organization.tabs[0]))))
		let second = try #require(store.state.arxLinkConfirmation)

		// A newer link replaces it: the old answer opens nothing, the new one does.
		await store.send(.event(.arxLinkFromPage(link("arx://space?name=Work", from: organization.tabs[0]))))
		let newer = try #require(store.state.arxLinkConfirmation)
		#expect(newer.id != second.id)
		await store.send(.ui(.confirmArxLink(second.id)))
		expectNoDifference(store.state.arxLinkConfirmation?.id, newer.id)
		await store.send(.ui(.confirmArxLink(newer.id)))
		await store.receive(\.ui.arxURLCommand)
	}

	@Test
	internal func privatePagesAndArxsOwnPagesAreDropped() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}

		await store.send(.event(.arxLinkFromPage(link("arx://chat", from: organization.tabs[0]))))
		await store.send(.event(.arxLinkFromPage(link("arx://little", from: organization.tabs[0], isPrivate: true))))
	}

	private func link(
		_ text: String,
		from tab: BrowserCore.Tab,
		isPrivate: Bool = false
	) -> BrowserExternalLink {
		.init(
			sourceTabID: tab.id,
			profileID: tab.profileID,
			isPrivate: isPrivate,
			sourceDocumentRevision: 1,
			sourceToken: 1,
			link: text,
			sourceOrigin: "https://page.example",
			hasUserGesture: true,
			isRedirect: false
		)
	}
}
