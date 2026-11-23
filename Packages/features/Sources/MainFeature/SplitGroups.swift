import AppUI
import BrowserCore
import Foundation
import SidebarFeature
import ViewerFeature
import _ComposableArchitecture

/// Split View groups: building them by drops, the group row's menu, and keeping each group in
/// step with the panes that show it. Divider drags and drop hovers never reach here; only the
/// layout they end in does.
@Reducer
internal struct SplitGroups {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		// A move that commits away from a group's block takes the tab out (`normalizeSplits`);
		// one that is cancelled or refused changes nothing, membership included.
		Pullback(\.sidebar.ui.moveItems) { state, value in
			let (ids, target, spaceID) = value
			guard case let .split(destination) = target else { return .none }
			return state.joinSplit(ids, onto: destination, in: spaceID, newID: .init(rawValue: uuid()))
		}

		Pullback(\.sidebar.ui.move) { state, value in
			let (id, target, spaceID) = value
			guard case let .split(destination) = target else { return .none }
			return state.joinSplit([id], onto: destination, in: spaceID, newID: .init(rawValue: uuid()))
		}

		Pullback(\.sidebar.ui.sidebar.splitGroup) { state, action in
			switch action {
			case let .focus(_, tab):
				let id = BrowserCore.Tab.ID(rawValue: tab)
				guard state.sidebar.organization.tabs[id: id] != nil else { return .none }

				// MainFeature synchronizes after every sidebar action.
				state.sidebar.select(id)
				return .none

			case let .separate(_, tab):
				state.sidebar.edit { $0.removeFromSplits([.init(rawValue: tab)]) }
				return state.showSelectionAfterSeparating()

			case let .separateAll(group):
				state.sidebar.edit { $0.splits.remove(id: .init(rawValue: group)) }
				return state.showSelectionAfterSeparating()

			case let .addTab(group):
				guard let split = state.sidebar.organization.splits[id: .init(rawValue: group)]
				else { return .none }
				guard split.tabIDs.count < min(SplitLayout.maximumPanes, state.viewer.capacity.panes(split.orientation))
				else { return state.refuseSplit(split.tabIDs.count >= SplitLayout.maximumPanes ? .full : .tooNarrow) }
				let tabs = split.tabIDs.compactMap { state.sidebar.organization.tabs[id: $0] }
				guard tabs.count == split.tabIDs.count, state.viewer.spaceID == state.sidebar.spaceID
				else { return .none }

				// The group and a new empty pane beside it, in one layout, then the command bar for it.
				return .concatenate(
					.send(.viewer(.layout(.init(
						tabs: tabs,
						activeTabID: nil,
						orientation: split.orientation,
						addsEmptyPane: true
					)))),
					.send(.ui(.presentNewPaneCommand))
				)

			case let .toggleOrientation(group):
				guard let split = state.sidebar.organization.splits[id: .init(rawValue: group)]
				else { return .none }
				let orientation: ViewerFeature.Orientation = split.orientation == .horizontal ? .vertical : .horizontal
				guard split.tabIDs.count <= state.viewer.capacity.panes(orientation)
				else { return state.refuseSplit(.tooNarrow) }
				state.sidebar.edit { $0.splits[id: .init(rawValue: group)]?.orientation = orientation }
				return .none

			case let .duplicate(group):
				return state.duplicateSplit(.init(rawValue: group), ids: { uuid() })

			case let .duplicateTab(tab):
				return .concatenate(
					.send(.sidebar(.ui(.sidebar(.select(.tab(tab)))))),
					.send(.ui(.duplicateTab))
				)

			case let .toggleMute(tab):
				return .send(.delegate(.toggleMute(.init(rawValue: tab))))

			case .chooseMoveDestination:
				// SidebarFeature asks the window where to.
				return .none

			case .rename, .changeIcon:
				// SidebarFeature stores these; the window only republishes the organization.
				return .send(.delegate(.organizationChanged(state.sidebar.organization)))
			}
		}

