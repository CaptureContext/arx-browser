import AppUI
import BrowserCore
import Foundation

extension SidebarFeature.State {
	public var space: Space {
		organization.spaces[id: spaceID] ?? organization.spaces[0]
	}

	public var selectedTab: BrowserCore.Tab? {
		organization.tabs[id: space.selectedTabID]
	}

	public var favorites: [SidebarItem] {
		(organization.profiles[id: space.profileID]?.favorites ?? [])
			.compactMap(tabItem)
	}

	public var savedItems: [SidebarItem] { rows(space.savedItems) }
	public var openTabs: [SidebarItem] { openTabItems(in: space) }

	/// A space's open tabs, each Split View group as one row where its first member is, and each
	/// tab group as a row holding its tabs (DEV-911).
	public func openTabItems(in space: Space) -> [SidebarItem] {
		let items = openTabRows(in: space)
		let groups = organization.tabGroups.filter { $0.spaceID == space.id }
		guard !groups.isEmpty else { return items }

		var result: [SidebarItem] = []

		// A group shows once; tabs of one that isn't one run yet show as they are.
		var shown: Set<TabGroup.ID> = []
		var index = 0
		while index < items.count {
			guard
				case let .tab(uuid) = items[index].id,
				let group = groups.first(where: { $0.tabIDs.contains(.init(rawValue: uuid)) }),
				shown.insert(group.id).inserted
			else {
				result.append(items[index])
				index += 1
				continue
			}

			var children: [SidebarItem] = []
			while index < items.count, case let .tab(member) = items[index].id, group.tabIDs.contains(.init(rawValue: member)) {
				children.append(items[index])
				index += 1
			}
			result.append(.init(
				id: .folder(group.id.rawValue),
				title: group.name,
				symbol: "folder.fill",
				tint: .lavender,
				children: children,
				isExpanded: group.isExpanded,
				isPinned: false,
				moveSelection: moveSelection,
				interactions: [.rename, .disclose],
				isTabGroup: true
			))
		}
		return result
	}

	private func openTabRows(in space: Space) -> [SidebarItem] {
		// Another window's open tabs, and so its split members, stay out of this window (DEV-822).
		rows(windowOpenTabs(in: space).map(SavedItem.tab))
	}

	/// A list's rows: open tabs, Pinned or a folder's, with each Split View group as one row where
	/// its first tab in the list is (DEV-1006). The row shows the group's tabs in this list; its
	/// Favorites stay in the grid, so a group of one tab and Favorites is that tab's own row.
	private func rows(_ items: [SavedItem]) -> [SidebarItem] {
		guard !organization.splits.isEmpty else { return items.compactMap(item) }

		var listed: Set<BrowserCore.Tab.ID> = []
		for case let .tab(id) in items { listed.insert(id) }
		var shown: Set<SplitGroup.ID> = []
		return items.compactMap { saved in
			guard
				case let .tab(id) = saved,
				let group = organization.splits.first(where: { $0.tabIDs.contains(id) })
			else { return item(saved) }
			guard shown.insert(group.id).inserted, var row = tabItem(id) else { return nil }

			let members = group.tabIDs.filter(listed.contains)
			guard members.count >= 2 else {
				row.splitPanes = .init(count: group.tabIDs.count, isVertical: group.orientation == .vertical)
				return row
			}
			row.split = .init(
				id: group.id.rawValue,
				members: members.compactMap(tabItem),
				paneIDs: group.tabIDs.map { .tab($0.rawValue) },
				title: group.title,
				icon: group.icon,
				isVertical: group.orientation == .vertical
			)
			return row
		}
	}

	/// Every space with all its tabs, as the Library's Spaces page shows them side by side.
	public var sidebarSpaces: [SidebarSpace] {
		organization.spaces.map(sidebarSpace)
	}

