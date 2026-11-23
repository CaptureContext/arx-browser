import Foundation

/// The window side the sidebar sits on, from Settings › Appearance (DEV-913).
public enum SidebarPosition: String, Codable, CaseIterable, Sendable {
	case left
	case right
}

/// Where a new tab opens among a space's open tabs, from Settings › General › Tabs (DEV-913).
/// A tab another tab opened goes where `placeOpenedTab` says instead (DEV-1243).
public enum NewTabPlacement: String, Codable, CaseIterable, Sendable {
	case bottom
	case top
	case belowCurrent
}

extension BrowserOrganization {
	/// Adds a new open tab to the space at `spaceIndex` where `placement` puts it: after the
	/// space's open tabs, before them, or right after the current tab (after its Split View group,
	/// so the split stays whole) when that's an open tab, else after them all.
	public mutating func placeNewTab(
		_ tab: Tab.ID,
		inSpaceAt spaceIndex: Int,
		placement: NewTabPlacement,
		current: Tab.ID?
	) {
		let open = spaces[spaceIndex].unpinnedTabs
		let index: Int
		switch placement {
		case .bottom:
			index = open.count

		case .top:
			index = 0

		case .belowCurrent:
			guard
				let current,
				let position = open.firstIndex(of: current)
			else {
				index = open.count
				break
			}

			let members = splits.first { $0.tabIDs.contains(current) }?.tabIDs ?? [current]
			let last = open.indices.last { members.contains(open[$0]) } ?? position
			index = last + 1
		}
		spaces[spaceIndex].unpinnedTabs.insert(tab, at: index)
	}

	/// Adds a tab made from another tab where Max's rules put it (DEV-1243, DEV-1325). It's the
	/// one way an action that makes a tab out of a tab places it: links and a page's own new tabs,
	/// Open in New Tab, Duplicate, a Peek kept as a tab, Little Arx opened in a space and a link
	/// opened in a split.
	///
	/// From an open tab, directly after it, every time, so a second tab from the same opener sits
	/// between it and the first; after its whole Split View group, which stays whole. From a
	/// bookmark (a Favorite, or a pinned tab, in a folder or not) or from no tab at all, first
	/// among the space's open tabs. The tab joins neither the bookmarks nor the folder.
	public mutating func placeOpenedTab(
		_ tab: Tab.ID,
		inSpaceAt spaceIndex: Int,
		opener: Tab.ID?
	) {
		let open = spaces[spaceIndex].unpinnedTabs
		var index: Int = 0
		if let opener, let position = open.firstIndex(of: opener) {
			index = lastIndex(ofSplitWith: opener, in: open, from: position) + 1
		}
		spaces[spaceIndex].unpinnedTabs.insert(tab, at: index)
	}

	/// Where the Split View group `tab` belongs to ends in `open`, or `position` without one.
	private func lastIndex(
		ofSplitWith tab: Tab.ID,
		in open: [Tab.ID],
		from position: Int
	) -> Int {
		let members = splits.first { $0.tabIDs.contains(tab) }?.tabIDs ?? [tab]
		return open.indices.last { members.contains(open[$0]) } ?? position
	}
}
