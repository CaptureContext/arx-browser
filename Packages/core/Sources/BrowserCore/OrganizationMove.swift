import Foundation

/// An explicit destination. Space roots preserve saved/open placement; open tabs never implicitly unpin.
public enum OrganizationMoveDestination: Equatable, Sendable {
	case spaceRoot
	case savedRoot
	case openTabs
	case favorites
	case folder(Folder.ID)
	case before(SavedItem)
	case after(SavedItem)
}

public struct OrganizationMove: Equatable, Sendable {
	public var previous: BrowserOrganization
	public var updated: BrowserOrganization
	public var roots: [SavedItem]
	public var destination: Space.ID

	/// Only these tabs need new native sessions. Same-profile identities remain unchanged.
	public var replacements: [Replacement]
	public var movedTabIDs: [Tab.ID]

	public init(
		previous: BrowserOrganization,
		updated: BrowserOrganization,
		roots: [SavedItem],
		destination: Space.ID,
		replacements: [Replacement],
		movedTabIDs: [Tab.ID]
	) {
		self.previous = previous
		self.updated = updated
		self.roots = roots
		self.destination = destination
		self.replacements = replacements
		self.movedTabIDs = movedTabIDs
	}

	/// Reopens source-profile pages with fresh identities, so old tab-scoped grants stay revoked.
	public func reversed(newTabID: () -> Tab.ID) throws -> Self {
		var restored = previous
		var ids = Set(previous.tabs.map(\.id) + updated.tabs.map(\.id))
		var mapping: [Tab.ID: Tab.ID] = [:]
		var copies: [Replacement] = []
		for replacement in replacements {
			let id = newTabID()
			guard ids.insert(id).inserted
			else { throw OrganizationMoveError.duplicateIdentity }

			let source = replacement.source
			guard let current = updated.tabs[id: replacement.destination.id]
			else { throw OrganizationMoveError.missingSource }

			let copy = Tab(
				id: id,
				profileID: source.profileID,
				savedDestination: source.savedDestination,
				restoration: current.restoration,
				customTitle: source.customTitle,
				icon: source.icon,
				automationClientID: source.automationClientID,
				movedFrom: [current.id] + current.movedFrom
			)
			guard let index = restored.tabs.index(id: source.id)
			else { throw OrganizationMoveError.missingSource }

			restored.tabs[index] = copy
			mapping[source.id] = id
			copies.append(.init(source: current, destination: copy))
		}

		func remap(_ item: SavedItem) -> SavedItem {
			if case let .tab(id) = item { return .tab(mapping[id] ?? id) }
			return item
		}

		for index in restored.profiles.indices {
			restored.profiles[index].favorites = restored.profiles[index].favorites.map { mapping[$0] ?? $0 }
		}
		for index in restored.spaces.indices {
			restored.spaces[index].savedItems = restored.spaces[index].savedItems.map(remap)
			restored.spaces[index].unpinnedTabs = restored.spaces[index].unpinnedTabs.map { mapping[$0] ?? $0 }
			if let selected = restored.spaces[index].selectedTabID {
				restored.spaces[index].selectedTabID = mapping[selected] ?? selected
			}
		}
		for index in restored.folders.indices {
			restored.folders[index].children = restored.folders[index].children.map(remap)
		}

		// A returning tab takes its place in its Split View group and tab group under its fresh
		// identity.
		for index in restored.splits.indices {
			restored.splits[index].tabIDs = restored.splits[index].tabIDs.map { mapping[$0] ?? $0 }
		}
		for index in restored.tabGroups.indices {
			restored.tabGroups[index].tabIDs = restored.tabGroups[index].tabIDs.map { mapping[$0] ?? $0 }
		}

		// Undo changes placement. Unrelated browsing and disclosure continue from the live tree.
		for index in restored.tabs.indices {
			if let current = updated.tabs[id: restored.tabs[index].id] {
				restored.tabs[index].restoration = current.restoration
			}
		}
		for index in restored.folders.indices {
			if let current = updated.folders[id: restored.folders[index].id] {
				restored.folders[index].isExpanded = current.isExpanded
			}
		}

		// A tab group's disclosure and name are presentation too (DEV-911).
		for index in restored.tabGroups.indices {
			if let current = updated.tabGroups[id: restored.tabGroups[index].id] {
				restored.tabGroups[index].isExpanded = current.isExpanded
				restored.tabGroups[index].name = current.name
			}
		}
		let returning = Dictionary(uniqueKeysWithValues: copies.map { ($0.source.id, $0.destination.id) })
		for index in restored.spaces.indices {
			guard let current = updated.spaces[id: restored.spaces[index].id] else { continue }
			guard let selected = current.selectedTabID else {
				restored.spaces[index].selectedTabID = nil
				continue
			}

			let candidate = returning[selected] ?? selected
			switch restored.location(of: candidate) {
			case let .favorite(profile) where profile == restored.spaces[index].profileID:
				restored.spaces[index].selectedTabID = candidate

			case let .pinned(space, _) where space == restored.spaces[index].id,
				let .unpinned(space) where space == restored.spaces[index].id:
				restored.spaces[index].selectedTabID = candidate

			default:
				break
			}
		}
		restored.normalizeSplits()
		restored.normalizeTabGroups()
		try restored.validate()

		let sourceSpace: Space.ID
		let sourceTab: Tab.ID?
		if case let .tab(id) = roots.first {
			sourceTab = id
		} else {
			sourceTab = replacements.first?.source.id
		}

		if case let .folder(id) = roots.first, let folder = previous.folders[id: id] {
			sourceSpace = folder.spaceID

		} else {
			switch sourceTab.flatMap({ previous.location(of: $0) }) {
			case let .pinned(id, _), let .unpinned(id):
				sourceSpace = id

			case let .favorite(profile):
				sourceSpace = previous.spaces.first(where: { $0.profileID == profile })?.id ?? previous.spaces[0].id

			default:
				sourceSpace = previous.spaces[0].id
			}
		}

		return .init(
			previous: updated,
			updated: restored,
			roots: [],
			destination: sourceSpace,
			replacements: copies,
			movedTabIDs: movedTabIDs.map { returning[$0] ?? $0 }
		)
	}

