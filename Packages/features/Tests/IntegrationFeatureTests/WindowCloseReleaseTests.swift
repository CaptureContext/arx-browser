import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1104: closing a window unloads the pages it held that nothing else holds, so they stop
/// playing and free their renderers. The workspace keeps the tabs; they load when shown again.
@Suite(.dependencies)
@MainActor
internal struct WindowCloseReleaseTests {
	private static let now: Date = .init(timeIntervalSinceReferenceDate: 2_000_000)
	private static let profile: Profile.ID = .init(rawValue: UUID(0))
	private static let work: Space.ID = .init(rawValue: UUID(100))
	private static let home: Space.ID = .init(rawValue: UUID(101))
	private static let other: UUID = .init(200)

	/// How long a wait for effects may take in real time. The defaults (half a second for the
	/// test clock, one for the store) run out when test-all starves the suite, though nothing
	/// is wrong; a real failure still fails, only later.
	private static let patience: Duration = .seconds(10)
	private let document: WorkspaceDocument = .unsaved()

	private static func tab(_ value: Int) -> BrowserCore.Tab.ID {
		.init(rawValue: UUID(value))
	}

	private static func tabs(_ values: Int...) -> Set<BrowserCore.Tab.ID> {
		Set(values.map(tab))
	}

	// MARK: - Closing

	@Test
	internal func closingTheLastWindowUnloadsEveryPageEvenTheSelectedAndPlayingOnes() async {
		let engine = FakePages(loaded: [1, 2, 3, 4, 5])
		let store = store(state(), engine: engine)

		await store.send(.ui(.closeWindow))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(engine.unloaded(.windowClosed) == Self.tabs(1, 2, 3, 4, 5))
		#expect(engine.calls.value.allSatisfy { $0.reason == .windowClosed })
		#expect(store.state.tabUnloading.unloaded == Self.tabs(1, 2, 3, 4, 5))
		#expect(store.state.tabUnloading.releasing.isEmpty)
		// The workspace keeps every tab, and the sidebar shows them unloaded when it opens again.
		#expect(store.state.workspace.tabs.count == 5)
		#expect(store.state.main.sidebar.unloadedTabs == Self.tabs(1, 2, 3, 4, 5))
	}

	@Test
	internal func closingOneOfTwoWindowsUnloadsOnlyItsSpacesPages() async {
		let engine = FakePages(loaded: [1, 2, 3, 4, 5])
		var state = state()
		state.windows.append(window(showing: Self.home, tab: 4))
		let store = store(state, engine: engine)

		await store.send(.ui(.closeAdditionalWindow(Self.other)))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		// Tabs 1 to 3 are the open window's space.
		#expect(engine.unloaded(.windowClosed) == Self.tabs(4, 5))
		#expect(store.state.tabUnloading.unloaded == Self.tabs(4, 5))
		// Only the closed window's tabs lose their video PiP (DEV-1128).
		#expect(engine.endedPictureInPicture.value == Self.tabs(4, 5))
	}

	@Test
	internal func closingAWindowOnASpaceAnotherWindowShowsUnloadsNothing() async {
		let engine = FakePages(loaded: [1, 2, 3, 4, 5])
		var state = state()
		state.windows.append(window(showing: Self.work, tab: 2))
		let store = store(state, engine: engine)

		await store.send(.ui(.closeAdditionalWindow(Self.other)))
		await store.receive(\.releaseWindowlessTabs)

		#expect(engine.calls.value.isEmpty)
		#expect(store.state.tabUnloading.releasing.isEmpty)
		// The open window on the same space keeps its tabs' video PiP (DEV-1128).
		#expect(engine.endedPictureInPicture.value.isEmpty)
	}