		Pullback(\.ui.dropTabInViewer) { state, value in
			let (id, edge) = value
			if let refusal = state.viewerDropRefusal(id, edge: edge) { return state.refuseSplit(refusal) }

			// The press that started this drag selected the tab, so the page shows it alone. The
			// drop does what it did before the press switched the page: the tab joins what the
			// page showed, the tab selected before the press, on the side it was dropped (DEV-994).
			if let press = state.pressedOver(id) {
				state.pressSelection = nil
				return state.joinPressedPage(press, edge: edge, newID: .init(rawValue: uuid()))
			}

			// A chat tab dropped on its own page splits with the page it opened over.
			if let page = state.chatTabOpenedOverPage(id) {
				state.chatTabOpenedOver = nil
				let ids = edge == .leading || edge == .top ? [id, page] : [page, id]

				// The chat was the tab in use, so it stays active wherever its pane goes.
				return state.openSplit(
					ids,
					orientation: edge.isHorizontal ? .horizontal : .vertical,
					active: id,
					newID: .init(rawValue: uuid())
				)
			}

			// Leaving another group first, so the new pane's group owns it alone, and moving into
			// the list the page's tabs share: a pinned tab dropped beside an open one becomes open,
			// an open one beside a pinned one is pinned (DEV-1006). The whole drop, including the
			// group the new pane records, undoes as one step.
			let previous = state.sidebar.organization
			if let anchor = state.paneAnchor(excluding: id) {
				do {
					try state.sidebar.organization.gatherForSplit([id], joining: anchor)
				} catch {
					return state.refuseSplit(.unavailable)
				}
			}
			state.sidebar.organization.removeFromSplits([id])
			guard let tab = state.sidebar.organization.tabs[id: id] else {
				state.sidebar.organization = previous
				return .none
			}
			state.sidebar.pushUndo(previous)
			let orientation: ViewerFeature.Orientation = edge.isHorizontal ? .horizontal : .vertical
			let index = edge == .leading || edge == .top ? 0 : state.viewer.panes.count

			// A tab that changed lists is published at once: a group may not form.
			let opened: Effect<MainFeature.Action> = previous.location(of: id) == state.sidebar.organization.location(of: id)
			? .none
			: .send(.delegate(.organizationChanged(state.sidebar.organization)))
			return .concatenate(opened, .send(.viewer(.insert(tab, at: index, orientation: orientation))))
		}

		Pullback(\.ui.openSplit) { state, value in
			let (ids, orientation) = value

			// Checked before drawing an identity for the group, as the shared path checks again.
			guard
				let first = ids.first,
				ids.count >= 2,
				ids.count <= SplitLayout.maximumPanes
			else { return .none }

			return state.openSplit(
				ids,
				orientation: orientation,
				active: first,
				newID: .init(rawValue: uuid())
			)
		}

		Pullback(\.viewer) { state, action in
			switch action {
			case .split, .insert, .ui(.swapPanes), .ui(.toggleOrientation), .ui(.resizeEnded), .ui(.equalize):
				return state.recordSplitLayout(closing: false)

			case let .show(tab?, _):
				// Filling an empty pane adds a member (a pinned tab was made an open one before it got
				// here, DEV-992). Putting a tab where a group member was is a selection: that tab
				// shows alone, and the group keeps its members.
				let replaced = state.showReplacing?.previousTabID
				state.showReplacing = nil
				let replacesMember = replaced.map { $0 != tab.id && state.sidebar.organization.split(containing: $0) != nil } ?? false
				if replacesMember, state.viewer.isSplit {
					return .send(.viewer(.layout(.init(tabs: [tab], activeTabID: tab.id))))
				}
				return state.recordSplitLayout(closing: false)

			case .selectSpace:
				// A restored layout follows the groups, never the other way round: a group member
				// shown again brings its whole group back as saved.
				guard state.viewer.spaceID == state.sidebar.spaceID else { return .none }
				return state.splitGroupSynchronization(selected: state.viewer.item.tab, paneID: nil) ?? .none

			case .ui(.closePane):
				return state.recordSplitLayout(closing: true)

			default:
				return .none
			}
		}
	}
}

