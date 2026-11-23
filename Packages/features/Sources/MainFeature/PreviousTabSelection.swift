import BrowserCore
import Foundation
import _ComposableArchitecture

extension MainFeature.State {
	/// The window's selected tab is about to be closed or reset (DEV-1228), with the tab to select
	/// instead once it is.
	internal struct LeavingSelection: Equatable, Sendable {
		internal var spaceID: Space.ID

		/// The tabs closed or reset.
		internal var tabs: Set<BrowserCore.Tab.ID>
		internal var previous: RecentTab
	}

	/// Whether the window keeps `recentTabs`: for ⌃Tab's switcher (DEV-544), or to go back to the
	/// previous tab (DEV-1228).
	internal var keepsRecentTabs: Bool {
		recentTabSwitcherEnabled || returnsToPreviousTab
	}

	/// The tab to select when `tabs`, among them the window's selected one, are closed or reset: the
	/// tab the window showed before it (`previousRecentTab`), while it's still there, in this space,
	/// and not one of them. Nil when there's none, so the selection clears as it always has.
	internal func previousTab(leaving tabs: Set<BrowserCore.Tab.ID>) -> RecentTab? {
		guard
			returnsToPreviousTab,
			let selected = sidebar.selectedTab?.id,
			tabs.contains(selected)
		else { return nil }

		let locations = sidebar.organization.tabLocations
		guard
			let previous = previousRecentTab,
			previous.tabID != selected,
			!tabs.contains(previous.tabID),
			previous.spaceID == sidebar.spaceID,
			canSwitch(to: previous, locations: locations)
		else { return nil }

		// Where the tab is now, not where it was shown: one moved to another space meanwhile, as from
		// another window, would take this window there.
		switch locations[previous.tabID] {
		case let .pinned(space, _), let .unpinned(space):
			guard space == sidebar.spaceID else { return nil }
		case let .favorite(profile):
			guard profile == sidebar.space.profileID else { return nil }
		case nil:
			return nil
		}
		return previous
	}
}

/// Selects the previous tab after the selected one was closed or reset (DEV-1228). MainFeature
/// notes it before the sidebar commits the close (`leavingSelection`); this runs after every reducer
/// that could have, and only where the selection was cleared and the window is still on that space.
/// The selection is recorded as part of the close's or reset's undo step.
@Reducer
internal struct PreviousTabSelection {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Reduce { state, _ in
			guard let leaving = state.leavingSelection else { return .none }

			state.leavingSelection = nil
			guard
				state.sidebar.spaceID == leaving.spaceID,
				state.sidebar.selectedTab == nil
			else { return .none }

			// The close or reset's own step, done as it was made, ends where the workspace is now.
			let step: Int? = state.sidebar.undo.indices.last.flatMap { index in
				state.sidebar.undo[index].after == state.sidebar.organization ? index : nil
			}
			guard let effect = state.switchToRecentTab(leaving.previous) else { return .none }

			// The selection made for it belongs to that step: ⌘Z sees it as the step's own, not as a
			// later choice, and so takes the step back with the tab it closed or reset selected again.
			// Anything selected after this still counts as a later choice.
			if let step {
				let selected: BrowserCore.Tab.ID? = state.sidebar.organization.spaces[id: leaving.spaceID]?.selectedTabID
				state.sidebar.undo[step].after?.spaces[id: leaving.spaceID]?.selectedTabID = selected
			}
			return effect
		}
	}
}
