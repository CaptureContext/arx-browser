import BrowserCore
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct OrdinaryTabPresentationTests {
	@Test(arguments: [false, true])
	internal func favoriteWithoutAProfileSpaceCannotChangePresentation(mounted: Bool) async throws {
		var (state, favorite, spaceID) = favoriteFixture()
		state.workspace = try state.workspace.applying(.removeSpace(spaceID), uuid: UUID.init)
		state.main.sidebar.organization = state.workspace
		state.focusedWindowID = UUID(99)
		if mounted { state.main.viewer.item = .init(tab: favorite, generation: 7) }
		try state.workspace.validate()
		#expect(state.workspace.tabs.ids.contains(favorite.id))
		#expect(!OrdinaryTabPresentation().canFocus(favorite, state: state))
		let store = TestStore(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if case .ui(.openWindow) = action {
					return OrdinaryTabPresentation().focus(favorite, state: &state)
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.open = { _ in Issue.record("An unavailable Favorite must not open in another profile") }
			$0.browserEngine.close = { _ in Issue.record("An unavailable Favorite must preserve existing sessions") }
			$0.browserSurface.focus = { _ in Issue.record("An unavailable Favorite must not take native focus") }
		}
		await store.send(.ui(.openWindow))
		await store.finish()
	}

	@Test
	internal func favoriteWithAProfileSpaceRestoresThatSpace() async throws {
		let (state, favorite, spaceID) = favoriteFixture()
		#expect(OrdinaryTabPresentation().canFocus(favorite, state: state))
		var opened: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if case .ui(.openWindow) = action {
					return OrdinaryTabPresentation().focus(favorite, state: &state)
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.close = { _ in Issue.record("Presentation must preserve existing sessions") }
		}
		await store.send(.ui(.openWindow)).finish()
		expectNoDifference(store.main.sidebar.spaceID, spaceID)
		expectNoDifference(store.main.sidebar.selectedTab?.id, favorite.id)
		expectNoDifference(store.main.viewer.item.tab?.id, favorite.id)
		expectNoDifference(store.main.viewer.item.tab?.profileID, favorite.profileID)
		expectNoDifference(opened, [favorite.id])
		try store.main.sidebar.organization.validate()
	}

	@Test(arguments: ["main", "split", "window", "little", "peek"], ["url", "entry", "loading", "error"])
	internal func navigationInAnyHostInvalidatesDeferredPresentation(
		host: String,
		change: String
	) async {
		let state = fixture()
		let context = TabPresentationContext(state)
		var navigation = state.main.viewer.item.navigation
		switch change {
		case "url":
			navigation.url = URL(string: "https://capturecontext.dev/next")!
		case "entry":
			navigation.history = [.init(id: 12, url: navigation.url!, title: "Same URL, new document", isCurrent: true)]
		case "loading":
			navigation.isLoading = true
		default:
			navigation.errorCode = -105
		}
		let action = navigationAction(navigation, host: host, state: state)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in Issue.record("A stale resume must not reopen panes after navigation") }
		}
		await store.send(action).finish()
		let viewer = store.main.viewer
		let focus = store.focusedWindowID
		await store.send(.resumeTabPresentation(context)).finish()
		expectNoDifference(store.main.viewer, viewer)
		expectNoDifference(store.focusedWindowID, focus)
	}

	@Test(
		arguments: [
			"closing",
			"replacing",
			"promoting",
			"releasing",
			"replacement",
			"hostClosing",
			"orphan",
			"pendingTransition",
		]
	)
	internal func peekTransitionInvalidatesDeferredPresentation(change: String) async {
		var state = fixture()
		let context = TabPresentationContext(state)
		switch change {
		case "closing": state.peeks[0].phase = .closing
		case "replacing": state.peeks[0].phase = .replacing
		case "promoting": state.peeks[0].phase = .promoting
		case "releasing": state.peeks[0].phase = .releasing
		case "replacement": state.peeks[0].replacementURL = URL(string: "https://capturecontext.dev/next")!
		case "hostClosing": state.closingPeekHosts.insert(state.peeks[0].source.windowID)
		case "orphan": state.peeks[0].orphanCloseRequested = true
		default: state.peekTransitions[state.peeks[0].id] = .dismiss
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in Issue.record("A stale resume must not compete with a Peek transition") }
		}
		await store.send(.resumeTabPresentation(context))
		await store.finish()
	}

	@Test
	internal func cosmeticTitleChangesDoNotInvalidatePresentationIdentity() {
		var state = fixture()
		let context = TabPresentationContext(state)
		for index in state.main.viewer.panes.indices {
			state.main.viewer.panes[index].item.navigation.title = "Updated title"
			state.main.viewer.panes[index].item.navigation.history[0].title = "Updated history title"
		}
		state.windows[0].viewer.item.navigation.title = "Updated title"
		state.windows[0].viewer.item.navigation.history[0].title = "Updated history title"
		state.littleWindows[0].viewer.navigation.title = "Updated title"
		state.littleWindows[0].viewer.navigation.history[0].title = "Updated history title"
		state.peeks[0].viewer.navigation.title = "Updated title"
		state.peeks[0].viewer.navigation.history[0].title = "Updated history title"
		expectNoDifference(TabPresentationContext(state), context)
	}

	@Test
	internal func nativeActivationInvalidatesIntentButStillAttachesAnAlreadyCommittedLayout() async {
		var state = fixture()
		state.windows = []
		state.littleWindows = []
		state.peeks = []
		let context = TabPresentationContext(state)
		state.windowActivationRevision += 1
		#expect(TabPresentationContext(state) != context)
		let paneIDs = state.main.viewer.panes.map(\.id)
		let tabIDs = state.main.viewer.panes.compactMap { $0.item.tab?.id }
		var opened: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserSurface.focus = { _ in Issue.record("Resuming a committed layout must not request focus") }
		}
		await store.send(.resumeTabPresentation(context)).finish()
		expectNoDifference(Set(opened), Set(tabIDs))
		expectNoDifference(store.main.viewer.panes.map(\.id), paneIDs)
		expectNoDifference(store.focusedWindowID, state.focusedWindowID)
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let navigation = BrowserNavigation(
			url: organization.tabs[0].restoration.url,
			title: "Original",
			history: [.init(id: 11, url: organization.tabs[0].restoration.url, title: "Original", isCurrent: true)]
		)
		state.main.viewer.item = .init(tab: organization.tabs[0], navigation: navigation, generation: 3)
		state.main.viewer.panes.append(
			.init(id: UUID(71), item: .init(tab: organization.tabs[1], navigation: navigation, generation: 4))
		)
		var window = MainFeature.State(organization: organization, spaceID: organization.spaces[1].id, id: UUID(72))
		let windowTab = BrowserCore.Tab(
			id: .init(rawValue: UUID(73)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Window", url: navigation.url!)
		)
		state.workspace.tabs.append(windowTab)
		state.workspace.spaces[1].unpinnedTabs.append(windowTab.id)
		state.main.sidebar.organization = state.workspace
		window.sidebar.organization = state.workspace
		window.viewer.item = .init(tab: windowTab, navigation: navigation, generation: 5)
		state.windows.append(window)
		let littleTab = BrowserCore.Tab(
			id: .init(rawValue: UUID(75)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Little", url: navigation.url!)
		)
		state.littleWindows.append(.init(id: UUID(74), spaceID: organization.spaces[0].id, tab: littleTab))
		state.littleWindows[0].viewer = .init(tab: littleTab, navigation: navigation, generation: 6)
		let peekTab = BrowserCore.Tab(
			id: .init(rawValue: UUID(77)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Peek", url: navigation.url!)
		)
		state.peeks.append(
			.init(
				id: UUID(76),
				source: .init(
					windowID: state.main.id,
					paneID: state.main.viewer.activePaneID,
					tabID: organization.tabs[0].id,
					spaceID: organization.spaces[0].id,
					profileID: peekTab.profileID,
					identity: "Fixture"
				),
				tab: peekTab,
				isTemporary: true
			)
		)
		state.peeks[0].viewer = .init(tab: peekTab, navigation: navigation, generation: 7)
		return state
	}

	private func favoriteFixture() -> (AppFeature.State, BrowserCore.Tab, Space.ID) {
		var organization = IntegrationFeatureTests().fixture()
		let profileID = Profile.ID(rawValue: UUID(80))
		let spaceID = Space.ID(rawValue: UUID(81))
		let favorite = BrowserCore.Tab(
			id: .init(rawValue: UUID(82)),
			profileID: profileID,
			savedDestination: .init(title: "Favorite", url: URL(string: "https://capturecontext.dev/favorite")!),
			restoration: .init(title: "Favorite", url: URL(string: "https://capturecontext.dev/favorite")!)
		)
		organization.profiles.append(.init(id: profileID, name: "Other profile", favorites: [favorite.id]))
		organization.spaces.append(.init(id: spaceID, profileID: profileID, name: "Other Space"))
		organization.tabs.append(favorite)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item = .init(tab: organization.tabs[0], generation: 3)
		return (state, favorite, spaceID)
	}

	private func navigationAction(
		_ navigation: BrowserNavigation,
		host: String,
		state: AppFeature.State
	) -> AppFeature.Action {
		switch host {
		case "window":
			let window = state.windows[0]
			let generation = window.viewer.item.generation
			return .windows(
				.element(
					id: window.id,
					action: .viewer(
						.panes(
							.element(
								id: window.viewer.activePaneID,
								action: .item(.event(.navigation(window.viewer.item.tab!.id, generation, navigation)))
							)
						)
					)
				)
			)

		case "little":
			let window = state.littleWindows[0]
			return .littleWindows(
				.element(
					id: window.id,
					action: .viewer(.event(.navigation(window.tab.id, window.viewer.generation, navigation)))
				)
			)

		case "peek":
			let peek = state.peeks[0]
			return .peeks(
				.element(
					id: peek.id,
					action: .viewer(.event(.navigation(peek.tab.id, peek.viewer.generation, navigation)))
				)
			)

		default:
			let pane = host == "split" ? state.main.viewer.panes[1] : state.main.viewer.panes[0]
			return .main(
				.viewer(
					.panes(
						.element(
							id: pane.id,
							action: .item(.event(.navigation(pane.item.tab!.id, pane.item.generation, navigation)))
						)
					)
				)
			)
		}
	}
}
