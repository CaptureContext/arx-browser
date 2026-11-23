import Foundation

extension BrowserOrganization {
	/// Why a step can't be taken back.
	public enum UndoError: Error, Equatable, Sendable {
		/// What the step changed has changed since so that it can't go back, such as a folder
		/// whose space is gone.
		case conflict
	}

	/// This workspace with the change from `before` to `after` taken back (DEV-1030).
	///
	/// Only what the step changed goes back, and only where nothing changed it again since:
	/// - tabs, folders, spaces, split views and tab groups it removed come back; those it made
	///   go, unless they changed since;
	/// - what it moved goes back where it was, unless it moved again since;
	/// - names, icons, settings and the like go back where it changed them;
	/// - a tab it closed comes back only while Recently Closed still holds it, so a tab
	///   reopened with ⇧⌘T isn't reopened twice.
	///
	/// Everything else stays as it is now: tabs opened since, what pages loaded, which tab each
	/// space shows, and changes made in other windows or by agents.
	///
	/// - Returns: Nil when nothing of the step is left to take back.
	/// - Throws: `UndoError.conflict` when what's left can't go back, such as the last space.
	public func reverting(
		_ after: Self,
		to before: Self
	) throws -> Self? {
		var result = self
		let context: UndoContext = .init(now: self, after: after, before: before)
		context.revertProfiles(in: &result)
		context.revertSpaces(in: &result)
		context.revertFolders(in: &result)
		context.revertTabs(in: &result)
		context.revertArchive(in: &result)
		try context.revertPlacements(in: &result)
		context.revertGroups(in: &result)
		context.removeMadeProfiles(in: &result)
		context.keepArchivedTabsLeftOut(in: &result)
		context.repairSelections(in: &result)

		// Taking back a space's creation can't leave the workspace without one, such as after the
		// space it was made beside was deleted for good.
		guard !result.spaces.isEmpty else { throw UndoError.conflict }

		var reverted = self
		try reverted.update { $0 = result }
		return reverted == self ? nil : reverted
	}
}

// MARK: - Context

/// The three workspaces a step is taken back between: now, and the step's after and before.
private struct UndoContext {
	internal let now: BrowserOrganization
	internal let after: BrowserOrganization
	internal let before: BrowserOrganization

	/// Where each tab and folder is in each workspace.
	internal let nowPlaces: [SavedItem: Place]
	internal let afterPlaces: [SavedItem: Place]
	internal let beforePlaces: [SavedItem: Place]

	internal init(
		now: BrowserOrganization,
		after: BrowserOrganization,
		before: BrowserOrganization
	) {
		self.now = now
		self.after = after
		self.before = before
		self.nowPlaces = now.places
		self.afterPlaces = after.places
		self.beforePlaces = before.places
	}

	/// A list a tab or folder sits in.
	enum Place: Hashable {
		case favorites(Profile.ID)
		case unpinned(Space.ID)
		case saved(Space.ID)
		case folder(Folder.ID)

		var isSaved: Bool {
			switch self {
			case .favorites, .saved, .folder: true
			case .unpinned: false
			}
		}
	}

	/// Whether the item is where the step put it: in the same list, and that list in the same
	/// space, since a folder moves with everything in it.
	internal func isWhereMade(_ item: SavedItem) -> Bool {
		let current = nowPlaces[item]
		let made = afterPlaces[item]
		return current == made && space(of: current, in: now) == space(of: made, in: after)
	}

	/// The space a list is in: a folder's moves with the folder.
	internal func space(
		of place: Place?,
		in organization: BrowserOrganization
	) -> Space.ID? {
		switch place {
		case let .folder(id): organization.folders[id: id]?.spaceID
		case let .unpinned(id), let .saved(id): id
		case .favorites, nil: nil
		}
	}

	// MARK: Entities

