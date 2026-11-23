@testable import AppFeature
import BrowserCore
import CustomDump
import Foundation
import Testing
import ViewerFeature
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// The link toast in split view (DEV-780): it shows in the pane whose link was copied, so it's
/// clear which tab it reports on. Outside split view it stays at the window's corner.
extension IntegrationFeatureTests {
	@Test
	internal func linkToastInSplitViewTargetsTheFocusedPane() async throws {
		let (state, panes) = splitState(focused: 1)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = { _ in true }
		}
		store.exhaustivity = .off

		await store.send(.ui(.copyLinks(.original)))
		await store.receive(\.event.linkActionFinished)
		let feedback = try #require(store.state.linkActionFeedback)
		expectNoDifference(feedback.windowID, state.main.id)
		expectNoDifference(feedback.paneID, panes[1].id)
		expectNoDifference(store.state.linkFeedbackTabID(feedback), panes[1].tabID)
		expectNoDifference(feedback.copiedURLs, [panes[1].url])
	}

	@Test
	internal func linkToastFollowsThePaneACommandCameFrom() async throws {
		let (state, panes) = splitState(focused: 1)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = { _ in true }
		}
		store.exhaustivity = .off

		// A command from the unfocused pane, such as its own menu, reports on that pane.
		await store.send(.ui(.command(.copyURL, .window(state.main.id, paneID: panes[0].id))))
		await store.receive(\.event.linkActionFinished)
		let feedback = try #require(store.state.linkActionFeedback)
		expectNoDifference(feedback.paneID, panes[0].id)
		expectNoDifference(store.state.linkFeedbackTabID(feedback), panes[0].tabID)
		expectNoDifference(feedback.copiedURLs, [panes[0].url])
	}

	@Test
	internal func linkToastPaneFallsBackToTheFocusedPane() {
		let (state, panes) = splitState(focused: 0)
		expectNoDifference(state.linkFeedbackPaneID(in: state.main.id, preferring: UUID(404)), panes[0].id)
		expectNoDifference(state.linkFeedbackPaneID(in: nil), panes[0].id)
		expectNoDifference(state.linkFeedbackPaneID(in: UUID(405)), nil)
	}

	@Test
	internal func sidebarCopyOfOneTabInSplitViewNamesItsPane() {
		let (state, panes) = splitState(focused: 1)
		let left = panes[0].tabID.rawValue
		expectNoDifference(state.linkSourcePaneID(in: state.main.id, tabIDs: [left]), panes[0].id)

		// Several tabs, or one not in a pane, leave it to the focused pane.
		expectNoDifference(state.linkSourcePaneID(in: state.main.id, tabIDs: [left, panes[1].tabID.rawValue]), nil)
		expectNoDifference(state.linkSourcePaneID(in: state.main.id, tabIDs: [UUID(406)]), nil)
	}

	@Test
	internal func linkToastOutsideSplitViewStaysAtTheWindowCorner() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = { _ in true }
		}
		store.exhaustivity = .off

		await store.send(.ui(.copyLinks(.original)))
		await store.receive(\.event.linkActionFinished)
		let feedback = try #require(store.state.linkActionFeedback)
		expectNoDifference(feedback.windowID, state.main.id)
		expectNoDifference(feedback.paneID, nil)
		expectNoDifference(store.state.linkFeedbackTabID(feedback), nil)
	}

	@Test
	internal func linkToastMovesToTheWindowCornerOnceTheSplitEnds() throws {
		var (state, panes) = splitState(focused: 1)
		let feedback: LinkActionFeedback = .init(
			windowID: state.main.id,
			paneID: panes[1].id,
			result: LinkTransformer.copy([.init(title: "", url: panes[1].url)], mode: .original),
			status: .copied
		)
		expectNoDifference(state.linkFeedbackTabID(feedback), panes[1].tabID)

		state.main.viewer.panes.remove(id: panes[1].id)
		state.main.viewer.activePaneID = panes[0].id
		expectNoDifference(state.linkFeedbackTabID(feedback), nil)
	}

	internal struct SplitPane {
		internal let id: UUID
		internal let tabID: BrowserCore.Tab.ID
		internal let url: URL
	}

	/// The main window split between the fixture's first two tabs.
	internal func splitState(focused: Int) -> (AppFeature.State, [SplitPane]) {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let urls = [URL(string: "https://left.example/")!, URL(string: "https://right.example/")!]
		var panes: [SplitPane] = []
		var viewerPanes: IdentifiedArrayOf<ViewerPaneFeature.State> = []
		for index in 0..<2 {
			let id = UUID(780 + index)
			let tab = organization.tabs[index]
			var item = ViewerItemFeature.State(tab: tab)
			item.navigation = .init(url: urls[index], title: "Pane \(index)")
			viewerPanes.append(.init(id: id, item: item))
			panes.append(.init(id: id, tabID: tab.id, url: urls[index]))
		}
		state.main.viewer.panes = viewerPanes
		state.main.viewer.activePaneID = panes[focused].id
		return (state, panes)
	}
}
