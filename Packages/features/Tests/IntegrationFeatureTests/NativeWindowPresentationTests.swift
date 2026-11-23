import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

extension IntegrationFeatureTests {
	@Test
	internal func geometryIsPreservedWhenTheTabPresentationChanges() async throws {
		let organization = fixture()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies { $0.workspaceDocument = document } operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let geometry = BrowserWindowGeometry(
			frame: .init(x: 100, y: 200, width: 1000, height: 800),
			displayID: 42,
			isFullScreen: true
		)
		await store.send(.event(.windowGeometryChanged(state.main.id, geometry)))
		await store.send(.main(.delegate(.presentationChanged)))
		expectNoDifference(store.state.windowLayout.windowPresentations.first { $0.id == state.main.id }?.geometry, geometry)
	}

	@Test
	internal func geometrySavedBeforeTheFirstShowKeepsTheSelectedTabForTheNextLaunch() async throws {
		let organization = fixture()
		let selected = try #require(organization.spaces[0].selectedTabID)
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies { $0.workspaceDocument = document } operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		#expect(state.main.viewer.item.tab == nil)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let geometry = BrowserWindowGeometry(frame: .init(x: 100, y: 200, width: 1000, height: 800), displayID: 42)

		// A new window places itself before its view's task shows the selected tab.
		await store.send(.event(.windowGeometryChanged(state.main.id, geometry)))
		let saved = store.state.windowLayout.windowPresentations
		expectNoDifference(
			saved.first { $0.id == state.main.id }?.spaces.flatMap { $0.panes.map(\.tabID) },
			[selected]
		)

		let relaunched = withDependencies {
			$0.workspaceDocument = .unsaved(.init(windowPresentations: saved))
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		expectNoDifference(relaunched.main.viewer.item.tab?.id, selected)
		expectNoDifference(relaunched.main.sidebar.selectedTab?.id, selected)
	}

	@Test
	internal func privateWindowGeometryNeverReachesSavedWindowRecords() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let id = UUID(900)
		state.windows.append(.init(organization: organization, spaceID: organization.spaces[0].id, isPrivate: true, id: id))
		let store = TestStore(initialState: state) { AppFeature() }
		await store.send(.event(.windowGeometryChanged(id, .init(frame: .init(x: 100, y: 100, width: 900, height: 700)))))
		#expect(!store.state.windowLayout.windowPresentations.contains { $0.id == id })
	}

	@Test
	internal func closeWindowCommandClosesTheWindowAndKeepsItsTabs() async throws {
		let organization = fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.command(.closeWindow, .window(state.main.id))))
		await store.receive(\.ui.closeWindow)
		#expect(!store.state.windowIsOpen)
		expectNoDifference(store.state.workspace.tabs, organization.tabs)
	}

	@Test
	internal func dockSpaceActionCreatesAWindowInTheChosenSpace() async throws {
		let organization = fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let id = UUID(900)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: { $0.uuid = .constant(id) }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.newWindowInSpace(organization.spaces[1].id)))
		expectNoDifference(store.state.windows[id: id]?.sidebar.spaceID, organization.spaces[1].id)
		expectNoDifference(store.state.focusedWindowID, id)
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func copiedFindSelectionTargetsOnlyTheOriginalPage() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item = .init(tab: organization.tabs[0])
		let target = AppFeature.CommandTarget.window(state.main.id, paneID: state.main.viewer.activePaneID)
		let captured = try #require(state.findSelectionItem(in: target))
		let action = try #require(state.findSelectionAction("selected words", in: target, from: captured))
		let store = Store(initialState: state) { AppFeature() }
		await store.send(action).finish()
		#expect(store.main.viewer.item.findQuery == nil)
		expectNoDifference(store.main.viewer.item.findSeed, "selected words")
		#expect(state.findSelectionItem(in: .settings) == nil)
		#expect(state.findSelectionItem(in: .downloads) == nil)
		state.main.viewer.item.findQuery = ""
		#expect(state.findSelectionAction("late words", in: target, from: captured) == nil)
		state.main.viewer.item.findQuery = captured.findQuery
		state.main.viewer.item.generation += 1
		#expect(state.findSelectionAction("late words", in: target, from: captured) == nil)
	}
}
