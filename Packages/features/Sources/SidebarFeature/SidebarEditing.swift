import AppUI
import BrowserCore
import Foundation

/// Sidebar intents adapt to transactional edits of the production organization model.
extension BrowserOrganization {
	public mutating func moveTab(
		_ id: SidebarItem.ID,
		toSpace destination: Space.ID
	) throws {
		guard
			case let .tab(uuid) = id,
			let tab = tabs.first(where: { $0.id.rawValue == uuid }),
			let space = spaces.first(where: { $0.id == destination }),
			tab.profileID == space.profileID
		else { throw SidebarEditingError.invalidDestination }
		let target: SidebarDropTarget = tab.savedDestination == nil ? .unpinnedRoot : .savedRoot
		try move(id, to: target, in: destination)
	}

	public mutating func resetPinnedTab(_ id: BrowserCore.Tab.ID) {
		guard
			let index = tabs.firstIndex(where: { $0.id == id }),
			let destination = tabs[index].savedDestination
		else { return }
		tabs[index].restoration = .init(
			title: destination.title,
			url: destination.url
		)
		for index in spaces.indices where spaces[index].selectedTabID == id {
			spaces[index].selectedTabID = nil
		}
	}

	public mutating func removeTab(_ id: BrowserCore.Tab.ID) {
		for index in spaces.indices {
			spaces[index].savedItems.removeAll { $0 == .tab(id) }
			spaces[index].unpinnedTabs.removeAll { $0 == id }
			if spaces[index].selectedTabID == id { spaces[index].selectedTabID = nil }
		}
		for index in folders.indices {
			folders[index].children.removeAll { $0 == .tab(id) }
		}
		for index in profiles.indices {
			profiles[index].favorites.removeAll { $0 == id }
		}
		tabs.removeAll { $0.id == id }
	}

	public mutating func preserveFavoriteSelection(
		from sourceID: Space.ID,
		to destinationID: Space.ID
	) {
		guard
			let source = spaces.first(where: { $0.id == sourceID }),
			let destinationIndex = spaces.firstIndex(where: { $0.id == destinationID }),
			spaces[destinationIndex].profileID == source.profileID,
			let selectedID = source.selectedTabID,
			case .favorite(source.profileID) = location(of: selectedID)
		else { return }
		spaces[destinationIndex].selectedTabID = selectedID
	}

	public mutating func move(
		_ id: SidebarItem.ID,
		to target: SidebarDropTarget,
		in spaceID: Space.ID
	) throws {
		let target = resolvingSplitTarget(target)
		let resolved = resolvingTabGroupTarget(target)
		guard case let .tab(uuid) = id else {
			return try moveItem(id, to: resolved?.target ?? target, in: spaceID)
		}

		// A moved tab leaves its group first, so the group never spans where it went, and joins
		// the one it was dropped in (DEV-911). Dropping a group's only tab on its own group
		// moves nothing and keeps the group.
		let tab: Tab.ID = .init(rawValue: uuid)
		if let group = resolved?.group, tabGroups[id: group]?.tabIDs == [tab] { return }
		try update { candidate in
			candidate.leaveTabGroups([tab])
			try candidate.moveItem(id, to: resolved?.target ?? target, in: spaceID)
			if let group = resolved?.group { candidate.joinTabGroup(tab, group) }
		}
	}

	/// Brings tabs into the list a split of them and `target` shares (`splitList(joining:adding:)`),
	/// beside its tabs, so they can join it (DEV-1006). An open tab moved onto a pinned tab is
	/// pinned, a pinned tab moved onto an open tab is unpinned, and a tab of another list or space
	/// of the profile moves over; each goes through `move`, as a drop beside the split would. A
	/// Favorite of the profile stays in the grid. A tab of another profile, or a Favorite of
	/// another, can't, and nothing changes.
	public mutating func gatherForSplit(
		_ ids: [Tab.ID],
		joining target: Tab.ID
	) throws {
		guard
			let list = splitList(joining: target, adding: ids),
			let spaceID = space(of: list),
			let profileID = spaces[id: spaceID]?.profileID
		else { throw SidebarEditingError.invalidDestination }

		try update { candidate in

			// After the split's last tab in the list, then after each tab brought in.
			var anchor: Tab.ID? = candidate.split(containing: target).flatMap { candidate.listMembers(of: $0).last }
			?? (candidate.splitList(of: target) == list ? target : nil)
			for id in ids where id != target {
				let location = candidate.location(of: id)
				if location == .favorite(profileID) { continue }
				if candidate.splitList(of: id) == list {
					anchor = anchor ?? id
					continue
				}
				guard
					let location,
					!location.isFavorite,
					candidate.tabs[id: id]?.profileID == profileID
				else { throw SidebarEditingError.invalidDestination }

				let destination: SidebarDropTarget = anchor.map { .after(.tab($0.rawValue)) } ?? list.root
				try candidate.move(.tab(id.rawValue), to: destination, in: spaceID)
				anchor = id
			}
		}
	}

