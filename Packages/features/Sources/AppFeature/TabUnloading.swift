import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import MemoryPressureClient
import _ComposableArchitecture

/// What Arx keeps to unload idle tabs (DEV-873). None of it is saved: a relaunch restores
/// tabs unloaded anyway, and they load when they're shown.
public struct TabUnloadingState: Equatable, Sendable {
	/// When each loaded tab left the screen, or when a sweep first found it hidden.
	internal var hiddenSince: [BrowserCore.Tab.ID: Date]

	/// When an agent last acted on each tab, kept for `TabUnloadPolicy.agentGrace`.
	internal var agentActivity: [BrowserCore.Tab.ID: Date]

	/// Tabs whose page the engine has unloaded. Their sidebar rows look unloaded.
	public internal(set) var unloaded: Set<BrowserCore.Tab.ID>

	/// The system's memory pressure. While it's critical every sweep unloads.
	public internal(set) var memoryPressure: MemoryPressureLevel

	/// Set by `startTabUnloading`; until then (headless runs) nothing is tracked.
	internal var isRunning: Bool

	/// The newest sweep. Only it may unload: a newer sweep or a change to what keeps tabs
	/// loaded moves past it.
	internal var sweep: Int

	/// Tabs closed windows held that haven't unloaded yet (DEV-1104): the engine kept them, as
	/// for unsaved input or a view still leaving its window, or hasn't been asked. Opening a
	/// window forgets them.
	internal var releasing: Set<BrowserCore.Tab.ID>

	/// How many times the engine was asked again about `releasing` since a window closed.
	internal var releaseRetries: Int

	/// The newest release of `releasing`. Only it may unload, as with `sweep`.
	internal var release: Int

	/// Tabs whose unsaved input the person let go when their window asked before closing
	/// (DEV-1107), with the document that agreed: they chose Leave, or the page had nothing to
	/// ask. Their release unloads them anyway while that document is current. Opening a window
	/// forgets them, with `releasing`.
	internal var answered: [BrowserCore.Tab.ID: UInt64]

	public init() {
		self.isRunning = false
		self.sweep = 0
		self.hiddenSince = [:]
		self.agentActivity = [:]
		self.unloaded = []
		self.memoryPressure = .normal
		self.releasing = []
		self.releaseRetries = 0
		self.release = 0
		self.answered = [:]
	}
}

