import BrowserCore
import Foundation
import SidebarFeature
import _ComposableArchitecture

/// A tab this window showed, and the space it showed it in (DEV-544). A Favorite is shared by its
/// profile's spaces, so going back to one goes back to the space it was shown in.
public struct RecentTab: Equatable, Hashable, Sendable {
	public var tabID: BrowserCore.Tab.ID
	public var spaceID: Space.ID

	public init(
		tabID: BrowserCore.Tab.ID,
		spaceID: Space.ID
	) {
		self.tabID = tabID
		self.spaceID = spaceID
	}
}

/// ⌃Tab's switcher while ⌃ is held (DEV-544): the window's tabs as they were when it began, the
/// one it's on and whether it shows yet. Showing a tab moves it to the front of `recentTabs`, so
/// the switcher keeps its own copy: a list that reshuffled under the walk would be no list.
public struct TabSwitcher: Equatable, Sendable {
	/// The tabs, the one shown when it began first, then the most recently shown.
	public var tabs: [RecentTab]

	/// The tab letting go of ⌃ goes to.
	public var index: Int

	/// False for the beat before it appears, so a quick ⌃Tab never shows it.
	public var isShown: Bool

	public init(
		tabs: [RecentTab],
		index: Int,
		isShown: Bool = false
	) {
		self.tabs = tabs
		self.index = index
		self.isShown = isShown
	}

	public var selected: RecentTab? {
		tabs.indices.contains(index) ? tabs[index] : nil
	}
}

/// What the keyboard and pointer do to ⌃Tab's switcher (DEV-544).
public enum TabSwitcherAction: Equatable, Sendable {
	/// ⌃Tab (1) or ⌃⇧Tab (-1): begins the switcher on the previous tab (or the oldest), or moves
	/// it on, wrapping.
	case step(Int)

	/// The pointer moved onto this row.
	case highlight(Int)

	/// A click on this row: goes there at once.
	case choose(Int)

	/// ⌃ let go of, or Return: goes to the tab the switcher is on.
	case commit

	/// Escape, or the window or app lost the keyboard: goes nowhere, and recency stays as it was.
	case cancel
}

extension MainFeature {
	/// How long ⌃ must be held before the switcher shows: a beat long enough to hide a tap, short
	/// enough that a hold never waits. It shows 0.15 s after Tab.
	public static let tabSwitcherBeat: Duration = .milliseconds(150)

	/// The longest `recentTabs` grows; older tabs still come after it in the sidebar's order.
	internal static let recentTabLimit: Int = 64

	internal enum TabSwitcherCancelID: Hashable {
		case beat
	}
}

extension MainFeature.State {
	/// The tab the window shows now and the space it shows it in: the active pane's, or the
	/// sidebar's selection while the panes haven't caught up with a space change.
	internal var shownRecentTab: RecentTab? {
		let paneTab = viewer.spaceID == sidebar.spaceID ? viewer.item.tab?.id : nil
		guard let id = paneTab ?? sidebar.selectedTab?.id else { return nil }
		return .init(tabID: id, spaceID: sidebar.spaceID)
	}

	/// Puts the tab the window shows at the front of `recentTabs` and drops tabs that closed. Writes
	/// only a change. The window does this after every action; a state put together by hand, such
	/// as a test's, calls it to start from the tab it shows.
	public mutating func recordRecentTab() {
		let tabs = sidebar.organization.tabs
		if recentTabs.contains(where: { tabs[id: $0.tabID] == nil }) {
			recentTabs.removeAll { tabs[id: $0.tabID] == nil }
		}

		// One tab back is all the window goes back to (DEV-1228): once it closed, there's none.
		if let previous = previousRecentTab, tabs[id: previous.tabID] == nil {
			previousRecentTab = nil
		}

		// A pane can still show a tab that just closed, until it lets the tab go.
		guard
			let shown = shownRecentTab,
			tabs[id: shown.tabID] != nil
		else { return }

		// The tab shown until now is the previous one, unless it closed: never an older one.
		if lastShownRecentTab != shown {
			if let last = lastShownRecentTab, last.tabID != shown.tabID {
				previousRecentTab = tabs[id: last.tabID] == nil ? nil : last
			}
			lastShownRecentTab = shown
		}
		guard recentTabs.first != shown else { return }

		recentTabs.removeAll { $0.tabID == shown.tabID }
		recentTabs.insert(shown, at: 0)
		if recentTabs.count > MainFeature.recentTabLimit {
			recentTabs.removeLast(recentTabs.count - MainFeature.recentTabLimit)
		}
	}

