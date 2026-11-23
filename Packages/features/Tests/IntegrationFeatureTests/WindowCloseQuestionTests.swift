import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1107: closing an ordinary window asks the pages it would release that hold unsaved input,
/// while it's still open. Leave closes it and unloads them with the others; Stay keeps it open.
@Suite(.dependencies)
@MainActor
internal struct WindowCloseQuestionTests {
	private static let now: Date = .init(timeIntervalSinceReferenceDate: 2_000_000)
	private static let profile: Profile.ID = .init(rawValue: UUID(0))
	private static let work: Space.ID = .init(rawValue: UUID(100))
	private static let home: Space.ID = .init(rawValue: UUID(101))
	private static let other: UUID = .init(200)
	private static let patience: Duration = .seconds(10)
	private let document: WorkspaceDocument = .unsaved()

	private static func tab(_ value: Int) -> BrowserCore.Tab.ID {
		.init(rawValue: UUID(value))
	}

	private static func tabs(_ values: Int...) -> Set<BrowserCore.Tab.ID> {
		Set(values.map(tab))
	}

	@Test
	internal func leaveClosesTheLastWindowAndUnloadsThePagesItAsked() async {
		let engine = AskingPages(loaded: [1, 2, 3, 4, 5], unsaved: [3, 5])
		let store = store(state(), engine: engine)

		await store.send(.ui(.requestCloseWindow(store.state.main.id)))
		#expect(store.state.windowIsOpen)
		// The window stays whole while it asks.
		#expect(!store.state.main.isClosing)
		await store.receive(\.event.windowCloseDecision)
		await store.receive(\.ui.closeWindow)
		await store.receive(\.releaseWindowlessTabs)
		await store.receive(\.event.windowlessTabsReleased)

		// Only the pages holding unsaved input were asked, in the workspace's order.
		#expect(engine.asked.value == [Self.tab(3), Self.tab(5)])
		#expect(!store.state.windowIsOpen)
		#expect(!store.state.main.isClosing)
		#expect(store.state.windowCloseRequests.isEmpty)
		#expect(engine.unloadedTabs == Self.tabs(1, 2, 3, 4, 5))
		#expect(engine.reasons(of: Self.tabs(3, 5)) == [.windowClosedAnswered])
		#expect(engine.reasons(of: Self.tabs(1, 2, 4)) == [.windowClosed])
		#expect(store.state.tabUnloading.answered.isEmpty)
		#expect(store.state.tabUnloading.releasing.isEmpty)
	}

	@Test
	internal func stayKeepsTheWindowOpenAndItsPagesLoaded() async {
		let engine = AskingPages(loaded: [1, 2, 3, 4, 5], unsaved: [3, 5], refusing: [3])
		let store = store(state(), engine: engine)

		await store.send(.ui(.requestCloseWindow(store.state.main.id)))
		await store.receive(\.event.windowCloseDecision)

		// The first refusal ends the close: the next page isn't asked.
		#expect(engine.asked.value == [Self.tab(3)])
		#expect(store.state.windowIsOpen)
		#expect(store.state.windowCloseRequests.isEmpty)
		#expect(store.state.tabUnloading.answered.isEmpty)
		#expect(engine.calls.value.isEmpty)

		// A second close asks again, and Leave closes it then.
		engine.refusing.setValue([])
		await store.send(.ui(.requestCloseWindow(store.state.main.id)))
		await store.receive(\.event.windowCloseDecision)
		await store.receive(\.ui.closeWindow)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(!store.state.windowIsOpen)
		#expect(engine.unloadedTabs == Self.tabs(1, 2, 3, 4, 5))
	}

	@Test
	internal func aWindowWithoutUnsavedInputClosesWithoutAsking() async {
		let engine = AskingPages(loaded: [1, 2, 3, 4, 5], unsaved: [])
		let store = store(state(), engine: engine)

		await store.send(.ui(.requestCloseWindow(store.state.main.id)))
		await store.receive(\.event.windowCloseDecision)
		await store.receive(\.ui.closeWindow)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(engine.asked.value.isEmpty)
		#expect(!store.state.windowIsOpen)
		#expect(engine.reasons(of: Self.tabs(1, 2, 3, 4, 5)) == [.windowClosed])
	}

