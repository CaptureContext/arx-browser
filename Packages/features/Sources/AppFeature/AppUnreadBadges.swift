import BrowserCore
import Foundation
import MainFeature
import SidebarFeature
import _ComposableArchitecture

/// Unread badges on tabs and Favorites (DEV-907). The engine reports each live page's badge,
/// from its title or the Badging API; the app keeps the last report per tab, so a tab whose page
/// was frozen or closed keeps showing what it last had, and hands every window's sidebar the
/// reports and every level's choice of whether badges show (DEV-1258).
@Reducer
internal struct AppUnreadBadges {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.event.unreadBadgeChanged) { state, value in
			let (tabID, badge) = value
			let existing = Set(state.allTabIDs)
			guard existing.contains(tabID) else { return .none }

			// Reports are rare, so tabs that went meanwhile are dropped here, not on every action.
			state.unreadBadges = state.unreadBadges.filter { existing.contains($0.key) }
			state.unreadBadges[tabID] = badge
			return .none
		}

		Pullback(\.main.delegate.setTabUnreadBadges) { state, value in
			state.setTabUnreadBadges(value.0, value.1)
			return .none
		}

		Pullback(\.windows) { state, action in
			guard case let .element(_, .delegate(.setTabUnreadBadges(tabID, visibility))) = action
			else { return .none }

			state.setTabUnreadBadges(tabID, visibility)
			return .none
		}
	}
}

extension AppFeature.State {
	/// A tab's own unread badges (DEV-1258), saved on this Mac. Tabs that went meanwhile lose
	/// theirs here, as choices are rare.
	internal mutating func setTabUnreadBadges(
		_ tabID: BrowserCore.Tab.ID,
		_ visibility: UnreadBadgeVisibility?
	) {
		let existing = Set(allTabIDs)
		guard existing.contains(tabID) else { return }

		settings.$unreadBadgeOverrides.withLock { overrides in
			overrides.tabs = overrides.tabs.filter { existing.contains($0.key) }
			overrides.tabs[tabID] = visibility
		}
	}

	/// Hands every window the badges and every level's choice. Only a difference reaches a sidebar.
	internal mutating func publishUnreadBadges() {
		let badges = unreadBadges
		let shows = settings.general.showsUnreadBadges
		let overrides = settings.unreadBadgeOverrides

		if main.sidebar.unreadBadges != badges { main.sidebar.unreadBadges = badges }
		if main.sidebar.showsUnreadBadges != shows { main.sidebar.showsUnreadBadges = shows }
		if main.sidebar.unreadBadgeOverrides != overrides { main.sidebar.unreadBadgeOverrides = overrides }
		for window in windows {
			if window.sidebar.unreadBadges != badges {
				windows[id: window.id]?.sidebar.unreadBadges = badges
			}
			if window.sidebar.showsUnreadBadges != shows {
				windows[id: window.id]?.sidebar.showsUnreadBadges = shows
			}
			if window.sidebar.unreadBadgeOverrides != overrides {
				windows[id: window.id]?.sidebar.unreadBadgeOverrides = overrides
			}
		}
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Keeps every window's rows in step with the tabs' unread badges, new windows included.
	internal func publishingUnreadBadges() -> some Reducer<State, Action> {
		CombineReducers {
			self
			Reduce { state, _ in
				state.publishUnreadBadges()
				return .none
			}
		}
	}
}
