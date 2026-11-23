import Foundation

extension BrowserOrganization {
	/// The list of the sidebar a Split View group's tabs share (DEV-1006): a space's open tabs, its
	/// Pinned, or one folder. A group's Favorites stay in the Favorites grid and belong to none.
	public enum SplitList: Hashable, Sendable {
		case open(Space.ID)
		case pinned(Space.ID)
		case folder(Folder.ID)
	}

	public func split(containing tabID: Tab.ID) -> SplitGroup? {
		splits.first { $0.tabIDs.contains(tabID) }
	}

	/// The list `tabID` is in, if it's in one: Favorites aren't.
	public func splitList(of tabID: Tab.ID) -> SplitList? {
		location(of: tabID).flatMap(Self.splitList)
	}

	/// The list the group's tabs share outside the Favorites grid.
	public func splitList(of group: SplitGroup) -> SplitList? {
		group.tabIDs.lazy.compactMap(splitList(of:)).first
	}

	/// The space a list belongs to.
	public func space(of list: SplitList) -> Space.ID? {
		switch list {
		case let .open(id), let .pinned(id): spaces[id: id] == nil ? nil : id
		case let .folder(id): folders[id: id]?.spaceID
		}
	}

	/// The group's members the sidebar's list shows, in pane order: all but its Favorites.
	public func listMembers(of group: SplitGroup) -> [Tab.ID] {
		guard let list = splitList(of: group) else { return [] }
		return group.tabIDs.filter { splitList(of: $0) == list }
	}

	/// The list a split of `target` and `added` shares: the target's group's, else the target's,
	/// else, for a Favorite, the first added tab's that is in a list. Other tabs move into it to join.
	public func splitList(
		joining target: Tab.ID,
		adding added: [Tab.ID]
	) -> SplitList? {
		split(containing: target).flatMap(splitList(of:))
		?? splitList(of: target)
		?? added.lazy.compactMap(splitList(of:)).first
	}

	private static func splitList(_ location: TabLocation) -> SplitList? {
		switch location {
		case let .unpinned(space): .open(space)
		case let .pinned(space, nil): .pinned(space)
		case let .pinned(_, folder?): .folder(folder)
		case .favorite: nil
		}
	}

	/// The list's rows in order; a folder in it is `nil`, which breaks a run of tabs.
	private func rows(of list: SplitList) -> [Tab.ID?] {
		let items: [SavedItem]
		switch list {
		case let .open(id): return spaces[id: id]?.unpinnedTabs ?? []
		case let .pinned(id): items = spaces[id: id]?.savedItems ?? []
		case let .folder(id): items = folders[id: id]?.children ?? []
		}
		return items.map { item in
			if case let .tab(id) = item { id } else { nil }
		}
	}

	/// Rewrites the list's rows, folders included.
	private mutating func reorder(
		_ list: SplitList,
		_ transform: ([SavedItem]) -> [SavedItem]
	) {
		switch list {
		case let .open(id):
			guard let index = spaces.index(id: id) else { return }
			let reordered = transform(spaces[index].unpinnedTabs.map(SavedItem.tab)).compactMap { item -> Tab.ID? in
				if case let .tab(id) = item { id } else { nil }
			}
			if reordered != spaces[index].unpinnedTabs { spaces[index].unpinnedTabs = reordered }

		case let .pinned(id):
			guard let index = spaces.index(id: id) else { return }
			let reordered = transform(spaces[index].savedItems)
			if reordered != spaces[index].savedItems { spaces[index].savedItems = reordered }

		case let .folder(id):
			guard let index = folders.index(id: id) else { return }
			let reordered = transform(folders[index].children)
			if reordered != folders[index].children { folders[index].children = reordered }
		}
	}

