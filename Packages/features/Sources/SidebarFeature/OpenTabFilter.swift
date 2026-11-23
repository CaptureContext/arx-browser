import BrowserCore

/// Which open tabs a window's sidebar shows (DEV-822). Windows share spaces, Favorites and pinned
/// tabs; with `ARX_INDEPENDENT_WINDOWS` on, each keeps its own open tabs. The organization stays
/// whole in every window, so this only picks what the window shows and acts on.
public enum OpenTabFilter: Equatable, Sendable {
	/// Every open tab: windows share them, or the window is private.
	case all

	/// Every open tab but those other windows keep, as the main window shows them.
	case excluding(Set<BrowserCore.Tab.ID>)

	/// Only the window's own open tabs, as an additional window shows them.
	case only(Set<BrowserCore.Tab.ID>)

	/// Whether the window shows this open tab.
	public func shows(_ id: BrowserCore.Tab.ID) -> Bool {
		switch self {
		case .all: true
		case let .excluding(tabs): !tabs.contains(id)
		case let .only(tabs): tabs.contains(id)
		}
	}
}

extension SidebarFeature.State {
	/// The space's open tabs this window shows, in the sidebar's order.
	public func windowOpenTabs(in space: Space) -> [BrowserCore.Tab.ID] {
		guard openTabFilter != .all else { return space.unpinnedTabs }
		return space.unpinnedTabs.filter(openTabFilter.shows)
	}

	/// Whether this window shows the tab: every Favorite and pinned tab, and its own open tabs.
	public func windowShows(_ id: BrowserCore.Tab.ID) -> Bool {
		guard openTabFilter != .all, openTabFilter.shows(id) == false else { return true }
		guard case .unpinned = organization.location(of: id) else { return true }
		return false
	}

	/// The current space's open tabs this window shows.
	public var windowOpenTabs: [BrowserCore.Tab.ID] { windowOpenTabs(in: space) }

	/// The group's tabs this window shows, which its whole-group actions act on (DEV-1160).
	public func windowTabGroupMembers(_ id: TabGroup.ID) -> Set<BrowserCore.Tab.ID> {
		Set((organization.tabGroups[id: id]?.tabIDs ?? []).filter(openTabFilter.shows))
	}

	/// The current space's tabs in the sidebar's order, as the window shows them: Favorites, pinned
	/// tabs and folders, then its own open tabs. Next Tab, ⌘1–9 and bulk actions read this.
	public var windowTabOrder: [BrowserCore.Tab.ID] {
		let order = organization.tabOrder(in: spaceID)
		guard openTabFilter != .all else { return order }

		let open = Set(space.unpinnedTabs)
		return order.filter { !open.contains($0) || openTabFilter.shows($0) }
	}
}