	internal func revertProfiles(in result: inout BrowserOrganization) {
		for index in result.profiles.indices {
			let id = result.profiles[index].id
			guard
				let after = after.profiles[id: id],
				let before = before.profiles[id: id]
			else { continue }

			var profile = result.profiles[index]
			profile.revert(\.name, after: after, before: before)
			profile.revert(\.searchEngine, after: after, before: before)
			profile.revert(\.appearance, after: after, before: before)
			profile.revert(\.tabArchiveInterval, after: after, before: before)
			profile.revert(\.remoteSearchSuggestions, after: after, before: before)
			profile.revert(\.showsFullURL, after: after, before: before)
			profile.revert(\.keptLoadedSites, after: after, before: before)
			profile.revert(\.unreadBadges, after: after, before: before)
			result.profiles[index] = profile
		}
	}

	internal func revertSpaces(in result: inout BrowserOrganization) {
		// Made by the step and left as it made them: they go. A space someone put a tab in since
		// stays.
		result.spaces.removeAll { space in
			guard
				before.spaces[id: space.id] == nil,
				let made = after.spaces[id: space.id]
			else { return false }

			return space.ignoringSelection == made.ignoringSelection
		}
		for index in result.spaces.indices {
			let id = result.spaces[index].id
			guard
				let after = after.spaces[id: id],
				let before = before.spaces[id: id]
			else { continue }

			result.spaces[index].revert(\.name, after: after, before: before)
			result.spaces[index].revert(\.icon, after: after, before: before)
			result.spaces[index].revert(\.appearance, after: after, before: before)

			// A space the step moved to another profile goes back to its own; its tabs went with
			// new identities, which come and go as tabs do.
			let space = result.spaces[index]
			if
				after.profileID != before.profileID,
				space.profileID == after.profileID,
				result.profiles[id: before.profileID] != nil
			{
				result.spaces[index] = .init(
					id: space.id,
					profileID: before.profileID,
					name: space.name,
					icon: space.icon,
					appearance: space.appearance,
					savedItems: space.savedItems,
					unpinnedTabs: space.unpinnedTabs,
					selectedTabID: space.selectedTabID
				)
			}
		}

		// Removed by the step: they come back as they were, their selection too. Their lists are
		// put together with every other list's.
		for space in before.spaces where after.spaces[id: space.id] == nil && now.spaces[id: space.id] == nil {
			guard result.profiles[id: space.profileID] != nil else { continue }

			result.spaces.append(space)
		}
		let order = merged(
			now: now.spaces.ids.elements,
			after: after.spaces.ids.elements,
			before: before.spaces.ids.elements,
			members: Set(result.spaces.ids),
			existedAfter: Set(after.spaces.ids)
		)
		result.spaces = .init(uniqueElements: order.compactMap { result.spaces[id: $0] })
	}

	internal func revertFolders(in result: inout BrowserOrganization) {
		result.folders.removeAll { folder in
			guard
				before.folders[id: folder.id] == nil,
				let made = after.folders[id: folder.id]
			else { return false }

			// Moved since, into another folder say, it stays.
			return folder == made && isWhereMade(.folder(folder.id))
		}
		for index in result.folders.indices {
			let id = result.folders[index].id
			guard
				let after = after.folders[id: id],
				let before = before.folders[id: id]
			else { continue }

			result.folders[index].revert(\.name, after: after, before: before)
			result.folders[index].revert(\.isExpanded, after: after, before: before)
		}
		for folder in before.folders where after.folders[id: folder.id] == nil && now.folders[id: folder.id] == nil {
			result.folders.append(folder)
		}
		result.folders = ordered(result.folders, now: now.folders, after: after.folders, before: before.folders)
	}

