import BrowserCore
import BrowserWorkspaceClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// Archives regular tabs that have gone unviewed longer than their profile's interval:
/// six hours unless the profile chose otherwise (DEV-1326).
///
/// Pinned tabs, tabs in folders and Favorites never qualify, and neither does a tab on screen in
/// any window, the tab a space has selected, or a tab in use while hidden (``tabsInUseUnviewed``):
/// playing media, in a call or Picture in Picture, on a site its profile keeps loaded, or an
/// agent's. A page holding unsaved input is asked before it closes, and stays if the person says
/// so (`inactiveArchivePermitted`).
/// A tab's clock starts when it leaves the screen or stops being in use, or when automatic
/// archiving finds it first, so turning the setting on never archives everything at once.
@Reducer
internal struct TabAutoArchiving {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	/// How often Arx looks for tabs to archive. Intervals are hours or longer.
	internal static let sweepInterval: Duration = .seconds(5 * 60)

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.date)
	private var date

	private enum Cancellation: Hashable { case sweep }

	internal var body: some ReducerOf<Self> {
		Pullback(\.startTabArchiving) { state in
			state.archivesInactiveTabs = true
			return .run { [clock] send in
				await send(.archiveInactiveTabs)
				for await _ in clock.timer(interval: Self.sweepInterval) {
					await send(.archiveInactiveTabs)
				}
			}
			.cancellable(id: Cancellation.sweep, cancelInFlight: true)
		}

		Pullback(\.archiveInactiveTabs) { state in
			state.archiveInactiveTabs(now: date.now)
		}

		// A tab may have come on screen while its page was asked; only those still unviewed close.
		Pullback(\.main.event.inactiveArchivePermitted) { state, value in
			let (entries, refused) = value
			let now = date.now

			// Someone answered the page's question and kept it: in use, so its clock starts over
			// and the page isn't asked again until the interval passes once more.
			if !refused.isEmpty {
				state.$tabsLastViewed.withLock { viewed in
					for id in refused where viewed[id] != nil { viewed[id] = now }
				}
			}

			// Agent tabs sent to the archive are due too, unless something started using them while
			// their pages were asked; one whose page asked to stay waits for the next look (DEV-1022).
			// Archiving holds only decisions taken under the current delay: a change clears it.
			let agentDue: Set<BrowserCore.Tab.ID> = state.automationPreferences.agentTabCleanup.delay == nil
			? []
			: Set(state.automation.agentTabsArchiving.filter { state.isTidyable($0.key, unusedSince: $0.value) }.keys)
			let due = state.dueForArchive(now: now).union(agentDue)
			for id in entries.map(\.tab.id) + refused { state.automation.agentTabsArchiving[id] = nil }
			let approved = entries.filter { due.contains($0.tab.id) }
			guard !approved.isEmpty
			else { return .send(.main(.event(.archiveFailed("")))) }

			return .send(.main(.event(.archiveApproved(approved))))
		}
	}
}

extension Reducer where State == AppFeature.State {
	/// Stamps tabs as they enter or leave the screen, and as their activity while hidden starts or
	/// ends (DEV-1326), for automatic archiving.
	internal func recordingViewedTabs() -> some Reducer<State, Action> {
		onChange(of: { $0.tabsOnScreen }, reduce: { state, previous, current in

			// An agent's tab shown or left starts its unused time over (DEV-1093).
			state.agentTabsShownOrHidden(previous.symmetricDifference(current))
			state.stampViewed(previous.union(current))
			return .none
		})

		// Activity that starts and ends between two sweeps counts as use too.
		.onChange(of: { $0.tabsActiveWhileHidden }, reduce: { state, previous, current in
			state.stampViewed(previous.symmetricDifference(current))
			return .none
		})
	}
}

extension AppFeature.State {
	/// Tabs shown in a pane of any open normal window, in Peek or in Little Arx. A closed main
	/// window keeps its panes for reopening, but they aren't on screen.
	internal var tabsOnScreen: Set<BrowserCore.Tab.ID> {
		let open = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		var ids = Set(open.flatMap { window in
			window.viewer.panes.compactMap { $0.item.tab?.id }
		})
		ids.formUnion(peeks.map(\.tab.id))
		ids.formUnion(littleWindows.map(\.tab.id))

		// A page floating in Page PiP is in view wherever its tab is (DEV-950).
		if let floating = pagePictureInPicture?.tabID { ids.insert(floating) }
		return ids
	}

	/// Tabs doing something while hidden (DEV-1326): media playing or in Picture in Picture, a
	/// call, or an agent at work. Their clocks start over as it starts and as it ends.
	internal var tabsActiveWhileHidden: Set<BrowserCore.Tab.ID> {
		var ids = tabsMakingSound.playing.union(tabsMakingSound.inCall).union(tabsInAgentUse)
		ids.formUnion(media.snapshot.sources.filter(\.isInPictureInPicture).map(\.id.tabID))
		return ids
	}

