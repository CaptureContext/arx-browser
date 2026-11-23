import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import Foundation
import MemoryPressureClient
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-873: hidden tabs unload after Settings' delay, and right away under critical memory
/// pressure, never the shown, selected or agent-used ones; their rows look unloaded until shown.
@Suite(.dependencies)
@MainActor
internal struct TabUnloadingTests {
	private static let now: Date = .init(timeIntervalSinceReferenceDate: 2_000_000)
	private static let profile: Profile.ID = .init(rawValue: UUID(0))
	private static let space: Space.ID = .init(rawValue: UUID(100))
	private let document: WorkspaceDocument = .unsaved()

	private static func tab(_ value: Int) -> BrowserCore.Tab.ID {
		.init(rawValue: UUID(value))
	}

	// MARK: - Timeout

	@Test
	internal func aSweepUnloadsOnlyHiddenTabsPastTheDelay() async {
		let engine = FakeEngine(loaded: [1, 2, 3, 4], unloaded: [])
		var state = state()
		state.tabUnloading.hiddenSince = [
			Self.tab(1): Self.now.addingTimeInterval(-24 * 60 * 60),
			Self.tab(2): Self.now.addingTimeInterval(-7 * 60 * 60),
			Self.tab(3): Self.now.addingTimeInterval(-60 * 60),
			Self.tab(4): Self.now.addingTimeInterval(-7 * 60 * 60),
		]

		// An agent's client keeps tab 4's logs.
		state.automation.developerLogs[Self.tab(4)] = UUID(9)
		let store = store(state, engine: engine)

		await store.send(.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)

		// Tab 1 is shown, tab 3 hasn't been hidden six hours, tab 4 is in an agent's use and
		// tab 5 has no page.
		expectNoDifference(engine.calls.value, [.init(id: Self.tab(2), reason: .inactive)])
		#expect(store.state.tabUnloading.unloaded == [Self.tab(2)])
		#expect(store.state.main.sidebar.unloadedTabs == [Self.tab(2)])
		#expect(store.state.main.sidebar.tabItem(Self.tab(2))?.isUnloaded == true)
		#expect(store.state.main.sidebar.tabItem(Self.tab(3))?.isUnloaded == false)
		// Loaded hidden tabs keep their clocks; unloaded and unopened ones have none.
		#expect(Set(store.state.tabUnloading.hiddenSince.keys) == [Self.tab(3), Self.tab(4)])
	}

	@Test
	internal func aLoadedHiddenTabWithoutAClockStartsOneAndWaits() async {
		let engine = FakeEngine(loaded: [1, 2], unloaded: [])
		let store = store(state(), engine: engine)

		await store.send(.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)

		#expect(engine.calls.value.isEmpty)
		#expect(store.state.tabUnloading.hiddenSince == [Self.tab(2): Self.now])
	}

	@Test
	internal func onlyWhenMemoryRunsLowKeepsTabsLoadedHoweverLongHidden() async {
		let engine = FakeEngine(loaded: [1, 2], unloaded: [])
		var state = state(delay: .never)
		state.tabUnloading.hiddenSince = [Self.tab(2): Self.now.addingTimeInterval(-30 * 24 * 60 * 60)]
		let store = store(state, engine: engine)

		await store.send(.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)

		#expect(engine.calls.value.isEmpty)
	}

	@Test
	internal func aTabTheEngineKeepsStaysLoaded() async {
		let engine = FakeEngine(loaded: [1, 2], unloaded: [], kept: [2])
		var state = state()
		state.tabUnloading.hiddenSince = [Self.tab(2): Self.now.addingTimeInterval(-7 * 60 * 60)]
		let store = store(state, engine: engine)

		await store.send(.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)

		expectNoDifference(engine.calls.value, [.init(id: Self.tab(2), reason: .inactive)])
		#expect(store.state.tabUnloading.unloaded.isEmpty)
		#expect(store.state.tabUnloading.hiddenSince[Self.tab(2)] != nil)
	}

	// MARK: - Memory pressure