extension MainFeature.State {
	/// The tabs the viewer shows that a group of this window's space can hold, in pane order: its
	/// open tabs, pinned tabs and tabs in its folders, and its profile's Favorites (DEV-1006).
	fileprivate var shownSplitTabs: [BrowserCore.Tab.ID] {
		let organization = sidebar.organization
		let spaceID = sidebar.spaceID
		let profileID = sidebar.space.profileID
		return viewer.panes.compactMap { $0.item.tab?.id }.filter { id in
			switch organization.location(of: id) {
			case let .favorite(profile): profile == profileID
			case let .unpinned(space), let .pinned(space, _): space == spaceID
			case nil: false
			}
		}
	}

	/// A tab the panes show that `id` would join: see `anchor(for:among:)`.
	internal func paneAnchor(excluding id: BrowserCore.Tab.ID) -> BrowserCore.Tab.ID? {
		anchor(for: id, among: viewer.panes.compactMap { $0.item.tab?.id })
	}

	/// The tab of `shown` that `id` joins, which decides the list it moves into: a tab of a group
	/// first, then one in `id`'s own list, so it moves only when it has to, then any tab in a list,
	/// then a Favorite (DEV-1006).
	internal func anchor(
		for id: BrowserCore.Tab.ID,
		among shown: [BrowserCore.Tab.ID]
	) -> BrowserCore.Tab.ID? {
		let organization = sidebar.organization

		// Only a tab whose split, or list, is in this space: a Favorite grouped in another space
		// would carry the tab off there (DEV-1006).
		let spaceID = sidebar.spaceID
		let shown = shown.filter { tab in
			guard tab != id else { return false }
			if let group = organization.split(containing: tab) { return group.spaceID == spaceID }
			return organization.splitList(of: tab).map { organization.space(of: $0) == spaceID } ?? true
		}
		let own = organization.splitList(of: id)
		return shown.first { organization.split(containing: $0) != nil && organization.splitList(of: $0) != nil }
		?? own.flatMap { list in shown.first { organization.splitList(of: $0) == list } }
		?? shown.first { organization.splitList(of: $0) != nil }
		?? shown.first
	}

	/// The group the viewer shows: the one holding every tab in its panes.
	public var shownSplit: SplitGroup? {
		guard viewer.isSplit, viewer.spaceID == sidebar.spaceID else { return nil }
		let shown = viewer.panes.compactMap { $0.item.tab?.id }
		guard shown.count > 1 else { return nil }
		return sidebar.organization.split(containing: shown[0]).flatMap { split in
			Set(shown).isSubset(of: split.tabIDs) ? split : nil
		}
	}

	/// Group members another window shows, which this window leaves out but still counts.
	public var hiddenSplitMemberCount: Int {
		hiddenSplitMemberCount(shown: viewer.panes.compactMap { $0.item.tab?.id })
	}

	/// Members of the group holding `shown` that another window shows.
	internal func hiddenSplitMemberCount(shown: [BrowserCore.Tab.ID]) -> Int {
		guard viewer.spaceID == sidebar.spaceID else { return 0 }

		// Even one visible member: the rest of its group may be in another window.
		guard
			let first = shown.first,
			let group = sidebar.organization.split(containing: first),
			Set(shown).isSubset(of: group.tabIDs)
		else { return 0 }
		return group.tabIDs.filter(viewer.tabsShownElsewhere.contains).count
	}

	/// Whether one more pane fits: the window's room and the group's four, hidden members included.
	public var canAddSplitPane: Bool {
		viewer.canAddPane && viewer.panes.count + hiddenSplitMemberCount < SplitLayout.maximumPanes
	}