	/// Whether `id` can share a split in `spaceID`, after `gatherForSplit` if it's in another list or
	/// space of the profile (DEV-1006). A Favorite of the profile can, from the grid.
	public func canJoinSplit(
		_ id: Tab.ID,
		in spaceID: Space.ID
	) -> Bool {
		guard let profileID = spaces[id: spaceID]?.profileID else { return false }
		switch location(of: id) {
		case let .favorite(profile): return profile == profileID
		case .pinned, .unpinned: return tabs[id: id]?.profileID == profileID
		case nil: return false
		}
	}

	/// A drop after a Split View row, which stands for its first tab, as a drop after the split's
	/// last tab in its list, so it lands past the whole row rather than inside it (DEV-1006).
	public func resolvingSplitTarget(_ target: SidebarDropTarget) -> SidebarDropTarget {
		guard
			case let .after(.tab(uuid)) = target,
			let group = split(containing: .init(rawValue: uuid)),
			let last = listMembers(of: group).last
		else { return target }

		return .after(.tab(last.rawValue))
	}

	/// A drop on a tab group's rows as an open-tab target, and the group it joins (DEV-911). The
	/// group's row takes a tab at its end and its upper edge just above it; the line between the
	/// row and its first tab, or beside any of its tabs, puts the tab in the group there.
	public func resolvingTabGroupTarget(
		_ target: SidebarDropTarget
	) -> (target: SidebarDropTarget, group: TabGroup.ID?)? {
		switch target {
		case let .inside(.folder(uuid)), let .split(.folder(uuid)):
			guard
				let group = tabGroups[id: .init(rawValue: uuid)],
				let last = group.tabIDs.last
			else { return nil }

			return (.after(.tab(last.rawValue)), group.id)

		case let .before(.folder(uuid)):
			guard
				let group = tabGroups[id: .init(rawValue: uuid)],
				let first = group.tabIDs.first
			else { return nil }

			return (.before(.tab(first.rawValue)), nil)

		case let .after(.folder(uuid)):
			guard
				let group = tabGroups[id: .init(rawValue: uuid)],
				let first = group.tabIDs.first
			else { return nil }

			return (.before(.tab(first.rawValue)), group.id)

		case let .before(.tab(uuid)), let .after(.tab(uuid)):
			return (target, tabGroup(containing: .init(rawValue: uuid))?.id)

		default:
			return nil
		}
	}

	private mutating func moveItem(
		_ id: SidebarItem.ID,
		to target: SidebarDropTarget,
		in spaceID: Space.ID
	) throws {
		try update { candidate in
			guard let spaceIndex = candidate.spaces.index(id: spaceID)
			else { throw SidebarEditingError.invalidDestination }
			let source = id.savedItem
			if target == .before(id) || target == .after(id) || target == .inside(id) { return }
			if case .folder = id, target == .unpinnedRoot || target == .favoritesRoot {
				throw SidebarEditingError.folderInOpenTabs
			}

			candidate.spaces.indices.forEach { index in
				candidate.spaces[index].savedItems.removeAll { $0 == source }
				if case let .tab(uuid) = id {
					candidate.spaces[index].unpinnedTabs.removeAll { $0.rawValue == uuid }
				}
			}
			candidate.folders.indices
				.forEach {
					candidate.folders[$0].children.removeAll { $0 == source }
				}
			if case let .tab(uuid) = id {
				candidate.profiles.indices
					.forEach { index in
						candidate.profiles[index].favorites.removeAll { $0.rawValue == uuid }
					}
				guard let index = candidate.tabs.firstIndex(where: { $0.id.rawValue == uuid })
				else { return }
				if target == .unpinnedRoot || candidate.isUnpinnedTarget(target) {
					candidate.tabs[index].savedDestination = nil
				} else if candidate.tabs[index].savedDestination == nil {
					candidate.tabs[index].savedDestination = .init(
						title: candidate.tabs[index].displayTitle,
						url: candidate.tabs[index].restoration.url
					)
				}
			}

			switch target {
			case .favoritesRoot:
				let profileID = candidate.spaces[spaceIndex].profileID
				guard
					case let .tab(uuid) = id,
					let index = candidate.profiles.firstIndex(where: { $0.id == profileID })
				else { throw SidebarEditingError.invalidDestination }
				candidate.profiles[index].favorites.append(.init(rawValue: uuid))

			case .savedRoot:
				candidate.spaces[spaceIndex].savedItems.append(source)

			case .unpinnedRoot:
				if case let .tab(uuid) = id {
					candidate.spaces[spaceIndex].unpinnedTabs.append(.init(rawValue: uuid))
				}

			case .split:
				// Joining a split is MainFeature's; a plain move never forms one.
				throw SidebarEditingError.invalidDestination

			case let .inside(destination):
				guard
					case let .folder(uuid) = destination,
					let index = candidate.folders.firstIndex(where: { $0.id.rawValue == uuid })
				else { throw SidebarEditingError.invalidDestination }
				guard candidate.folders[index].spaceID == spaceID
				else { throw SidebarEditingError.invalidDestination }
				candidate.folders[index].children.append(source)
				candidate.folders[index].isExpanded = true

			case let .before(destination), let .after(destination):
				let after = target == .after(destination)
				try candidate.insert(
					source,
					relativeTo: destination,
					after: after,
					spaceIndex: spaceIndex
				)
			}

			// A favorite moved into this space is no longer available in other spaces.
			for index in candidate.spaces.indices where candidate.spaces[index].id != spaceID {
				guard
					case let .tab(uuid) = id,
					candidate.spaces[index].selectedTabID?.rawValue == uuid
				else { continue }

				if case .favorite = candidate.location(of: .init(rawValue: uuid)) { continue }
				candidate.spaces[index].selectedTabID = nil
			}
		}
	}