	@Test
	internal func criticalPressureUnloadsEveryHiddenTabPastTheGraceRightAway() async {
		let engine = FakeEngine(loaded: [1, 2, 3, 4], unloaded: [])
		var state = state()
		state.tabUnloading.hiddenSince = [
			Self.tab(2): Self.now.addingTimeInterval(-2 * 60),
			Self.tab(3): Self.now.addingTimeInterval(-30),
			Self.tab(4): Self.now.addingTimeInterval(-10 * 60),
		]
		let store = store(state, engine: engine)

		await store.send(.event(.memoryPressureChanged(.warning)))
		#expect(engine.calls.value.isEmpty)

		await store.send(.event(.memoryPressureChanged(.critical)))
		await store.receive(\.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)

		// Longest hidden first; tab 3 was hidden too recently, tab 1 is shown.
		expectNoDifference(engine.calls.value, [
			.init(id: Self.tab(4), reason: .memoryPressure),
			.init(id: Self.tab(2), reason: .memoryPressure),
		])
		#expect(store.state.tabUnloading.unloaded == [Self.tab(2), Self.tab(4)])

		// Staying critical doesn't start another sweep of its own; the minute sweep keeps going.
		await store.send(.event(.memoryPressureChanged(.critical)))
		await store.send(.event(.memoryPressureChanged(.normal)))
		#expect(store.state.tabUnloading.memoryPressure == .normal)
	}

	/// DEV-873: Settings › Advanced › Memory's grace decides how long low memory waits.
	@Test
	internal func lowMemoryWaitsForTheGraceSettingsChoose() async {
		let engine = FakeEngine(loaded: [1, 2, 3], unloaded: [])
		var state = state()
		state.settings.$general.withLock { $0.tabUnloadPressureGrace = .fiveMinutes }
		state.tabUnloading.hiddenSince = [
			Self.tab(2): Self.now.addingTimeInterval(-2 * 60),
			Self.tab(3): Self.now.addingTimeInterval(-6 * 60),
		]
		let store = store(state, engine: engine)

		await store.send(.event(.memoryPressureChanged(.critical)))
		await store.receive(\.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)
		expectNoDifference(engine.calls.value, [.init(id: Self.tab(3), reason: .memoryPressure)])

		await store.send(.settings(.ui(.tabUnloadPressureGrace(.oneMinute))))
		#expect(store.state.settings.general.tabUnloadPressureGrace == .oneMinute)
		#expect(document.preferences.tabUnloadPressureGrace == .oneMinute)
		await store.send(.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)
		expectNoDifference(engine.calls.value, [
			.init(id: Self.tab(3), reason: .memoryPressure),
			.init(id: Self.tab(2), reason: .memoryPressure),
		])
	}

	@Test
	internal func startingListensToMemoryPressure() async {
		let engine = FakeEngine(loaded: [1, 2], unloaded: [])
		var state = state()
		state.tabUnloading.hiddenSince = [Self.tab(2): Self.now.addingTimeInterval(-5 * 60)]
		let levels = AsyncStream.makeStream(of: MemoryPressureLevel.self)
		let clock = TestClock()
		let store = store(state, engine: engine) {
			$0.memoryPressure = .init(levels: { levels.stream })
			$0.continuousClock = clock
		}

		let start = await store.send(.startTabUnloading)
		levels.continuation.yield(.critical)
		await store.receive(\.event.memoryPressureChanged)
		await store.receive(\.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)
		expectNoDifference(engine.calls.value, [.init(id: Self.tab(2), reason: .memoryPressure)])

		await clock.advance(by: TabUnloadPolicy.sweepInterval)
		await store.receive(\.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)

		levels.continuation.finish()
		await start.cancel()
	}

	// MARK: - Showing

	@Test
	internal func showingAnUnloadedTabClearsItsLookAndStartsTheOtherTabsClock() async {
		let engine = FakeEngine(loaded: [1], unloaded: [2])
		var state = state()
		state.tabUnloading.isRunning = true
		state.tabUnloading.unloaded = [Self.tab(2)]
		state.main.sidebar.unloadedTabs = [Self.tab(2)]
		let store = store(state, engine: engine)
		let shown = store.state.workspace.tabs[id: Self.tab(2)]

		await store.send(.main(.viewer(.item(.show(shown)))))

		#expect(store.state.tabUnloading.unloaded.isEmpty)
		#expect(store.state.main.sidebar.unloadedTabs.isEmpty)
		#expect(store.state.tabUnloading.hiddenSince[Self.tab(1)] == Self.now)
		#expect(store.state.tabUnloading.hiddenSince[Self.tab(2)] == nil)
	}