	internal func revertTabs(in result: inout BrowserOrganization) {
		// Made by the step, such as a new tab, still where it put them and not renamed or saved
		// anew since: they go, and their pages close. A page loaded since doesn't keep one.
		result.tabs.removeAll { tab in
			guard before.tabs[id: tab.id] == nil, let made = after.tabs[id: tab.id] else { return false }

			return isWhereMade(.tab(tab.id))
			&& tab.customTitle == made.customTitle
			&& tab.icon == made.icon
			&& tab.savedDestination == made.savedDestination
		}
		for index in result.tabs.indices {
			let id = result.tabs[index].id
			guard
				let after = after.tabs[id: id],
				let before = before.tabs[id: id]
			else { continue }

			result.tabs[index].revert(\.customTitle, after: after, before: before)
			result.tabs[index].revert(\.icon, after: after, before: before)

			// A reset pin's page, say; a page loaded since stays.
			result.tabs[index].revert(\.restoration, after: after, before: before)
			result.tabs[index].revert(\.automationClientID, after: after, before: before)
		}

		// Removed by the step: they come back with their pages. One the step closed comes back
		// only while Recently Closed still holds it; reopened with ⇧⌘T or deleted from there,
		// it stays as it is.
		let archivedByStep = archivedByStep
		let archivedNow = Set(now.archive.map(\.id))
		for tab in before.tabs where after.tabs[id: tab.id] == nil && now.tabs[id: tab.id] == nil {
			if let entry = archivedByStep[tab.id], !archivedNow.contains(entry) { continue }
			guard result.profiles[id: tab.profileID] != nil else { continue }

			result.tabs.append(tab)
		}
		result.tabs = ordered(result.tabs, now: now.tabs, after: after.tabs, before: before.tabs)
	}

	internal func revertArchive(in result: inout BrowserOrganization) {
		let added = Set(after.archive.map(\.id)).subtracting(before.archive.map(\.id))
		let removed = Set(before.archive.map(\.id)).subtracting(after.archive.map(\.id))
		let current = Set(now.archive.map(\.id))
		let open = Set(result.tabs.ids)
		var entries = now.archive.filter { !added.contains($0.id) }
		entries += before.archive.filter { removed.contains($0.id) && !current.contains($0.id) && !open.contains($0.tab.id) }
		let order = merged(
			now: now.archive.map(\.id),
			after: after.archive.map(\.id),
			before: before.archive.map(\.id),
			members: Set(entries.map(\.id)),
			existedAfter: Set(after.archive.map(\.id))
		)
		let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		result.archive = order.compactMap { byID[$0] }
	}

	/// The archive entries the step added, by the tab each holds.
	private var archivedByStep: [Tab.ID: ArchivedTab.ID] {
		let existing = Set(before.archive.map(\.id))
		return Dictionary(
			after.archive.filter { !existing.contains($0.id) }.map { ($0.tab.id, $0.id) },
			uniquingKeysWith: { first, _ in first }
		)
	}

	// MARK: Placements

