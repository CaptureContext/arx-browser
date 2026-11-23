import Foundation

extension BrowserOrganization {
	/// Pins are returned in visible tree order, without expanding nested folders implicitly.
	public func tabs(
		in folderID: Folder.ID,
		includingDescendants: Bool = false
	) -> [Tab.ID] {
		guard let folder = folders[id: folderID] else { return [] }
		var visited: Set<Folder.ID> = [folderID]
		func collect(_ items: [SavedItem]) -> [Tab.ID] {
			items.flatMap { item -> [Tab.ID] in
				switch item {
				case let .tab(id):
					return [id]

				case let .folder(id):
					guard
						includingDescendants,
						visited.insert(id).inserted,
						let child = folders[id: id]
					else { return [] }
					return collect(child.children)
				}
			}
		}
		return collect(folder.children)
	}

	/// Captures the exact subtree whose live pages must agree to close before deletion.
	public func folderSubtree(_ id: Folder.ID) -> [Folder] {
		var visited: Set<Folder.ID> = []
		func collect(_ id: Folder.ID) -> [Folder] {
			guard visited.insert(id).inserted, let folder = folders[id: id]
			else { return [] }
			return [folder] + folder.children.flatMap { item -> [Folder] in
				guard case let .folder(childID) = item else { return [] }
				return collect(childID)
			}
		}
		return collect(id)
	}

	/// Replaces a folder in its parent with its ordered children; their identities are retained.
	public mutating func ungroupFolder(_ id: Folder.ID) throws {
		try update { organization in
			guard let folder = organization.folders[id: id]
			else { throw FolderEditingError.missingFolder }
			try organization.replaceFolder(id, with: folder.children)
			organization.folders.removeAll { $0.id == id }
		}
	}

	/// The caller obtains close approval for every descendant session before committing this edit.
	public mutating func deleteFolder(_ id: Folder.ID) throws {
		try update { organization in
			guard organization.folders.ids.contains(id)
			else { throw FolderEditingError.missingFolder }
			let folderIDs = Set(organization.folderSubtree(id).map(\.id))
			let tabIDs = Set(organization.tabs(in: id, includingDescendants: true))
			try organization.replaceFolder(id, with: [])
			organization.folders.removeAll { folderIDs.contains($0.id) }
			organization.tabs.removeAll { tabIDs.contains($0.id) }
			for index in organization.spaces.indices {
				if let selected = organization.spaces[index].selectedTabID, tabIDs.contains(selected) {
					organization.spaces[index].selectedTabID = nil
				}
			}
		}
	}

	public mutating func updateSavedURL(_ id: Tab.ID) throws {
		try update { organization in
			guard
				let index = organization.tabs.index(id: id),
				organization.tabs[index].savedDestination != nil
			else { throw FolderEditingError.missingPin }
			let currentURL = organization.tabs[index].restoration.url
			organization.tabs[index].savedDestination?.url = currentURL
		}
	}

	private mutating func replaceFolder(
		_ id: Folder.ID,
		with children: [SavedItem]
	) throws {
		for index in spaces.indices {
			if let position = spaces[index].savedItems.firstIndex(of: .folder(id)) {
				spaces[index].savedItems.replaceSubrange(position...position, with: children)
				return
			}
		}
		for index in folders.indices {
			if let position = folders[index].children.firstIndex(of: .folder(id)) {
				folders[index].children.replaceSubrange(position...position, with: children)
				return
			}
		}
		throw FolderEditingError.missingFolder
	}
}

private enum FolderEditingError: Error {
	case missingFolder
	case missingPin
}