	/// Why dropping `id` on the page's `edge` would do nothing, if it would.
	///
	/// `checksOwnership` is off for the page's hover: what other windows show is only refreshed
	/// when a drop arrives, and the drop is checked again then.
	public func viewerDropRefusal(
		_ id: BrowserCore.Tab.ID,
		edge: SplitDropEdge,
		checksOwnership: Bool = true
	) -> SplitDropRefusal? {
		if let press = pressedOver(id) {
			guard
				!isClosing,
				!transferInProgress,
				viewer.spaceID == sidebar.spaceID,
				!checksOwnership || !press.panes.contains(where: viewer.tabsShownElsewhere.contains)
			else { return .unavailable }

			// Judged as the drop would have been on the page before the press.
			let hidden = checksOwnership ? hiddenSplitMemberCount(shown: press.panes) : 0
			if press.panes.count + hidden >= SplitLayout.maximumPanes { return .full }
			let orientation: ViewerFeature.Orientation = edge.isHorizontal ? .horizontal : .vertical
			if press.panes.count >= viewer.capacity.panes(orientation) { return .tooNarrow }
			return nil
		}
		if let page = chatTabOpenedOverPage(id) {
			guard
				!isClosing,
				!transferInProgress,
				viewer.spaceID == sidebar.spaceID,
				!checksOwnership || !viewer.tabsShownElsewhere.contains(page)
			else { return .unavailable }
			let orientation: ViewerFeature.Orientation = edge.isHorizontal ? .horizontal : .vertical
			return viewer.capacity.panes(orientation) < 2 ? .tooNarrow : nil
		}
		guard
			!isClosing,
			!transferInProgress,
			viewer.spaceID == sidebar.spaceID,
			sidebar.organization.canJoinSplit(id, in: sidebar.spaceID),
			!checksOwnership || !viewer.tabsShownElsewhere.contains(id),
			!viewer.panes.contains(where: { $0.item.tab?.id == id }),
			viewer.panes.allSatisfy({ $0.item.tab != nil })
		else { return .unavailable }

		// Members another window shows still count toward the group's four.
		let hidden = checksOwnership ? hiddenSplitMemberCount : 0
		if viewer.panes.count + hidden >= SplitLayout.maximumPanes { return .full }
		let orientation: ViewerFeature.Orientation = edge.isHorizontal ? .horizontal : .vertical
		if viewer.panes.count >= viewer.capacity.panes(orientation) { return .tooNarrow }
		return nil
	}

	/// The press that selected `id`, while the page shows what it did before the press with `id`
	/// in place of the previous tab, and with what of that page this window can still show: a drag
	/// of the pressed tab into the page joins that page (DEV-994).
	internal func pressedOver(_ id: BrowserCore.Tab.ID) -> MainFeature.State.PressSelection? {
		let shown = viewer.panes.compactMap { $0.item.tab?.id }
		guard
			var press = pressSelection,
			press.tab == id,
			shown.contains(id),
			shown.allSatisfy({ $0 == id || press.panes.contains($0) }),
			sidebar.organization.canJoinSplit(id, in: sidebar.spaceID)
		else { return nil }

		let kept = press.panes.filter { $0 != id && sidebar.organization.tabs[id: $0] != nil && canPresent($0) }
		if kept != press.panes {
			// A tab the page showed is gone: what's left shares the page equally.
			press.panes = kept
			press.fractions = SplitLayout.equal(kept.count)
		}
		guard press.panes.contains(press.previous) else { return nil }
		return press
	}

	/// The page a chat tab opened over (DEV-793), while the chat shows alone and the page is
	/// still an open tab of this space. Dropping the chat on its own page pairs the two, which is
	/// how Open in Tab and then a drag onto the page's edge puts the chat beside the page.
	internal func chatTabOpenedOverPage(_ id: BrowserCore.Tab.ID) -> BrowserCore.Tab.ID? {
		guard
			let opened = chatTabOpenedOver,
			opened.chat == id,
			opened.page != id,
			viewer.panes.count == 1,
			viewer.item.tab?.id == id,
			sidebar.space.unpinnedTabs.contains(opened.page),
			sidebar.organization.tabs[id: opened.page] != nil
		else { return nil }
		return opened.page
	}

