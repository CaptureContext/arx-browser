import AppFeature
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// A tab keeps its page's URL and title even when no window shows it.
extension IntegrationFeatureTests {
	/// The headless pass: a tab reopened with its history, which no pane shows, is moved back
	/// to /a. Its sidebar row, an agent's inventory and the saved workspace follow the page.
	@Test
	internal func aTabNoWindowShowsKeepsTheTitleItsPageSettledOn() async throws {
		var organization = fixture()
		let shown = organization.tabs[0].id
		let restored = organization.tabs[1].id
		let pageB = URL(string: "https://capturecontext.dev/b")!
		let pageA = URL(string: "https://capturecontext.dev/a")!
		organization.tabs[id: restored]?.restoration = .init(title: "Pass b", url: pageB)
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		#expect(state.main.viewer.panes.allSatisfy { $0.item.tab?.id != restored })
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// Loading and failed reports change nothing.
		await store.send(.event(.pageSettled(restored, .init(url: pageA, title: "Pass a", isLoading: true))))
		await store.send(.event(.pageSettled(restored, .init(url: pageA, title: "Pass a", errorCode: -2))))
		await store.finish()
		await store.skipReceivedActions()
		expectNoDifference(store.state.workspace.tabs[id: restored]?.restoration.title, "Pass b")

		await store.send(.event(.pageSettled(restored, .init(url: pageA, title: "Pass a"))))
		await store.finish()
		await store.skipReceivedActions()

		expectNoDifference(store.state.workspace.tabs[id: restored]?.restoration, .init(title: "Pass a", url: pageA))
		expectNoDifference(store.state.main.sidebar.organization.tabs[id: restored]?.displayTitle, "Pass a")
		expectNoDifference(store.state.unsavedOrganization?.tabs[id: restored]?.restoration.url, pageA)

		// The tab the window shows is untouched.
		expectNoDifference(store.state.workspace.tabs[id: shown]?.restoration, organization.tabs[id: shown]?.restoration)
	}

	/// The window that shows the page takes it, as its pane would, so its undo stays; once no
	/// window shows it, main takes it.
	@Test
	internal func theShowingWindowTakesItsPageAndKeepsItsUndo() async throws {
		var organization = fixture()
		let tab = organization.tabs[1].id
		let page = URL(string: "https://capturecontext.dev/a")!
		organization.tabs[id: tab]?.restoration = .init(title: "Pass b", url: URL(string: "https://capturecontext.dev/b")!)
		let other = UUID(900)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		var window = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, id: other)
		window.viewer.item.tab = organization.tabs[id: tab]
		window.sidebar.undo = [.init(before: organization)]
		state.windows.append(window)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.pageSettled(tab, .init(url: page, title: "Pass a"))))
		await store.finish()
		await store.skipReceivedActions()
		expectNoDifference(store.state.workspace.tabs[id: tab]?.restoration.title, "Pass a")
		expectNoDifference(store.state.windows[id: other]?.sidebar.undo.count, 1)

		await store.send(.windows(.element(id: other, action: .viewer(.item(.show(nil))))))
		await store.send(.event(.pageSettled(tab, .init(url: page, title: "Pass a again"))))
		await store.finish()
		await store.skipReceivedActions()
		expectNoDifference(store.state.workspace.tabs[id: tab]?.restoration.title, "Pass a again")
	}

	/// With main's window closed and no other window showing the tab, main still takes it.
	@Test
	internal func aClosedMainWindowStillKeepsTheTabsTitle() async throws {
		var organization = fixture()
		let tab = organization.tabs[1].id
		organization.tabs[id: tab]?.restoration = .init(title: "Pass b", url: URL(string: "https://capturecontext.dev/b")!)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.windowIsOpen = false
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.pageSettled(tab, .init(url: URL(string: "https://capturecontext.dev/a"), title: "Pass a"))))
		await store.finish()
		await store.skipReceivedActions()
		expectNoDifference(store.state.workspace.tabs[id: tab]?.restoration.title, "Pass a")
	}

	/// A page whose tab has gone, or that is in a private window, changes no ordinary tab.
	@Test
	internal func aSettledPageWithoutAnOrdinaryTabChangesNothing() async throws {
		let organization = fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))) {
			AppFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.pageSettled(.init(rawValue: UUID(99)), .init(url: URL(string: "https://capturecontext.dev/a"), title: "Pass a"))))
		await store.finish()
		expectNoDifference(store.state.workspace, organization)
	}
}