/// Unloads tabs hidden longer than Settings allows (General › Tabs, or Advanced › Memory), and,
/// once memory pressure turns critical, every tab it may that has been hidden past Advanced ›
/// Memory's grace (DEV-873), as Ardia's Memory Saver does.
///
/// `TabUnloadEligibility` keeps the tabs the app knows are in use: shown in any window, Peek
/// or Little Arx, each space's selected tab, and tabs an agent is acting on, and those the
/// person keeps loaded (DEV-932): tabs on a site their profile lists, and pinned tabs and
/// Favorites when Settings says so. The engine then
/// applies Chrome's discard rules and its own (`PageUnloadBlockers`). An unloaded tab keeps
/// its page, title, icon and back/forward list, and loads again when it's shown.
@Reducer
internal struct TabUnloading {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.date)
	private var date

	@Dependency(\.memoryPressure)
	private var memoryPressure

	internal enum Cancellation: Hashable {
		case sweep
		case pressure

		/// A sweep waiting to run. What keeps a tab loaded changing first cancels it, so a
		/// sweep never unloads with facts older than the store's.
		case pendingSweep

		/// One sweep, so a stale sweep can be stopped without touching a newer one.
		case sweepRun(Int)

		/// A release of closed windows' tabs waiting to run (DEV-1104).
		case pendingRelease

		/// One release, so a stale one can be stopped without touching a newer one.
		case releaseRun(Int)

		/// The wait before asking the engine again about tabs it kept.
		case releaseRetry

		/// One wait, so a stale one can be stopped without touching a newer one.
		case releaseRetryRun(Int)
	}

	/// How long a release waits before asking the engine again about the tabs it kept: their
	/// view may still be leaving the closed window, their page opening or loading. The later
	/// waits cover a slow load; a page that settles asks again sooner.
	internal static let releaseRetryDelays: [Duration] = [
		.milliseconds(500),
		.seconds(1),
		.seconds(2),
		.seconds(5),
		.seconds(15),
		.seconds(60),
	]

	/// Stops every sweep that hasn't run yet, including one whose task hasn't registered its
	/// cancellable: it reports in with an outdated number and is cancelled then.
	internal static func cancelPendingSweep(_ state: inout State) -> Effect<Action> {
		state.tabUnloading.sweep &+= 1
		return .cancel(id: Cancellation.pendingSweep)
	}

	/// Replaces a release that hasn't run yet with one that reads what holds tabs now, when
	/// closed windows' tabs are still waiting to unload (DEV-1104).
	internal static func restartPendingRelease(_ state: inout State) -> Effect<Action> {
		guard !state.tabUnloading.releasing.isEmpty else { return .none }

		state.tabUnloading.release &+= 1
		return .concatenate(.cancel(id: Cancellation.pendingRelease), .send(.releaseWindowlessTabs))
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.startTabUnloading) { state in
			state.tabUnloading.isRunning = true
			return .merge(
				.run { [clock] send in
					for await _ in clock.timer(interval: TabUnloadPolicy.sweepInterval) {
						await send(.unloadIdleTabs)
					}
				}
				.cancellable(id: Cancellation.sweep, cancelInFlight: true),
				.run { [memoryPressure] send in
					for await level in memoryPressure.levels() {
						await send(.event(.memoryPressureChanged(level)))
					}
				}
				.cancellable(id: Cancellation.pressure, cancelInFlight: true)
			)
		}

		Pullback(\.event.memoryPressureChanged) { state, level in
			let previous = state.tabUnloading.memoryPressure
			state.tabUnloading.memoryPressure = level
			guard level == .critical, previous != .critical else { return .none }

			return .send(.unloadIdleTabs)
		}

		// Every minute, tabs still waiting since their window closed are asked again: an agent's
		// grace may have ended, or a page finished loading without settling (DEV-1104).
		Pullback(\.unloadIdleTabs) { state in
			Self.restartPendingRelease(&state)
		}

		Pullback(\.unloadIdleTabs) { state in
			let now = date.now
			let reason: TabUnloadReason = state.tabUnloading.memoryPressure == .critical
			? .memoryPressure
			: .inactive
			let delay = state.settings.general.tabUnloadDelay
			let pressureGrace = state.settings.general.tabUnloadPressureGrace
			let candidates = state.tabUnloadCandidates(now: now)
			let keptSites = state.keptLoadedSitesByTab
			state.tabUnloading.sweep &+= 1
			let number = state.tabUnloading.sweep

			let unload: Effect<Action> = .run { @MainActor [engine] send in

				// Both cancellation IDs are registered by now. Report in first, so a newer sweep or
				// a change to what keeps tabs loaded reduced before that registration stops this one.
				send(.event(.tabUnloadSweepStarted(number)))

				// Runs without suspending from here on, so no action lands between this check and
				// the unloads.
				guard !Task.isCancelled, engine.tabUnloadingIsAvailable() else { return }

				let sweep = TabUnloadSweep.run(
					candidates,
					delay: delay,
					pressureGrace: pressureGrace,
					reason: reason,
					now: now,
					keptSites: keptSites,
					engine: engine
				)
				send(.event(.tabUnloadSweepFinished(loaded: sweep.loaded, unloaded: sweep.unloaded, at: now)))
			}
			.cancellable(id: Cancellation.sweepRun(number))
			.cancellable(id: Cancellation.pendingSweep)

			// `cancelInFlight` cancels when the task registers, off the main actor, so an older
			// sweep with older facts could cancel this one and unload instead. Cancel pending
			// sweeps synchronously in reducer order; one that registers later is stopped when
			// it reports in.
			return .concatenate(.cancel(id: Cancellation.pendingSweep), unload)
		}

		Pullback(\.event.tabUnloadSweepStarted) { state, number in
			guard state.tabUnloading.sweep != number else { return .none }

			return .cancel(id: Cancellation.sweepRun(number))
		}

		Pullback(\.event.tabUnloadSweepFinished) { state, value in
			let (loaded, unloaded, now) = value
			state.finishTabUnloadSweep(loaded: loaded, unloaded: unloaded, now: now)
			return .none
		}

		Pullback(\.releaseWindowlessTabs) { state in
			let now = date.now

			// Tabs an open window holds again stop waiting; those on screen or in an agent's use
			// wait for that to end.
			state.tabUnloading.releasing = state.windowlessTabsWaiting
			let due = state.windowlessTabs(now: now)
			guard !due.isEmpty else {
				// Nothing left to ask: moving the number on stops a retry whose task hasn't started
				// yet, which a cancel alone can miss (it reports in with the older number).
				state.tabUnloading.release &+= 1
				state.tabUnloading.forgetAnswersOutsideReleasing()
				return .cancel(id: Cancellation.releaseRetry)
			}

			state.tabUnloading.release &+= 1
			let number = state.tabUnloading.release
			let tabs = Array(state.workspace.tabs.ids)
			let answered = state.tabUnloading.answered.filter { due.contains($0.key) }
			let release: Effect<Action> = .run { @MainActor [engine] send in

				// As a sweep does: report in first, so a newer release stops this one.
				send(.event(.windowlessTabReleaseStarted(number)))
				guard !Task.isCancelled, engine.tabUnloadingIsAvailable() else { return }

				let result = TabUnloadSweep.release(due, answered: answered, among: tabs, engine: engine)
				send(.event(.windowlessTabsReleased(
					released: result.released,
					loaded: result.loaded,
					unloaded: result.unloaded,
					at: now
				)))
			}
			.cancellable(id: Cancellation.releaseRun(number))
			.cancellable(id: Cancellation.pendingRelease)

			return .concatenate(
				.cancel(id: Cancellation.pendingRelease),
				.cancel(id: Cancellation.releaseRetry),
				release
			)
		}

		// A page that was still loading or opening while the release ran asks again once it
		// settles, after the retries ran out too (DEV-1104).
		Pullback(\.event.pageSettled) { state, value in
			let (tabID, _) = value
			guard state.tabUnloading.releasing.contains(tabID) else { return .none }

			return Self.restartPendingRelease(&state)
		}

		Pullback(\.event.windowlessTabReleaseStarted) { state, number in
			guard state.tabUnloading.release != number else { return .none }

			return .cancel(id: Cancellation.releaseRun(number))
		}

		Pullback(\.event.windowlessTabReleaseRetryStarted) { state, number in
			guard state.tabUnloading.release != number else { return .none }

			return .cancel(id: Cancellation.releaseRetryRun(number))
		}

		Pullback(\.event.windowlessTabsReleased) { state, value in
			let (released, loaded, unloaded, now) = value
			state.finishTabUnloadSweep(loaded: loaded, unloaded: unloaded, now: now)
			state.tabUnloading.releasing.subtract(released)
			state.tabUnloading.forgetAnswersOutsideReleasing()
			let retry = state.tabUnloading.releaseRetries
			guard
				!state.tabUnloading.releasing.isEmpty,
				retry < Self.releaseRetryDelays.count
			else { return .none }

			state.tabUnloading.releaseRetries += 1

			// A cancel only reaches an effect whose task has started, so the wait reports in
			// first, as a release does: a window opening or a newer release before it started
			// has moved the number on and stops it before it sleeps.
			let number = state.tabUnloading.release
			return .run { @MainActor [clock] send in
				send(.event(.windowlessTabReleaseRetryStarted(number)))
				guard !Task.isCancelled else { return }

				try await clock.sleep(for: Self.releaseRetryDelays[retry])
				send(.releaseWindowlessTabs)
			}
			.cancellable(id: Cancellation.releaseRetryRun(number))
			.cancellable(id: Cancellation.releaseRetry)
		}
	}
}