	private func isUnpinnedTarget(_ target: SidebarDropTarget) -> Bool {
		switch target {
		case let .before(.tab(uuid)), let .after(.tab(uuid)):
			return spaces.contains { $0.unpinnedTabs.contains { $0.rawValue == uuid } }

		default:
			return false
		}
	}

	private mutating func insert(
		_ item: SavedItem,
		relativeTo target: SidebarItem.ID,
		after: Bool,
		spaceIndex: Int
	) throws {
		let offset = after ? 1 : 0
		if case let .tab(uuid) = target {
			for profile in profiles.indices {
				if let index = profiles[profile].favorites.firstIndex(where: { $0.rawValue == uuid }) {
					guard case let .tab(tabID) = item
					else { throw SidebarEditingError.invalidDestination }
					profiles[profile].favorites.insert(tabID, at: index + offset)
					return
				}
			}
		}
		if
			case let .tab(uuid) = target,
			let index = spaces[spaceIndex].unpinnedTabs.firstIndex(where: { $0.rawValue == uuid })
		{
			guard case let .tab(tabID) = item
			else { throw SidebarEditingError.folderInOpenTabs }
			spaces[spaceIndex].unpinnedTabs.insert(tabID, at: index + offset)
			return
		}
		if let index = spaces[spaceIndex].savedItems.firstIndex(of: target.savedItem) {
			spaces[spaceIndex].savedItems.insert(item, at: index + offset)
			return
		}
		for folder in folders.indices where folders[folder].spaceID == spaces[spaceIndex].id {
			if let index = folders[folder].children.firstIndex(of: target.savedItem) {
				folders[folder].children.insert(item, at: index + offset)
				return
			}
		}
		throw SidebarEditingError.invalidDestination
	}
}

extension SidebarItem.ID {
	public var savedItem: SavedItem {
		switch self {
		case let .tab(id): .tab(.init(rawValue: id))
		case let .folder(id): .folder(.init(rawValue: id))
		}
	}
}

private enum SidebarEditingError: Error {
	case invalidDestination
	case folderInOpenTabs
}

// Native close approval and completion belong to MainFeature/AppFeature.
extension SidebarFeature.State {
	/// A pin or Favorite went back to its saved page: its row shakes (DEV-1225).
	public mutating func noteReset(_ id: BrowserCore.Tab.ID) {
		guard shakesResetPins else { return }

		resetPulses[.tab(id.rawValue), default: 0] += 1
	}

	public mutating func commitTabClose(
		_ id: BrowserCore.Tab.ID,
		reset: Bool
	) {
		// Done as it's made: a tab selected afterwards isn't part of it (DEV-1198).
		edit(sealed: true) { organization in
			if reset {
				organization.resetPinnedTab(id)
			} else {
				organization.removeTab(id)
			}
		}
	}
}

extension BrowserOrganization.TabLocation {
	fileprivate var isFavorite: Bool {
		if case .favorite = self { true } else { false }
	}
}

extension BrowserOrganization.SplitList {
	/// The end of the list, where a tab goes when nothing in it is beside the split.
	fileprivate var root: SidebarDropTarget {
		switch self {
		case .open: .unpinnedRoot
		case .pinned: .savedRoot
		case let .folder(id): .inside(.folder(id.rawValue))
		}
	}
}