	@Test
	internal func tabsAnAgentUsesStayLoadedForItsGraceOnly() async {
		let engine = FakePages(loaded: [1, 2, 3, 4])
		var state = state()
		state.automation.developerLogs[Self.tab(2)] = UUID(9)
		state.tabUnloading.agentActivity[Self.tab(3)] = Self.now.addingTimeInterval(-60)

		// Past the grace, though no sweep has pruned it yet.
		state.tabUnloading.agentActivity[Self.tab(4)] = Self.now.addingTimeInterval(-TabUnloadPolicy.agentGrace - 60)
		let clock = TestClock()
		let store = store(state, engine: engine) { $0.continuousClock = clock }

		await store.send(.ui(.closeWindow))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(engine.unloaded(.windowClosed) == Self.tabs(1, 4))
		// The agents' tabs wait for their use and grace to end.
		#expect(store.state.tabUnloading.releasing == Self.tabs(2, 3))
		// Their video PiP closes with the window all the same (DEV-1128).
		#expect(engine.endedPictureInPicture.value == Self.tabs(1, 2, 3, 4, 5))
	}

	/// A tab in an agent's grace when its window closed waits, and unloads on the first minute
	/// after the grace ends.
	@Test
	internal func aTabInAnAgentsGraceUnloadsOnceTheGraceEnds() async {
		let engine = FakePages(loaded: [1, 2])
		let clock = TestClock()
		let start = Self.now
		let graceEnded = start.addingTimeInterval(TabUnloadPolicy.agentGrace)
		let now = LockIsolated(start)
		var state = state()
		state.tabUnloading.agentActivity[Self.tab(2)] = start.addingTimeInterval(-60)
		let store = store(state, engine: engine) {
			$0.continuousClock = clock
			$0.date = .init { now.value }
		}

		await store.send(.ui(.closeWindow))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(engine.unloaded(.windowClosed) == Self.tabs(1))
		#expect(store.state.tabUnloading.releasing == Self.tabs(2))

		now.setValue(graceEnded)
		await store.send(.unloadIdleTabs)
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(engine.unloaded(.windowClosed) == Self.tabs(1, 2))
		#expect(store.state.tabUnloading.releasing.isEmpty)
	}

	/// The window left open moving to the closed window's space holds its tabs again.
	@Test
	internal func aWindowMovingToTheClosedWindowsSpaceKeepsItsTabs() async {
		let engine = FakePages(loaded: [1, 2, 3, 4, 5], kept: [4, 5])
		let clock = TestClock()
		var state = state()
		state.windows.append(window(showing: Self.home, tab: 4))
		let store = store(state, engine: engine) { $0.continuousClock = clock }

		await store.send(.ui(.closeAdditionalWindow(Self.other)))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(store.state.tabUnloading.releasing == Self.tabs(4, 5))

		await store.send(.main(.sidebar(.ui(.spaceSelected(Self.home)))))
		await store.receive(\.releaseWindowlessTabs)
		await clock.run(timeout: Self.patience)

		#expect(store.state.tabUnloading.releasing.isEmpty)
		#expect(engine.calls.value.filter { $0.id == Self.tab(4) }.count == 1)
	}

	/// A waiting tab moved into the open window's space stays loaded.
	@Test
	internal func aTabMovedIntoAnOpenWindowsSpaceStopsWaiting() async {
		let engine = FakePages(loaded: [1, 2, 3, 4, 5], kept: [4, 5])
		let clock = TestClock()
		var state = state()
		state.windows.append(window(showing: Self.home, tab: 4))
		let store = store(state, engine: engine) { $0.continuousClock = clock }

		await store.send(.ui(.closeAdditionalWindow(Self.other)))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(store.state.tabUnloading.releasing == Self.tabs(4, 5))

		// As an approved change from Settings or an agent moves it.
		let previous = store.state.workspace
		var moved = previous
		moved.spaces[id: Self.home]?.unpinnedTabs.removeAll { $0 == Self.tab(5) }
		moved.spaces[id: Self.work]?.unpinnedTabs.append(Self.tab(5))
		await store.send(.event(.organizationChangeApproved(previous, moved, [])))
		await store.receive(\.releaseWindowlessTabs)

		#expect(store.state.tabUnloading.releasing == Self.tabs(4))
	}

