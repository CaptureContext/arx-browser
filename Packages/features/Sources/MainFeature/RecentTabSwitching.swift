import BrowserCore
import Foundation
import SidebarFeature
import _ComposableArchitecture

/// ⌃Tab's recent-tab switcher (DEV-544), behind `ARX_RECENT_TAB_SWITCHER`. The app's key monitor
/// sends `ui.tabSwitcher`: `step` for ⌃Tab and ⌃⇧Tab, `commit` when ⌃ is let go of and `cancel`
/// for Escape. A ⌃Tab let go of within `tabSwitcherBeat` goes straight to the previous tab without
/// the switcher ever showing.
@Reducer
internal struct RecentTabSwitching {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	@Dependency(\.continuousClock)
	private var clock

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.tabSwitcher) { state, action in
			guard state.recentTabSwitcherEnabled else { return .none }

			// A closing window takes no switching, as it takes no commands.
			guard !state.isClosing else {
				guard state.tabSwitcher != nil else { return .none }
				state.tabSwitcher = nil
				return .cancel(id: MainFeature.TabSwitcherCancelID.beat)
			}

			switch action {
			case let .step(step):
				guard var switcher = state.tabSwitcher else {
					let tabs = state.recentTabSwitcherTabs
					guard state.offersAnotherTab(tabs) else { return .none }

					// The previous tab, or for ⌃⇧Tab the one shown longest ago. A window showing no
					// tab yet, as a new window does, begins on the first.
					let showsFirst = state.shownRecentTab.map { $0 == tabs.first } ?? false
					let index = step > 0 ? (showsFirst ? 1 : 0) : tabs.count - 1
					state.tabSwitcher = .init(tabs: tabs, index: index)
					return .run { [clock] send in
						try await clock.sleep(for: MainFeature.tabSwitcherBeat)
						await send(.tabSwitcherBeat)
					}
					.cancellable(id: MainFeature.TabSwitcherCancelID.beat, cancelInFlight: true)
				}
				let count = switcher.tabs.count
				switcher.index = ((switcher.index + step) % count + count) % count

				// A second press is a walk: show it now.
				switcher.isShown = true
				state.tabSwitcher = switcher
				return .cancel(id: MainFeature.TabSwitcherCancelID.beat)

			case let .highlight(index):
				guard state.tabSwitcher?.tabs.indices.contains(index) == true else { return .none }
				state.tabSwitcher?.index = index
				return .none

			case let .choose(index):
				guard state.tabSwitcher?.tabs.indices.contains(index) == true else { return .none }
				state.tabSwitcher?.index = index
				return commit(&state)

			case .commit:
				return commit(&state)

			case .cancel:
				guard state.tabSwitcher != nil else { return .none }
				state.tabSwitcher = nil
				return .cancel(id: MainFeature.TabSwitcherCancelID.beat)
			}
		}

		Pullback(\.tabSwitcherBeat) { state in
			guard state.tabSwitcher?.isShown == false else { return .none }
			state.tabSwitcher?.isShown = true
			return .none
		}
	}

	private func commit(_ state: inout State) -> Effect<Action> {
		guard let switcher = state.tabSwitcher else { return .none }
		state.tabSwitcher = nil
		let cancel: Effect<Action> = .cancel(id: MainFeature.TabSwitcherCancelID.beat)
		guard let entry = switcher.selected, let switched = state.switchToRecentTab(entry) else { return cancel }
		return .merge(cancel, switched)
	}
}