	/// What the sidebar's pager reads about every space. Its tabs are left to the space's own
	/// page, through ``sidebarSpace(_:)``, so building this doesn't grow with the tabs.
	public var sidebarSpaceSummaries: [SidebarSpaceSummary] {
		// Spaces of one profile share its Favorites.
		var favorites: [Profile.ID: [SidebarItem]] = [:]
		return organization.spaces.map { space in
			let profileFavorites: [SidebarItem]
			if let cached = favorites[space.profileID] {
				profileFavorites = cached
			} else {
				profileFavorites = (organization.profiles[id: space.profileID]?.favorites ?? []).compactMap(tabItem)
				favorites[space.profileID] = profileFavorites
			}
			return .init(
				id: space.id.rawValue,
				profileID: space.profileID.rawValue,
				profileName: organization.profiles[id: space.profileID]?.name,
				hasSavedItems: space.savedItems.contains(where: exists),
				favorites: profileFavorites,
				selectedID: space.selectedTabID.map { .tab($0.rawValue) },
				url: organization.tabs[id: space.selectedTabID]?.restoration.url
			)
		}
	}

	/// One space with all its tabs, for its page in the sidebar.
	public func sidebarSpace(_ id: Space.ID) -> SidebarSpace? {
		organization.spaces[id: id].map(sidebarSpace)
	}

	private func sidebarSpace(_ space: Space) -> SidebarSpace {
		.init(
			id: space.id.rawValue,
			name: space.name,
			symbol: (space.icon ?? .dot).rawValue,
			profileID: space.profileID.rawValue,
			profileName: organization.profiles[id: space.profileID]?.name,
			isExpanded: !collapsedSpaces.contains(space.id),
			favorites: (organization.profiles[id: space.profileID]?.favorites ?? [])
				.compactMap(tabItem),
			savedItems: rows(space.savedItems),
			unpinnedTabs: openTabItems(in: space),
			selectedID: space.selectedTabID.map { .tab($0.rawValue) },
			url: organization.tabs[id: space.selectedTabID]?.restoration.url
		)
	}

	/// Whether a saved item still has its tab or folder, as `item(_:)` shows only those.
	private func exists(_ item: SavedItem) -> Bool {
		switch item {
		case let .tab(id): organization.tabs[id: id] != nil
		case let .folder(id): organization.folders[id: id] != nil
		}
	}

	public func tabItem(_ id: BrowserCore.Tab.ID) -> SidebarItem? {
		guard let tab = organization.tabs[id: id] else { return nil }

		// A chat tab (DEV-761) shows the assistant's face instead of a site's icon.
		let symbol = tab.isChat ? SidebarItem.assistantSymbol : SidebarItem.siteSymbol
		let tint: SidebarTint = .lavender
		let isAtInitialState: Bool = tab.savedDestination
			.map { $0.url == tab.restoration.url && $0.title == tab.restoration.title }
		?? true

		return .init(
			id: .tab(id.rawValue),
			title: tab.displayTitle,
			symbol: symbol,
			siteIcon: tab.isChat ? nil : .init(
				profileID: tab.profileID.rawValue,
				pageURL: tab.siteIconURL
			),
			tint: tint,
			isPinned: tab.savedDestination != nil,
			isAtInitialState: isAtInitialState,
			moveSelection: moveSelection,
			localHost: LocalDevelopment.hostLabel(tab.restoration.url),
			// A chat tab plays nothing to mute.
			audio: tab.isChat ? nil : tabAudio[id] ?? defaultTabAudio,
			isUnloaded: unloadedTabs.contains(id),
			usesWebKit: webKitTabs.contains(id),
			agent: tabAgents[id],
			selection: bulkSelection(containing: id),
			unread: unread(tab),
			unreadBadges: unreadBadgeChoice(tab),
			keepLoaded: keepLoaded(tab),
			customIcon: tab.icon,
			isPickingIcon: iconPickerTabID == id
		)
	}

