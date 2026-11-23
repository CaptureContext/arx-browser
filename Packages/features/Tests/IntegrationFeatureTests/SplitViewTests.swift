import AppFeature
import BrowserCore
import BrowserEngineClient
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct SplitViewTests {
	@Test
	internal func delayedNavigationStaysWithOriginatingPaneAfterFocusChanges() async throws {
		let tabs = IntegrationFeatureTests().fixture().tabs
		let stream = AsyncStream<BrowserNavigation>.makeStream()
		var initial = ViewerFeature.State()
		let firstID = initial.activePaneID
		let secondID = UUID(20)
		initial.panes.append(.init(id: secondID, item: .init(tab: tabs[1])))
		let store = TestStore(initialState: initial) { ViewerFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in stream.stream }
		}
		await store.send(.item(.show(tabs[0]))) {
			$0.panes[id: firstID]?.item.tab = tabs[0]
			$0.panes[id: firstID]?.item.navigation = .init(url: tabs[0].restoration.url, title: tabs[0].restoration.title)
			$0.panes[id: firstID]?.item.generation = 1
			$0.panes[id: firstID]?.item.isObserving = true
			$0.observationGeneration = 1
		}
		await store.send(.ui(.focus(secondID))) { $0.activePaneID = secondID }
		let navigation = BrowserNavigation(url: URL(string: "https://delayed.example"), title: "Delayed")
		stream.continuation.yield(navigation)
		await store.receive(\.panes) { $0.panes[id: firstID]?.item.navigation = navigation }
		await store.receive(\.panes)
		expectNoDifference(store.state.panes[id: secondID]?.item.navigation, .init())
		expectNoDifference(store.state.activePaneID, secondID)
		await store.send(.ui(.closePane(firstID))) { $0.panes.remove(id: firstID) }
		stream.continuation.yield(.init(title: "After removal"))
		await store.finish()
	}

	@Test
	internal func closingPaneKeepsSessionAndRejectsDelayedActions() async throws {
		let tabs = IntegrationFeatureTests().fixture().tabs
		var initial = ViewerFeature.State(item: .init(tab: tabs[0]))
		let firstID = initial.activePaneID
		let secondID = UUID(20)
		initial.panes.append(.init(id: secondID, item: .init(tab: tabs[1])))
		initial.activePaneID = secondID
		let store = TestStore(initialState: initial) { ViewerFeature() }
		await store.send(.ui(.closePane(secondID))) {
			$0.panes.remove(id: secondID)
			$0.activePaneID = firstID
		}

		// No engine.close dependency is supplied: placement removal must never close a session.
		await store.send(.command(.reload, in: secondID, tabID: tabs[1].id))
		await store.send(.panes(.element(
			id: secondID,
			action: .item(.event(.failed(tabs[1].id, 0, "late")))
		)))
		expectNoDifference(store.state.item.tab?.id, tabs[0].id)
		await store.finish()
	}

	@Test
	internal func existingTabFocusesItsPaneAndOccupiedPaneIsNotReplaced() async throws {
		let tabs = IntegrationFeatureTests().fixture().tabs
		var initial = ViewerFeature.State(item: .init(tab: tabs[0]))
		let firstID = initial.activePaneID
		let secondID = UUID(20)
		initial.panes.append(.init(id: secondID, item: .init(tab: tabs[1])))
		let store = TestStore(initialState: initial) { ViewerFeature() } withDependencies: {
			$0.uuid = .constant(UUID(21))
		}
		await store.send(.show(tabs[1], in: firstID)) { $0.activePaneID = secondID }
		await store.send(.ui(.swapPanes)) { $0.panes.swapAt(0, 1) }
		await store.send(.ui(.toggleOrientation)) { $0.orientation = .vertical }
		await store.send(.ui(.resize([0.8, 0.2]))) { $0.fractions = [0.8, 0.2] }
		await store.send(.ui(.resize([.nan, 1])))
		await store.send(.ui(.resize([0.5, 0.25, 0.25])))

		// A split takes new empty panes up to four, without replacing an occupied one.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.split(nil))
		expectNoDifference(store.state.panes.map { $0.item.tab?.id }, [tabs[1].id, tabs[0].id, nil])
		expectNoDifference(store.state.fractions, SplitLayout.equal(3))
		expectNoDifference(store.state.activePaneID, UUID(21))

		// Turning is refused when the other axis has no room for every pane.
		await store.send(.ui(.capacityChanged(.init(horizontal: 2, vertical: 4))))
		await store.send(.ui(.toggleOrientation))
		expectNoDifference(store.state.orientation, .vertical)
		await store.send(.ui(.capacityChanged(.init(horizontal: 3, vertical: 2))))
		#expect(!store.state.canAddPane)
		await store.finish()
	}

	@Test
	internal func queuedCommandDoesNotNavigateAReplacementTab() async throws {
		let tabs = IntegrationFeatureTests().fixture().tabs
		let initial = ViewerFeature.State(item: .init(tab: tabs[1]))
		let store = TestStore(initialState: initial) { ViewerFeature() }
		await store.send(.command(.reload, in: initial.activePaneID, tabID: tabs[0].id))
		await store.finish()
	}

	@Test
	internal func deletingActiveTabLeavesOtherPaneMounted() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let removed = organization.tabs[0]
		let kept = organization.tabs[1]
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item.tab = removed
		let firstID = initial.viewer.activePaneID
		let secondID = UUID(20)
		initial.viewer.panes.append(.init(id: secondID, item: .init(tab: kept)))
		organization.tabs.removeAll { $0.id == removed.id }
		organization.spaces[0].unpinnedTabs.removeAll { $0 == removed.id }
		organization.spaces[0].selectedTabID = nil
		let store = TestStore(initialState: initial) { MainFeature() }
		await store.send(.reconcile(organization)) {
			$0.sidebar.organization = organization
			$0.knownTabIDs.remove(removed.id)

			// The closed tab leaves the window's recent tabs (DEV-544).
			$0.recentTabs = []
		}
		await store.receive(\.viewer.ui.closePane) {
			$0.viewer.panes.remove(id: firstID)
			$0.viewer.activePaneID = secondID
			$0.sidebar.select(kept.id)
			$0.recentTabs = [.init(tabID: kept.id, spaceID: organization.spaces[0].id)]

			// The closed tab isn't one to go back to (DEV-1228).
			$0.lastShownRecentTab = .init(tabID: kept.id, spaceID: organization.spaces[0].id)
		}
		await store.receive(\.viewer.ui.focus)
		expectNoDifference(store.state.viewer.item.tab?.id, kept.id)
		await store.finish()
	}

	@Test
	internal func rendererFailureIsLocalToItsPane() async throws {
		let tabs = IntegrationFeatureTests().fixture().tabs
		var initial = ViewerFeature.State(item: .init(tab: tabs[0]))
		let firstID = initial.activePaneID
		let secondID = UUID(20)
		initial.panes.append(.init(id: secondID, item: .init(tab: tabs[1])))
		initial.activePaneID = secondID
		let store = TestStore(initialState: initial) { ViewerFeature() }
		await store.send(.panes(.element(
			id: firstID,
			action: .item(.event(.failed(tabs[0].id, 0, "Renderer stopped")))
		))) {
			$0.panes[id: firstID]?.item.failure = "Renderer stopped"
		}
		#expect(store.state.item.failure == nil)
		await store.finish()
	}

	@Test
	internal func commandBarKeepsOriginAndRemovedPaneCommandsAreNoOps() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item = .init(tab: organization.tabs[0], navigation: .init(url: URL(string: "https://origin.example")))
		let firstID = initial.viewer.activePaneID
		let secondID = UUID(20)
		initial.viewer.panes.append(.init(id: secondID, item: .init(tab: organization.tabs[1])))
		let store = TestStore(initialState: initial) { MainFeature() }
		await store.send(.ui(.openCommand(.currentTab))) {
			$0.commandBarPaneID = firstID
			$0.commandBarContext = .init(window: initial, paneID: firstID, mode: .currentTab)
			$0.commandBar.suggestsRemotely = true
			$0.commandBar.isChatAvailable = true

			// History's page-text search runs in the window's profile (DEV-1068).
			$0.commandBar.pageTextProfileID = initial.sidebar.space.profileID

			// Bang rows read their site's stored icon in the window's profile (DEV-1311).
			$0.commandBar.bangIconProfileID = initial.sidebar.space.profileID

			// No history has loaded, so there's nothing to delete from it (DEV-810).
			$0.commandBar.actionAvailability.removesHistory = false
			$0.commandBar.reservedShortcuts = Set(BrowserCommand.allCases.filter { $0 != .copyURL }.compactMap {
				initial.keyboardShortcuts.shortcut(for: $0)?.display
			})
		}
		await store.receive(\.commandBar.present) {
			$0.commandBar.isPresented = true
			$0.commandBar.mode = .currentTab
			$0.commandBar.query = "https://origin.example"
			$0.commandBar.candidates = initial.commandCandidates
			$0.commandBar.prefilledQuery = "https://origin.example"
			$0.commandBar.focusRequest = 1
			$0.commandBar.selectedID = initial.commandCandidates.first?.presentation.id
		}
		await store.send(.viewer(.ui(.focus(secondID)))) {
			$0.viewer.activePaneID = secondID
			$0.sidebar.select(organization.tabs[1].id)
			$0.recentTabs.insert(.init(tabID: organization.tabs[1].id, spaceID: organization.spaces[0].id), at: 0)

			// The tab shown before, one back (DEV-1228).
			$0.previousRecentTab = initial.recentTabs.first
			$0.lastShownRecentTab = .init(tabID: organization.tabs[1].id, spaceID: organization.spaces[0].id)
		}
		let entry = try #require(initial.commandCandidates.first { $0.intent == .command(.copyURL) })
		let execution = CommandBarFeature.Execution(
			entry: entry,
			mode: .currentTab,
			presentationID: store.state.commandBar.focusRequest
		)
		await store.send(.commandBar(.delegate(.execute(execution)))) { $0.commandBarContext = nil }
		await store.receive(\.delegate.commandFromPane)
		await store.send(.ui(.paneCommand(.copyURL, firstID)))
		await store.receive(\.delegate.copyURL)
		await store.send(.viewer(.ui(.closePane(firstID)))) { $0.viewer.panes.remove(id: firstID) }
		await store.send(.ui(.paneCommand(.reload, firstID)))
		await store.send(.commandBar(.delegate(.execute(execution))))
		await store.finish()
	}

	@Test
	internal func splitRequestFocusesExistingOwnerInAnotherWindow() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.main.viewer.item.tab = organization.tabs[1]
		initial.main.sidebar.select(organization.tabs[1].id)
		initial.main.recordRecentTab()
		let otherID = UUID(20)
		var other = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, id: otherID)
		other.viewer.item.tab = organization.tabs[0]
		initial.windows.append(other)
		let store = TestStore(initialState: initial) { AppFeature() }
		await store.send(.main(.ui(.splitTab(organization.tabs[0].id))))
		await store.receive(\.main.delegate.requestSplit) { $0.focusedWindowID = otherID }
		await store.receive(\.windows)
		expectNoDifference(store.state.main.viewer.panes.count, 1)
		expectNoDifference(store.state.windows[id: otherID]?.viewer.item.tab?.id, organization.tabs[0].id)
		await store.finish()
	}
}
