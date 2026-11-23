import BrowserCore
import Foundation
import SidebarFeature
import _ComposableArchitecture

/// A sidebar tab dropped outside every Arx window leaves the window for Little Arx (DEV-793).
/// The window asks the app first, which refuses a tab a Peek shows. Then the window takes the
/// tab out of its space without closing its page; the app hands the page
/// to a new Little Arx window in the same space, so it never crosses into another profile.
@Reducer
internal struct TabTearOff {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	internal var body: some ReducerOf<Self> {
		// The window can't see Peeks or other windows; the app answers with `tearOff`.
		Pullback(\.ui.dropTabOutsideWindows) { state, value in
			let (id, point) = value
			guard state.tabTearingOff(id) != nil
			else { return .none }

			return .send(.delegate(.requestTearOff(id, at: point)))
		}

		Pullback(\.tearOff) { state, value in
			let (id, point) = value
			guard
				let tab = state.tabTearingOff(id),
				case let .unpinned(spaceID) = state.sidebar.organization.location(of: id)
			else { return .none }

			// Leaving for Little Arx isn't a step ⌘Z takes back, and no earlier step brings the tab
			// back while Little Arx shows it: a step only puts back tabs it removed (DEV-1030).
			// Without `windowUndo`, the history goes.
			state.sidebar.sealUndo()
			do {
				try state.sidebar.organization.update { $0.removeTab(id) }
			} catch {
				return .none
			}

			// A selection that still named the tab would make the next move miss its source.
			state.sidebar.moveSelection.removeAll { $0 == .tab(id.rawValue) }

			// Forgotten before synchronizing, which closes the pages of removed tabs.
			state.knownTabIDs.remove(id)
			if state.chatTabOpenedOver?.chat == id || state.chatTabOpenedOver?.page == id {
				state.chatTabOpenedOver = nil
			}

			// The app hears of the move before the organization without the tab is published,
			// so the tab's chat surface survives the handoff.
			return .concatenate(
				.send(.delegate(.moveToLittleArx(tab, spaceID, at: point))),
				.send(.synchronize)
			)
		}
	}
}

extension MainFeature.State {
	/// The tab, if it can leave this window for Little Arx: an open tab of an ordinary window, not
	/// a saved one or a favorite, and not one being closed or moved.
	internal func tabTearingOff(_ id: BrowserCore.Tab.ID) -> BrowserCore.Tab? {
		guard
			!isPrivate,
			!isClosing,
			!transferInProgress,
			!pendingTabCloses.contains(id),
			case let .unpinned(spaceID) = sidebar.organization.location(of: id),
			let tab = sidebar.organization.tabs[id: id],
			sidebar.organization.spaces[id: spaceID]?.profileID == tab.profileID
		else { return nil }

		return tab
	}
}
