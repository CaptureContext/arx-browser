import Foundation

extension BrowserOrganization {
	/// A space's tabs in sidebar order: its profile's favorites, its saved tabs
	/// depth-first through folders (collapsed or not), then its unpinned tabs.
	public func tabOrder(in spaceID: Space.ID) -> [Tab.ID] {
		guard let space = spaces[id: spaceID]
		else { return [] }

		var order = profiles[id: space.profileID]?.favorites ?? []
		var visited: Set<Folder.ID> = []

		func append(_ items: [SavedItem]) {
			for item in items {
				switch item {
				case let .tab(id):
					order.append(id)

				case let .folder(id):
					guard
						visited.insert(id).inserted,
						let folder = folders[id: id]
					else { continue }

					append(folder.children)
				}
			}
		}

		append(space.savedItems)
		order += space.unpinnedTabs
		return order
	}
}