	public struct Replacement: Equatable, Sendable {
		public var source: Tab
		public var destination: Tab

		public init(
			source: Tab,
			destination: Tab
		) {
			self.source = source
			self.destination = destination
		}
	}
}

public enum OrganizationMoveError: Error, Equatable, Sendable {
	case emptySelection
	case missingSource
	case invalidDestination
	case folderCycle
	case cannotUnpinImplicitly
	case duplicateIdentity
}

extension BrowserOrganization {
	public func hasSameMoveStructure(as other: Self) -> Bool {
		var comparable = self
		for index in comparable.tabs.indices {
			if let old = other.tabs[id: comparable.tabs[index].id] {
				comparable.tabs[index].restoration = old.restoration
			}
		}
		for index in comparable.spaces.indices {
			if let old = other.spaces[id: comparable.spaces[index].id] {
				comparable.spaces[index].selectedTabID = old.selectedTabID
			}
		}
		for index in comparable.folders.indices {
			if let old = other.folders[id: comparable.folders[index].id] {
				comparable.folders[index].isExpanded = old.isExpanded
			}
		}

		// A tab group's disclosure and name are presentation, as a folder's disclosure is (DEV-911).
		for index in comparable.tabGroups.indices {
			if let old = other.tabGroups[id: comparable.tabGroups[index].id] {
				comparable.tabGroups[index].isExpanded = old.isExpanded
				comparable.tabGroups[index].name = old.name
			}
		}

		// A split's pane sizes, orientation, name and icon are presentation, like disclosure.
		for index in comparable.splits.indices {
			if let old = other.splits[id: comparable.splits[index].id] {
				comparable.splits[index].fractions = old.fractions
				comparable.splits[index].orientation = old.orientation
				comparable.splits[index].title = old.title
				comparable.splits[index].icon = old.icon
			}
		}
		return comparable == other
	}

