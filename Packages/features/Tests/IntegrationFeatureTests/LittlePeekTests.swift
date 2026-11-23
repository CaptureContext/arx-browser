import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

extension IntegrationFeatureTests {
	@Test
	internal func littlePeekKeepsOriginalSessionAndRejectsUnderlyingMutations() async throws {
		let state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		var commands: [BrowserCore.Tab.ID] = []
		let store = littlePeekStore(state) {
			$0.browserEngine.command = { id, _ in commands.append(id) }
		}

		await openLittlePeek(store, id: little.id)
		let peek = try #require(store.state.peeks.first)
		expectNoDifference(peek.source.host, .littleArx(generation: little.viewer.generation))
		expectNoDifference(peek.source.tabID, little.tab.id)
		expectNoDifference(peek.tab.profileID, little.tab.profileID)
		expectNoDifference(store.state.littleWindows[id: little.id]?.peekID, peek.id)
		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(store.state.commandTarget(in: little.id), .peek(peek.id))
		let underlying = try #require(store.state.captureSource(for: .window(little.id)))
		#expect(store.state.captureViewer(for: underlying) == nil)

		await store.send(.littleWindows(.element(
			id: little.id,
			action: .ui(.openCommand(.currentTab))
		)))
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .viewer(.ui(.command(.reload)))
		)))
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .changeProfile(.init(rawValue: UUID(90)), state.workspace.spaces[1].id)
		)))
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .ui(.promote(little.spaceID, little.tab.profileID))
		)))
		await store.finish()

		expectNoDifference(store.state.littleWindows[id: little.id]?.viewer, little.viewer)
		#expect(store.state.littleWindows[id: little.id]?.commandBar.isPresented == false)
		#expect(store.state.littleWindows[id: little.id]?.isPromoting == false)
		#expect(commands.isEmpty)

		await store.send(.ui(.command(.reload, .peek(peek.id))))
		await store.finish()
		expectNoDifference(commands, [peek.tab.id])
	}

	@Test
	internal func littlePeekHostCloseApprovesBothPagesAndCanCancelEither() async throws {
		let state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		var allowPreview = false
		var allowSource = false
		var approvals: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = littlePeekStore(state) {
			$0.browserEngine.permitsClosing = { id in
				approvals.append(id)
				return id == little.tab.id ? allowSource : allowPreview
			}
			$0.browserEngine.close = { closed.append($0) }
			$0.date.now = Date(timeIntervalSince1970: 500)
		}
		await openLittlePeek(store, id: little.id)
		let peek = try #require(store.state.peeks.first)

		await store.send(.littleWindows(.element(
			id: little.id,
			action: .ui(.close)
		)))
		await store.receive {
			if case .peeks(.element(_, .event(.closeDecision(false)))) = $0 { true } else { false }
		}
		await store.finish()
		expectNoDifference(approvals, [peek.tab.id])
		#expect(closed.isEmpty)
		#expect(store.state.littleWindows[id: little.id] != nil)
		expectNoDifference(store.state.peeks.first?.phase, .idle)

		allowPreview = true
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .ui(.close)
		)))
		await store.receive(\.event.peekReleased)
		await store.receive {
			if case .littleWindows(.element(_, .event(.closeDecision(_, false)))) = $0 { true } else { false }
		}
		await store.finish()
		expectNoDifference(approvals, [peek.tab.id, peek.tab.id, little.tab.id])
		expectNoDifference(closed, [peek.tab.id])
		#expect(store.state.peeks.isEmpty)
		#expect(store.state.littleWindows[id: little.id]?.peekID == nil)
		#expect(store.state.littleWindows[id: little.id]?.isClosing == false)

		allowSource = true
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .ui(.close)
		)))
		await store.receive {
			if case .littleWindows(.element(_, .delegate(.closeApproved))) = $0 { true } else { false }
		}
		await store.finish()
		#expect(store.state.littleWindows.isEmpty)
		expectNoDifference(closed, [peek.tab.id, little.tab.id])

		// DEV-728: the closed source page joins its space's archive; nothing else changes.
		expectNoDifference(store.state.workspace.tabs, state.workspace.tabs)
		expectNoDifference(store.state.workspace.spaces, state.workspace.spaces)
		expectNoDifference(store.state.workspace.archive.map(\.tab.id), [little.tab.id])
	}

	@Test
	internal func littlePeekDismissalRestoresSourceFocusWithoutClosingIt() async throws {
		let state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		var focused: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = littlePeekStore(state) {
			$0.browserSurface.focus = { focused.append($0) }
			$0.browserEngine.close = { closed.append($0) }
		}
		await openLittlePeek(store, id: little.id)
		let peek = try #require(store.state.peeks.first)
		await store.send(.ui(.dismissPeek(windowID: little.id)))
		await store.receive(\.event.peekReleased)
		await store.finish()

		expectNoDifference(closed, [peek.tab.id])
		expectNoDifference(focused, [little.tab.id])
		expectNoDifference(store.state.littleWindows.first?.viewer, little.viewer)
		expectNoDifference(store.state.focusedWindowID, little.id)
	}

	@Test(arguments: [PeekDestination.tab, .littleArx])
	internal func littlePeekPromotionKeepsPreviewAndOriginalSession(_ destination: PeekDestination) async throws {
		let state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		var closed: [BrowserCore.Tab.ID] = []
		let store = littlePeekStore(state) {
			$0.browserEngine.close = { closed.append($0) }
		}
		await openLittlePeek(store, id: little.id)
		let peek = try #require(store.state.peeks.first)
		await store.send(.ui(.promotePeek(windowID: little.id, destination: destination)))
		await store.receive(\.event.peekPromotionReady)
		await store.receive(\.event.peekReleased)
		await store.finish()

		#expect(store.state.peeks.isEmpty)
		#expect(closed.isEmpty)
		expectNoDifference(store.state.littleWindows[id: little.id]?.viewer, little.viewer)
		#expect(store.state.littleWindows[id: little.id]?.peekID == nil)
		if destination == .tab {
			expectNoDifference(store.state.workspace.tabs.last?.id, peek.tab.id)
			expectNoDifference(store.state.main.viewer.item.tab?.id, peek.tab.id)
			expectNoDifference(store.state.focusedWindowID, state.main.id)
			#expect(store.state.windowIsOpen)

		} else {
			expectNoDifference(store.state.workspace, state.workspace)
			expectNoDifference(store.state.littleWindows.last?.tab.id, peek.tab.id)
			expectNoDifference(store.state.focusedWindowID, store.state.littleWindows.last?.id)
		}
	}

	@Test
	internal func littlePeekPromotionPreservesAnExistingSplitNeighbor() async throws {
		var state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		let neighbor = state.workspace.tabs[1]
		let neighborPane = UUID(55)
		state.windowIsOpen = true
		state.main.viewer.spaceID = little.spaceID
		state.main.viewer.item = .init(tab: state.workspace.tabs[0])
		state.main.viewer.panes.append(.init(id: neighborPane, item: .init(tab: neighbor)))
		let store = littlePeekStore(state)

		await openLittlePeek(store, id: little.id)
		let peek = try #require(store.state.peeks.first)
		await store.send(.ui(.promotePeek(windowID: little.id, destination: .tab)))
		await store.receive(\.event.peekPromotionReady)
		await store.receive(\.event.peekReleased)
		await store.finish()

		expectNoDifference(store.state.main.viewer.item.tab?.id, peek.tab.id)
		expectNoDifference(store.state.main.viewer.panes[id: neighborPane]?.item.tab?.id, neighbor.id)
		expectNoDifference(store.state.littleWindows[id: little.id]?.tab.id, little.tab.id)
	}

	@Test
	internal func littlePeekPromotionDoesNotReplaceAnotherHostsPreview() async throws {
		var state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		state.windowIsOpen = true
		let store = littlePeekStore(state)
		await store.send(.ui(.peekURL(
			URL(string: "https://other-preview.example")!,
			sourceWindowID: state.main.id,
			sourcePaneID: state.main.viewer.activePaneID
		)))
		await store.receive {
			if case .peeks(.element(_, .viewer(.show))) = $0 { true } else { false }
		}
		await store.finish()
		let other = try #require(store.state.peeks.first)
		await openLittlePeek(store, id: little.id)
		let peek = try #require(store.state.peeks.last)
		await store.send(.ui(.promotePeek(windowID: little.id, destination: .tab)))
		await store.receive(\.event.peekPromotionReady)
		await store.receive(\.event.peekReleased)
		await store.finish()

		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(store.state.peeks[id: other.id], other)
		expectNoDifference(store.state.peeks[id: peek.id]?.phase, .idle)
		#expect(store.state.peeks[id: peek.id]?.error != nil)
	}

	@Test(arguments: [false, true])
	internal func littlePeekPromotionReconcilesBackgroundSelectionAndUndo(_ hasTransferUndo: Bool) async throws {
		var state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		let previous = state.workspace
		let move = try previous.moving(
			[.tab(previous.tabs[0].id)],
			to: .savedRoot,
			in: little.spaceID,
			newTabID: { .init(rawValue: UUID(90)) }
		)
		state.workspace = move.updated
		state.main.sidebar.organization = move.updated
		state.main.sidebar.undo = [.init(before: previous)]
		state.main.sidebar.transferUndos = hasTransferUndo ? [move] : []
		state.main.viewer.item = .init(tab: move.updated.tabs[0])
		state.windowIsOpen = true

		var background = MainFeature.State(
			organization: move.updated,
			spaceID: little.spaceID,
			id: UUID(60)
		)
		background.sidebar.select(move.updated.tabs[1].id)
		background.sidebar.undo = [.init(before: previous)]
		background.sidebar.transferUndos = hasTransferUndo ? [move] : []
		background.viewer.item = .init(tab: move.updated.tabs[1], generation: 8)
		state.windows.append(background)
		let store = littlePeekStore(state)

		await openLittlePeek(store, id: little.id)
		let peek = try #require(store.state.peeks.first)
		await store.send(.ui(.promotePeek(windowID: little.id, destination: .tab)))
		await store.receive(\.event.peekPromotionReady)
		await store.receive(\.event.peekReleased)
		await store.finish()

		let updated = try #require(store.state.windows[id: background.id])
		expectNoDifference(updated.sidebar.selectedTab?.id, background.sidebar.selectedTab?.id)
		expectNoDifference(updated.viewer, background.viewer)
		expectNoDifference(store.state.main.viewer.item.tab?.id, peek.tab.id)

		for host in [store.state.main, updated] {
			// A move to another profile can't go back once something else changed, so it's no
			// longer a step; a move within one profile stays one (DEV-1030).
			#expect(host.sidebar.undo.count == (hasTransferUndo && !move.replacements.isEmpty ? 0 : 1))
			#expect(host.sidebar.transferUndos.isEmpty)
			#expect(host.knownTabIDs.contains(peek.tab.id))
		}

		await store.send(.windows(.element(id: background.id, action: .sidebar(.ui(.undo)))))
		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		#expect(store.state.workspace.tabs.ids.contains(peek.tab.id))
		#expect(store.state.windows[id: background.id]?.sidebar.organization.tabs.ids.contains(peek.tab.id) == true)
		expectNoDifference(store.state.main.viewer.item.tab?.id, peek.tab.id)
		expectNoDifference(store.state.windows[id: background.id]?.viewer, background.viewer)
	}

	@Test(arguments: [false, true])
	internal func littlePeekBorrowsOnlyUnmountedPermanentTabs(_ mounted: Bool) async throws {
		var state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		let tab = state.workspace.tabs[0]
		if mounted {
			state.main.viewer.item.tab = tab
			state.windowIsOpen = true
		}
		var closed: [BrowserCore.Tab.ID] = []
		let store = littlePeekStore(state) {
			$0.browserEngine.close = { closed.append($0) }
		}
		await store.send(.ui(.peekTab(tab.id, sourceWindowID: little.id, sourcePaneID: little.id)))
		await store.finish()

		if mounted {
			#expect(store.state.peeks.isEmpty)
			expectNoDifference(store.state.focusedWindowID, state.main.id)

		} else {
			let peek = try #require(store.state.peeks.first)
			#expect(!peek.isTemporary)
			expectNoDifference(peek.tab.id, tab.id)
			await store.send(.ui(.dismissPeek(windowID: little.id)))
			await store.receive(\.event.peekReleased)
			await store.finish()
			#expect(store.state.peeks.isEmpty)
		}
		#expect(closed.isEmpty)
		expectNoDifference(store.state.workspace, state.workspace)
	}

	@Test(arguments: [false, true])
	internal func littlePeekPromotionRejectsSourceGenerationChangedDuringHandoff(_ afterRelease: Bool) async throws {
		var state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: little.tab.profileID,
			restoration: .init(title: "Preview", url: URL(string: "https://preview.example")!)
		)
		var peek = PeekFeature.State(
			id: UUID(81),
			source: .init(
				windowID: little.id,
				paneID: little.id,
				tabID: little.tab.id,
				spaceID: little.spaceID,
				profileID: little.tab.profileID,
				identity: "Default · Work",
				host: .littleArx(generation: little.viewer.generation)
			),
			tab: tab,
			isTemporary: true
		)
		if afterRelease {
			peek.phase = .releasing
			state.peekTransitions[peek.id] = .promote(.tab)
		}
		state.peeks.append(peek)
		state.littleWindows[id: little.id]?.peekID = peek.id
		let (gate, continuation) = AsyncStream<Void>.makeStream()
		var hold = true
		let store = littlePeekStore(state) {
			$0.browserEngine.open = { _ in
				if hold { for await _ in gate { return } }
			}
		}
		if !afterRelease {
			await store.send(.ui(.promotePeek(windowID: little.id, destination: .tab)))
			await store.receive {
				if case .peeks(.element(_, .delegate(.promote))) = $0 { true } else { false }
			}
		}
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .viewer(.suspend)
		)))
		hold = false
		continuation.yield(())
		continuation.finish()
		if afterRelease {
			await store.send(.event(.peekReleased(peek.id)))

		} else {
			await store.receive(\.event.peekPromotionReady)
		}
		await store.finish()

		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(store.state.peeks.first?.id, peek.id)
		expectNoDifference(store.state.peeks.first?.phase, .idle)
		#expect(store.state.peeks.first?.error != nil)
		#expect(!store.state.windowIsOpen)
	}

	@Test
	internal func littleCloseApprovalCannotCloseAReplacedViewer() async throws {
		let state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		let (gate, continuation) = AsyncStream<Void>.makeStream()
		var closed: [BrowserCore.Tab.ID] = []
		let store = littlePeekStore(state) {
			$0.browserEngine.permitsClosing = { _ in
				for await _ in gate { return true }
				return false
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .ui(.close)
		)))
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .viewer(.suspend)
		)))
		continuation.yield(())
		continuation.finish()

		// The approval was for the viewer that was replaced, so it can't close the window. The
		// window asks the page it shows now instead (DEV-965), and that page says no.
		await store.receive {
			if case .littleWindows(.element(_, .event(.closeDecision))) = $0 { true } else { false }
		}
		await store.receive {
			if case .littleWindows(.element(_, .event(.closeDecision))) = $0 { true } else { false }
		}
		await store.finish()

		#expect(store.state.littleWindows[id: little.id] != nil)
		#expect(store.state.littleWindows[id: little.id]?.isClosing == false)
		#expect(closed.isEmpty)
	}

	@Test
	internal func littlePeekURLSubmissionRetainsTheProfileShownWhenEntryOpened() async throws {
		var state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		let source = try #require(state.peekSource(windowID: little.id, paneID: little.id))
		let profileID = Profile.ID(rawValue: UUID(90))
		let spaceID = Space.ID(rawValue: UUID(91))
		state.workspace.profiles.append(.init(id: profileID, name: "Other"))
		state.workspace.spaces.append(.init(id: spaceID, profileID: profileID, name: "Other Space"))
		let store = littlePeekStore(state) {
			$0.browserEngine.close = { _ in }
		}
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .changeProfile(profileID, spaceID)
		)))
		await store.receive {
			if case .littleWindows(.element(_, .viewer(.show))) = $0 { true } else { false }
		}
		await store.send(.ui(.peekURLFromSource(URL(string: "https://preview.example")!, source)))
		await store.finish()

		#expect(store.state.peeks.isEmpty)
		expectNoDifference(store.state.littleWindows[id: little.id]?.tab.profileID, profileID)
	}

	@Test
	internal func littleCloseDelegateRechecksTheApprovedViewerBeforeRemoval() async throws {
		var state = littlePeekFixture()
		let little = try #require(state.littleWindows.first)
		let child = TestStore(initialState: little) { LittleArxFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = { _ in true }
		}
		child.exhaustivity = .off(showSkippedAssertions: false)
		await child.send(.ui(.close))
		await child.receive(\.event.closeDecision)
		await child.receive(\.delegate.closeApproved)
		await child.finish()
		let request = try #require(child.state.closeRequest)
		state.littleWindows[id: little.id] = child.state

		var closed: [BrowserCore.Tab.ID] = []
		let store = littlePeekStore(state) {
			$0.browserEngine.close = { closed.append($0) }
		}
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .viewer(.suspend)
		)))
		await store.send(.littleWindows(.element(
			id: little.id,
			action: .delegate(.closeApproved(request))
		)))
		await store.finish()

		#expect(store.state.littleWindows[id: little.id] != nil)
		#expect(store.state.littleWindows[id: little.id]?.isClosing == false)
		#expect(closed.isEmpty)
	}

	private func littlePeekFixture() -> AppFeature.State {
		let organization = fixture()
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id),
			windowIsOpen: false
		)
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(41)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Source", url: URL(string: "https://source.example")!)
		)
		var little = LittleArxFeature.State(id: UUID(40), spaceID: organization.spaces[0].id, tab: tab)
		little.viewer = .init(tab: tab, generation: 3)
		state.littleWindows.append(little)
		state.focusedWindowID = little.id
		return state
	}

	private func littlePeekStore(
		_ state: AppFeature.State,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	private func openLittlePeek(
		_ store: TestStoreOf<AppFeature>,
		id: UUID
	) async {
		await store.send(.ui(.peekURL(
			URL(string: "https://preview.example")!,
			sourceWindowID: id,
			sourcePaneID: id
		)))
		await store.receive {
			if case .peeks(.element(_, .viewer(.show))) = $0 { true } else { false }
		}
		await store.finish()
	}
}