	/// Keeps each group to the tabs of one list next to each other (the list holding most of them,
	/// the earlier pane's on a tie, and in it the longest run), plus Favorites of that list's
	/// space's profile, up to four in pane order. A group follows its list to another space. Groups
	/// left with fewer than two members, or with none in a list, go.
	public mutating func normalizeSplits() {
		guard !splits.isEmpty else { return }

		let locations = tabLocations
		var claimed: Set<Tab.ID> = []
		var normalized: IdentifiedArrayOf<SplitGroup> = []
		for var group in splits {
			let previous = group.tabIDs
			let lists = previous.map { id in
				claimed.contains(id) ? nil : locations[id].flatMap(Self.splitList)
			}
			guard
				let list = Self.mostCommon(lists.compactMap { $0 }),
				let spaceID = space(of: list),
				let profileID = spaces[id: spaceID]?.profileID
			else { continue }

			let candidates = Set(zip(previous, lists).compactMap { id, member in member == list ? id : nil })
			let block = Set(Self.longestRun(of: candidates, in: rows(of: list)))
			let members = previous.filter { id in
				block.contains(id) || !claimed.contains(id) && locations[id] == .favorite(profileID)
			}
			group.tabIDs = Array(members.prefix(SplitLayout.maximumPanes))
			guard
				group.tabIDs.count >= 2,
				group.tabIDs.contains(where: block.contains)
			else { continue }

			claimed.formUnion(group.tabIDs)
			group.spaceID = spaceID
			if group.tabIDs != previous {
				// Keep the surviving panes' shares relative to each other.
				let kept = group.tabIDs.compactMap { id in previous.firstIndex(of: id).flatMap { group.fractions[safe: $0] } }
				group.fractions = SplitLayout.sanitized(kept, count: group.tabIDs.count)
			} else {
				group.fractions = SplitLayout.sanitized(group.fractions, count: group.tabIDs.count)
			}
			normalized.append(group)
		}
		splits = normalized
	}

	/// Moves a group's tabs in its list next to each other, in pane order, where its first one in
	/// the sidebar is. Its Favorites stay in the grid.
	public mutating func gatherSplit(_ id: SplitGroup.ID) {
		guard
			let group = splits[id: id],
			let list = splitList(of: group)
		else { return }

		let members = Set(group.tabIDs.map(SavedItem.tab))
		reorder(list) { items in
			guard let anchor = items.firstIndex(where: members.contains) else { return items }
			let present = group.tabIDs.map(SavedItem.tab).filter(items.contains)
			return items[..<anchor].filter { !members.contains($0) }
			+ present
			+ items[anchor...].filter { !members.contains($0) }
		}
	}

	/// Runs an edit made of several moves, then gives back the groups its steps dissolved or
	/// trimmed their members, where no other group took one since, so a whole split moved tab by
	/// tab stays one (DEV-1006). Normalizing then keeps what still shares a list.
	public mutating func keepingSplits(_ edit: (inout Self) throws -> Void) rethrows {
		let before = splits
		try edit(&self)
		for group in before where splits[id: group.id] != group {
			let taken = group.tabIDs.contains { id in
				splits.contains { $0.id != group.id && $0.tabIDs.contains(id) }
			}
			guard !taken else { continue }

			if let index = splits.index(id: group.id) {
				splits[index] = group
			} else {
				splits.append(group)
			}
		}
		normalizeSplits()
	}

	/// Puts tabs into `list` right after `anchor`, or at its end when the list doesn't hold it.
	public mutating func insertTabs(
		_ ids: [Tab.ID],
		into list: SplitList,
		after anchor: Tab.ID?
	) {
		reorder(list) { items in
			var items = items
			let index = anchor.flatMap { items.firstIndex(of: .tab($0)) }.map { $0 + 1 } ?? items.endIndex
			items.insert(contentsOf: ids.map(SavedItem.tab), at: index)
			return items
		}
	}

	/// The list the most of `lists` name, the first one named on a tie.
	private static func mostCommon(_ lists: [SplitList]) -> SplitList? {
		var counts: [SplitList: Int] = [:]
		for list in lists { counts[list, default: 0] += 1 }
		var best: SplitList?
		for list in lists where best.map({ (counts[list] ?? 0) > (counts[$0] ?? 0) }) ?? true {
			best = list
		}
		return best
	}