/// One sweep against the engine, on the main actor.
internal enum TabUnloadSweep {
	internal struct Result: Equatable, Sendable {
		/// Tabs with a loaded page after the sweep.
		internal var loaded: Set<BrowserCore.Tab.ID>

		/// Tabs whose page is unloaded after the sweep.
		internal var unloaded: Set<BrowserCore.Tab.ID>
	}

	/// Reads which tabs are loaded, unloads the due ones longest hidden first, and reads the
	/// engine's answer back.
	@MainActor
	internal static func run(
		_ candidates: [TabUnloadPolicy.Candidate],
		delay: TabUnloadDelay,
		pressureGrace: TabUnloadPressureGrace,
		reason: TabUnloadReason,
		now: Date,
		keptSites: [BrowserCore.Tab.ID: [String]] = [:],
		engine: BrowserEngineClient
	) -> Result {
		let weighed = candidates.map { candidate in
			var candidate = candidate
			let snapshot = engine.snapshot(candidate.id)
			candidate.facts.isLoaded = snapshot.map { !$0.navigation.isUnloaded } ?? false

			// DEV-932: the page's live address, in case it reached a kept site since the
			// candidates were read.
			if let url = snapshot?.navigation.url, let sites = keptSites[candidate.id] {
				candidate.facts.isKeptLoaded = candidate.facts.isKeptLoaded
				|| sites.contains { KeptLoadedSite.matches(url, site: $0) }
			}
			return candidate
		}
		let due = TabUnloadPolicy.dueTabs(
			weighed,
			delay: delay,
			pressureGrace: pressureGrace,
			reason: reason,
			now: now
		)
		for id in due {
			_ = engine.unloadTab(id, reason)
		}

		var result = Result(loaded: [], unloaded: [])
		for candidate in candidates {
			guard let snapshot = engine.snapshot(candidate.id) else { continue }

			if snapshot.navigation.isUnloaded {
				result.unloaded.insert(candidate.id)
			} else {
				result.loaded.insert(candidate.id)
			}
		}
		return result
	}

