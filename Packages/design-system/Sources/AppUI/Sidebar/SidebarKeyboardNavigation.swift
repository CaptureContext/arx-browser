/// Where an arrow key takes keyboard focus among the sidebar's rows, as in Finder's list view
/// and NSOutlineView. Moving focus never selects a tab; Space still does.
internal enum SidebarKeyboardNavigation {
	internal enum Key: Equatable, Sendable {
		case up
		case down
		case left
		case right
	}

	internal enum Outcome: Equatable, Sendable {
		/// Move keyboard focus to this row.
		case focus(SidebarItem.ID)

		/// Expand or collapse this folder; focus stays on it.
		case toggle(SidebarItem.ID)
	}

	/// - Parameters:
	///   - rows: the visible rows in reading order: a collapsed folder's children left out, except
	///     the selected tab it still shows (DEV-1110).
	internal static func outcome(
		of key: Key,
		from id: SidebarItem.ID,
		in rows: [SidebarTreeRow]
	) -> Outcome? {
		guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
		let row = rows[index]

		switch key {
		case .up:
			return index > 0 ? .focus(rows[index - 1].id) : nil

		case .down:
			return index < rows.count - 1 ? .focus(rows[index + 1].id) : nil

		case .right:
			guard row.item.isFolder else { return nil }
			guard row.item.isExpanded else {
				return row.item.interactions.contains(.disclose) ? .toggle(id) : nil
			}

			// The first child follows its expanded folder, one level deeper.
			guard
				index < rows.count - 1,
				rows[index + 1].depth == row.depth + 1
			else { return nil }
			return .focus(rows[index + 1].id)

		case .left:
			if row.item.isFolder, row.item.isExpanded, row.item.interactions.contains(.disclose) {
				return .toggle(id)
			}
			guard row.depth > 0 else { return nil }

			// The parent is the nearest row above that sits one level up.
			let parent = rows[..<index].last { $0.depth == row.depth - 1 }
			return parent.map { .focus($0.id) }
		}
	}
}
