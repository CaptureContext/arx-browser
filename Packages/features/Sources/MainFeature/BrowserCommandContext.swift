import BrowserCore
import Foundation

extension MainFeature.State {
	/// The Library shows only what this window can open.
	public var librarySections: [LibrarySection] {
		var sections: [LibrarySection] = []
		if mediaAvailable, !isPrivate { sections.append(.media) }
		if downloadsAvailable { sections.append(.downloads) }
		if !isPrivate { sections.append(.history) }
		sections.append(.spaces)
		if !isPrivate { sections.append(.archive) }
		return sections
	}

	/// What sits beside the rail. An unavailable selection falls back to the first available one.
	public var libraryPanel: LibrarySection? {
		librarySections.contains(librarySelection) ? librarySelection : librarySections.first
	}

	internal mutating func prepareArchivePanel() {
		guard !isPrivate, !archive.isWorking else { return }
		archive.profileID = sidebar.space.profileID
		archive.query = ""
		archive.spaceFilter = nil
		archive.selectedIDs = []
		archive.restorationConfirmation = nil
		archive.message = nil
		refreshArchive()
	}

	/// Commands that change the window's organization, shared by the command bar and the menus.
	public func organizationAction(for command: BrowserCommand) -> MainFeature.Action? {
		switch command {
		case .newSpace: .sidebar(.ui(.newSpace))

		case .nextSpace: adjacentSpace(by: 1).map { .sidebar(.ui(.spaceSelected($0))) }

		case .previousSpace: adjacentSpace(by: -1).map { .sidebar(.ui(.spaceSelected($0))) }

		case .toggleLibrary: .ui(.libraryOpenChanged(!isLibraryOpen))

		case .chats: .ui(.chatOpenChanged(!isChatOpen))

		case .pinChatToTab: .ui(.chatPlacement(.togglePinToTab))

		case .openChatInTab: .ui(.chatPlacement(.openInTab))

		case .moveItems: .sidebar(.ui(.sidebar(.chooseMoveDestination(nil))))

		case .archiveAllInSpace: .ui(.archiveSelectedTabs(sidebar.windowOpenTabs))

		// The Library's History page (DEV-817). The command bar's history-only mode stays.
		case .showHistory: .ui(.openLibrary(.history))

		case .nextTab: adjacentTab(by: 1).map { .ui(.selectTab($0)) }

		case .previousTab: adjacentTab(by: -1).map { .ui(.selectTab($0)) }

		case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab:
			tab(for: command).map { .ui(.selectTab($0)) }

		default: command.spaceNumber.flatMap(space(numbered:)).map { .sidebar(.ui(.spaceSelected($0))) }
		}
	}

	/// The tab a Select Tab command picks in the sidebar's order; the ninth is the last tab.
	private func tab(for command: BrowserCommand) -> BrowserCore.Tab.ID? {
		let order = sidebar.windowTabOrder
		guard let number = command.tabNumber else { return nil }
		if command == .lastTab { return order.last }
		return order.indices.contains(number - 1) ? order[number - 1] : nil
	}

	/// The tab `step` places from the current one in the sidebar's order, wrapping.
	/// Without a current tab, Next picks the first one and Previous the last.
	private func adjacentTab(by step: Int) -> BrowserCore.Tab.ID? {
		let order = sidebar.windowTabOrder
		guard !order.isEmpty else { return nil }
		guard
			let current = viewer.item.tab?.id ?? sidebar.selectedTab?.id,
			let index = order.firstIndex(of: current)
		else { return step > 0 ? order.first : order.last }

		return order[(index + step + order.count) % order.count]
	}

	/// The Nth space in the switcher's and the Library's order, counting from 1.
	private func space(numbered number: Int) -> Space.ID? {
		let spaces = sidebar.organization.spaces
		return spaces.indices.contains(number - 1) ? spaces[number - 1].id : nil
	}

	private func adjacentSpace(by step: Int) -> Space.ID? {
		let spaces = sidebar.organization.spaces
		guard
			!spaces.isEmpty,
			let index = spaces.firstIndex(where: { $0.id == sidebar.spaceID })
		else { return nil }

		return spaces[(index + step + spaces.count) % spaces.count].id
	}

	public var commandContext: BrowserCommandContext {
		context(
			for: viewer.item.tab ?? (!viewer.isSplit ? sidebar.selectedTab : nil),
			navigation: viewer.item.navigation,
			isReading: viewer.item.reader != nil
		)
	}

	public func commandContext(in paneID: UUID) -> BrowserCommandContext? {
		guard let pane = viewer.panes[id: paneID] else { return nil }
		return context(for: pane.item.tab, navigation: pane.item.navigation, isReading: pane.item.reader != nil)
	}

	private func context(
		for tab: BrowserCore.Tab?,
		navigation: BrowserNavigation,
		isReading: Bool
	) -> BrowserCommandContext {
		let isBusy = transferInProgress
		|| pendingFolderDeletion != nil
		|| !pendingTabCloses.isEmpty
		|| archive.isWorking

		return .init(
			host: .main,
			hasTab: tab != nil,
			isSaved: tab.flatMap { item in sidebar.organization.tabs[id: item.id] }?.savedDestination != nil,
			isPrivate: isPrivate,
			isBusy: isBusy,
			isClosing: isClosing,
			canUndo: !sidebar.undo.isEmpty,
			canReopenArchivedTab: sidebar.organization.archive.contains {
				$0.tab.profileID == sidebar.space.profileID
			},
			canReopenClosedWindow: canReopenClosedWindow,
			canArchiveSelectedTabs: !archiveSelection(fallback: tab?.id).isEmpty,
			canArchiveSpace: !sidebar.windowOpenTabs.isEmpty,
			canSwitchSpace: sidebar.organization.spaces.count > 1,
			spaceCount: sidebar.organization.spaces.count,
			isSplit: viewer.isSplit,
			canAddPane: canAddSplitPane,
			canGoBack: navigation.canGoBack,
			canGoForward: navigation.canGoForward,
			isLoading: navigation.isLoading,
			canSavePage: navigation.showsWebPage,
			tabCount: sidebar.windowTabOrder.count,
			captureAvailable: captureAvailable,
			downloadsAvailable: downloadsAvailable,
			// WebKit pages aren't darkened, so the command doesn't turn their site off (DEV-1020).
			darkPagesOffered: darkPagesOffered && navigation.engine != .webKit,
			mediaAvailable: mediaAvailable,
			canPresentMedia: tab.map { presentableMediaTabs.contains($0.id) } ?? false,
			developerModeEnabled: developerModeEnabled,
			readingModeEnabled: readingModeEnabled,
			isReading: isReading,
			usesWebKit: navigation.engine == .webKit,
			// Hide Element is uBlock's picker, so it needs content blocking on, and its feature flag
			// while the picker is proven (DEV-1019).
			canHideElements: siteMenu.hideElementEnabled && siteMenu.general.blocksContent,
			pageTranslationEnabled: pageTranslationEnabled,
			// The page's address, as the proxy link commands copy it (DEV-1262).
			canProxyLink: (navigation.url ?? tab?.restoration.url)
				.map { LinkTransformer.proxies($0, rules: proxyLinkRules) } ?? false
		)
	}
}

/// A chat placement command for the app to carry out with the chat the window shows (DEV-761).
public enum ChatPlacementRequest: Equatable, Sendable {
	/// Pins the window's chat to the current tab, or unpins the tab's chat when it has one.
	case togglePinToTab

	/// Opens the window's chat as a chat tab.
	case openInTab
}