	/// What a release of closed windows' tabs found (DEV-1104).
	internal struct Release: Equatable, Sendable {
		/// Tabs no longer waiting: unloaded now or before, or with no page. The engine kept the
		/// others, or asked to be asked again.
		internal var released: Set<BrowserCore.Tab.ID>

		/// Tabs with a loaded page after the release.
		internal var loaded: Set<BrowserCore.Tab.ID>

		/// Tabs whose page is unloaded after the release.
		internal var unloaded: Set<BrowserCore.Tab.ID>
	}

	/// Unloads the given tabs because no window holds them, then reads every tab of `tabs` back
	/// as a sweep does. Those `answered` before their window closed unload despite unsaved input
	/// (DEV-1107).
	@MainActor
	internal static func release(
		_ due: Set<BrowserCore.Tab.ID>,
		answered: [BrowserCore.Tab.ID: UInt64] = [:],
		among tabs: [BrowserCore.Tab.ID],
		engine: BrowserEngineClient
	) -> Release {
		var released: Set<BrowserCore.Tab.ID> = []
		for id in due {
			// An answer counts only for the document that gave it.
			let answeredHere = answered[id].map { engine.snapshot(id)?.documentRevision == $0 } ?? false
			let reason: TabUnloadReason = answeredHere ? .windowClosedAnswered : .windowClosed
			switch engine.unloadTab(id, reason) {
			case .kept, .busy: break
			case .unloaded, .alreadyUnloaded, .unavailable: released.insert(id)
			}
		}

		var result = Release(released: released, loaded: [], unloaded: [])
		for id in tabs {
			guard let snapshot = engine.snapshot(id) else { continue }

			if snapshot.navigation.isUnloaded {
				result.unloaded.insert(id)
			} else {
				result.loaded.insert(id)
			}
		}
		return result
	}
}