	/// Puts every tab and folder in its list, back where the step found it if it's still where
	/// the step put it, and keeps each list's order where nothing reordered it since.
	internal func revertPlacements(in result: inout BrowserOrganization) throws {
		func exists(_ place: Place) -> Bool {
			switch place {
			case let .favorites(id): result.profiles[id: id] != nil
			case let .unpinned(id), let .saved(id): result.spaces[id: id] != nil
			case let .folder(id): result.folders[id: id] != nil
			}
		}

		var targets: [SavedItem: Place] = [:]
		var orphans: [SavedItem] = []
		let items = result.tabs.ids.map(SavedItem.tab) + result.folders.ids.map(SavedItem.folder)
		for item in items {
			let current = nowPlaces[item]
			let made = afterPlaces[item]
			let previous = beforePlaces[item]
			let candidates: [Place?] = made != previous && isWhereMade(item)
			? [previous, current]
			: [current, previous]
			guard let place = candidates.compactMap({ $0 }).first(where: exists) else {
				orphans.append(item)
				continue
			}

			targets[item] = place
		}

		// A tab with nowhere to go doesn't come back; a folder can't be left out.
		for orphan in orphans {
			guard case let .tab(id) = orphan else { throw BrowserOrganization.UndoError.conflict }

			result.tabs.remove(id: id)
		}

		var members: [Place: Set<SavedItem>] = [:]
		for (item, place) in targets { members[place, default: []].insert(item) }

		func list(_ place: Place, in organization: BrowserOrganization) -> [SavedItem] {
			organization.list(place)
		}

		let existedAfter = Set(afterPlaces.keys)
		func ordered(_ place: Place) -> [SavedItem] {
			merged(
				now: list(place, in: now),
				after: list(place, in: after),
				before: list(place, in: before),
				members: members[place] ?? [],
				existedAfter: existedAfter
			)
		}

		for index in result.profiles.indices {
			let place = Place.favorites(result.profiles[index].id)
			result.profiles[index].favorites = ordered(place).compactMap(\.tabID)
		}
		for index in result.spaces.indices {
			let id = result.spaces[index].id
			result.spaces[index].unpinnedTabs = ordered(.unpinned(id)).compactMap(\.tabID)
			result.spaces[index].savedItems = ordered(.saved(id))
		}
		for index in result.folders.indices {
			result.folders[index].children = ordered(.folder(result.folders[index].id))
		}

		// A folder belongs to the space its outermost folder sits in.
		var spaces: [Folder.ID: Space.ID] = [:]
		for folder in result.folders.ids {
			var seen: Set<Folder.ID> = []
			var current = folder
			while true {
				guard seen.insert(current).inserted
				else { throw BrowserOrganization.UndoError.conflict }

				switch targets[.folder(current)] {
				case let .saved(space):
					spaces[folder] = space

				case let .folder(parent):
					current = parent
					continue

				case .favorites, .unpinned, nil:
					throw BrowserOrganization.UndoError.conflict
				}
				break
			}
		}
		for index in result.folders.indices {
			if let space = spaces[result.folders[index].id] { result.folders[index].spaceID = space }
		}

		// Pinned and Favorites tabs keep a saved page; open tabs don't. A tab the step pinned or
		// unpinned gets back the one it had.
		for index in result.tabs.indices {
			let id = result.tabs[index].id
			let isSaved = targets[.tab(id)]?.isSaved ?? false
			guard
				let previous = before.tabs[id: id],
				(previous.savedDestination != nil) == isSaved
			else { continue }

			// Pinned or unpinned back, it gets back the saved page it had; moved between saved
			// places, it keeps one saved since unless the step changed it.
			let isRepinned = now.tabs[id: id] == nil || (result.tabs[index].savedDestination != nil) != isSaved
			if isRepinned {
				result.tabs[index].savedDestination = previous.savedDestination
			} else if
				let made = after.tabs[id: id],
				made.savedDestination != nil,
				previous.savedDestination != nil,
				result.tabs[index].savedDestination != nil
			{
				// Saved before, by the step and now: each part goes back on its own, so a rename
				// since keeps its title while the address the step changed goes back.
				result.tabs[index].revert(\.savedDestination!.title, after: made, before: previous)
				result.tabs[index].revert(\.savedDestination!.url, after: made, before: previous)
				result.tabs[index].revert(\.savedDestination!.iconURL, after: made, before: previous)
			} else if let made = after.tabs[id: id] {
				result.tabs[index].revert(\.savedDestination, after: made, before: previous)
			}
		}
	}

	/// Profiles the step made, still as it made them and with nothing left in them, go.
	internal func removeMadeProfiles(in result: inout BrowserOrganization) {
		let used = Set(result.spaces.map(\.profileID))
		.union(result.tabs.map(\.profileID))
		.union(result.archive.map(\.tab.profileID))
		result.profiles.removeAll { profile in
			before.profiles[id: profile.id] == nil
			&& after.profiles[id: profile.id] == profile
			&& !used.contains(profile.id)
		}
	}

