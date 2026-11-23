import BrowserCore
import Foundation
import SidebarFeature

/// Where each tab sits in an Arx window for the extensions tabs and windows
/// APIs. A window holds its visible space's tabs in sidebar order; `index` is
/// that position, so it stays put while other tabs load or unload their pages.
/// A tab shown in a pane belongs to that window; any other belongs to the first
/// window whose visible space lists it (the main window first). With independent
/// windows, a window's space lists only the open tabs it keeps (DEV-822), so
/// another window's background tab is never named in the main window. The active
/// pane's tab is active and every shown one is highlighted. Private windows
/// hold nothing: extensions never see private pages. Little Arx windows hold
/// only their own tab.
internal enum ExtensionTabPlacements {
	internal struct Window: Equatable {
		internal var number: Int

		/// The visible space, or nil for a window that holds only its shown tabs.
		internal var spaceID: Space.ID?
		internal var isPrivate: Bool

		/// The visible space's open tabs this window keeps (DEV-822).
		internal var openTabFilter: OpenTabFilter

		/// Tabs shown in the window's panes, in pane order.
		internal var shown: [BrowserCore.Tab.ID]
		internal var active: BrowserCore.Tab.ID?

		internal init(
			number: Int,
			spaceID: Space.ID?,
			isPrivate: Bool = false,
			openTabFilter: OpenTabFilter = .all,
			shown: [BrowserCore.Tab.ID],
			active: BrowserCore.Tab.ID?
		) {
			self.number = number
			self.spaceID = spaceID
			self.isPrivate = isPrivate
			self.openTabFilter = openTabFilter
			self.shown = shown
			self.active = active
		}
	}

	internal struct Placement: Equatable {
		internal var windowNumber: Int
		internal var index: Int
		internal var isActive: Bool
		internal var isHighlighted: Bool
	}

	internal static func plan(
		_ windows: [Window],
		organization: BrowserOrganization
	) -> [BrowserCore.Tab.ID: Placement] {
		let windows = windows.filter { !$0.isPrivate && $0.number > 0 }
		var owners: [BrowserCore.Tab.ID: Int] = [:]
		for (offset, window) in windows.enumerated() {
			for id in window.shown where owners[id] == nil {
				owners[id] = offset
			}
		}

		var placements: [BrowserCore.Tab.ID: Placement] = [:]
		for (offset, window) in windows.enumerated() {
			var held: [BrowserCore.Tab.ID] = []
			var seen: Set<BrowserCore.Tab.ID> = []
			let order = window.spaceID.map { order(of: window, in: $0, organization: organization) } ?? []
			for id in order + window.shown where owners[id, default: offset] == offset {
				guard seen.insert(id).inserted else { continue }

				owners[id] = offset
				held.append(id)
			}
			for (index, id) in held.enumerated() {
				placements[id] = .init(
					windowNumber: window.number,
					index: index,
					isActive: id == window.active,
					isHighlighted: window.shown.contains(id)
				)
			}
		}
		return placements
	}

	/// The space's tabs in sidebar order, without the open tabs other windows keep.
	private static func order(
		of window: Window,
		in spaceID: Space.ID,
		organization: BrowserOrganization
	) -> [BrowserCore.Tab.ID] {
		let order = organization.tabOrder(in: spaceID)
		guard window.openTabFilter != .all, let space = organization.spaces[id: spaceID]
		else { return order }

		let open = Set(space.unpinnedTabs)
		return order.filter { !open.contains($0) || window.openTabFilter.shows($0) }
	}

	/// What `new` changes from `old`: each tab that arrived or moved, and nil for each tab no
	/// longer in any window. A tab switch changes two tabs, not the whole window (DEV-945).
	internal static func changes(
		from old: [BrowserCore.Tab.ID: Placement],
		to new: [BrowserCore.Tab.ID: Placement]
	) -> [BrowserCore.Tab.ID: Placement?] {
		var changes: [BrowserCore.Tab.ID: Placement?] = [:]
		for (id, placement) in new where old[id] != placement {
			changes[id] = .some(placement)
		}
		for id in old.keys where new[id] == nil {
			changes[id] = .some(nil)
		}
		return changes
	}
}
