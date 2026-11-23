import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct PaneCommandTests {
	@Test
	internal func historyCommandUsesOriginPaneAvailabilityAndTab() async throws {
		var initial = fixture()
		let originID = initial.main.viewer.activePaneID
		let otherID = UUID(20)
		let tabID = try #require(initial.main.viewer.item.tab?.id)
		initial.main.viewer.activePaneID = otherID
		initial.main.recordRecentTab()
		let invoked = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.command = { id, command in
				expectNoDifference(command, .back)
				invoked.withValue { $0.append(id) }
			}
		}
		await store.send(.main(.delegate(.commandFromPane(.goBack, originID))))
		await store.receive(\.ui.command)
		await store.receive(\.main.ui.paneCommand)
		await store.receive(\.main.viewer.command)
		await store.finish()
		expectNoDifference(invoked.value, [tabID])
		expectNoDifference(store.state.main.viewer.activePaneID, otherID)
		await store.send(.ui(.command(.goBack, .window(initial.main.id, paneID: otherID))))
		await store.send(.ui(.command(.reload, .window(initial.main.id, paneID: UUID(99)))))
		await store.finish()
		expectNoDifference(invoked.value, [tabID])
	}

	@Test
	internal func closingOriginPaneDoesNotCloseTheFocusedPaneOrItsSession() async throws {
		var initial = fixture()
		let originID = initial.main.viewer.activePaneID
		let otherID = UUID(20)
		initial.main.viewer.activePaneID = otherID
		initial.main.sidebar.select(try #require(initial.main.viewer.item.tab?.id))
		initial.main.recordRecentTab()
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { _ in Issue.record("Closing a pane must retain the browser session") }
		}
		await store.send(.ui(.command(.closePane, .window(initial.main.id, paneID: originID))))
		await store.receive(\.main.ui.paneCommand)
		await store.receive(\.main.viewer.ui.closePane) { $0.main.viewer.panes.remove(id: originID) }
		expectNoDifference(store.state.main.viewer.activePaneID, otherID)
		expectNoDifference(store.state.main.viewer.panes.count, 1)
		await store.send(.ui(.command(.closePane, .window(initial.main.id, paneID: otherID))))
		await store.finish()
	}

	@Test
	internal func splitCommandsAreOfferedOnlyForSupportedHostAndLayout() async throws {
		let state = fixture()

		// A two-pane split still takes up to four panes, while the window has room for them.
		#expect(BrowserCommand.newSplit.isEnabled(in: state.main.commandContext))
		#expect(!BrowserCommand.newSplit.isEnabled(in: .init(host: .main, hasTab: true, isSplit: true, canAddPane: false)))
		#expect(BrowserCommand.closePane.isEnabled(in: state.main.commandContext))
		#expect(!BrowserCommand.closePane.isEnabled(in: .init(host: .main)))
		#expect(!BrowserCommand.newSplit.isEnabled(in: .init(host: .little, hasTab: true)))
		#expect(!BrowserCommand.swapPanes.isEnabled(in: .init(host: .main, isBusy: true, isSplit: true)))
		try BrowserPreferences().validate()
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.main.viewer.item = .init(tab: organization.tabs[0], navigation: .init(canGoBack: true))
		initial.main.viewer.panes.append(.init(id: UUID(20), item: .init(tab: organization.tabs[1])))
		return initial
	}
}
