import Foundation

/// A named, collapsible run of a space's open tabs (DEV-911).
///
/// Members are unpinned tabs of `spaceID`, in sidebar order, next to each other.
/// `BrowserOrganization.normalizeTabGroups()` repairs everything else, so a closed or moved member
/// never blocks an edit: a tab that lands between two members joins, and a group with no members
/// left goes.
public struct TabGroup: Identifiable, Equatable, Codable, Sendable {
	public let id: ID
	public var spaceID: Space.ID
	public var name: String
	public var tabIDs: [Tab.ID]
	public var isExpanded: Bool

	public init(
		id: ID,
		spaceID: Space.ID,
		name: String,
		tabIDs: [Tab.ID],
		isExpanded: Bool = true
	) {
		self.id = id
		self.spaceID = spaceID
		self.name = name
		self.tabIDs = tabIDs
		self.isExpanded = isExpanded
	}
}

extension TabGroup {
	public typealias ID = BrowserID<Self>
}

extension BrowserOrganization {
	/// Keeps each group to its members still open in its space, plus any open tab between two of
	/// them, in sidebar order. A tab belongs to one group, the earlier one; empty groups go.
	public mutating func normalizeTabGroups() {
		guard !tabGroups.isEmpty else { return }

		var claimed: Set<Tab.ID> = []
		var normalized: IdentifiedArrayOf<TabGroup> = []
		for var group in tabGroups {
			guard let space = spaces[id: group.spaceID] else { continue }

			let open = space.unpinnedTabs
			let members = Set(group.tabIDs)
			let indices = open.indices.filter { members.contains(open[$0]) && !claimed.contains(open[$0]) }
			guard var first = indices.first, var last = indices.last else { continue }

			// A Split View group is one row, so it's wholly in a group or out of it.
			for split in splits where split.spaceID == group.spaceID {
				let positions = open.indices.filter { split.tabIDs.contains(open[$0]) }
				guard
					let start = positions.first,
					let end = positions.last,
					start <= last,
					end >= first
				else { continue }

				first = min(first, start)
				last = max(last, end)
			}

			// One unbroken run: another group's tabs end it.
			group.tabIDs = Array(open[first...last].prefix { !claimed.contains($0) })
			claimed.formUnion(group.tabIDs)
			normalized.append(group)
		}
		tabGroups = normalized
	}

	/// The group a tab belongs to.
	public func tabGroup(containing tab: Tab.ID) -> TabGroup? {
		tabGroups.first { $0.tabIDs.contains(tab) }
	}

	/// Puts open tabs of one space into a new group where the first of them is, in sidebar order.
	/// Each leaves any group it was in.
	public mutating func groupTabs(
		_ ids: [Tab.ID],
		in spaceID: Space.ID,
		id: TabGroup.ID,
		name: String
	) throws {
		try update { organization in
			guard let index = organization.spaces.index(id: spaceID)
			else { throw TabGroupError.invalidSelection }

			let open = organization.spaces[index].unpinnedTabs
			let selected = Set(ids)
			let members = open.filter(selected.contains)
			guard
				!members.isEmpty,
				members.count == selected.count,
				let anchor = open.firstIndex(where: selected.contains)
			else { throw TabGroupError.invalidSelection }

			organization.leaveTabGroups(selected)
			var order = open[..<anchor].filter { !selected.contains($0) }
			+ members
			+ open[anchor...].filter { !selected.contains($0) }

			// Tabs taken from the middle of another group go after it, so it doesn't take them back.
			for group in organization.tabGroups where group.spaceID == spaceID {
				let positions = group.tabIDs.compactMap(order.firstIndex(of:))
				guard
					let first = positions.min(),
					let last = positions.max(),
					let start = order.firstIndex(of: members[0]),
					start > first,
					start < last
				else { continue }

				order.removeAll(where: selected.contains)
				let groupEnd = order.lastIndex(where: group.tabIDs.contains) ?? order.count - 1
				order.insert(contentsOf: members, at: groupEnd + 1)
			}
			organization.spaces[index].unpinnedTabs = order
			organization.tabGroups.append(.init(
				id: id,
				spaceID: spaceID,
				name: name,
				tabIDs: members
			))
		}
	}