	/// A window opened after a release was reduced, before its task ran, keeps its tabs: the
	/// release read the holds before it opened.
	@Test
	internal func aWindowOpenedBeforeTheReleaseRunsKeepsItsTabs() async {
		let engine = FakePages(loaded: [1, 2, 3])
		let store = Store(initialState: state()) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.date = .constant(Self.now)
			$0.browserEngine.tabUnloadingIsAvailable = { true }
			$0.browserEngine.snapshot = { id in engine.snapshot(id) }
			$0.browserEngine.unloadTab = { id, reason in engine.unload(id, reason: reason) }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}

		let close = store.send(.ui(.closeWindow))
		store.send(.ui(.openWindow))
		await close.finish()

		#expect(engine.calls.value.isEmpty)
		#expect(store.tabUnloading.releasing.isEmpty)
	}

	@Test
	internal func quittingReleasesNothing() async {
		let engine = FakePages(loaded: [1, 2])
		var state = state()
		state.checkingQuit = true
		let store = store(state, engine: engine)

		await store.send(.ui(.closeWindow))

		#expect(engine.calls.value.isEmpty)
	}

	@Test
	internal func headlessRunsReleaseNothing() async {
		let engine = FakePages(loaded: [1, 2])
		var state = state()
		state.tabUnloading.isRunning = false
		let store = store(state, engine: engine)

		await store.send(.ui(.closeWindow))

		#expect(engine.calls.value.isEmpty)
	}

	// MARK: - Kept pages

	@Test
	internal func aPageTheEngineKeepsIsAskedAgainAFewTimes() async {
		let engine = FakePages(loaded: [1, 2], kept: [2])
		let clock = TestClock()
		let store = store(state(), engine: engine) { $0.continuousClock = clock }

		await store.send(.ui(.closeWindow))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(store.state.tabUnloading.releasing == Self.tabs(2))

		for delay in TabUnloading.releaseRetryDelays {
			await sleeping(on: clock)
			await clock.advance(by: delay)
			await store.receive(\.releaseWindowlessTabs)
			await store.receive(\.event.windowlessTabsReleased)
		}
		await clock.run(timeout: Self.patience)

		// The first release, then one per retry; tab 1 unloaded the first time.
		#expect(engine.calls.value.filter { $0.id == Self.tab(2) }.count == 1 + TabUnloading.releaseRetryDelays.count)
		#expect(engine.calls.value.filter { $0.id == Self.tab(1) }.count == 1)
		#expect(store.state.tabUnloading.releasing == Self.tabs(2))
	}

	/// A page still loading when the retries ran out is asked again once it settles.
	@Test
	internal func aKeptPageIsAskedAgainWhenItSettles() async throws {
		let engine = FakePages(loaded: [1, 2], kept: [2])
		let clock = TestClock()
		let store = store(state(), engine: engine) { $0.continuousClock = clock }
		let url = try #require(URL(string: "https://example.com/slow"))

		await store.send(.ui(.closeWindow))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)
		for delay in TabUnloading.releaseRetryDelays {
			await sleeping(on: clock)
			await clock.advance(by: delay)
			await store.receive(\.releaseWindowlessTabs)
			await store.receive(\.event.windowlessTabsReleased)
		}
		engine.stopKeeping(Self.tab(2))

		// Another page settling changes nothing.
		await store.send(.event(.pageSettled(Self.tab(1), .init(url: url, title: "Other"))))
		#expect(engine.calls.value.filter { $0.id == Self.tab(2) }.count == 1 + TabUnloading.releaseRetryDelays.count)

		await store.send(.event(.pageSettled(Self.tab(2), .init(url: url, title: "Slow"))))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(engine.unloaded(.windowClosed) == Self.tabs(1, 2))
		#expect(store.state.tabUnloading.releasing.isEmpty)
	}

	/// The Page PiP of a window that moved to another space before closing unloads too.
	@Test
	internal func aClosedWindowsPagePiPFromAnotherSpaceUnloads() async {
		let engine = FakePages(loaded: [1, 2, 3, 4, 5])
		var state = state()
		state.windows.append(window(showing: Self.work, tab: 3))
		state.pagePictureInPicture = .init(tabID: Self.tab(4), windowID: Self.other, phase: .open)
		let store = store(state, engine: engine)

		await store.send(.ui(.closeAdditionalWindow(Self.other)))
		await store.receive(\.ui.closePagePictureInPicture)
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		// Main still shows the window's space; tab 4 was home's.
		#expect(engine.unloaded(.windowClosed) == Self.tabs(4))
	}

	/// Page PiP closes with the window that owns its tab (Max's decision), and its page unloads
	/// once the floating window lets it go.
	@Test
	internal func closingTheWindowEndsItsPagePiPThenUnloadsThePage() async {
		// The floating window still holds tab 2's view until it closes.
		let engine = FakePages(loaded: [1, 2], kept: [2])
		let clock = TestClock()
		var state = state()
		state.pagePictureInPicture = .init(tabID: Self.tab(2), windowID: state.main.id, phase: .open)
		let store = store(state, engine: engine) { $0.continuousClock = clock }

		await store.send(.ui(.closeWindow))
		await store.receive(\.ui.closePagePictureInPicture)
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(store.state.pagePictureInPicture?.phase == .returning(focusesTab: false))
		#expect(engine.calls.value.contains(.init(id: Self.tab(2), reason: .windowClosed)))
		#expect(store.state.tabUnloading.releasing == Self.tabs(2))

		engine.stopKeeping(Self.tab(2))
		await store.send(.event(.pagePictureInPictureClosed(Self.tab(2))))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(store.state.pagePictureInPicture == nil)
		#expect(store.state.tabUnloading.releasing.isEmpty)
		#expect(store.state.tabUnloading.unloaded == Self.tabs(1, 2))
	}

	@Test
	internal func pagePiPFromAnotherWindowKeepsFloating() async {
		let engine = FakePages(loaded: [1, 2, 3, 4, 5])
		var state = state()
		state.windows.append(window(showing: Self.home, tab: 4))
		state.pagePictureInPicture = .init(tabID: Self.tab(2), windowID: state.main.id, phase: .open)
		let store = store(state, engine: engine)

		await store.send(.ui(.closeAdditionalWindow(Self.other)))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(store.state.pagePictureInPicture?.phase == .open)
		#expect(engine.unloaded(.windowClosed) == Self.tabs(4, 5))
	}

	/// Another window on the same space closing leaves the PiP of a window still open alone.
	@Test
	internal func pagePiPOfAnOpenWindowOnTheClosedWindowsSpaceKeepsFloating() async {
		let engine = FakePages(loaded: [1, 2, 3])
		var state = state()
		state.windows.append(window(showing: Self.work, tab: 2))
		state.pagePictureInPicture = .init(tabID: Self.tab(3), windowID: state.main.id, phase: .open)
		let store = store(state, engine: engine)

		await store.send(.ui(.closeAdditionalWindow(Self.other)))
		await store.receive(\.releaseWindowlessTabs)

		#expect(store.state.pagePictureInPicture?.phase == .open)
		#expect(engine.calls.value.isEmpty)
	}

	@Test
	internal func openingAWindowForgetsThePagesWaitingToUnload() async {
		let engine = FakePages(loaded: [1, 2], kept: [2])
		let clock = TestClock()
		let store = store(state(), engine: engine) { $0.continuousClock = clock }

		await store.send(.ui(.closeWindow))
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(store.state.tabUnloading.releasing == Self.tabs(2))

		await store.send(.ui(.openWindow))
		#expect(store.state.tabUnloading.releasing.isEmpty)

		await clock.run(timeout: Self.patience)
		#expect(engine.calls.value.filter { $0.id == Self.tab(2) }.count == 1)
	}

	// MARK: - Fixture

	/// Waits until an effect sleeps on the clock, so advancing it can't pass the retry's wait
	/// before the retry's task has started it: a starved task can take longer than the yields
	/// `advance` gives it.
	private func sleeping(on clock: TestClock<Duration>) async {
		let deadline = ContinuousClock.now.advanced(by: Self.patience)
		while ContinuousClock.now < deadline {
			do {
				try await clock.checkSuspension()
			} catch {
				return
			}
			try? await Task.sleep(for: .milliseconds(5))
		}
		Issue.record("Nothing slept on the test clock within \(Self.patience)")
	}

	private func state() -> AppFeature.State {
		let tabs: [BrowserCore.Tab] = (1...5).map { value in
			.init(
				id: Self.tab(value),
				profileID: Self.profile,
				restoration: .init(title: "Tab \(value)", url: URL(string: "https://capturecontext.dev/\(value)")!)
			)
		}
		let organization = BrowserOrganization(
			profiles: [.init(id: Self.profile, name: "Default")],
			spaces: [
				.init(
					id: Self.work,
					profileID: Self.profile,
					name: "Work",
					savedItems: [.tab(Self.tab(2))],
					unpinnedTabs: [Self.tab(1), Self.tab(3)],
					selectedTabID: Self.tab(1)
				),
				.init(
					id: Self.home,
					profileID: Self.profile,
					name: "Home",
					unpinnedTabs: [Self.tab(4), Self.tab(5)],
					selectedTabID: Self.tab(4)
				),
			],
			tabs: tabs
		)
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: Self.work))
		}
		state.main.viewer.item = .init(tab: tabs[0])
		state.tabUnloading.isRunning = true
		return state
	}

	private func window(
		showing space: Space.ID,
		tab value: Int
	) -> MainFeature.State {
		var window = MainFeature.State(organization: state().workspace, spaceID: space, id: Self.other)
		window.viewer.item = .init(tab: state().workspace.tabs[id: Self.tab(value)])
		return window
	}

	private func store(
		_ state: AppFeature.State,
		engine: FakePages,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.date = .constant(Self.now)
			$0.browserEngine.tabUnloadingIsAvailable = { true }
			$0.browserEngine.snapshot = { id in engine.snapshot(id) }
			$0.browserEngine.unloadTab = { id, reason in engine.unload(id, reason: reason) }
			$0.browserEngine.endPictureInPicture = { id in engine.endPictureInPicture(id) }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.timeout = Self.patience
		return store
	}
}