	/// A tab the step closed that can't come back, its space gone since, stays in Recently
	/// Closed rather than disappearing.
	internal func keepArchivedTabsLeftOut(in result: inout BrowserOrganization) {
		let kept = Set(result.archive.map(\.id))
		let open = Set(result.tabs.ids)
		let leftOut = now.archive.filter { !kept.contains($0.id) && !open.contains($0.tab.id) }
		guard !leftOut.isEmpty else { return }

		let ids = merged(
			now: now.archive.map(\.id),
			after: now.archive.map(\.id),
			before: now.archive.map(\.id),
			members: kept.union(leftOut.map(\.id)),
			existedAfter: []
		)
		let entries = Dictionary((result.archive + leftOut).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		result.archive = ids.compactMap { entries[$0] }
	}

	// MARK: Split views and tab groups

	internal func revertGroups(in result: inout BrowserOrganization) {
		result.splits = reverted(result.splits, after: after.splits, before: before.splits, members: \.tabIDs) { group, after, before in
			group.revert(\.spaceID, after: after, before: before)
			group.revert(\.tabIDs, after: after, before: before)
			group.revert(\.orientation, after: after, before: before)
			group.revert(\.fractions, after: after, before: before)
			group.revert(\.title, after: after, before: before)
			group.revert(\.icon, after: after, before: before)
		}
		result.tabGroups = reverted(result.tabGroups, after: after.tabGroups, before: before.tabGroups, members: \.tabIDs) { group, after, before in
			group.revert(\.spaceID, after: after, before: before)
			group.revert(\.name, after: after, before: before)
			group.revert(\.tabIDs, after: after, before: before)
			group.revert(\.isExpanded, after: after, before: before)
		}
	}

	private func reverted<Element: Identifiable & Equatable>(
		_ current: IdentifiedArrayOf<Element>,
		after: IdentifiedArrayOf<Element>,
		before: IdentifiedArrayOf<Element>,
		members: WritableKeyPath<Element, [Tab.ID]>,
		fields: (inout Element, Element, Element) -> Void
	) -> IdentifiedArrayOf<Element> {
		var result = current
		result.removeAll { element in
			before[id: element.id] == nil && after[id: element.id] == element
		}
		for index in result.indices {
			guard
				let after = after[id: result[index].id],
				let before = before[id: result[index].id]
			else { continue }

			fields(&result[index], after, before)
		}

		// Tabs a group took in since the step, a new group or one that was there, stay in it: a
		// group the step changed doesn't take them back.
		var newer: [Tab.ID: Element.ID] = [:]
		for element in current {
			let held = Set(after[id: element.id]?[keyPath: members] ?? [])
			for tab in element[keyPath: members] where !held.contains(tab) { newer[tab] = element.id }
		}
		for index in result.indices where before[id: result[index].id] != nil {
			let id = result[index].id
			result[index][keyPath: members].removeAll { tab in newer[tab].map { $0 != id } ?? false }
		}

		// One the step removed comes back unless a group made since holds its tabs.
		for element in before where after[id: element.id] == nil && current[id: element.id] == nil {
			let held = Set(result.flatMap { $0[keyPath: members] })
			guard held.isDisjoint(with: element[keyPath: members]) else { continue }

			result.append(element)
		}
		return ordered(result, now: current, after: after, before: before)
	}

	/// `elements` with each one that comes back where it was, so a step taken back leaves the
	/// workspace as it was, not just equivalent.
	private func ordered<Element: Identifiable>(
		_ elements: IdentifiedArrayOf<Element>,
		now: IdentifiedArrayOf<Element>,
		after: IdentifiedArrayOf<Element>,
		before: IdentifiedArrayOf<Element>
	) -> IdentifiedArrayOf<Element> {
		let order = merged(
			now: now.ids.elements,
			after: after.ids.elements,
			before: before.ids.elements,
			members: Set(elements.ids),
			existedAfter: Set(after.ids)
		)
		return .init(uniqueElements: order.compactMap { elements[id: $0] })
	}

	// MARK: Selection

	/// A space whose selected tab is gone or elsewhere now selects nothing; the window picks
	/// what it shows.
	internal func repairSelections(in result: inout BrowserOrganization) {
		let places = result.places
		for index in result.spaces.indices {
			let space = result.spaces[index]
			guard let selected = space.selectedTabID else { continue }

			let allowed = switch places[.tab(selected)] {
			case let .favorites(profile): profile == space.profileID
			case let .unpinned(id), let .saved(id): id == space.id
			case let .folder(folder): result.folders[id: folder]?.spaceID == space.id
			case nil: false
			}
			if !allowed { result.spaces[index].selectedTabID = nil }
		}
	}

	// MARK: Order

	/// `members` in the order the step found them where nothing rearranged the list since, or in
	/// today's order where something did. A member new to the list follows the one it followed
	/// now, or the one it followed before the step.
	///
	/// - Parameters:
	///   - existedAfter: Everything there was anywhere after the step. Something new since,
	///     such as a tab opened, doesn't count as rearranging the list it joined; something moved in
	///     from elsewhere does.
	internal func merged<Item: Hashable>(
		now: [Item],
		after: [Item],
		before: [Item],
		members: Set<Item>,
		existedAfter: Set<Item>
	) -> [Item] {
		let nowSet = Set(now)
		let afterSet = Set(after)
		let beforeSet = Set(before)
		let untouchedSince = now.filter(afterSet.contains) == after.filter(nowSet.contains)
		&& now.allSatisfy { afterSet.contains($0) || !existedAfter.contains($0) }
		var result: [Item]
		if after != before, untouchedSince {
			result = before.filter(members.contains)
			result = inserting(now.filter { members.contains($0) && !beforeSet.contains($0) }, into: result, following: now)
		} else {
			result = now.filter(members.contains)
		}
		let placed = Set(result)
		let missing = before.filter { members.contains($0) && !placed.contains($0) }
		result = inserting(missing, into: result, following: before)
		let all = Set(result)
		result += members.filter { !all.contains($0) }.sorted { lhs, rhs in
			(now.firstIndex(of: lhs) ?? .max) < (now.firstIndex(of: rhs) ?? .max)
		}
		return result
	}

	/// Each of `items` placed after the nearest item before it in `reference` that's already in
	/// `base`, or first.
	private func inserting<Item: Hashable>(
		_ items: [Item],
		into base: [Item],
		following reference: [Item]
	) -> [Item] {
		var result = base
		let positions = Dictionary(reference.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
		for item in items {
			guard let position = positions[item] else {
				result.append(item)
				continue
			}

			let anchor = reference[..<position].reversed().first(where: result.contains)
			let index = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
			result.insert(item, at: index)
		}
		return result
	}
}

// MARK: - Helpers

extension BrowserOrganization {
	/// Where each tab and folder sits.
	fileprivate var places: [SavedItem: UndoContext.Place] {
		var places: [SavedItem: UndoContext.Place] = [:]
		for profile in profiles {
			for id in profile.favorites { places[.tab(id)] = .favorites(profile.id) }
		}
		for space in spaces {
			for id in space.unpinnedTabs { places[.tab(id)] = .unpinned(space.id) }
			for item in space.savedItems { places[item] = .saved(space.id) }
		}
		for folder in folders {
			for item in folder.children { places[item] = .folder(folder.id) }
		}
		return places
	}

	fileprivate func list(_ place: UndoContext.Place) -> [SavedItem] {
		switch place {
		case let .favorites(id): profiles[id: id]?.favorites.map(SavedItem.tab) ?? []
		case let .unpinned(id): spaces[id: id]?.unpinnedTabs.map(SavedItem.tab) ?? []
		case let .saved(id): spaces[id: id]?.savedItems ?? []
		case let .folder(id): folders[id: id]?.children ?? []
		}
	}
}

extension SavedItem {
	fileprivate var tabID: Tab.ID? {
		guard case let .tab(id) = self else { return nil }
		return id
	}
}

extension Space {
	fileprivate var ignoringSelection: Self {
		var space = self
		space.selectedTabID = nil
		return space
	}
}

extension Equatable {
	/// Takes `path` back to `before` where the step changed it and nothing changed it since.
	fileprivate mutating func revert<Value: Equatable>(
		_ path: WritableKeyPath<Self, Value>,
		after: Self,
		before: Self
	) {
		guard
			after[keyPath: path] != before[keyPath: path],
			self[keyPath: path] == after[keyPath: path]
		else { return }

		self[keyPath: path] = before[keyPath: path]
	}
}