	@Test
	internal func anAdditionalWindowAsksOnlyThePagesItReleases() async {
		// Tab 2 is the main window's space, which stays open.
		let engine = AskingPages(loaded: [1, 2, 3, 4, 5], unsaved: [2, 4])
		var state = state()
		state.windows.append(window(showing: Self.home, tab: 4))
		let store = store(state, engine: engine)

		await store.send(.ui(.requestCloseWindow(Self.other)))
		#expect(store.state.windowCloseRequests[Self.other] != nil)
		await store.receive(\.event.windowCloseDecision)
		await store.receive(\.ui.closeAdditionalWindow)
		await store.receive(\.event.windowlessTabsReleased)

		// Its pane's tab first.
		#expect(engine.asked.value == [Self.tab(4)])
		#expect(store.state.windows.isEmpty)
		#expect(store.state.windowIsOpen)
		#expect(engine.unloadedTabs == Self.tabs(4, 5))
		#expect(engine.reasons(of: Self.tabs(4)) == [.windowClosedAnswered])
		#expect(engine.calls.value.allSatisfy { $0.id != Self.tab(2) })
	}

	@Test
	internal func anAnsweredPageAnAgentKeepsUnloadsWithItsAnswerLater() async {
		let engine = AskingPages(loaded: [1, 2, 3], unsaved: [3])
		let start = Self.now
		let graceEnded = start.addingTimeInterval(TabUnloadPolicy.agentGrace)
		var state = state()
		state.tabUnloading.agentActivity[Self.tab(3)] = start.addingTimeInterval(-60)
		let now = LockIsolated(start)
		let store = store(state, engine: engine) {
			$0.continuousClock = TestClock()
			$0.date = .init { now.value }
		}

		await store.send(.ui(.requestCloseWindow(store.state.main.id)))
		await store.receive(\.event.windowCloseDecision)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(store.state.tabUnloading.releasing == Self.tabs(3))
		#expect(store.state.tabUnloading.answered == [Self.tab(3): 1])

		now.setValue(graceEnded)
		await store.send(.unloadIdleTabs)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(engine.reasons(of: Self.tabs(3)) == [.windowClosedAnswered])
		#expect(engine.unloadedTabs.contains(Self.tab(3)))
		#expect(store.state.tabUnloading.answered.isEmpty)
	}

	@Test
	internal func anAnswerDoesNotCoverTheNextDocument() async {
		let engine = AskingPages(loaded: [1, 2, 3], unsaved: [3])
		let start = Self.now
		let graceEnded = start.addingTimeInterval(TabUnloadPolicy.agentGrace)
		var state = state()
		state.tabUnloading.agentActivity[Self.tab(3)] = start.addingTimeInterval(-60)
		let now = LockIsolated(start)
		let store = store(state, engine: engine) {
			$0.continuousClock = TestClock()
			$0.date = .init { now.value }
		}

		await store.send(.ui(.requestCloseWindow(store.state.main.id)))
		await store.receive(\.event.windowCloseDecision)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(store.state.tabUnloading.answered == [Self.tab(3): 1])

		// An agent took the page to another document while it kept it loaded.
		let navigated: [BrowserCore.Tab.ID: UInt64] = [Self.tab(3): 2]
		engine.documents.setValue(navigated)
		now.setValue(graceEnded)
		await store.send(.unloadIdleTabs)
		await store.receive(\.event.windowlessTabsReleased)

		#expect(engine.reasons(of: Self.tabs(3)) == [.windowClosed])
		#expect(!engine.unloadedTabs.contains(Self.tab(3)))
	}

	@Test
	internal func openingAWindowForgetsTheAnswers() async {
		let engine = AskingPages(loaded: [1, 2, 3], unsaved: [3])
		var state = state()
		state.automation.developerLogs[Self.tab(3)] = UUID(9)
		let store = store(state, engine: engine) { $0.continuousClock = TestClock() }

		await store.send(.ui(.requestCloseWindow(store.state.main.id)))
		await store.receive(\.event.windowCloseDecision)
		await store.receive(\.event.windowlessTabsReleased)
		#expect(store.state.tabUnloading.answered == [Self.tab(3): 1])

		await store.send(.ui(.openWindow))
		#expect(store.state.tabUnloading.answered.isEmpty)
		#expect(store.state.tabUnloading.releasing.isEmpty)
	}