	/// Undo, or another window's edit, can take away the group the panes show. The panes then
	/// give way to the selection, so a later resize can't bring the group back.
	internal mutating func followShownSplit() -> Effect<MainFeature.Action> {
		guard viewer.isSplit || shownSplitID != nil else { return .none }
		let previous = shownSplitID
		let current = shownSplit?.id
		if current != previous { shownSplitID = current }
		guard
			let previous,
			current == nil,
			sidebar.organization.splits[id: previous] == nil,
			viewer.spaceID == sidebar.spaceID,
			viewer.isSplit,
			// Only a tab still there: a closed member is close synchronization's to resolve.
			let selected = sidebar.selectedTab,
			canPresent(selected.id)
		else { return .none }
		return .send(.viewer(.layout(.init(tabs: [selected], activeTabID: selected.id))))
	}

	/// Separated tabs show alone; a selection still in a group shows that group.
	fileprivate mutating func showSelectionAfterSeparating() -> Effect<MainFeature.Action> {
		let changed: Effect<MainFeature.Action> = .send(.delegate(.organizationChanged(sidebar.organization)))
		guard
			let selected = sidebar.selectedTab,
			viewer.spaceID == sidebar.spaceID,
			sidebar.organization.split(containing: selected.id) == nil
		else { return changed }
		return .merge(changed, .send(.viewer(.layout(.init(tabs: [selected], activeTabID: selected.id)))))
	}

	/// Makes `ids` one group in that order and shows it with `active` focused and selected.
	fileprivate mutating func openSplit(
		_ ids: [BrowserCore.Tab.ID],
		orientation: BrowserSpacePresentation.Orientation?,
		active: BrowserCore.Tab.ID,
		newID: SplitGroup.ID
	) -> Effect<MainFeature.Action> {
		guard
			ids.count >= 2,
			ids.count <= SplitLayout.maximumPanes,
			Set(ids).count == ids.count,
			ids.contains(active)
		else { return .none }

		var organization = sidebar.organization
		do {
			// The others move into the first tab's list, which automation names: beside an open tab
			// a pinned one becomes open, beside a pinned one an open one is pinned (DEV-1006).
			try organization.gatherForSplit(Array(ids.dropFirst()), joining: ids[0])
		} catch {
			return refuseSplit(.unavailable)
		}
		organization.removeFromSplits(Set(ids))
		do {
			try organization.update { candidate in
				try candidate.joinSplit(
					Array(ids.dropFirst()),
					with: ids[0],
					orientation: orientation,
					newID: newID
				)
			}
		} catch {
			return refuseSplit(.unavailable)
		}
		let previous = sidebar.organization
		sidebar.organization = organization
		sidebar.pushUndo(previous)
		sidebar.select(active)

		// The whole requested layout, even over an empty pane waiting for a tab.
		if
			viewer.spaceID == sidebar.spaceID,
			let group = sidebar.organization.split(containing: active)
		{
			let tabs = group.tabIDs.compactMap { sidebar.organization.tabs[id: $0] }
			return .merge(
				.send(.viewer(.layout(.init(
					tabs: tabs,
					activeTabID: active,
					orientation: group.orientation,
					fractions: group.fractions
				)))),
				.send(.delegate(.organizationChanged(sidebar.organization)))
			)
		}

		// Explicit, so a space restored for it shows this group, not its saved layout.
		return .send(.synchronizeSelecting(active))
	}

