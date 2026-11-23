import AppUI
import BrowserCore
import Foundation

extension PreviewFeature.State {
	internal var space: Space {
		organization.spaces[id: spaceID] ?? organization.spaces[0]
	}

	internal var selectedTab: BrowserCore.Tab? {
		organization.tabs[id: space.selectedTabID]
	}

	internal var favorites: [SidebarItem] {
		(organization.profiles[id: space.profileID]?.favorites ?? [])
			.compactMap(tabItem)
	}

	internal var savedItems: [SidebarItem] { space.savedItems.compactMap(item) }

	internal var openTabs: [SidebarItem] { space.unpinnedTabs.compactMap(tabItem) }

	internal var sidebarSpaces: [SidebarSpace] {
		organization.spaces.filter { $0.profileID == space.profileID }.map { space in
			.init(
				id: space.id.rawValue,
				name: space.name,
				isExpanded: !collapsedSpaces.contains(space.id),
				favorites: favorites,
				savedItems: space.savedItems.compactMap(item),
				unpinnedTabs: space.unpinnedTabs.compactMap(tabItem),
				selectedID: space.selectedTabID.map { .tab($0.rawValue) },
				url: organization.tabs[id: space.selectedTabID]?.restoration.url
			)
		}
	}

	internal func tabItem(_ id: BrowserCore.Tab.ID) -> SidebarItem? {
		guard let tab = organization.tabs[id: id] else { return nil }
		let (symbol, tint) = PreviewFixture.icon(for: tab)
		let isAtInitialState = tab.savedDestination.map { destination in
			destination.url == tab.restoration.url && destination.title == tab.restoration.title
		} ?? true

		return .init(
			id: .tab(id.rawValue),
			title: tab.displayTitle,
			symbol: symbol,
			tint: tint,
			isPinned: tab.savedDestination != nil,
			isAtInitialState: isAtInitialState
		)
	}

	internal func item(_ item: SavedItem) -> SidebarItem? {
		switch item {
		case let .tab(id):
			return tabItem(id)

		case let .folder(id):
			guard let folder = organization.folders[id: id] else { return nil }
			return .init(
				id: .folder(id.rawValue),
				title: folder.name,
				symbol: "folder.fill",
				tint: .lavender,
				children: folder.children.compactMap(self.item),
				isExpanded: folder.isExpanded
			)
		}
	}

	internal var proposedURL: URL? {
		let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return nil }
		let directURL = URL(string: text).flatMap { url in
			["https", "http"].contains(url.scheme ?? "") && url.host() != nil ? url : nil
		}
		if let directURL { return directURL }

		let looksLikeHost = text.contains(".") && !text.contains(" ")
		if looksLikeHost, let url = URL(string: "https://\(text)"), url.host() != nil { return url }

		var search = URLComponents(string: "https://www.google.com/search")!
		search.queryItems = [.init(name: "q", value: text)]
		return search.url
	}

	internal var commandResults: [CommandBarResult] {
		let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		var tabs = organization.tabs.filter { $0.profileID == space.profileID }
		if query.isEmpty {
			tabs.sort { lhs, rhs in
				if lhs.id == space.selectedTabID { return true }
				if rhs.id == space.selectedTabID { return false }
				return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
			}
		} else {
			tabs = tabs.filter { tab in
				tab.displayTitle.localizedCaseInsensitiveContains(query)
				|| tab.restoration.url.absoluteString.localizedCaseInsensitiveContains(query)
			}
		}
		var results = tabs.prefix(query.isEmpty ? 5 : 30).map { tab in
			let (symbol, tint) = PreviewFixture.icon(for: tab)
			return CommandBarResult(
				id: tab.id.rawValue.uuidString,
				title: tab.displayTitle,
				subtitle: query.isEmpty ? "" : tab.restoration.url.host() ?? "",
				actionTitle: String.localized(.appUI.command.switchToTab),
				symbol: symbol,
				tint: tint
			)
		}
		if !query.isEmpty {
			results += organization.folders
				.filter { $0.spaceID == spaceID && $0.name.localizedCaseInsensitiveContains(query) }
				.map { folder in
					.init(
						id: "folder:\(folder.id.rawValue)",
						title: folder.name,
						actionTitle: String.localized(.appUI.command.openFolder),
						symbol: "folder.fill",
						tint: .lavender
					)
				}
			results += organization.spaces
				.filter { $0.profileID == space.profileID && $0.name.localizedCaseInsensitiveContains(query) }
				.map { match in
					.init(
						id: "space:\(match.id.rawValue)",
						title: match.name,
						actionTitle: String.localized(.appUI.command.switchToSpace),
						symbol: "square.stack",
						tint: .lavender
					)
				}
			let commands: [CommandBarResult] = [
				.init(
					id: "new-folder",
					title: String.localized(.appUI.sidebar.newFolder),
					actionTitle: String.localized(.appUI.command.action),
					symbol: "folder.badge.plus"
				),
				.init(
					id: "toggle-sidebar",
					title: String.localized(.appUI.sidebar.toggle),
					actionTitle: String.localized(.appUI.command.action),
					symbol: "sidebar.left"
				),
				.init(
					id: "undo",
					title: String.localized(.appUI.common.undo),
					actionTitle: String.localized(.appUI.command.action),
					symbol: "arrow.uturn.backward"
				),
			]
			results += commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
			let openURL: CommandBarResult = .init(
				id: "open-url",
				title: query.contains(".") ? query : String.localized(.appUI.command.searchFor(query)),
				actionTitle: String.localized(.appUI.sidebar.newTab),
				symbol: "magnifyingglass"
			)
			results.append(openURL)
		}
		return results
	}

	internal mutating func selectSpace(_ id: Space.ID) {
		guard organization.spaces.ids.contains(id) else { return }
		organization.preserveFavoriteSelection(from: spaceID, to: id)
		spaceID = id
	}

	internal mutating func select(_ id: BrowserCore.Tab.ID) {
		if case let .pinned(destination, folder) = organization.location(of: id) {
			spaceID = destination
			reveal(folder)
		} else if case let .unpinned(destination) = organization.location(of: id) {
			spaceID = destination
		}
		if let index = organization.spaces.firstIndex(where: { $0.id == spaceID }) {
			organization.spaces[index].selectedTabID = id
		}
		message = nil
	}

	internal mutating func reveal(_ folderID: Folder.ID?) {
		collapsedSpaces.remove(spaceID)
		var current = folderID
		while let id = current {
			if let index = organization.folders.firstIndex(where: { $0.id == id }) {
				organization.folders[index].isExpanded = true
			}
			current = organization.folders.first(where: { $0.children.contains(.folder(id)) })?.id
		}
	}

	internal mutating func edit(_ change: (inout BrowserOrganization) throws -> Void) {
		let previous = organization
		do {
			try organization.update(change)
			if previous != organization { undo.append(previous) }
			message = nil
		} catch {
			message = String.localized(.appUI.preview.invalidMove)
		}
	}
}
