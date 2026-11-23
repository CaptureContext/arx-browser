import BrowserCore

extension BrowserOrganization {
	/// Retain a window's selected position when a space gets new profile-bound tab identities.
	internal func selection(
		_ id: BrowserCore.Tab.ID?,
		from previous: BrowserOrganization,
		in space: Space
	) -> BrowserCore.Tab.ID? {
		guard let id, let oldSpace = previous.spaces[id: space.id] else { return nil }
		guard oldSpace.profileID != space.profileID else { return id }

		switch previous.location(of: id) {
		case .unpinned(space.id):
			guard
				let index = oldSpace.unpinnedTabs.firstIndex(of: id),
				space.unpinnedTabs.indices.contains(index)
			else { return nil }
			return space.unpinnedTabs[index]

		case let .pinned(space.id, folderID):
			let oldItems = folderID.flatMap { folder in previous.folders[id: folder]?.children }
			?? oldSpace.savedItems
			let newItems = folderID.flatMap { folder in folders.first { $0.id == folder }?.children }
			?? space.savedItems
			guard
				let index = oldItems.firstIndex(of: .tab(id)),
				newItems.indices.contains(index),
				case let .tab(replacement) = newItems[index]
			else { return nil }
			return replacement

		default:
			return nil
		}
	}
}