extension AppFeature.State {
	/// Tabs an agent is acting on now: ones an automation request in flight targets, and ones
	/// whose console and network logs a client keeps.
	internal var tabsInAgentUse: Set<BrowserCore.Tab.ID> {
		var ids = Set(automation.pending.values.compactMap { $0.request.operation.unloadTargetTabID })
		ids.formUnion(automation.developerLogs.keys)
		return ids
	}

	/// Every tab of the workspace with what the app knows about it. The sweep adds whether the
	/// engine has it loaded.
	internal func tabUnloadCandidates(now: Date) -> [TabUnloadPolicy.Candidate] {
		let onScreen = tabsOnScreen
		let selected = Set(workspace.spaces.compactMap(\.selectedTabID))
		let agents = tabsInAgentUse
		let keepsPinnedTabs = settings.general.keepsPinnedTabsLoaded

		// Every tab's place in one pass, only when pinned tabs stay loaded.
		let locations = keepsPinnedTabs ? workspace.tabLocations : [:]
		return workspace.tabs.map { tab in
			let recentAgent = tabUnloading.agentActivity[tab.id]
				.map { now.timeIntervalSince($0) < TabUnloadPolicy.agentGrace } ?? false
			let isPinned = switch locations[tab.id] {
			case .favorite, .pinned: true
			case .unpinned, nil: false
			}
			let isKeptLoaded = workspace.profiles[id: tab.profileID]?.keepsLoaded(tab.restoration.url) == true
			|| (keepsPinnedTabs && isPinned)
			return .init(
				id: tab.id,
				facts: .init(
					isLoaded: false,
					isOnScreen: onScreen.contains(tab.id),
					isSelectedInSpace: selected.contains(tab.id),
					isInAgentUse: agents.contains(tab.id) || recentAgent,
					isChat: tab.isChat,
					isKeptLoaded: isKeptLoaded
				),
				hiddenSince: tabUnloading.hiddenSince[tab.id]
			)
		}
	}

	/// The kept sites of each tab whose profile has any (DEV-932), for the sweep to check the
	/// page's live address against.
	internal var keptLoadedSitesByTab: [BrowserCore.Tab.ID: [String]] {
		let sites = Dictionary(uniqueKeysWithValues: workspace.profiles.compactMap { profile in
			profile.keptLoadedSites.map { (profile.id, $0) }
		})
		guard !sites.isEmpty else { return [:] }

		var result: [BrowserCore.Tab.ID: [String]] = [:]
		for tab in workspace.tabs {
			if let kept = sites[tab.profileID] { result[tab.id] = kept }
		}
		return result
	}

	/// What decides which tabs are kept loaded (DEV-932): each profile's sites and, while
	/// Settings keeps them loaded, the pinned tabs and Favorites. It changes only when one of
	/// those does, and costs nothing per tab while pinned tabs may unload.
	internal var tabsKeptLoadedKey: TabsKeptLoadedKey {
		var pinned: Set<BrowserCore.Tab.ID>?
		if settings.general.keepsPinnedTabsLoaded {
			var ids = Set(workspace.profiles.flatMap(\.favorites))
			for space in workspace.spaces {
				for case let .tab(id) in space.savedItems { ids.insert(id) }
			}
			for folder in workspace.folders {
				for case let .tab(id) in folder.children { ids.insert(id) }
			}
			pinned = ids
		}
		return .init(sites: workspace.profiles.map(\.keptLoadedSites), pinned: pinned)
	}

	/// Starts the clock of loaded tabs found hidden without one, forgets tabs that aren't
	/// loaded, and takes the engine's unloaded tabs.
	internal mutating func finishTabUnloadSweep(
		loaded: Set<BrowserCore.Tab.ID>,
		unloaded: Set<BrowserCore.Tab.ID>,
		now: Date
	) {
		let onScreen = tabsOnScreen
		var hiddenSince = tabUnloading.hiddenSince.filter { loaded.contains($0.key) && !onScreen.contains($0.key) }
		for id in loaded where !onScreen.contains(id) && hiddenSince[id] == nil {
			hiddenSince[id] = now
		}
		tabUnloading.hiddenSince = hiddenSince
		tabUnloading.unloaded = unloaded.subtracting(onScreen)
		tabUnloading.agentActivity = tabUnloading.agentActivity.filter {
			now.timeIntervalSince($0.value) < TabUnloadPolicy.agentGrace
		}
	}

