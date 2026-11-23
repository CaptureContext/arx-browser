import Foundation

/// Visible tree rows retain their indentation for pointer-based drop placement.
internal struct SidebarTreeRow: Identifiable {
	internal let item: SidebarItem
	internal let depth: Int

	/// A collapsed folder showing its selected tab beneath it (DEV-1110).
	internal let isPartlyRevealed: Bool

	/// The collapsed folder a selected tab shows under when the tab really sits in a folder
	/// inside it, so a drop beside the tab lands in the folder the person sees (DEV-1110).
	internal let shownParentID: SidebarItem.ID?

	/// A row of a folder that is closing, folded to no height while the folder closes, so the
	/// rows below close up with it (DEV-1249). Nothing else sees it: not the keyboard, a drop or
	/// VoiceOver.
	internal let isFolded: Bool

	internal init(
		item: SidebarItem,
		depth: Int,
		isPartlyRevealed: Bool = false,
		shownParentID: SidebarItem.ID? = nil,
		isFolded: Bool = false
	) {
		self.item = item
		self.depth = depth
		self.isPartlyRevealed = isPartlyRevealed
		self.shownParentID = shownParentID
		self.isFolded = isFolded
	}

	internal var id: SidebarItem.ID { item.id }

	/// The rows a person sees, in reading order.
	///
	/// - Parameters:
	///   - revealed: the selected tab and the rest of its split. A collapsed folder holding one
	///     still shows it, and only it, one level in (DEV-1110).
	///   - folding: folders that are closing. A collapsed one still lists the rows it showed
	///     open, folded, around the ones it keeps showing (DEV-1249).
	internal static func flatten(
		_ items: [SidebarItem],
		depth: Int = 0,
		revealing revealed: Set<SidebarItem.ID> = [],
		folding: Set<SidebarItem.ID> = []
	) -> [Self] {
		items.flatMap { item in
			guard item.isFolder else { return [Self(item: item, depth: depth)] }

			if item.isExpanded {
				return [Self(item: item, depth: depth)]
				+ flatten(item.children, depth: depth + 1, revealing: revealed, folding: folding)
			}

			let shown: [Self] = revealedDescendants(of: item, revealed)
				.map { child, isNested in
					Self(item: child, depth: depth + 1, shownParentID: isNested ? item.id : nil)
				}
			let folder = Self(item: item, depth: depth, isPartlyRevealed: !shown.isEmpty)
			guard folding.contains(item.id) else { return [folder] + shown }

			// The rows it showed open, in their order, each shown one where it was.
			let shownByID: [SidebarItem.ID: Self] = .init(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
			let open: [Self] = flatten(item.children, depth: depth + 1, revealing: revealed, folding: folding)
				.map { row in
					shownByID[row.id] ?? Self(item: row.item, depth: row.depth, isFolded: true)
				}
			return [folder] + open
		}
	}

	/// The folders and tab groups among `items` that show their rows, however deep.
	internal static func expandedFolderIDs(in items: [SidebarItem]) -> Set<SidebarItem.ID> {
		items.reduce(into: []) { ids, item in
			guard item.isFolder else { return }
			if item.isExpanded { ids.insert(item.id) }
			ids.formUnion(expandedFolderIDs(in: item.children))
		}
	}

	/// The tabs or Split View rows deep in a collapsed folder that stay visible. They sit under
	/// the outermost collapsed folder, the nearest one still on screen, however deep they are.
	/// Each comes with whether it sits in a folder inside `folder` rather than in `folder` itself.
	private static func revealedDescendants(
		of folder: SidebarItem,
		_ revealed: Set<SidebarItem.ID>
	) -> [(item: SidebarItem, isNested: Bool)] {
		guard !revealed.isEmpty else { return [] }

		return folder.children.flatMap { child -> [(item: SidebarItem, isNested: Bool)] in
			if child.isFolder {
				return revealedDescendants(of: child, revealed).map { ($0.item, true) }
			}

			let isRevealed: Bool = revealed.contains(child.id)
			|| child.split?.memberIDs.contains(where: revealed.contains) == true
			return isRevealed ? [(child, false)] : []
		}
	}

	internal static func find(
		_ id: SidebarItem.ID,
		in items: [SidebarItem]
	) -> SidebarItem? {
		for item in items {
			// A Split View row stands for each of its members (DEV-1006).
			if item.id == id || item.split?.memberIDs.contains(id) == true { return item }
			if let match = find(id, in: item.children) { return match }
		}
		return nil
	}
}