	/// Plans one complete edit without changing the source. Descendants selected with an ancestor move once.
	public func moving(
		_ selection: [SavedItem],
		to target: OrganizationMoveDestination,
		in destinationID: Space.ID,
		unpinning: Bool = false,
		newTabID: () -> Tab.ID
	) throws -> OrganizationMove {
		try validate()
		guard !selection.isEmpty
		else { throw OrganizationMoveError.emptySelection }

		guard let destination = spaces[id: destinationID]
		else { throw OrganizationMoveError.invalidDestination }

		var unique: [SavedItem] = []
		for item in selection where !unique.contains(item) {
			switch item {
			case let .tab(id):
				guard tabs.ids.contains(id)
				else { throw OrganizationMoveError.missingSource }

			case let .folder(id):
				guard folders.ids.contains(id)
				else { throw OrganizationMoveError.missingSource }
			}
			unique.append(item)
		}
		let selectedFolders = unique.compactMap { item -> Folder.ID? in
			if case let .folder(id) = item { id } else { nil }
		}
		let roots = unique.filter { item in
			!selectedFolders.contains { id in item != .folder(id) && descendants(of: id).contains(item) }
		}
		let allItems = roots.flatMap { item -> [SavedItem] in
			if case let .folder(id) = item { return [item] + descendants(of: id) }
			return [item]
		}
		let folderIDs = Set(allItems.compactMap { item -> Folder.ID? in
			if case let .folder(id) = item { id } else { nil }
		})
		let sourceTabs = allItems.compactMap { item -> Tab? in
			if case let .tab(id) = item { tabs[id: id] } else { nil }
		}
		let placement = try movePlacement(target, destination: destination)
		if case let .folder(id) = placement.collection, folderIDs.contains(id) {
			throw OrganizationMoveError.folderCycle
		}
		if let anchor = placement.anchor, allItems.contains(anchor) {
			throw OrganizationMoveError.invalidDestination
		}
		if !folderIDs.isEmpty, placement.collection == .openTabs || placement.collection == .favorites {
			throw OrganizationMoveError.invalidDestination
		}

		let unpinsImplicitly = !unpinning
		&& placement.collection == .openTabs
		&& sourceTabs.contains(where: { $0.savedDestination != nil })

		if unpinsImplicitly {
			throw OrganizationMoveError.cannotUnpinImplicitly
		}

		var candidate = self
		var replacements: [OrganizationMove.Replacement] = []
		var identities = Set(tabs.map(\.id))
		var mapped: [Tab.ID: Tab.ID] = [:]
		for tab in sourceTabs where tab.profileID != destination.profileID {
			let id = newTabID()
			guard identities.insert(id).inserted
			else { throw OrganizationMoveError.duplicateIdentity }

			let copy = Tab(
				id: id,
				profileID: destination.profileID,
				savedDestination: tab.savedDestination,
				restoration: tab.restoration,
				customTitle: tab.customTitle,
				icon: tab.icon,
				automationClientID: tab.automationClientID,
				movedFrom: [tab.id] + tab.movedFrom
			)
			mapped[tab.id] = id
			replacements.append(.init(source: tab, destination: copy))
			candidate.tabs.removeAll { $0.id == tab.id }
			candidate.tabs.append(copy)
		}

		func remap(_ item: SavedItem) -> SavedItem {
			if case let .tab(id) = item { return .tab(mapped[id] ?? id) }
			return item
		}

		for index in candidate.folders.indices where folderIDs.contains(candidate.folders[index].id) {
			candidate.folders[index].spaceID = destinationID
			candidate.folders[index].children = candidate.folders[index].children.map(remap)
		}

		// Remove roots together before calculating the insertion index. This preserves batch order.
		for index in candidate.spaces.indices {
			candidate.spaces[index].savedItems.removeAll { roots.contains($0) }
			candidate.spaces[index].unpinnedTabs.removeAll { roots.contains(.tab($0)) }
		}
		for index in candidate.profiles.indices {
			candidate.profiles[index].favorites.removeAll { roots.contains(.tab($0)) }
		}
		for index in candidate.folders.indices where !folderIDs.contains(candidate.folders[index].id) {
			candidate.folders[index].children.removeAll { roots.contains($0) }
		}
		let moved = roots.map(remap)
		if target == .spaceRoot {
			let open = moved.filter { item in
				if case let .tab(id) = item { candidate.tabs[id: id]?.savedDestination == nil } else { false }
			}
			try candidate.insertMove(
				moved.filter { !open.contains($0) },
				at: .init(collection: .saved),
				destination: destination
			)
			try candidate.insertMove(
				open,
				at: .init(collection: .openTabs),
				destination: destination
			)

		} else {
			try candidate.insertMove(moved, at: placement, destination: destination)
		}
		let movedIDs = sourceTabs.map { mapped[$0.id] ?? $0.id }

		// Moved tabs leave their tab groups, so a group never spans to where they went (DEV-911).
		candidate.leaveTabGroups(Set(sourceTabs.map(\.id) + movedIDs))
		if unpinning, placement.collection == .openTabs {
			for index in candidate.tabs.indices where movedIDs.contains(candidate.tabs[index].id) {
				candidate.tabs[index].savedDestination = nil
			}
		}
		for index in candidate.spaces.indices {
			guard let selected = candidate.spaces[index].selectedTabID else { continue }
			let valid: Bool
			switch candidate.location(of: selected) {
			case let .favorite(profile): valid = profile == candidate.spaces[index].profileID
			case let .pinned(space, _), let .unpinned(space): valid = space == candidate.spaces[index].id
			case nil: valid = false
			}
			if !valid { candidate.spaces[index].selectedTabID = nil }
		}
		for index in replacements.indices {
			if let placed = candidate.tabs[id: replacements[index].destination.id] {
				replacements[index].destination = placed
			}
		}

		// Settle Split View membership here, so the plan's result (and its Undo) is what commits.
		candidate.normalizeSplits()
		candidate.normalizeTabGroups()
		try candidate.validate()
		return .init(
			previous: self,
			updated: candidate,
			roots: roots,
			destination: destinationID,
			replacements: replacements,
			movedTabIDs: movedIDs
		)
	}