	/// What each open ordinary window holds loaded (DEV-1104), by window.
	internal var windowHolds: [UUID: WindowHold] {
		let open = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		var holds: [UUID: WindowHold] = [:]
		for window in open where !window.isPrivate {
			holds[window.id] = .init(
				spaceID: window.sidebar.spaceID,
				panes: Set(window.viewer.panes.compactMap { $0.item.tab?.id })
			)
		}
		return holds
	}

	/// The tabs these windows hold: what their panes show, their spaces' tabs, pinned or not,
	/// and the Favorites of their spaces' profiles.
	internal func tabsHeld(by holds: some Sequence<WindowHold>) -> Set<BrowserCore.Tab.ID> {
		var ids: Set<BrowserCore.Tab.ID> = []
		var spaces: Set<Space.ID> = []
		for hold in holds {
			ids.formUnion(hold.panes)
			spaces.insert(hold.spaceID)
		}
		guard !spaces.isEmpty else { return ids }

		for space in workspace.spaces where spaces.contains(space.id) {
			ids.formUnion(space.unpinnedTabs)
			for case let .tab(id) in space.savedItems { ids.insert(id) }
			if let profile = workspace.profiles[id: space.profileID] { ids.formUnion(profile.favorites) }
		}
		for folder in workspace.folders where spaces.contains(folder.spaceID) {
			for case let .tab(id) in folder.children { ids.insert(id) }
		}
		return ids
	}

	/// The tabs waiting to release that nothing holds now (DEV-1104): no open window, Peek,
	/// Little Arx or Page PiP shows them or their space, no agent acts on them or did within its
	/// grace, and they're still workspace tabs other than chats.
	internal func windowlessTabs(now: Date) -> Set<BrowserCore.Tab.ID> {
		let releasing = windowlessTabsWaiting
		guard !releasing.isEmpty else { return [] }

		let recentAgents = tabUnloading.agentActivity
			.filter { now.timeIntervalSince($0.value) < TabUnloadPolicy.agentGrace }
			.keys

		var onScreen = tabsOnScreen

		// A page going back from Page PiP to a closed window isn't on screen for long.
		if let floating = pagePictureInPicture, case .returning = floating.phase, !onScreenInPane(floating.tabID) {
			onScreen.remove(floating.tabID)
		}
		let held = onScreen
			.union(tabsInAgentUse)
			.union(recentAgents)
		return releasing.subtracting(held)
	}

	/// The closed windows' tabs still worth releasing: workspace tabs, not chats, that no open
	/// window holds. Some wait for an agent or for leaving the screen first.
	internal var windowlessTabsWaiting: Set<BrowserCore.Tab.ID> {
		let releasing = tabUnloading.releasing
		guard !releasing.isEmpty else { return [] }

		let held = tabsHeld(by: windowHolds.values)
		return releasing.filter { id in
			guard !held.contains(id), let tab = workspace.tabs[id: id] else { return false }
			return !tab.isChat
		}
	}