	/// Puts the pressed tab back beside what the page showed before the press, as a drop on that
	/// page would have: it joins the group there or pairs with the open tab there, on the side it
	/// was dropped, and pinned tabs or Favorites in the panes keep sharing them (DEV-994).
	fileprivate mutating func joinPressedPage(
		_ press: PressSelection,
		edge: SplitDropEdge,
		newID: SplitGroup.ID
	) -> Effect<MainFeature.Action> {
		let leads = edge == .leading || edge == .top
		let orientation: ViewerFeature.Orientation = edge.isHorizontal ? .horizontal : .vertical
		let ids = leads ? [press.tab] + press.panes : press.panes + [press.tab]
		var organization = sidebar.organization

		// The tab joins the list the page's tabs share (DEV-1006).
		let partner = anchor(for: press.tab, among: press.panes)
		do {
			if let partner { try organization.gatherForSplit([press.tab], joining: partner) }
		} catch {
			return refuseSplit(.unavailable)
		}
		organization.removeFromSplits([press.tab])
		if let partner {
			do {
				let members = organization.split(containing: partner)?.tabIDs.count ?? 1
				try organization.joinSplit(
					[press.tab],
					with: partner,
					at: leads ? 0 : members,
					orientation: orientation,
					newID: newID
				)
			} catch {
				return refuseSplit(.unavailable)
			}
		}
		let previous = sidebar.organization
		sidebar.organization = organization
		sidebar.pushUndo(previous)
		sidebar.select(press.tab)
		let group = organization.split(containing: press.tab)
		let tabs = ids.compactMap { organization.tabs[id: $0] }
		return .merge(
			.send(.viewer(.layout(.init(
				tabs: tabs,
				activeTabID: press.tab,
				orientation: orientation,
				fractions: group?.tabIDs == ids ? group?.fractions : nil
			)))),
			.send(.delegate(.organizationChanged(organization)))
		)
	}

	/// A tab of this space about to fill a pane of a split, by Add to Split View or a split's empty
	/// pane, moves into the list the other panes' tabs share first (DEV-1006): beside open tabs a
	/// pinned one becomes open, beside pinned ones an open one is pinned. It happens before the
	/// pane takes the tab, so the page loads it as it will be, it joins as a member, and Undo
	/// restores the group as it was. Published at once, since no group may form to publish it. A
	/// Favorite stays in the grid and joins from there.
	internal mutating func gatherTabForPane(_ id: BrowserCore.Tab.ID) -> Effect<MainFeature.Action> {
		guard
			viewer.spaceID == sidebar.spaceID,
			let anchor = paneAnchor(excluding: id)
		else { return .none }
		switch sidebar.organization.location(of: id) {
		case let .unpinned(space), let .pinned(space, _):
			guard space == sidebar.spaceID else { return .none }
		case .favorite, nil:
			return .none
		}

		let previous = sidebar.organization
		guard (try? sidebar.organization.gatherForSplit([id], joining: anchor)) != nil else { return .none }
		guard sidebar.organization != previous else { return .none }
		sidebar.pushUndo(previous)
		return .send(.delegate(.organizationChanged(sidebar.organization)))
	}

	fileprivate mutating func refuseSplit(_ refusal: SplitDropRefusal) -> Effect<MainFeature.Action> {
		sidebar.message = refusal.message
		return .none
	}

