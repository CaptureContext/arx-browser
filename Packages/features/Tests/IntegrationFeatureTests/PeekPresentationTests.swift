import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

extension IntegrationFeatureTests {
	@Test
	internal func peekKeepsTheClickedPointAndOpensWithoutOneFromKeyboard() async throws {
		let state = peekHostFixture()
		let paneID = state.main.viewer.activePaneID
		let source = try #require(state.peekSource(windowID: state.main.id, paneID: paneID))
		let origin = CGPoint(x: 420, y: 310)
		func makeStore() -> TestStoreOf<AppFeature> {
			let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
				$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
				$0.uuid = .incrementing
				$0.browserEngine.open = { _ in }
				$0.browserEngine.close = { _ in }
			}
			store.exhaustivity = .off(showSkippedAssertions: false)
			return store
		}

		let clicked = makeStore()
		await clicked.send(
			.ui(.peekURLFromSource(URL(string: "https://preview.example/clicked")!, source, origin: origin))
		)
		await clicked.finish()
		expectNoDifference(clicked.state.peeks.first?.origin, origin)

		let typed = makeStore()
		await typed.send(
			.ui(
				.peekURL(
					URL(string: "https://preview.example/typed")!,
					sourceWindowID: state.main.id,
					sourcePaneID: paneID
				)
			)
		)
		await typed.finish()
		#expect(typed.state.peeks.first != nil)
		expectNoDifference(typed.state.peeks.first?.origin, nil)
	}

	@Test
	internal func peekPromotionPreservesSessionAndCapturedPaneAfterFocusChanges() async throws {
		let state = peekHostFixture()
		let sourceID = state.main.viewer.activePaneID
		let otherID = try #require(state.main.viewer.panes.last?.id)
		var opened: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.uuid = .incrementing
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekURL(
					URL(string: "https://preview.example/first")!,
					sourceWindowID: state.main.id,
					sourcePaneID: sourceID
				)
			)
		)
		await store.finish()
		let peek = try #require(store.state.peeks.first)
		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(store.state.main.viewer, state.main.viewer)
		await store.send(.main(.viewer(.ui(.focus(otherID)))))
		await store.send(.ui(.promotePeek(windowID: state.main.id, destination: .tab)))
		await store.receive(\.event.peekPromotionReady)
		await store.receive(\.event.peekReleased)
		await store.receive { if case .main(.viewer(.show)) = $0 { true } else { false } }
		await store.finish()
		#expect(store.state.peeks.isEmpty)
		expectNoDifference(store.state.workspace.tabs.last?.id, peek.tab.id)
		expectNoDifference(store.state.main.viewer.panes[id: sourceID]?.item.tab?.id, peek.tab.id)
		expectNoDifference(store.state.main.viewer.activePaneID, sourceID)
		expectNoDifference(
			store.state.main.viewer.panes[id: otherID]?.item.tab?.id,
			state.main.viewer.panes[id: otherID]?.item.tab?.id
		)
		#expect(opened.contains(peek.tab.id))
		#expect(Set(opened).isSubset(of: Set(state.workspace.tabs.map(\.id) + [peek.tab.id])))
		expectNoDifference(closed, [])
	}

	@Test
	internal func closingPeekHostWaitsForBeforeUnloadAndClosesOnlyTemporarySession() async throws {
		let state = peekHostFixture()
		var permitted = false
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.permitsClosing = { _ in permitted }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekURL(
					URL(string: "https://preview.example")!,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.finish()
		let peek = try #require(store.state.peeks.first)
		await store.send(.ui(.closeWindow))
		await store.receive { if case .peeks(.element(_, .event(.closeDecision(false)))) = $0 { true } else { false } }
		await store.finish()
		#expect(store.state.windowIsOpen)
		expectNoDifference(store.state.peeks.first?.phase, .idle)
		#expect(store.state.closingPeekHosts.isEmpty)
		expectNoDifference(closed, [])
		permitted = true
		await store.send(.ui(.closeWindow))
		await store.receive(\.event.peekReleased)
		await store.receive(\.ui.closeWindow)
		await store.finish()
		#expect(!store.state.windowIsOpen)
		#expect(store.state.peeks.isEmpty)
		expectNoDifference(closed, [peek.tab.id])
		expectNoDifference(store.state.workspace, state.workspace)
	}

	@Test
	internal func cancelledAdditionalWindowCloseRetainsSavedPaneLayout() async throws {
		var state = peekHostFixture()
		var window = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(50))
		window.viewer.item.tab = state.workspace.tabs[0]
		state.windows.append(window)
		let saved = BrowserWindowPresentation(
			id: window.id,
			activeSpaceID: window.sidebar.spaceID,
			spaces: [
				.init(
					id: window.sidebar.spaceID,
					panes: [.init(id: window.viewer.activePaneID, tabID: window.viewer.item.tab?.id)],
					activePaneID: window.viewer.activePaneID
				),
			]
		)
		state.$windowLayout.withLock { $0.windowPresentations = [saved] }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.browserEngine.open = { _ in }
			$0.browserEngine.permitsClosing = { _ in false }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekURL(
					URL(string: "https://preview.example")!,
					sourceWindowID: window.id,
					sourcePaneID: window.viewer.activePaneID
				)
			)
		)
		await store.finish()
		await store.send(.ui(.closeAdditionalWindow(window.id)))
		await store.receive { if case .peeks(.element(_, .event(.closeDecision(false)))) = $0 { true } else { false } }
		await store.finish()
		#expect(store.state.windows[id: window.id] != nil)
		expectNoDifference(store.state.windowLayout.windowPresentations, [saved])
		expectNoDifference(store.state.peeks.count, 1)
	}

	@Test
	internal func existingPinnedPeekRetainsPlacementAndReturnsItsSession() async throws {
		var state = peekHostFixture()
		let tabID = state.workspace.tabs[1].id
		try state.workspace.move(.tab(tabID.rawValue), to: .savedRoot, in: state.workspace.spaces[0].id)
		state.main.sidebar.organization = state.workspace
		var closed: [BrowserCore.Tab.ID] = []
		var released: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.permitsClosing = { _ in
				Issue.record("Returning an existing tab must not close it")
				return false
			}
			$0.browserSurface.release = { released.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekTab(
					tabID,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.finish()
		#expect(store.state.peeks.first?.isTemporary == false)
		await store.send(.ui(.dismissPeek(windowID: state.main.id)))
		await store.receive(\.event.peekReleased)
		await store.finish()
		#expect(store.state.peeks.isEmpty)
		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(
			store.state.main.viewer.panes.map { $0.item.tab?.id },
			state.main.viewer.panes.map { $0.item.tab?.id }
		)
		expectNoDifference(closed, [])
		expectNoDifference(released, [tabID, tabID])
	}

	@Test
	internal func peekFocusesAnExistingOtherWindowPaneWithoutTakingItsSession() async throws {
		var state = peekHostFixture()
		let tabID = state.workspace.tabs[1].id
		state.main.viewer.panes.removeLast()
		var window = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(50))
		window.viewer.panes.append(.init(id: UUID(51), item: .init(tab: state.workspace.tabs[1])))
		state.windows.append(window)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekTab(
					tabID,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.finish()
		#expect(store.state.peeks.isEmpty)
		await store.receive(\.windows)
		expectNoDifference(store.state.focusedWindowID, window.id)
		expectNoDifference(store.state.windows[id: window.id]?.viewer.activePaneID, UUID(51))
		expectNoDifference(store.state.main.viewer, state.main.viewer)
	}

	@Test
	internal func peekReplacementNeverNestsAndHonorsCancellation() async throws {
		let state = peekHostFixture()
		var permitted = false
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.permitsClosing = { _ in permitted }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let firstURL = URL(string: "https://first.example")!
		let nextURL = URL(string: "https://next.example")!
		await store.send(
			.ui(
				.peekURL(
					firstURL,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.finish()
		let first = try #require(store.state.peeks.first)
		await store.send(
			.ui(
				.peekURL(
					nextURL,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.receive { if case .peeks(.element(_, .event(.closeDecision(false)))) = $0 { true } else { false } }
		await store.finish()
		expectNoDifference(store.state.peeks.map(\.id), [first.id])
		expectNoDifference(closed, [])
		permitted = true
		await store.send(
			.ui(
				.peekURL(
					nextURL,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.receive(\.event.peekReleased)
		await store.finish()
		expectNoDifference(store.state.peeks.count, 1)
		expectNoDifference(store.state.peeks.first?.tab.restoration.url, nextURL)
		expectNoDifference(closed, [first.tab.id])
		expectNoDifference(store.state.workspace, state.workspace)
	}

	@Test
	internal func failedPeekPromotionRetainsSessionAndWorkspace() async throws {
		let state = peekHostFixture()
		var fail = false
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in
				if fail { throw BrowserEngineClient.Failure.unavailable }
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekURL(
					URL(string: "https://preview.example")!,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.finish()
		let peek = try #require(store.state.peeks.first)
		fail = true
		await store.send(.ui(.promotePeek(windowID: state.main.id, destination: .tab)))
		await store.receive { if case .peeks(.element(_, .event(.promotionFailed))) = $0 { true } else { false } }
		await store.finish()
		expectNoDifference(store.state.peeks.first?.id, peek.id)
		expectNoDifference(store.state.peeks.first?.phase, .idle)
		#expect(store.state.peeks.first?.error != nil)
		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(closed, [])
	}

	@Test
	internal func temporaryPeekPromotionToLittleKeepsIdentityWithoutSavingATab() async throws {
		let state = peekHostFixture()
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekURL(
					URL(string: "https://preview.example")!,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.finish()
		let peek = try #require(store.state.peeks.first)
		await store.send(.ui(.promotePeek(windowID: state.main.id, destination: .littleArx)))
		await store.receive(\.event.peekReleased)
		await store.finish()
		#expect(store.state.peeks.isEmpty)
		expectNoDifference(store.state.littleWindows.first?.tab, peek.tab)
		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(closed, [])
	}

	@Test
	internal func removingOriginPaneClosesTemporaryPeekWithoutRemovingItsTab() async throws {
		let state = peekHostFixture()
		let paneID = state.main.viewer.activePaneID
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekURL(
					URL(string: "https://preview.example")!,
					sourceWindowID: state.main.id,
					sourcePaneID: paneID
				)
			)
		)
		await store.finish()
		let peek = try #require(store.state.peeks.first)
		await store.send(.main(.viewer(.ui(.closePane(paneID)))))
		await store.receive(\.event.peekReleased)
		await store.finish()
		#expect(store.state.peeks.isEmpty)
		expectNoDifference(closed, [peek.tab.id])
		expectNoDifference(store.state.workspace.tabs, state.workspace.tabs)
	}

	@Test(arguments: [false, true])
	internal func peekPromotionRevalidatesOriginAfterEveryAsyncHandoff(_ invalidateAfterRelease: Bool) async throws {
		var state = peekHostFixture()
		let paneID = state.main.viewer.activePaneID
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Preview", url: URL(string: "https://preview.example")!)
		)
		let peek = PeekFeature.State(
			id: UUID(81),
			source: .init(
				windowID: state.main.id,
				paneID: paneID,
				tabID: state.main.viewer.item.tab?.id,
				spaceID: state.main.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Default · Work"
			),
			tab: tab,
			isTemporary: true
		)
		state.peeks.append(peek)
		if invalidateAfterRelease {
			state.peeks[id: peek.id]?.phase = .releasing
			state.peekTransitions[peek.id] = .promote(.tab)
		}
		let (gate, continuation) = AsyncStream<Void>.makeStream()
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.browserEngine.open = { _ in
				guard !invalidateAfterRelease else { return }
				for await _ in gate { return }
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		if !invalidateAfterRelease {
			await store.send(.ui(.promotePeek(windowID: state.main.id, destination: .tab)))
			await store.receive { if case .peeks(.element(_, .delegate(.promote))) = $0 { true } else { false } }
		}
		await store.send(.ui(.closeWindow))
		#expect(store.state.windowIsOpen)
		#expect(store.state.closingPeekHosts.isEmpty)
		await store.send(.main(.viewer(.ui(.closePane(paneID)))))
		continuation.yield(())
		continuation.finish()
		if invalidateAfterRelease {
			await store.send(.event(.peekReleased(peek.id)))
		} else {
			await store.receive(\.event.peekPromotionReady)
		}
		await store.finish()
		expectNoDifference(store.state.peeks.first?.id, peek.id)
		expectNoDifference(store.state.peeks.first?.phase, .idle)
		#expect(store.state.peeks.first?.error != nil)
		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(closed, [])
	}

	@Test
	internal func quittingCancelsPeekPromotionWithoutSendingToRemovedChild() async throws {
		var state = peekHostFixture()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Preview", url: URL(string: "https://preview.example")!)
		)
		state.peeks.append(
			.init(
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
		)
		let (gate, continuation) = AsyncStream<Void>.makeStream()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.browserEngine.open = { _ in for await _ in gate { return } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.promotePeek(windowID: state.main.id, destination: .tab)))
		await store.receive { if case .peeks(.element(_, .delegate(.promote))) = $0 { true } else { false } }
		await store.send(.event(.quitDecision(true, state.workspace.tabs.map(\.id) + [tab.id])))
		await store.finish()
		continuation.finish()
		#expect(store.state.shouldQuit)
		#expect(store.state.peeks.isEmpty)
		expectNoDifference(store.state.workspace, state.workspace)
	}

	@Test
	internal func existingPeekOwnsSessionDuringSplitRequestsAndOtherWindowRestoration() async throws {
		var state = peekHostFixture()
		let tab = state.workspace.tabs[1]
		state.main.viewer.panes.removeLast()
		state.peeks.append(
			.init(
				id: UUID(80),
				source: .init(
					windowID: state.main.id,
					paneID: state.main.viewer.activePaneID,
					tabID: state.main.viewer.item.tab?.id,
					spaceID: state.main.sidebar.spaceID,
					profileID: tab.profileID,
					identity: "Default · Work"
				),
				tab: tab,
				isTemporary: false
			)
		)
		var other = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(81))
		other.viewer.requestedSpaceID = other.sidebar.spaceID
		state.windows.append(other)
		var focused: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in }, focus: { focused.append($0) })
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.windows(.element(id: other.id, action: .delegate(.requestSplit(tab.id)))))
		await store.finish()
		expectNoDifference(store.state.focusedWindowID, state.main.id)
		expectNoDifference(focused, [tab.id])
		expectNoDifference(store.state.windows[id: other.id]?.viewer.panes.count, 1)
		let presentationRequest = MainFeature.Action.delegate(
			.requestSpacePresentation(other.sidebar.spaceID, selected: tab.id, selectRequested: true)
		)
		await store.send(.windows(.element(id: other.id, action: presentationRequest)))
		await store.receive { if case .windows(.element(_, .viewer(.selectSpace))) = $0 { true } else { false } }
		await store.finish()
		#expect(store.state.windows[id: other.id]?.viewer.panes.contains(where: { $0.item.tab?.id == tab.id }) == false)
		expectNoDifference(store.state.peeks.first?.tab.id, tab.id)
	}

	@Test
	internal func cancelledOrphanPeekDoesNotRepeatBeforeUnloadOnUnrelatedActions() async throws {
		let state = peekHostFixture()
		var requests = 0
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.browserEngine.open = { _ in }
			$0.browserEngine.permitsClosing = { _ in
				requests += 1
				return false
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(
			.ui(
				.peekURL(
					URL(string: "https://preview.example")!,
					sourceWindowID: state.main.id,
					sourcePaneID: state.main.viewer.activePaneID
				)
			)
		)
		await store.finish()
		await store.send(.main(.viewer(.ui(.closePane(state.main.viewer.activePaneID)))))
		await store.receive { if case .peeks(.element(_, .event(.closeDecision(false)))) = $0 { true } else { false } }
		await store.send(.main(.viewer(.ui(.focus(store.state.main.viewer.activePaneID)))))
		await store.finish()
		expectNoDifference(requests, 1)
		expectNoDifference(store.state.peeks.count, 1)
		expectNoDifference(store.state.peeks.first?.phase, .idle)
	}

	private func peekHostFixture() -> AppFeature.State {
		let organization = fixture()
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		main.viewer.panes.append(.init(id: UUID(70), item: .init(tab: organization.tabs[1])))
		return .init(main: main)
	}
}
