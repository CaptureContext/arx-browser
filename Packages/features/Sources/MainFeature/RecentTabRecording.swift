import BrowserCore
import Foundation
import SidebarFeature
import _ComposableArchitecture

/// Keeps `recentTabs` current after every action (DEV-544): the tab the window shows goes to the
/// front, closed tabs leave it and the open switcher. Last, so it sees what every reducer did.
@Reducer
internal struct RecentTabRecording {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Reduce { state, _ in

			// Kept for going back to the previous tab too (DEV-1228).
			guard state.keepsRecentTabs else { return .none }

			state.recordRecentTab()
			guard let switcher = state.tabSwitcher else { return .none }

			// A tab that closed while ⌃ is held leaves the switcher; the one it's on stays chosen.
			let locations = state.sidebar.organization.tabLocations
			let tabs = switcher.tabs.filter { state.canSwitch(to: $0, locations: locations) }
			guard tabs != switcher.tabs else { return .none }
			guard state.offersAnotherTab(tabs) else {
				state.tabSwitcher = nil
				return .cancel(id: MainFeature.TabSwitcherCancelID.beat)
			}
			let selected = switcher.selected
			state.tabSwitcher?.tabs = tabs
			state.tabSwitcher?.index = selected.flatMap(tabs.firstIndex(of:)) ?? min(switcher.index, tabs.count - 1)
			return .none
		}
	}
}
