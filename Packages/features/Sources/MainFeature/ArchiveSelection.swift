import BrowserCore
import Foundation

extension MainFeature.State {
	public var archiveSelectedTabIDs: [BrowserCore.Tab.ID] {
		archiveSelection(fallback: sidebar.selectedTab?.id)
	}

	/// An explicit selection never falls back to an unrelated active page.
	/// Resolve in sidebar order, regardless of the order in which rows were selected.
	internal func archiveSelection(fallback: BrowserCore.Tab.ID?) -> [BrowserCore.Tab.ID] {
		let selected: Set<BrowserCore.Tab.ID>
		if sidebar.moveSelection.isEmpty {
			selected = Set(fallback.map { [$0] } ?? [])

		} else {
			selected = Set(sidebar.moveSelection.compactMap { item in
				guard case let .tab(id) = item else { return nil }
				return BrowserCore.Tab.ID(rawValue: id)
			})
		}

		return sidebar.organization.spaces
			.filter { $0.profileID == sidebar.space.profileID }
			.flatMap(\.unpinnedTabs)
			.filter { selected.contains($0) }
	}
}