	/// The group's tabs stay open where they are, out of any group.
	public mutating func ungroupTabs(_ id: TabGroup.ID) {
		tabGroups.remove(id: id)
	}

	/// Only these of the group's tabs leave it; the rest stay grouped. A window with independent
	/// open tabs ungroups the part of a group it shows, and the other windows keep theirs
	/// (DEV-1160). A Split View is one row, so one with a leaving tab leaves whole. Tabs that would
	/// sit between members still grouped go after them, so the group doesn't take them back.
	public mutating func ungroupTabs(
		_ id: TabGroup.ID,
		members: Set<Tab.ID>
	) {
		guard let group = tabGroups[id: id] else { return }

		var members = members
		for split in splits where split.tabIDs.contains(where: members.contains) {
			members.formUnion(split.tabIDs)
		}
		let kept = group.tabIDs.filter { !members.contains($0) }
		guard !kept.isEmpty else { return ungroupTabs(id) }

		tabGroups[id: id]?.tabIDs = kept
		guard
			let index = spaces.index(id: group.spaceID),
			let first = kept.first,
			let last = kept.last
		else { return }

		var order = spaces[index].unpinnedTabs
		guard
			let start = order.firstIndex(of: first),
			let end = order.firstIndex(of: last),
			order[start...end].contains(where: members.contains)
		else { return }

		let leaving = order[start...end].filter(members.contains)
		order.removeAll(where: Set(leaving).contains)
		let groupEnd = order.firstIndex(of: last) ?? order.count - 1
		order.insert(contentsOf: leaving, at: groupEnd + 1)
		spaces[index].unpinnedTabs = order
	}

	/// Pinning a group turns it into a pinned folder of its name at the end of the space's pinned
	/// tabs, holding its tabs in order.
	///
	/// With `members`, only those of its tabs are pinned and the rest stay open as the group: a
	/// window with independent open tabs pins the part of a group it shows, and the other windows
	/// keep theirs (DEV-1160).
	public mutating func pinTabGroup(
		_ id: TabGroup.ID,
		as folderID: Folder.ID,
		members: Set<Tab.ID>? = nil
	) throws {
		try update { organization in
			guard
				let group = organization.tabGroups[id: id],
				let index = organization.spaces.index(id: group.spaceID)
			else { throw TabGroupError.invalidSelection }

			let pinned = members.map { members in group.tabIDs.filter(members.contains) } ?? group.tabIDs
			guard !pinned.isEmpty else { throw TabGroupError.invalidSelection }

			let pinning = Set(pinned)
			organization.spaces[index].unpinnedTabs.removeAll(where: pinning.contains)
			for tab in pinned {
				guard let tabIndex = organization.tabs.index(id: tab) else { continue }
				organization.tabs[tabIndex].savedDestination = .init(
					title: organization.tabs[tabIndex].displayTitle,
					url: organization.tabs[tabIndex].restoration.url
				)
			}
			organization.folders.append(.init(
				id: folderID,
				spaceID: group.spaceID,
				name: group.name,
				children: pinned.map(SavedItem.tab),
				isExpanded: group.isExpanded
			))
			organization.spaces[index].savedItems.append(.folder(folderID))
			if pinned.count == group.tabIDs.count {
				organization.tabGroups.remove(id: id)
			} else {
				organization.tabGroups[id: id]?.tabIDs.removeAll(where: pinning.contains)
			}
		}
	}

	/// The tabs leave whatever groups they're in, as a tab dragged out does.
	public mutating func leaveTabGroups(_ tabs: Set<Tab.ID>) {
		for index in tabGroups.indices {
			tabGroups[index].tabIDs.removeAll(where: tabs.contains)
		}
	}

	/// The tab joins the group, which then takes it in sidebar order. Call after the tab is in
	/// the group's space, next to its tabs.
	public mutating func joinTabGroup(
		_ tab: Tab.ID,
		_ id: TabGroup.ID
	) {
		leaveTabGroups([tab])
		tabGroups[id: id]?.tabIDs.append(tab)
		normalizeTabGroups()
	}
}

public enum TabGroupError: Error, Equatable, Sendable {
	case invalidSelection
}
