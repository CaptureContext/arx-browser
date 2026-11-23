import Foundation

extension SidebarItem {
	/// Folders are not links. Only explicitly selected tabs participate, in selection order.
	public var linkTabIDs: [UUID] {
		guard case let .tab(clickedID) = id else { return [] }
		guard moveSelection.contains(id) else { return [clickedID] }
		var seen: Set<UUID> = []
		return moveSelection.compactMap { item in
			guard case let .tab(id) = item, seen.insert(id).inserted else { return nil }
			return id
		}
	}
}