	/// The tabs ⌃Tab walks: the one shown now, then the others this window showed, most recent
	/// first, then the space's tabs it hasn't shown yet in the sidebar's order. Only tabs the window
	/// can go to: not another window's open tabs, nor one closing. Unloaded tabs are listed as they
	/// are; listing loads nothing.
	public var recentTabSwitcherTabs: [RecentTab] {
		// Every tab's location in one pass, not a search of the organization per tab (DEV-947).
		let locations = sidebar.organization.tabLocations
		var seen: Set<BrowserCore.Tab.ID> = []
		var result: [RecentTab] = []
		func add(_ entry: RecentTab) {
			guard canSwitch(to: entry, locations: locations), seen.insert(entry.tabID).inserted else { return }
			result.append(entry)
		}
		if let shown = shownRecentTab { add(shown) }
		recentTabs.forEach(add)
		for id in sidebar.windowTabOrder {
			add(.init(tabID: id, spaceID: sidebar.spaceID))
		}
		return result
	}

	/// Whether the window can go to the tab: it's still there and this window shows it (every
	/// Favorite and pinned tab, and its own open tabs), and a Favorite's profile still has a space to
	/// show it in. `locations` is the organization's `tabLocations`, read once by the caller.
	internal func canSwitch(
		to entry: RecentTab,
		locations: [BrowserCore.Tab.ID: BrowserOrganization.TabLocation]
	) -> Bool {
		guard
			let tab = sidebar.organization.tabs[id: entry.tabID],
			!pendingTabCloses.contains(entry.tabID)
		else { return false }

		switch locations[entry.tabID] {
		case .pinned: return true
		case .unpinned: return sidebar.openTabFilter.shows(entry.tabID)
		case .favorite: return favoriteSpace(for: tab, preferring: entry.spaceID) != nil
		case nil: return false
		}
	}

	/// Whether the switcher has a tab to go to other than the one shown.
	internal func offersAnotherTab(_ tabs: [RecentTab]) -> Bool {
		let shown = shownRecentTab
		return tabs.contains { $0 != shown }
	}

	/// The space a Favorite shows in: the one it was last shown in, which its row names, while that's
	/// still the Favorite's profile's; else the current space when it's that profile's.
	private func favoriteSpace(
		for tab: BrowserCore.Tab,
		preferring spaceID: Space.ID
	) -> Space.ID? {
		if sidebar.organization.spaces[id: spaceID]?.profileID == tab.profileID { return spaceID }
		return sidebar.space.profileID == tab.profileID ? sidebar.spaceID : nil
	}

	/// Shows the tab as the command bar's Switch to Tab does, going to its space first. Nil when
	/// the window can't go there now.
	internal mutating func switchToRecentTab(_ entry: RecentTab) -> Effect<MainFeature.Action>? {
		guard
			!isClosing,
			canSwitch(to: entry, locations: sidebar.organization.tabLocations),
			let tab = sidebar.organization.tabs[id: entry.tabID]
		else { return nil }
		guard entry != shownRecentTab else { return Effect.none }

		let previousSpace = sidebar.spaceID
		if case .favorite = sidebar.organization.location(of: entry.tabID),
			let space = favoriteSpace(for: tab, preferring: entry.spaceID),
			space != sidebar.spaceID {
			sidebar.selectSpace(space)
		}
		sidebar.select(entry.tabID)
		if sidebar.spaceID != previousSpace { isLibraryOpen = false }
		return .merge(
			viewerSynchronization(selected: sidebar.selectedTab, paneID: viewer.activePaneID),
			.send(.delegate(.organizationChanged(sidebar.organization)))
		)
	}
}