	/// The longest stretch of `order` made only of `members`, the first one on a tie.
	private static func longestRun(
		of members: Set<Tab.ID>,
		in order: [Tab.ID?]
	) -> [Tab.ID] {
		var best: [Tab.ID] = []
		var current: [Tab.ID] = []
		for id in order {
			if let id, members.contains(id) {
				current.append(id)
				if current.count > best.count { best = current }
			} else {
				current = []
			}
		}
		return best
	}

	/// Takes these tabs out of their groups, dissolving any group left with one member. The
	/// remaining members move next to each other, ahead of the tabs that left.
	public mutating func removeFromSplits(_ tabIDs: Set<Tab.ID>) {
		guard !tabIDs.isEmpty else { return }
		for index in splits.indices.reversed() {
			let previous = splits[index].tabIDs
			let kept = previous.filter { !tabIDs.contains($0) }
			guard kept.count != previous.count else { continue }

			if kept.count < 2 {
				splits.remove(at: index)
			} else {
				let fractions = kept.compactMap { id in previous.firstIndex(of: id).map { splits[index].fractions[$0] } }
				splits[index].tabIDs = kept
				splits[index].fractions = SplitLayout.sanitized(fractions, count: kept.count)

				// The tabs that stay close ranks over the one that left, so they remain a block.
				gatherSplit(splits[index].id)
			}
		}
	}

	/// Puts `added` beside `target` in the target's group, or makes a new group of both, with
	/// equal panes. `index` is where the added tabs go among the panes; `nil` appends them.
	///
	/// Every tab has to be in the list the split shares (`splitList(joining:adding:)`) or be a
	/// Favorite of that list's space's profile; SidebarFeature's `gatherForSplit` brings others in.
	///
	/// - Returns: The group's identity.
	@discardableResult
	public mutating func joinSplit(
		_ added: [Tab.ID],
		with target: Tab.ID,
		at index: Int? = nil,
		orientation: BrowserSpacePresentation.Orientation? = nil,
		newID: SplitGroup.ID
	) throws -> SplitGroup.ID {
		var added = added.filter { $0 != target }
		var seen: Set<Tab.ID> = []
		added = added.filter { seen.insert($0).inserted }
		guard
			let list = splitList(joining: target, adding: added),
			let spaceID = space(of: list),
			let profileID = spaces[id: spaceID]?.profileID
		else { throw SplitError.notInOneList }

		for id in [target] + added {
			let location = location(of: id)
			guard location == .favorite(profileID) || location.flatMap(Self.splitList) == list
			else { throw SplitError.notInOneList }
		}

		let existing = split(containing: target)
		let current = existing?.tabIDs ?? [target]
		let incoming = added.filter { !current.contains($0) }
		guard !incoming.isEmpty else { return existing?.id ?? newID }
		guard current.count + incoming.count <= SplitLayout.maximumPanes
		else { throw SplitError.full }

		removeFromSplits(Set(incoming))
		var members = split(containing: target)?.tabIDs ?? [target]
		let position = index.map { min(max(0, $0), members.count) } ?? members.count
		members.insert(contentsOf: incoming, at: position)

		if let groupID = split(containing: target)?.id {
			splits[id: groupID]?.tabIDs = members
			splits[id: groupID]?.equalize()
			if let orientation { splits[id: groupID]?.orientation = orientation }
			gatherSplit(groupID)
			normalizeSplits()
			return groupID
		}
		splits.append(.init(
			id: newID,
			spaceID: spaceID,
			tabIDs: members,
			orientation: orientation ?? .horizontal
		))
		gatherSplit(newID)
		normalizeSplits()
		return newID
	}
}

extension BrowserOrganization {
	public enum SplitError: Error, Equatable, Sendable {
		/// A split's tabs share one list of the sidebar (open tabs, Pinned or one folder), besides
		/// Favorites of its space's profile, and at least one is in that list. Callers bring tabs
		/// into the list first (SidebarFeature's `gatherForSplit`, DEV-1006).
		case notInOneList

		/// A split already holds four tabs.
		case full
	}
}

extension Array {
	fileprivate subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