	/// A tab shown right after a sweep was reduced, before the sweep's task registered its
	/// cancellable, stays loaded: the sweep reports in with facts older than the store's and is
	/// cancelled (DEV-606).
	@Test
	internal func aTabShownBeforeTheSweepRunsStaysLoaded() async {
		let engine = FakeEngine(loaded: [1, 2], unloaded: [])
		var state = state()
		state.tabUnloading.isRunning = true
		state.tabUnloading.hiddenSince = [Self.tab(2): Self.now.addingTimeInterval(-24 * 60 * 60)]
		let shown = state.workspace.tabs[id: Self.tab(2)]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.date = .constant(Self.now)
			$0.browserEngine.tabUnloadingIsAvailable = { true }
			$0.browserEngine.snapshot = { id in engine.snapshot(id) }
			$0.browserEngine.unloadTab = { id, reason in engine.unload(id, reason: reason) }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}

		let sweep = store.send(.unloadIdleTabs)
		store.send(.main(.viewer(.item(.show(shown)))))
		await sweep.finish()

		#expect(engine.calls.value.isEmpty)
		#expect(store.tabUnloading.unloaded.isEmpty)
	}

	// MARK: - Agents

	@Test
	internal func tabsAnAgentActsOnAreInUseAndStayProtectedForAWhile() async {
		var state = state()
		let request = AutomationRequest(
			id: UUID(20),
			clientID: UUID(21),
			sessionID: UUID(22),
			operation: .load(.init(targetID: Self.tab(3).rawValue, expectedRevision: ""))
		)
		state.automation.pending[request.id] = .init(request: request, grantRevision: UUID(23))
		state.automation.developerLogs[Self.tab(4)] = UUID(21)
		#expect(state.tabsInAgentUse == [Self.tab(3), Self.tab(4)])

		state.automation.pending = [:]
		state.automation.developerLogs = [:]
		state.tabUnloading.agentActivity[Self.tab(3)] = Self.now.addingTimeInterval(-60)
		state.tabUnloading.agentActivity[Self.tab(4)] = Self.now.addingTimeInterval(-TabUnloadPolicy.agentGrace)
		let facts = Dictionary(
			uniqueKeysWithValues: state.tabUnloadCandidates(now: Self.now).map { ($0.id, $0.facts) }
		)
		#expect(facts[Self.tab(3)]?.isInAgentUse == true)
		#expect(facts[Self.tab(4)]?.isInAgentUse == false)
		#expect(facts[Self.tab(1)]?.isOnScreen == true)
		#expect(facts[Self.tab(1)]?.isSelectedInSpace == true)
	}

	// MARK: - Kept loaded (DEV-932)

	@Test(arguments: [false, true])
	internal func sitesTheProfileKeepsNeverUnloadOnTheTimerOrUnderPressure(underPressure: Bool) async {
		let engine = FakeEngine(loaded: [1, 2, 3], unloaded: [])
		var state = state()
		state.workspace.profiles[id: Self.profile]?.keptLoadedSites = ["capturecontext.dev"]
		state.main.sidebar.organization.profiles[id: Self.profile]?.keptLoadedSites = ["capturecontext.dev"]
		state.tabUnloading.hiddenSince = [
			Self.tab(2): Self.now.addingTimeInterval(-24 * 60 * 60),
			Self.tab(3): Self.now.addingTimeInterval(-24 * 60 * 60),
		]
		if underPressure { state.tabUnloading.memoryPressure = .critical }
		let store = store(state, engine: engine)

		await store.send(.unloadIdleTabs)
		await store.receive(\.event.tabUnloadSweepFinished)

		expectNoDifference(engine.calls.value, [])
		let facts = store.state.tabUnloadCandidates(now: Self.now)
		#expect(facts.allSatisfy { $0.facts.isKeptLoaded })
	}

	/// A page that reached a kept site after the candidates were read is checked at its live
	/// address before the sweep unloads anything.
	@Test
	internal func theSweepChecksAPagesLiveAddressAgainstKeptSites() async {
		let engine = FakeEngine(loaded: [2], unloaded: [])
		let candidate = TabUnloadPolicy.Candidate(
			id: Self.tab(2),
			facts: .init(isLoaded: false, isOnScreen: false, isSelectedInSpace: false, isInAgentUse: false, isChat: false),
			hiddenSince: Self.now.addingTimeInterval(-24 * 60 * 60)
		)
		var client = BrowserEngineClient(status: { .ready })
		client.snapshot = { _ in .init(navigation: .init(url: URL(string: "https://music.example.com/now")!), revision: 1) }
		client.unloadTab = { id, reason in engine.unload(id, reason: reason) }

		_ = TabUnloadSweep.run(
			[candidate],
			delay: .oneHour,
			pressureGrace: .thirtySeconds,
			reason: .inactive,
			now: Self.now,
			keptSites: [Self.tab(2): ["example.com"]],
			engine: client
		)
		expectNoDifference(engine.calls.value, [])

		_ = TabUnloadSweep.run(
			[candidate],
			delay: .oneHour,
			pressureGrace: .thirtySeconds,
			reason: .inactive,
			now: Self.now,
			engine: client
		)
		expectNoDifference(engine.calls.value, [.init(id: Self.tab(2), reason: .inactive)])
	}

	@Test
	internal func pinnedTabsAndFavoritesStayLoadedOnlyWhenSettingsSaysSo() async {
		var state = state()
		state.workspace.spaces[id: Self.space]?.unpinnedTabs.removeAll { $0 == Self.tab(2) || $0 == Self.tab(3) }
		state.workspace.spaces[id: Self.space]?.savedItems = [.tab(Self.tab(2))]
		state.workspace.profiles[id: Self.profile]?.favorites = [Self.tab(3)]
		func kept(_ state: AppFeature.State) -> Set<BrowserCore.Tab.ID> {
			Set(state.tabUnloadCandidates(now: Self.now).filter(\.facts.isKeptLoaded).map(\.id))
		}
		#expect(kept(state).isEmpty)

		state.settings.$general.withLock { $0.keepsPinnedTabsLoaded = true }
		#expect(kept(state) == [Self.tab(2), Self.tab(3)])
	}

	@Test
	internal func theTabMenuKeepsItsSiteLoadedAndStopsKeepingIt() async throws {
		var state = state()
		state.workspace.profiles[id: Self.profile]?.keptLoadedSites = ["dev"]
		state.main.sidebar.organization = state.workspace
		let store = store(state, engine: FakeEngine(loaded: [], unloaded: []))
		let row = SidebarItem.ID.tab(Self.tab(2).rawValue)
		#expect(store.state.main.sidebar.tabItem(Self.tab(2))?.keepLoaded == .init(site: "capturecontext.dev", isKept: true))

		// Off drops the parent entry that covered it.
		await store.send(.main(.sidebar(.ui(.sidebar(.setSiteKeptLoaded(row, false))))))
		await store.receive(\.main.delegate.changeOrganization)
		await store.receive(\.delegate.save)
		#expect(store.state.workspace.profiles[id: Self.profile]?.keptLoadedSites == nil)
		#expect(store.state.main.sidebar.tabItem(Self.tab(2))?.keepLoaded?.isKept == false)

		await store.send(.main(.sidebar(.ui(.sidebar(.setSiteKeptLoaded(row, true))))))
		await store.receive(\.main.delegate.changeOrganization)
		await store.receive(\.delegate.save)
		#expect(store.state.workspace.profiles[id: Self.profile]?.keptLoadedSites == ["capturecontext.dev"])
	}

	/// A queued sweep is cancelled when what keeps tabs loaded changes, as this key does.
	@Test
	internal func theKeptLoadedKeyFollowsSitesAndPinnedTabsOnlyWhenTheyCount() async {
		var state = state()
		let initial = state.tabsKeptLoadedKey
		state.workspace.spaces[id: Self.space]?.savedItems = [.tab(Self.tab(2))]

		// Pinning doesn't matter while pinned tabs may unload.
		#expect(state.tabsKeptLoadedKey == initial)

		state.settings.$general.withLock { $0.keepsPinnedTabsLoaded = true }
		let pinned = state.tabsKeptLoadedKey
		#expect(pinned != initial)
		#expect(pinned.pinned == [Self.tab(2)])

		state.workspace.profiles[id: Self.profile]?.keptLoadedSites = ["capturecontext.dev"]
		#expect(state.tabsKeptLoadedKey != pinned)
	}

	@Test
	internal func theSwitchSavesKeepingPinnedTabsLoaded() async {
		let store = store(state(), engine: FakeEngine(loaded: [], unloaded: []))

		await store.send(.settings(.ui(.keepsPinnedTabsLoaded(true))))

		#expect(store.state.settings.general.keepsPinnedTabsLoaded)
	}

	// MARK: - Settings

	@Test
	internal func thePickerSavesTheDelay() async {
		let store = store(state(), engine: FakeEngine(loaded: [], unloaded: []))

		await store.send(.settings(.ui(.tabUnloadDelay(.twoHours))))

		#expect(store.state.settings.general.tabUnloadDelay == .twoHours)
	}

	// MARK: - Fixture

	private func state(delay: TabUnloadDelay = .provisionalDefault) -> AppFeature.State {
		let tabs: [BrowserCore.Tab] = (1...5).map { value in
			.init(
				id: Self.tab(value),
				profileID: Self.profile,
				restoration: .init(title: "Tab \(value)", url: URL(string: "https://capturecontext.dev/\(value)")!)
			)
		}
		let organization = BrowserOrganization(
			profiles: [.init(id: Self.profile, name: "Default")],
			spaces: [.init(
				id: Self.space,
				profileID: Self.profile,
				name: "Work",
				unpinnedTabs: tabs.map(\.id),
				selectedTabID: Self.tab(1)
			)],
			tabs: tabs
		)
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: Self.space))
		}
		state.main.viewer.item = .init(tab: tabs[0])
		state.settings.$general.withLock { $0.tabUnloadDelay = delay }
		return state
	}

	private func store(
		_ state: AppFeature.State,
		engine: FakeEngine,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.date = .constant(Self.now)
			$0.browserEngine.tabUnloadingIsAvailable = { true }
			$0.browserEngine.snapshot = { id in engine.snapshot(id) }
			$0.browserEngine.unloadTab = { id, reason in engine.unload(id, reason: reason) }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}