	/// Notes the tabs closed windows held, to release them (DEV-1104): every workspace tab once
	/// no ordinary window is open. Opening a window forgets what was waiting.
	fileprivate mutating func noteWindowHolds(
		previous: [UUID: WindowHold],
		current: [UUID: WindowHold]
	) -> Effect<AppFeature.Action> {
		var effect: Effect<AppFeature.Action> = .none
		if current.keys.contains(where: { previous[$0] == nil }), !tabUnloading.releasing.isEmpty {
			// A release that hasn't run yet read the holds before this window opened.
			tabUnloading.releasing = []
			tabUnloading.answered = [:]
			tabUnloading.release &+= 1
			effect = .merge(
				.cancel(id: TabUnloading.Cancellation.pendingRelease),
				.cancel(id: TabUnloading.Cancellation.releaseRetry)
			)
		}
		let closed = previous.filter { current[$0.key] == nil }
		guard !closed.isEmpty else {
			// A window moving to another space may hold what a release that hasn't run is about
			// to unload.
			let moved = current.contains { id, hold in previous[id].map { $0 != hold } ?? false }
			guard moved else { return effect }

			return .merge(effect, TabUnloading.restartPendingRelease(&self))
		}

		var released = current.isEmpty ? Set(workspace.tabs.ids) : tabsHeld(by: closed.values)

		// The Page PiP a closed window owns, though the window moved to another space since.
		if let floating = pagePictureInPicture, closed.keys.contains(floating.windowID) {
			released.insert(floating.tabID)
		}
		tabUnloading.releasing.formUnion(released)
		tabUnloading.releaseRetries = 0

		// Video and document PiP close with the window that owns their tab (Max), at once, even
		// for a tab an agent keeps loaded until its grace ends (DEV-1128). A tab an open window
		// still holds keeps its PiP.
		let endingPictureInPicture = released.subtracting(tabsHeld(by: current.values))
		let endsPictureInPicture: Effect<AppFeature.Action> = endingPictureInPicture.isEmpty
		? .none
		: .run { @MainActor _ in
			@Dependency(\.browserEngine)
			var engine

			for id in endingPictureInPicture { engine.endPictureInPicture(id) }
		}

		// Page PiP closes with the window that owns its tab (Max); the engine ends media PiP.
		// A window still open keeps the PiP it owns, though another window shared its space.
		if
			let floating = pagePictureInPicture,
			current[floating.windowID] == nil,
			closed.keys.contains(floating.windowID) || released.contains(floating.tabID)
		{
			return .merge(
				endsPictureInPicture,
				.concatenate(
					.send(.ui(.closePagePictureInPicture(focusesTab: false))),
					.send(.releaseWindowlessTabs)
				)
			)
		}
		return .merge(endsPictureInPicture, .send(.releaseWindowlessTabs))
	}

	/// Whether an open window's pane shows the tab.
	private func onScreenInPane(_ id: BrowserCore.Tab.ID) -> Bool {
		windowHolds.values.contains { $0.panes.contains(id) }
	}