/// The engine's pages: loaded or unloaded, and the ones it keeps loaded.
private final class FakePages: Sendable {
	struct Call: Equatable, Sendable {
		let id: BrowserCore.Tab.ID
		let reason: TabUnloadReason
	}

	let calls: LockIsolated<[Call]> = .init([])

	/// The tabs whose video or document PiP the engine was asked to end (DEV-1128).
	let endedPictureInPicture: LockIsolated<Set<BrowserCore.Tab.ID>> = .init([])
	private let pages: LockIsolated<[BrowserCore.Tab.ID: Bool]>
	private let kept: LockIsolated<Set<BrowserCore.Tab.ID>>

	init(
		loaded: Set<Int>,
		kept: Set<Int> = []
	) {
		var pages: [BrowserCore.Tab.ID: Bool] = [:]
		for value in loaded { pages[.init(rawValue: UUID(value))] = false }
		let initial = pages
		self.pages = .init(initial)
		self.kept = .init(Set(kept.map { .init(rawValue: UUID($0)) }))
	}

	func unloaded(_ reason: TabUnloadReason) -> Set<BrowserCore.Tab.ID> {
		Set(calls.value.filter { $0.reason == reason && pages.value[$0.id] == true }.map(\.id))
	}

	func endPictureInPicture(_ id: BrowserCore.Tab.ID) {
		endedPictureInPicture.withValue { _ = $0.insert(id) }
	}

	func stopKeeping(_ id: BrowserCore.Tab.ID) {
		kept.withValue { _ = $0.remove(id) }
	}

	func snapshot(_ id: BrowserCore.Tab.ID) -> BrowserSessionSnapshot? {
		pages.value[id].map { .init(navigation: .init(isUnloaded: $0), revision: 1) }
	}

	func unload(
		_ id: BrowserCore.Tab.ID,
		reason: TabUnloadReason
	) -> TabUnloadOutcome {
		calls.withValue { $0.append(.init(id: id, reason: reason)) }
		guard let unloaded = pages.value[id] else { return .unavailable }
		guard !unloaded else { return .alreadyUnloaded }
		guard !kept.value.contains(id) else { return .kept }

		pages.withValue { $0[id] = true }
		return .unloaded
	}
}
