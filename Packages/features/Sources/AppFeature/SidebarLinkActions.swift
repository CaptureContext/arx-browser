import BrowserCore
import Foundation
import MainFeature

extension AppFeature.State {
	/// Revalidates the complete sidebar selection instead of silently copying surviving stale targets.
	public func sidebarLinkItems(
		in windowID: UUID,
		tabIDs: [UUID],
		saved: Bool = false
	) -> [LinkCopyItem] {
		let window = windowID == main.id ? (windowIsOpen ? main : nil) : windows[id: windowID]
		guard let window, !window.isClosing else { return [] }
		let organization = window.isPrivate ? window.sidebar.organization : workspace
		guard
			let space = organization.spaces[id: window.sidebar.spaceID],
			space.profileID == window.sidebar.space.profileID
		else { return [] }

		var seen: Set<UUID> = []
		var items: [LinkCopyItem] = []
		for id in tabIDs where seen.insert(id).inserted {
			guard
				let tab = organization.tabs.first(where: { $0.id.rawValue == id }),
				tab.profileID == space.profileID
			else { return [] }
			switch organization.location(of: tab.id) {
			case let .favorite(profileID):
				guard profileID == space.profileID else { return [] }
			case let .pinned(spaceID, _), let .unpinned(spaceID):
				guard spaceID == space.id else { return [] }
			case nil: return []
			}

			if saved {
				guard let destination = tab.savedDestination else { return [] }
				items.append(.init(title: destination.title, url: destination.url))
				continue
			}
			let navigation = sidebarLinkNavigation(for: tab, in: window)
			items.append(.init(
				title: navigation.flatMap { $0.title.isEmpty ? nil : $0.title } ?? tab.displayTitle,
				url: navigation?.url ?? tab.restoration.url
			))
		}
		return items
	}

	private func sidebarLinkNavigation(
		for tab: BrowserCore.Tab,
		in source: MainFeature.State
	) -> BrowserNavigation? {
		if !source.isPrivate, let peek = peeks.first(where: { $0.tab.id == tab.id && $0.tab.profileID == tab.profileID }) {
			return peek.viewer.navigation
		}
		if let navigation = source.viewer.panes.first(where: { $0.item.tab?.id == tab.id })?.item.navigation {
			return navigation
		}
		guard !source.isPrivate else { return nil }
		let owners = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		return owners.lazy.flatMap(\.viewer.panes)
			.first(where: { $0.item.tab?.id == tab.id && $0.item.tab?.profileID == tab.profileID })?.item.navigation
	}
}