	/// The tabs each ordinary window's sidebar shows as unloaded. Private windows show their
	/// own tabs, which never unload.
	fileprivate mutating func publishUnloadedTabs() {
		let ordinary = tabUnloading.unloaded
		let mainTabs = main.isPrivate ? [] : ordinary
		if main.sidebar.unloadedTabs != mainTabs { main.sidebar.unloadedTabs = mainTabs }
		for window in windows {
			let tabs = window.isPrivate ? [] : ordinary
			if window.sidebar.unloadedTabs != tabs { windows[id: window.id]?.sidebar.unloadedTabs = tabs }
		}
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Starts a tab's hidden clock when it leaves the screen, clears it and the unloaded look
	/// when it comes back (the engine loads it then), and notes when agents act on tabs. A
	/// change to what keeps tabs loaded cancels a sweep that hasn't run yet.
	internal func trackingTabUnloading() -> some Reducer<State, Action> {
		self
			.onChange(of: { $0.tabsOnScreen }, reduce: { state, previous, current in
				guard state.tabUnloading.isRunning else { return .none }

				@Dependency(\.date)
				var date

				let now = date.now
				for id in previous.subtracting(current) { state.tabUnloading.hiddenSince[id] = now }
				for id in current { state.tabUnloading.hiddenSince[id] = nil }
				state.tabUnloading.unloaded.subtract(current)
				return .merge(
					TabUnloading.cancelPendingSweep(&state),
					TabUnloading.restartPendingRelease(&state)
				)
			})
			.onChange(of: { Set($0.workspace.spaces.compactMap(\.selectedTabID)) }, reduce: { state, _, _ in
				guard state.tabUnloading.isRunning else { return .none }

				return TabUnloading.cancelPendingSweep(&state)
			})

			// A site or pinned tab kept loaded since the sweep read its candidates (DEV-932).
			.onChange(of: { $0.tabsKeptLoadedKey }, reduce: { state, _, _ in
				guard state.tabUnloading.isRunning else { return .none }

				return TabUnloading.cancelPendingSweep(&state)
			})
			.onChange(of: { $0.tabsInAgentUse }, reduce: { state, previous, current in
				guard state.tabUnloading.isRunning else { return .none }

				@Dependency(\.date)
				var date

				let now = date.now

				// Those just finished count from now too.
				for id in previous.union(current) { state.tabUnloading.agentActivity[id] = now }
				return .merge(
					TabUnloading.cancelPendingSweep(&state),
					TabUnloading.restartPendingRelease(&state)
				)
			})

			// DEV-1104: closing a window releases the tabs it held that nothing else holds. Not
			// while quitting, which closes every page anyway.
			.onChange(of: { $0.windowHolds }, reduce: { state, previous, current in
				guard state.tabUnloading.isRunning, !state.shouldQuit, !state.checkingQuit
				else { return .none }

				return state.noteWindowHolds(previous: previous, current: current)
			})

			// A waiting tab an open window holds again, say moved into its space, mustn't unload
			// by a release that read it before. Those a release finished with left `releasing`.
			.onChange(of: { $0.windowlessTabsWaiting }, reduce: { state, previous, current in
				let heldAgain = previous.subtracting(current).intersection(state.tabUnloading.releasing)
				guard !heldAgain.isEmpty else { return .none }

				return TabUnloading.restartPendingRelease(&state)
			})
	}

	/// Keeps every ordinary window's sidebar in step with the unloaded tabs, new windows
	/// included. Only a difference reaches a sidebar.
	internal func publishingUnloadedTabs() -> some Reducer<State, Action> {
		CombineReducers {
			self
			Reduce { state, _ in
				state.publishUnloadedTabs()
				return .none
			}
		}
	}
}

extension TabUnloadingState {
	/// Answers of tabs no longer waiting to release are spent (DEV-1107).
	fileprivate mutating func forgetAnswersOutsideReleasing() {
		answered = answered.filter { releasing.contains($0.key) }
	}
}

/// What an open ordinary window holds loaded (DEV-1104).
internal struct WindowHold: Equatable, Sendable {
	internal var spaceID: Space.ID

	/// The tabs its panes show, of any space.
	internal var panes: Set<BrowserCore.Tab.ID>
}

/// `AppFeature.State.tabsKeptLoadedKey` (DEV-932).
internal struct TabsKeptLoadedKey: Equatable, Sendable {
	internal var sites: [[String]?]
	internal var pinned: Set<BrowserCore.Tab.ID>?
}

extension AutomationOperation {
	/// The tab an agent's request acts on, for keeping it loaded (DEV-873).
	internal var unloadTargetTabID: BrowserCore.Tab.ID? {
		let target: UUID? = switch self {
		case let .command(command): command.action.targetKind == .tab ? command.targetID : nil
		case let .capture(request): request.targetID
		case let .inspect(request): request.targetID
		case let .click(request): request.targetID
		case let .wait(request): request.targetID
		case let .form(request): request.target.targetID
		case let .scroll(request): request.target.targetID
		case let .signIn(request): request.targetID
		case let .load(request): request.targetID
		case let .pdf(request): request.targetID
		case let .findInPage(request): request.targetID
		case let .dialog(request): request.targetID
		case let .media(request): request.targetID
		case let .script(request): request.targetID
		case let .logs(request): request.targetID
		case let .passwordSignIn(request): request.targetID
		case .inventory, .batch, .data, .link, .settings: nil
		}
		return target.map(BrowserCore.Tab.ID.init(rawValue:))
	}
}