/// The engine's pages: loaded, unloaded or none.
private final class FakeEngine: Sendable {
	struct Call: Equatable, Sendable {
		let id: BrowserCore.Tab.ID
		let reason: TabUnloadReason
	}

	let calls: LockIsolated<[Call]> = .init([])
	private let pages: LockIsolated<[BrowserCore.Tab.ID: Bool]>
	private let kept: Set<BrowserCore.Tab.ID>

	init(
		loaded: Set<Int>,
		unloaded: Set<Int>,
		kept: Set<Int> = []
	) {
		var pages: [BrowserCore.Tab.ID: Bool] = [:]
		for value in loaded { pages[.init(rawValue: UUID(value))] = false }
		for value in unloaded { pages[.init(rawValue: UUID(value))] = true }
		let initial = pages
		self.pages = .init(initial)
		self.kept = Set(kept.map { .init(rawValue: UUID($0)) })
	}

	func snapshot(_ id: BrowserCore.Tab.ID) -> BrowserSessionSnapshot? {
		pages.value[id].map { .init(navigation: .init(isUnloaded: $0), revision: 1) }
	}

	func unload(
		_ id: BrowserCore.Tab.ID,
		reason: TabUnloadReason
	) -> TabUnloadOutcome {
		calls.withValue { $0.append(.init(id: id, reason: reason)) }
		guard pages.value[id] == false else { return .unavailable }
		guard !kept.contains(id) else { return .kept }

		pages.withValue { $0[id] = true }
		return .unloaded
	}
}