	/// Drops sidebar rows onto an open tab or a group's row, putting them in its split.
	fileprivate mutating func joinSplit(
		_ ids: [SidebarItem.ID],
		onto destination: SidebarItem.ID,
		in spaceID: Space.ID,
		newID: SplitGroup.ID
	) -> Effect<MainFeature.Action> {
		guard case let .tab(targetUUID) = destination else { return .none }
		let target = BrowserCore.Tab.ID(rawValue: targetUUID)
		let current = sidebar.organization.split(containing: target)
		let members = current?.tabIDs ?? [target]
		let added = ids.compactMap { id -> BrowserCore.Tab.ID? in
			guard case let .tab(uuid) = id else { return nil }
			let tabID = BrowserCore.Tab.ID(rawValue: uuid)
			return members.contains(tabID) ? nil : tabID
		}
		guard !added.isEmpty else { return .none }

		// The drop's own space: the Spaces overview offers every space's rows. A tab of another
		// list or space moves into the target's list beside it: onto a pinned tab it's pinned, onto
		// an open tab it's open; a Favorite joins from the grid (DEV-1006).
		guard
			sidebar.organization.canJoinSplit(target, in: spaceID),
			added.allSatisfy({ sidebar.organization.canJoinSplit($0, in: spaceID) })
		else { return refuseSplit(.unavailable) }
		guard members.count + added.count <= SplitLayout.maximumPanes
		else { return refuseSplit(.full) }
		let orientation = current?.orientation ?? .horizontal
		guard members.count + added.count <= viewer.capacity.panes(orientation)
		else { return refuseSplit(.tooNarrow) }

		var failed = false
		sidebar.edit { organization in
			do {
				try organization.gatherForSplit(added, joining: target)
				try organization.joinSplit(added, with: target, newID: newID)
			} catch {
				failed = true
				throw error
			}
		}
		guard !failed else { return refuseSplit(.unavailable) }

		// MainFeature synchronizes after every sidebar action, which shows the group. Selecting a
		// Favorite doesn't change spaces, so the group's space is selected first (DEV-1006).
		if
			let group = sidebar.organization.split(containing: target),
			group.spaceID != sidebar.spaceID
		{
			sidebar.selectSpace(group.spaceID)
		}
		sidebar.select(added[0])
		return .none
	}

	fileprivate mutating func duplicateSplit(
		_ id: SplitGroup.ID,
		ids: () -> UUID
	) -> Effect<MainFeature.Action> {
		guard
			let split = sidebar.organization.splits[id: id],
			let list = sidebar.organization.splitList(of: split)
		else { return .none }

		// The copies go after the group in its list, its Favorites' copies too; in Pinned or a
		// folder they're pinned at the page each one shows, which they open at (DEV-1006).
		let pins: Bool = if case .open = list { false } else { true }
		let copies: [BrowserCore.Tab] = split.tabIDs.compactMap { tabID in
			guard let tab = sidebar.organization.tabs[id: tabID] else { return nil }
			let navigation = viewer.panes.first(where: { $0.item.tab?.id == tabID })?.item.navigation
			let restoration = BrowserCore.Tab.Restoration(
				title: navigation.flatMap { $0.title.isEmpty ? nil : $0.title } ?? tab.restoration.title,
				url: navigation?.url ?? tab.restoration.url
			)
			return .init(
				id: .init(rawValue: ids()),
				profileID: tab.profileID,
				savedDestination: pins ? .init(title: tab.customTitle ?? restoration.title, url: restoration.url) : nil,
				restoration: restoration,
				customTitle: tab.customTitle,
				icon: tab.icon
			)
		}
		guard copies.count == split.tabIDs.count else { return .none }
		let groupID = SplitGroup.ID(rawValue: ids())
		let last = sidebar.organization.listMembers(of: split).last
		sidebar.edit { organization in
			organization.tabs.append(contentsOf: copies)
			organization.insertTabs(copies.map(\.id), into: list, after: last)
			organization.splits.append(.init(
				id: groupID,
				spaceID: split.spaceID,
				tabIDs: copies.map(\.id),
				orientation: split.orientation,
				fractions: split.fractions,
				title: split.title,
				icon: split.icon
			))
		}
		knownTabIDs.formUnion(copies.map(\.id))
		guard
			let first = copies.first,
			sidebar.organization.tabs[id: first.id] != nil
		else { return .none }
		sidebar.select(first.id)
		return .none
	}