	@Test
	internal func aPrivateWindowKeepsItsOwnClose() async {
		let engine = AskingPages(loaded: [1], unsaved: [1])
		var state = state()
		var window = MainFeature.State(organization: state.workspace, spaceID: Self.home, isPrivate: true, id: Self.other)
		window.viewer.item = .init(tab: state.workspace.tabs[id: Self.tab(4)])
		state.windows.append(window)
		let store = store(state, engine: engine)

		await store.send(.ui(.requestCloseWindow(Self.other)))
		await store.receive(\.ui.closeAdditionalWindow)
		await store.receive(\.ui.requestClosePrivateWindow)
		#expect(store.state.windowCloseRequests.isEmpty)
	}

	// MARK: - Fixture

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
		engine: AskingPages,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.date = .constant(Self.now)

			// The private window's own close.
			$0.uuid = .incrementing
						$0.browserEngine.tabUnloadingIsAvailable = { true }
			$0.browserEngine.snapshot = { id in engine.snapshot(id) }
			$0.browserEngine.unloadTab = { id, reason in engine.unload(id, reason: reason) }
			$0.browserEngine.tabHoldsUnsavedInput = { id in engine.holdsUnsavedInput(id) }
			$0.browserEngine.permitsClosing = { id in engine.permitsClosing(id) }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.timeout = Self.patience
		return store
	}
}

/// The engine's pages: loaded or unloaded, those holding unsaved input, which a closed window's
/// unload keeps unless answered, and those whose before-unload question the person answers Stay.
private final class AskingPages: Sendable {
	struct Call: Equatable, Sendable {
		let id: BrowserCore.Tab.ID
		let reason: TabUnloadReason
	}

	let calls: LockIsolated<[Call]> = .init([])
	let asked: LockIsolated<[BrowserCore.Tab.ID]> = .init([])
	let refusing: LockIsolated<Set<BrowserCore.Tab.ID>>

	/// Each loaded page's document; 1 unless a test navigates it.
	let documents: LockIsolated<[BrowserCore.Tab.ID: UInt64]> = .init([:])
	private let pages: LockIsolated<[BrowserCore.Tab.ID: Bool]>
	private let unsaved: Set<BrowserCore.Tab.ID>

	init(
		loaded: Set<Int>,
		unsaved: Set<Int>,
		refusing: Set<Int> = []
	) {
		var pages: [BrowserCore.Tab.ID: Bool] = [:]
		for value in loaded { pages[.init(rawValue: UUID(value))] = false }
		let initial = pages
		self.pages = .init(initial)
		self.unsaved = Set(unsaved.map { .init(rawValue: UUID($0)) })
		self.refusing = .init(Set(refusing.map { .init(rawValue: UUID($0)) }))
	}

	var unloadedTabs: Set<BrowserCore.Tab.ID> {
		Set(pages.value.filter(\.value).keys)
	}

	/// The distinct reasons the engine was asked to unload these tabs for.
	func reasons(of ids: Set<BrowserCore.Tab.ID>) -> Set<TabUnloadReason> {
		Set(calls.value.filter { ids.contains($0.id) }.map(\.reason))
	}

	func holdsUnsavedInput(_ id: BrowserCore.Tab.ID) -> Bool {
		unsaved.contains(id) && pages.value[id] == false
	}

	func permitsClosing(_ id: BrowserCore.Tab.ID) -> Bool {
		asked.withValue { $0.append(id) }
		return !refusing.value.contains(id)
	}

	func snapshot(_ id: BrowserCore.Tab.ID) -> BrowserSessionSnapshot? {
		pages.value[id].map {
			.init(navigation: .init(isUnloaded: $0), revision: 1, documentRevision: $0 ? nil : documents.value[id] ?? 1)
		}
	}

	func unload(
		_ id: BrowserCore.Tab.ID,
		reason: TabUnloadReason
	) -> TabUnloadOutcome {
		calls.withValue { $0.append(.init(id: id, reason: reason)) }
		guard let unloaded = pages.value[id] else { return .unavailable }
		guard !unloaded else { return .alreadyUnloaded }
		guard reason == .windowClosedAnswered || !unsaved.contains(id) else { return .kept }

		pages.withValue { $0[id] = true }
		return .unloaded
	}
}