	/// The tab's site and whether its profile keeps it loaded (DEV-932); none for a chat tab or
	/// a page off the web.
	private func keepLoaded(_ tab: BrowserCore.Tab) -> SidebarItem.KeepLoaded? {
		guard
			!tab.isChat,
			let profile = organization.profiles[id: tab.profileID],
			let site = KeptLoadedSite.site(of: tab.restoration.url)
		else { return nil }

		return .init(site: site, isKept: profile.keepsLoaded(tab.restoration.url))
	}

	/// The tab's own unread badges choice and what it inherits from its site, its profile and the
	/// browser default (DEV-1258); none for a chat tab, which has no badge.
	private func unreadBadgeChoice(_ tab: BrowserCore.Tab) -> SidebarItem.UnreadBadges? {
		guard !tab.isChat else { return nil }

		return .init(
			tab: unreadBadgeOverrides.tabs[tab.id],
			inherited: unreadBadgeOverrides.inherited(
				by: tab,
				profile: organization.profiles[id: tab.profileID]?.unreadBadges,
				browser: .init(shows: showsUnreadBadges)
			)
		)
	}

	/// What the tab has unread (DEV-907): its live page's last report, or what its saved title
	/// says, unless the tab, its site, its profile or the browser default hides badges (DEV-1258).
	private func unread(_ tab: BrowserCore.Tab) -> SidebarItem.Unread? {
		guard
			!tab.isChat,
			unreadBadgeChoice(tab)?.resolved.shows == true
		else { return nil }

		let host = tab.unreadBadgeHost
		let badge = unreadBadges[tab.id] ?? UnreadBadge(title: tab.restoration.title)
		guard badge.isVisible else { return nil }

		return .init(badge: badge, host: host)
	}

	/// The selection a selected tab's bulk menu acts on, while it holds several tabs (DEV-883).
	private func bulkSelection(containing id: BrowserCore.Tab.ID) -> SidebarItem.Selection? {
		guard
			moveSelection.count > 1,
			moveSelection.contains(.tab(id.rawValue))
		else { return nil }

		var tabIDs: [SidebarItem.ID] = []
		var openTabCount: Int = 0
		var savedTabCount: Int = 0
		for case let .tab(uuid) in moveSelection where !tabIDs.contains(.tab(uuid)) {
			guard let tab = organization.tabs[id: .init(rawValue: uuid)] else { continue }
			tabIDs.append(.tab(uuid))
			if tab.savedDestination == nil {
				openTabCount += 1
			} else {
				savedTabCount += 1
			}
		}
		guard tabIDs.count > 1 else { return nil }

		return .init(
			tabIDs: tabIDs,
			openTabCount: openTabCount,
			savedTabCount: savedTabCount
		)
	}

