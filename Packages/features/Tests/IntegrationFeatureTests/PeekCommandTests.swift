import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct PeekCommandTests {
	@Test
	internal func pageAndLinkCommandsUseThePreviewWhileThePaneRemainsUnchanged() async throws {
		let initial = fixture()
		let peek = try #require(initial.peeks.first)
		let invoked = LockIsolated<[BrowserCore.Tab.ID]>([])
		let copied = LockIsolated<[String]>([])
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.command = { id, _ in invoked.withValue { $0.append(id) } }
			$0.linkSharing.copy = { text in
				copied.withValue { $0.append(text) }
				return true
			}
		}
		expectNoDifference(initial.commandTarget(in: initial.main.id), .peek(peek.id))
		await store.send(.ui(.command(.reload, .peek(peek.id)))).finish()
		await store.send(.ui(.command(.goBack, .peek(peek.id)))).finish()
		await store.send(.ui(.command(.copyURL, .peek(peek.id)))).finish()
		await store.send(.ui(.command(.address, .peek(peek.id)))).finish()
		expectNoDifference(invoked.value, [peek.tab.id, peek.tab.id])
		expectNoDifference(copied.value, [peek.viewer.navigation.url!.absoluteString])
		expectNoDifference(store.peeks[id: peek.id]?.locationFocusRequest, 1)
		expectNoDifference(store.main.viewer, initial.main.viewer)
	}

	@Test
	internal func stalePreviewAndUnderlyingPaneCommandsCannotAffectAnotherSession() async throws {
		let initial = fixture()
		let peek = try #require(initial.peeks.first)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.command = { _, _ in Issue.record("A stale target must not invoke the engine") }
			$0.browserEngine.permitsClosing = { _ in
				Issue.record("A stale target must not close a page")
				return true
			}
		}
		await store.send(.ui(.command(.reload, .peek(UUID(99)))))
		await store.send(.ui(.command(.closeTab, .window(initial.main.id, paneID: initial.main.viewer.activePaneID))))
		await store.send(.ui(.command(.newSplit, .peek(peek.id))))
		await store.send(.ui(.command(.newTab, .peek(peek.id))))
		await store.finish()
	}

	@Test
	internal func closeCommandHonorsTheTemporaryPreviewBeforeUnload() async throws {
		let initial = fixture()
		let peek = try #require(initial.peeks.first)
		var checked: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = {
				checked.append($0)
				return false
			}
			$0.browserEngine.close = { _ in Issue.record("Canceled preview close must retain the session") }
		}
		await store.send(.ui(.command(.closeTab, .peek(peek.id)))).finish()
		expectNoDifference(checked, [peek.tab.id])
		expectNoDifference(store.peeks, initial.peeks)
		expectNoDifference(store.main.viewer, initial.main.viewer)
	}


	@Test
	internal func closeWindowWithPeekHonorsTheHostsBeforeUnloadDecision() async throws {
		let initial = fixture()
		let peek = try #require(initial.peeks.first)
		let checked = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { id in
				checked.withValue { $0.append(id) }
				return false
			}
			$0.browserEngine.close = { _ in Issue.record("Canceled host close must retain its preview") }
		}
		await store.send(.ui(.command(.closeWindow, .peek(peek.id)))).finish()
		expectNoDifference(checked.value, [peek.tab.id])
		#expect(store.windowIsOpen)
		expectNoDifference(store.peeks, initial.peeks)
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item = .init(tab: organization.tabs[0])
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Preview", url: URL(string: "https://preview.example/original")!)
		)
		var peek = PeekFeature.State(
			id: UUID(81),
			source: .init(
				windowID: state.main.id,
				paneID: state.main.viewer.activePaneID,
				tabID: organization.tabs[0].id,
				spaceID: state.main.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Fixture"
			),
			tab: tab,
			isTemporary: true
		)
		peek.viewer = .init(
			tab: tab,
			navigation: .init(url: URL(string: "https://preview.example/current")!, canGoBack: true)
		)
		state.peeks.append(peek)
		return state
	}
}