	/// Depth-first order includes complete nested subtrees, independent of disclosure state.
	public func descendants(of folderID: Folder.ID) -> [SavedItem] {
		guard let folder = folders[id: folderID] else { return [] }
		var visited: Set<Folder.ID> = [folderID]
		func collect(_ children: [SavedItem]) -> [SavedItem] {
			children.flatMap { item -> [SavedItem] in
				guard
					case let .folder(id) = item,
					visited.insert(id).inserted,
					let nested = folders[id: id]
				else { return [item] }

				return [item] + collect(nested.children)
			}
		}
		return collect(folder.children)
	}
}

private struct MovePlacement {
	internal enum Collection: Equatable {
		case saved
		case openTabs
		case favorites
		case folder(Folder.ID)
	}

	internal var collection: Collection
	internal var anchor: SavedItem?
	internal var after: Bool

	internal init(
		collection: Collection,
		anchor: SavedItem? = nil,
		after: Bool = false
	) {
		self.collection = collection
		self.anchor = anchor
		self.after = after
	}
}

extension BrowserOrganization {
	fileprivate func movePlacement(
		_ target: OrganizationMoveDestination,
		destination: Space
	) throws -> MovePlacement {
		switch target {
		case .spaceRoot, .savedRoot:
			return .init(collection: .saved)

		case .openTabs:
			return .init(collection: .openTabs)

		case .favorites:
			return .init(collection: .favorites)

		case let .folder(id):
			guard folders.contains(where: { $0.id == id && $0.spaceID == destination.id })
			else { throw OrganizationMoveError.invalidDestination }

			return .init(collection: .folder(id))

		case let .before(item), let .after(item):
			let collection: MovePlacement.Collection
			if case let .tab(id) = item, profiles[id: destination.profileID]?.favorites.contains(id) == true {
				collection = .favorites
			} else if case let .tab(id) = item, destination.unpinnedTabs.contains(id) {
				collection = .openTabs
			} else if destination.savedItems.contains(item) {
				collection = .saved
			} else if let folder = folders.first(where: { $0.spaceID == destination.id && $0.children.contains(item) }) {
				collection = .folder(folder.id)
			} else {
				throw OrganizationMoveError.invalidDestination
			}
			return .init(collection: collection, anchor: item, after: target == .after(item))
		}
	}

	fileprivate mutating func insertMove(
		_ items: [SavedItem],
		at placement: MovePlacement,
		destination: Space
	) throws {
		guard !items.isEmpty else { return }

		func insert(into values: inout [SavedItem]) throws {
			let index: Int
			if let anchor = placement.anchor {
				guard let found = values.firstIndex(of: anchor)
				else { throw OrganizationMoveError.invalidDestination }

				index = found + (placement.after ? 1 : 0)

			} else {
				index = values.endIndex
			}
			values.insert(contentsOf: items, at: index)
		}

		guard let space = spaces.index(id: destination.id)
		else { throw OrganizationMoveError.invalidDestination }

		switch placement.collection {
		case .saved:
			try insert(into: &spaces[space].savedItems)

		case let .folder(id):
			guard let index = folders.index(id: id)
			else { throw OrganizationMoveError.invalidDestination }

			try insert(into: &folders[index].children)
			folders[index].isExpanded = true

		case .openTabs:
			var values = spaces[space].unpinnedTabs.map(SavedItem.tab)
			try insert(into: &values)
			spaces[space].unpinnedTabs = values.compactMap { if case let .tab(id) = $0 { id } else { nil } }

		case .favorites:
			guard let index = profiles.index(id: destination.profileID)
			else { throw OrganizationMoveError.invalidDestination }

			var values = profiles[index].favorites.map(SavedItem.tab)
			try insert(into: &values)
			profiles[index].favorites = values.compactMap { if case let .tab(id) = $0 { id } else { nil } }
		}

		if placement.collection != .openTabs {
			for item in items {
				guard
					case let .tab(id) = item,
					let index = tabs.index(id: id),
					tabs[index].savedDestination == nil
				else { continue }

				tabs[index].savedDestination = .init(
					title: tabs[index].displayTitle,
					url: tabs[index].restoration.url
				)
			}
		}
	}
}
