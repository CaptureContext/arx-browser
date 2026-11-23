import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-949: a page's HTML full screen fills the window showing it, and ends when the page
/// stops showing there.
@Suite(.dependencies)
@MainActor
internal struct PageFullScreenTests {
	@Test
	internal func aShownPageFillsItsWindowAndLeavesWhenItSaysSo() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[0].id
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.event(.pageFullScreenChanged(tab, true))) {
			$0.pageFullScreen = .init(tabID: tab, windowID: state.main.id)
		}
		await store.send(.event(.pageFullScreenChanged(tab, false))) {
			$0.pageFullScreen = nil
		}
		await store.finish()
		expectNoDifference(exits.value, [])
	}

	@Test
	internal func aHiddenPageNeverTakesTheScreen() async throws {
		let state = fixture()
		let hidden = state.workspace.tabs[1].id
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.event(.pageFullScreenChanged(hidden, true)))
		await store.finish()
		#expect(store.state.pageFullScreen == nil)
		expectNoDifference(exits.value, [hidden])
	}

	/// A headless run has no screen to fill: the page's request goes straight back out.
	@Test
	internal func aHeadlessRunRefusesIt() async throws {
		var state = fixture()
		state.automation.isUnattended = true
		let tab = state.workspace.tabs[0].id
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.event(.pageFullScreenChanged(tab, true)))
		await store.finish()
		#expect(store.state.pageFullScreen == nil)
		expectNoDifference(exits.value, [tab])
	}

	@Test
	internal func anotherTabInTheWindowEndsIt() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.pageFullScreen = .init(tabID: tab, windowID: state.main.id)
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(state.workspace.tabs[1].id.rawValue)))))))
		await store.skipReceivedActions()
		await store.finish()
		#expect(store.state.pageFullScreen == nil)
		expectNoDifference(exits.value, [tab])
	}

	/// The window's own controls would sit under the page, so they take it out of full screen.
	@Test
	internal func theCommandBarAndFindBarEndIt() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		#expect(state.pageFullScreenWindow(showing: tab) == state.main.id)

		state.main.commandBar.isPresented = true
		#expect(state.pageFullScreenWindow(showing: tab) == nil)

		state.main.commandBar.isPresented = false
		state.main.viewer.item.findQuery = ""
		#expect(state.pageFullScreenWindow(showing: tab) == nil)

		// DEV-991: the Library, opened from the sidebar beside the page, is wider than it.
		state.main.viewer.item.findQuery = nil
		state.main.isLibraryOpen = true
		#expect(state.pageFullScreenWindow(showing: tab) == nil)
	}

	/// Commands that bring up the window's own interface leave first; page-only ones don't.
	@Test
	internal func browserCommandsLeaveUnlessTheyActOnThePage() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.pageFullScreen = .init(tabID: tab, windowID: state.main.id)
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.ui(.command(.zoomIn, .window(state.main.id))))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.pageFullScreen != nil)

		await store.send(.ui(.command(.captureRegion, .window(state.main.id))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.pageFullScreen == nil)
		expectNoDifference(exits.value, [tab])
	}

	/// DEV-991: ⌘S in the page's window shows the sidebar beside it and hides it again; the page
	/// stays in full screen, and the window's own sidebar setting doesn't change.
	@Test
	internal func toggleSidebarShowsTheSidebarBesideThePage() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.pageFullScreen = .init(tabID: tab, windowID: state.main.id)
		let sidebarIsVisible = state.main.sidebar.sidebarIsVisible
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.ui(.command(.toggleSidebar, .window(state.main.id))))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.pageFullScreen, .init(tabID: tab, windowID: state.main.id, showsSidebar: true))
		#expect(store.state.main.sidebar.sidebarIsVisible == sidebarIsVisible)

		await store.send(.ui(.command(.toggleSidebar, .window(state.main.id))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		expectNoDifference(store.state.pageFullScreen, .init(tabID: tab, windowID: state.main.id, showsSidebar: false))
		#expect(store.state.main.sidebar.sidebarIsVisible == sidebarIsVisible)
		expectNoDifference(exits.value, [])
	}

	/// ⌘S in another window, or over a Peek's page, which has no sidebar of its own, still leaves.
	@Test(arguments: [false, true])
	internal func toggleSidebarElsewhereLeaves(peek: Bool) async throws {
		var state = fixture()
		var tab = state.workspace.tabs[0]
		var window = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: UUID(90)
		)
		window.viewer.item.tab = state.workspace.tabs[1]
		state.windows.append(window)
		if peek {
			tab = BrowserCore.Tab(
				id: .init(rawValue: UUID(80)),
				profileID: state.workspace.profiles[0].id,
				restoration: .init(title: "Preview", url: URL(string: "https://preview.example")!)
			)
			var preview = PeekFeature.State(
				id: UUID(81),
				source: .init(
					windowID: state.main.id,
					paneID: state.main.viewer.activePaneID,
					tabID: state.main.viewer.item.tab?.id,
					spaceID: state.main.sidebar.spaceID,
					profileID: tab.profileID,
					identity: "Default · Work"
				),
				tab: tab,
				isTemporary: true
			)
			preview.viewer.tab = tab
			state.peeks.append(preview)
		}
		state.pageFullScreen = .init(tabID: tab.id, windowID: state.main.id)
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.ui(.command(.toggleSidebar, .window(peek ? state.main.id : window.id))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.pageFullScreen == nil)
		expectNoDifference(exits.value, [tab.id])
	}

	@Test
	internal func leavingMacOSFullScreenTakesThePageOut() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.pageFullScreen = .init(tabID: tab, windowID: state.main.id)
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.ui(.exitPageFullScreen)) {
			$0.pageFullScreen = nil
		}
		await store.finish()
		expectNoDifference(exits.value, [tab])
	}

	@Test
	internal func onePageFillsTheScreenAtATime() async throws {
		var state = fixture()
		let first = state.workspace.tabs[0].id
		let second = state.workspace.tabs[1].id
		var window = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: UUID(90)
		)
		window.viewer.item.tab = state.workspace.tabs[1]
		state.windows.append(window)
		let exits = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, exits: exits)

		await store.send(.event(.pageFullScreenChanged(first, true))) {
			$0.pageFullScreen = .init(tabID: first, windowID: state.main.id)
		}
		await store.send(.event(.pageFullScreenChanged(second, true))) {
			$0.pageFullScreen = .init(tabID: second, windowID: window.id)
		}
		await store.finish()
		expectNoDifference(exits.value, [first])

		// The first page's late report doesn't end the second's.
		await store.send(.event(.pageFullScreenChanged(first, false)))
		expectNoDifference(store.state.pageFullScreen, .init(tabID: second, windowID: window.id))
	}

	@Test
	internal func aPeekFillsTheWindowItCameFrom() async throws {
		var state = fixture()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Preview", url: URL(string: "https://preview.example")!)
		)
		var peek = PeekFeature.State(
			id: UUID(81),
			source: .init(
				windowID: state.main.id,
				paneID: state.main.viewer.activePaneID,
				tabID: state.main.viewer.item.tab?.id,
				spaceID: state.main.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Default · Work"
			),
			tab: tab,
			isTemporary: true
		)
		peek.viewer.tab = tab
		state.peeks.append(peek)
		#expect(state.pageFullScreenWindow(showing: tab.id) == state.main.id)

		// A Peek on its way out no longer shows it.
		state.peeks[id: peek.id]?.phase = .closing
		#expect(state.pageFullScreenWindow(showing: tab.id) == nil)
	}

	@Test
	internal func aLittleArxPageFillsItsOwnWindow() async throws {
		var state = fixture()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(82)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Call", url: URL(string: "https://meet.example")!)
		)
		var little = LittleArxFeature.State(
			id: UUID(83),
			spaceID: state.workspace.spaces[0].id,
			tab: tab
		)
		little.viewer.tab = tab
		state.littleWindows.append(little)
		#expect(state.pageFullScreenWindow(showing: tab.id) == little.id)

		state.littleWindows[id: little.id]?.isClosing = true
		#expect(state.pageFullScreenWindow(showing: tab.id) == nil)
	}

	// MARK: - Fixture

	/// The main window showing the first of two tabs in its space.
	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item.tab = organization.tabs[0]
		return state
	}

	private func makeStore(
		_ state: AppFeature.State,
		exits: LockIsolated<[BrowserCore.Tab.ID]>
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserEngine.command = { id, command in
				if command == .exitFullScreen { exits.withValue { $0.append(id) } }
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