	/// Keeps the group shown in the viewer in step with its panes, once a layout change ends:
	/// membership and order, orientation and pane shares. Two or more of the space's tabs in panes,
	/// one of them in a list, make a group; closing a pane takes its tab out, and only that: a
	/// pinned tab isn't reset (DEV-1006).
	fileprivate mutating func recordSplitLayout(closing: Bool) -> Effect<MainFeature.Action> {
		guard viewer.spaceID == sidebar.spaceID, !isClosing else { return .none }
		let shown = shownSplitTabs
		let spaceID = sidebar.spaceID
		let current = sidebar.organization

		// The group most of the panes belong to; a tab added from another group leaves that one.
		let candidates = shown.compactMap(current.split(containing:))
		let best = candidates.max { lhs, rhs in
			let left = shown.filter(lhs.tabIDs.contains).count
			let right = shown.filter(rhs.tabIDs.contains).count
			if left != right { return left < right }

			// On a tie, the group of the earlier pane wins.
			return (candidates.firstIndex(of: lhs) ?? 0) > (candidates.firstIndex(of: rhs) ?? 0)
		}

		// Panes become that group only when it already holds two of them (or all, for one pane).
		// Otherwise they're a new group, and a tab added from elsewhere leaves its old one alone.
		let existing = best.flatMap { group -> SplitGroup? in
			let held = shown.filter(group.tabIDs.contains).count
			return held >= 2 || held == shown.count ? group : nil
		}

		var organization = sidebar.organization
		if shown.count >= 2 {
			// A tab of another space may share the panes, but only this space's are members.
			let shares = viewer.panes.enumerated().compactMap { index, pane -> Double? in
				guard let id = pane.item.tab?.id, shown.contains(id) else { return nil }
				return viewer.fractions.indices.contains(index) ? viewer.fractions[index] : nil
			}
			organization.removeFromSplits(Set(shown).subtracting(existing?.tabIDs ?? []))

			// Members another window shows were left out of the layout, not out of the group.
			let hidden = (existing?.tabIDs ?? []).filter { !shown.contains($0) && viewer.tabsShownElsewhere.contains($0) }
			var members = shown
			var memberShares = SplitLayout.sanitized(shares, count: shown.count)
			if let existing, !hidden.isEmpty {
				let visibleShare = 1 - hidden.compactMap { id in existing.tabIDs.firstIndex(of: id).map { existing.fractions[$0] } }
					.reduce(0, +)
				for id in hidden {
					guard let index = existing.tabIDs.firstIndex(of: id) else { continue }
					let position = min(index, members.count)
					members.insert(id, at: position)
					memberShares.insert(existing.fractions[index], at: position)
				}
				for index in members.indices where !hidden.contains(members[index]) {
					memberShares[index] *= max(0, visibleShare)
				}
			}

			// More than four with the hidden ones: leave the group as it is rather than drop one.
			guard members.count <= SplitLayout.maximumPanes else { return .none }
			if let existing, organization.splits[id: existing.id] != nil {
				organization.splits[id: existing.id]?.tabIDs = members
				organization.splits[id: existing.id]?.orientation = viewer.orientation
				organization.splits[id: existing.id]?.fractions = SplitLayout.sanitized(memberShares, count: members.count)
			} else {
				@Dependency(\.uuid)
				var uuid

				organization.splits.append(.init(
					id: .init(rawValue: uuid()),
					spaceID: spaceID,
					tabIDs: members,
					orientation: viewer.orientation,
					fractions: shares
				))
			}
		} else if closing, let existing {
			// What's left on screen is one tab; members shown elsewhere stay grouped.
			let remaining = existing.tabIDs.filter { shown.contains($0) || viewer.tabsShownElsewhere.contains($0) }
			if remaining.count >= 2 {
				organization.removeFromSplits(Set(existing.tabIDs).subtracting(remaining))
			} else {
				organization.splits.remove(id: existing.id)
			}
		} else {
			return .none
		}
		if let first = shown.first, let id = organization.split(containing: first)?.id {
			organization.gatherSplit(id)
		}
		organization.normalizeSplits()
		guard
			organization != sidebar.organization,
			(try? organization.validate()) != nil
		else { return .none }
		sidebar.organization = organization
		return .send(.delegate(.organizationChanged(organization)))
	}
}