	public func item(_ item: SavedItem) -> SidebarItem? {
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
				children: rows(folder.children),
				isExpanded: folder.isExpanded,
				moveSelection: moveSelection
			)
		}
	}

	public mutating func selectSpace(_ id: Space.ID) {
		guard organization.spaces.ids.contains(id) else { return }
		organization.preserveFavoriteSelection(from: spaceID, to: id)
		spaceID = id
	}

	/// Selects the tab in its own space, or in this space when it's a Favorite of the space's
	/// profile. A tab the organization doesn't place there, such as one another window or an agent
	/// just closed or moved while this window still shows it, leaves the selection as it was: a
	/// space selecting a tab it doesn't hold makes every later save fail (DEV-1261).
	public mutating func select(_ id: BrowserCore.Tab.ID) {
		switch organization.location(of: id) {
		case let .pinned(destination, folder):
			spaceID = destination

			// A collapsed folder stays collapsed and shows the tab beneath it (DEV-1110).
			reveal(SidebarFolderReveal.isEnabled ? nil : folder)

		case let .unpinned(destination):
			spaceID = destination

		case let .favorite(profileID):
			guard organization.spaces[id: spaceID]?.profileID == profileID
			else { return }

		case nil:
			return
		}
		if let index = organization.spaces.index(id: spaceID) {
			organization.spaces[index].selectedTabID = id
		}
		message = nil
	}

	public mutating func reveal(_ folderID: Folder.ID?) {
		collapsedSpaces.remove(spaceID)
		var current = folderID
		while let id = current {
			if let index = organization.folders.firstIndex(where: { $0.id == id }) {
				organization.folders[index].isExpanded = true
			}
			current = organization.folders.first(where: { $0.children.contains(.folder(id)) })?.id
		}
	}

	internal func requiresProfileTransfer(
		_ ids: [SidebarItem.ID],
		to destination: Space.ID
	) -> Bool {
		guard let space = organization.spaces[id: destination]
		else { return false }

		return ids.contains { id in
			guard
				case let .tab(uuid) = id,
				let tab = organization.tabs.first(where: { $0.id.rawValue == uuid })
			else { return false }

			return tab.profileID != space.profileID
		}
	}

	/// A drop on a tab group's rows as a plain open-tab target, for moves that go through the
	/// tree move, which takes moved tabs out of their groups itself (DEV-911).
	internal func tabGroupFreeTarget(_ target: SidebarDropTarget?) -> SidebarDropTarget? {
		let target = target.map(organization.resolvingSplitTarget)
		return target.flatMap { organization.resolvingTabGroupTarget($0)?.target } ?? target
	}

	/// A single tab dropped where a tab group is involved: on a group's rows, or taken out of one.
	/// It moves as a single item does, which knows which group it joins (DEV-911).
	internal func isTabGroupMove(
		_ ids: [SidebarItem.ID],
		to target: SidebarDropTarget?
	) -> Bool {
		guard
			ids.count == 1,
			case let .tab(uuid) = ids[0],
			let target
		else { return false }

		if organization.tabGroup(containing: .init(rawValue: uuid)) != nil { return true }
		if case let .inside(.folder(id)) = target { return organization.tabGroups[id: .init(rawValue: id)] != nil }
		return organization.resolvingTabGroupTarget(target)?.group != nil
	}

	/// Each entry holds full organization copies, so history keeps only the most recent edits.
	public static let undoLimit: Int = 50

	/// Starts the window's own step for a change it just made from `previous`, in `space` (the
	/// space it shows, unless the change already showed another); the step it made before ends
	/// there (DEV-1030).
	public mutating func pushUndo(
		_ previous: BrowserOrganization,
		in space: Space.ID? = nil
	) {
		sealLastStep(with: previous)
		appendUndo(.init(before: previous, spaceID: space ?? spaceID))
	}

	/// A step that's done as it's made, such as a close: nothing the window does next, a selection
	/// or a page loading, belongs to it (DEV-1030).
	public mutating func pushSealedUndo(_ previous: BrowserOrganization) {
		sealLastStep(with: previous)
		appendUndo(.init(before: previous, after: organization, spaceID: spaceID))
	}

	/// Ends the step being made, if any, where the workspace is now, keeping the history: what a
	/// page loads since isn't part of it (DEV-1030).
	public mutating func endOpenStep() {
		sealLastStep(with: organization)
	}

	/// Ends the step being made where the workspace is now, before a change that isn't this
	/// window's own: another window's or an agent's, archived tabs, ⇧⌘T (DEV-1030). Without
	/// `windowUndo` such a change clears the history, as a step there restores the workspace it
	/// started from whole.
	public mutating func sealUndo() {
		guard windowUndo else {
			undo.removeAll()
			transferUndos.removeAll()
			return
		}

		// Moving pages back to their profile needs the workspace exactly as the move left it,
		// and asks each page first. After a change from elsewhere it can't, so such a move is no
		// longer a step: taking it back otherwise would close its pages without asking. A move
		// between spaces of one profile stays a step, which takes back only what it moved.
		if !transferUndos.isEmpty {
			let crossProfile = transferUndos.filter { !$0.replacements.isEmpty }
			undo.removeAll { step in crossProfile.contains { $0.previous == step.before } }
			transferUndos.removeAll()
		}
		sealLastStep(with: organization)
	}

	/// Adds a step, such as Move to Window's or one another window or an agent made, after ending
	/// the one being made.
	public mutating func appendUndo(_ step: OrganizationUndo) {
		if step.after != nil { sealLastStep(with: organization) }
		undo.append(step)
		guard undo.count > Self.undoLimit else { return }

		let dropped = undo.prefix(undo.count - Self.undoLimit)
		undo.removeFirst(dropped.count)
		transferUndos.removeAll { move in dropped.contains { $0.before == move.previous } }
	}

	/// Forgets the steps that made these open tabs, which another window keeps now: taking one
	/// back here would close them there (DEV-1030).
	public mutating func dropStepsMaking(_ tabs: Set<BrowserCore.Tab.ID>) {
		let current = organization
		undo.removeAll { step in
			let after = step.after ?? current
			return tabs.contains { step.before.tabs[id: $0] == nil && after.tabs[id: $0] != nil }
		}
	}

	/// Forgets a profile move that can't go back as it came, and its step.
	public mutating func dropTransferStep(_ move: OrganizationMove) {
		undo.removeAll { $0.before == move.previous }
		transferUndos.removeAll { $0.previous == move.previous }
	}

	/// The profile move `step` made, which only its own reverse takes back.
	internal func transferUndo(for step: OrganizationUndo?) -> OrganizationMove? {
		step.flatMap { step in transferUndos.last { $0.previous == step.before } }
	}

	private mutating func sealLastStep(with current: BrowserOrganization) {
		guard let last = undo.indices.last else { return }

		undo[last] = undo[last].sealed(with: current)
	}

	/// The workspace with `step` taken back. A step this window made selects again the tab its
	/// space showed before, unless something else was selected there since.
	///
	/// - Returns: Whether anything changed: a step can leave only its selection to take back, such
	///   as closing a pin already at its saved page.
	@discardableResult
	internal mutating func takeBack(
		_ step: OrganizationUndo,
		to reverted: BrowserOrganization
	) -> Bool {
		var reverted = reverted
		if
			step.restoresSelection,
			let spaceID = step.spaceID,
			let index = reverted.spaces.index(id: spaceID),
			let previous = step.before.spaces[id: spaceID]?.selectedTabID,
			organization.spaces[id: spaceID]?.selectedTabID == step.after?.spaces[id: spaceID]?.selectedTabID,
			reverted.canShow(previous, in: spaceID)
		{
			reverted.spaces[index].selectedTabID = previous
		}
		defer { organization = reverted }
		return reverted != organization
	}

	/// Applies the change, or keeps the organization and shows why the move failed. Returns
	/// whether the change applied.
	///
	/// - Parameters:
	///   - sealed: Whether the change is a step that's done as it's made, such as a close:
	///     a selection made afterwards isn't part of it (DEV-1198).
	@discardableResult
	public mutating func edit(
		sealed: Bool = false,
		_ change: (inout BrowserOrganization) throws -> Void
	) -> Bool {
		let previous = organization
		do {
			try organization.update(change)
			if previous != organization {
				if sealed { pushSealedUndo(previous) } else { pushUndo(previous) }
			}
			message = nil
			return true
		} catch {
			message = String.localized(.appUI.preview.invalidMove)
			return false
		}
	}
}

extension BrowserOrganization {
	/// Whether the space can show the tab: one of its own, or a Favorite of its profile.
	fileprivate func canShow(
		_ tabID: BrowserCore.Tab.ID,
		in spaceID: Space.ID
	) -> Bool {
		guard let space = spaces[id: spaceID] else { return false }

		return switch location(of: tabID) {
		case .favorite(space.profileID), .unpinned(spaceID), .pinned(spaceID, _): true
		default: false
		}
	}
}
