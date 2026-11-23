import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

/// A tab keeps the URL and title its page settled on even when no window shows it: an agent's
/// tab, a background one, or a restored one moved back along its history. The engine reports
/// every ordinary page. A page a window shows goes to that window, as its pane's report does, so
/// the publication never reconciles (and clears the undo of) the window showing it; any other
/// goes to main, whose organization every publication keeps current even while its window is
/// closed. The sidebar, an agent's inventory and the next launch, whose saved history must end
/// at the tab's URL, all see where the page is.
@Reducer
internal struct AppPageNavigation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.event.pageSettled) { state, value in
			let (tabID, navigation) = value
			guard let windowID = state.settledPageOwner(tabID)
			else { return .none }

			// Unchanged pages, such as the one a pane already reported, change nothing there.
			return state.send(.takePageNavigation(tabID, navigation), to: windowID)
		}
	}
}

extension AppFeature.State {
	/// The ordinary window that shows the tab, else main, when the tab is an ordinary one.
	internal func settledPageOwner(_ tabID: BrowserCore.Tab.ID) -> UUID? {
		guard !main.isPrivate, main.sidebar.organization.tabs[id: tabID] != nil
		else { return nil }

		let owners = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		let shower = owners.first { owner in
			owner.viewer.panes.contains { $0.item.tab?.id == tabID }
		}
		return shower?.id ?? main.id
	}
}