	/// Hidden tabs that are in use all the same, which automatic archiving keeps (DEV-1326): those
	/// active while hidden, and those on a site the profile keeps loaded (DEV-932). Their clock
	/// starts over while they are, so one that stops waits a whole interval again.
	internal var tabsInUseUnviewed: Set<BrowserCore.Tab.ID> {
		var ids = tabsActiveWhileHidden
		for tab in workspace.tabs where workspace.profiles[id: tab.profileID]?.keepsLoaded(tab.restoration.url) == true {
			ids.insert(tab.id)
		}
		return ids
	}

	/// Regular tabs past their profile's interval, by the times recorded so far.
	fileprivate func dueForArchive(now: Date) -> Set<BrowserCore.Tab.ID> {
		let intervals = archiveIntervals
		let kept = tabsOnScreen
			.union(workspace.spaces.compactMap(\.selectedTabID))
			.union(tabsInUseUnviewed)
		var due: Set<BrowserCore.Tab.ID> = []
		for space in workspace.spaces {
			guard let interval = intervals[space.profileID] else { continue }

			for id in space.unpinnedTabs where !kept.contains(id) {
				guard
					workspace.tabs[id: id]?.savedDestination == nil,
					let viewed = tabsLastViewed[id],
					now.timeIntervalSince(viewed) >= interval
				else { continue }

				due.insert(id)
			}
		}
		return due
	}

	/// How long each profile's tabs may go unviewed, for profiles that archive: all but those
	/// that chose Never.
	private var archiveIntervals: [Profile.ID: TimeInterval] {
		Dictionary(
			workspace.profiles.compactMap { profile in
				profile.effectiveTabArchiveInterval.duration.map { (profile.id, $0) }
			},
			uniquingKeysWith: { first, _ in first }
		)
	}

	/// Stamps tabs once automatic archiving runs and some profile archives.
	fileprivate mutating func stampViewed(_ ids: Set<BrowserCore.Tab.ID>) {
		guard
			!ids.isEmpty,
			archivesInactiveTabs,
			workspace.profiles.contains(where: { $0.effectiveTabArchiveInterval.duration != nil })
		else { return }

		@Dependency(\.date)
		var date

		recordViewed(ids, now: date.now)
	}

	/// Stamps tabs entering or leaving the screen, only for profiles that archive automatically.
	fileprivate mutating func recordViewed(
		_ ids: Set<BrowserCore.Tab.ID>,
		now: Date
	) {
		let intervals = archiveIntervals
		guard !intervals.isEmpty else { return }

		let stamped = ids.filter { id in
			guard let tab = workspace.tabs[id: id] else { return false }
			return intervals[tab.profileID] != nil
		}
		guard !stamped.isEmpty else { return }

		$tabsLastViewed.withLock { viewed in
			for id in stamped { viewed[id] = now }
		}
	}

	/// Keeps a last-viewed time for every unpinned tab of a profile that archives, and asks the
	/// main window to archive those past their profile's interval.
	internal mutating func archiveInactiveTabs(now: Date) -> Effect<AppFeature.Action> {
		let intervals = archiveIntervals
		guard !intervals.isEmpty || !tabsLastViewed.isEmpty else { return .none }

		// Each space's selected tab is what the space shows when it's opened next.
		let onScreen = tabsOnScreen.union(workspace.spaces.compactMap(\.selectedTabID))
		let inUse = tabsInUseUnviewed
		var tracked: [BrowserCore.Tab.ID: Date] = [:]
		var due: [BrowserCore.Tab.ID] = []
		for space in workspace.spaces {
			guard let interval = intervals[space.profileID] else { continue }

			for id in space.unpinnedTabs {
				guard
					let tab = workspace.tabs[id: id],
					tab.savedDestination == nil
				else { continue }

				// Tabs on screen are stamped when they leave it, so a sweep doesn't rewrite them.
				guard !onScreen.contains(id), let viewed = tabsLastViewed[id] else {
					tracked[id] = tabsLastViewed[id] ?? now
					continue
				}

				// In use while hidden: its clock starts over at each sweep until it stops.
				guard !inUse.contains(id) else {
					tracked[id] = now
					continue
				}

				tracked[id] = viewed
				if now.timeIntervalSince(viewed) >= interval {
					due.append(id)
				}
			}
		}

		// Also forgets tabs that closed, moved or belong to profiles that stopped archiving.
		if tracked != tabsLastViewed {
			$tabsLastViewed.withLock { $0 = tracked }
		}
		guard !due.isEmpty else { return .none }

		return .send(.main(.archiveInactiveTabs(due)))
	}
}
