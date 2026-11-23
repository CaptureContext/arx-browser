import AppUI
import BrowserCore
import BrowserEngineClient
import CommandBarFeature
import Foundation
import ViewerFeature
import _ComposableArchitecture

@Reducer
internal struct SplitView {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.commandBarSettingsRows)
	private var settingsRows

	internal var body: some ReducerOf<Self> {
		Pullback(\.present) { state, value in
			let (id, paneID) = value
			guard
				!state.isClosing,
				let pane = state.viewer.panes[id: paneID],
				let original = state.sidebar.organization.tabs[id: id]
			else { return .none }

			let location = state.sidebar.organization.location(of: id)
			if case .favorite = location, original.profileID != state.sidebar.space.profileID { return .none }

			// A tab filling a split's empty pane joins the list the split's tabs share (DEV-1006).
			let opened = state.viewer.isSplit && pane.item.tab == nil ? state.gatherTabForPane(id) : .none
			guard let tab = state.sidebar.organization.tabs[id: id] else { return .none }
			state.sidebar.select(id)
			return .merge(opened, state.viewerSynchronization(selected: tab, paneID: paneID))
		}

		Pullback(\.addPane) { state, id in
			guard !state.isClosing else { return .none }

			// Only now that the tab enters a pane here does it move into the panes' list (DEV-1006).
			let opened = state.gatherTabForPane(id)
			guard let tab = state.sidebar.organization.tabs[id: id] else { return opened }
			return .concatenate(opened, .send(.viewer(.split(tab))))
		}

		Pullback(\.ui.splitTab) { state, id in
			guard !state.isClosing, !state.transferInProgress, !state.archive.isWorking else { return .none }
			let isShown = id.map { id in state.viewer.panes.contains { $0.item.tab?.id == id } } ?? false
			guard isShown || state.canAddSplitPane else { return .none }
			let tab = id.flatMap { id in state.sidebar.organization.tabs[id: id] }

			// Another window's open tab stays out of this window's Split View (DEV-822).
			guard id == nil || tab.map({ state.canPresent($0.id) && state.sidebar.windowShows($0.id) }) == true
			else { return .none }
			return id.map { .send(.delegate(.requestSplit($0))) } ?? .concatenate(
				.send(.viewer(.split(nil))),
				.send(.ui(.presentNewPaneCommand))
			)
		}

		Pullback(\.ui.developerHeader) { state, value in
			let (action, paneID) = value
			guard
				!state.isClosing,
				state.showsDeveloperHeader,
				let index = state.viewer.panes.index(id: paneID),
				let tabID = state.viewer.panes[index].item.tab?.id
			else { return .none }

			// Pane commands and the site menu act on the active pane.
			let focus: Effect<Action> = state.viewer.activePaneID == paneID
			? .none
			: .send(.viewer(.ui(.focus(paneID))))
			switch action {
			case .copyURL:
				return .concatenate(focus, .send(.ui(.paneCommand(.copyURL, paneID))))

			case .toggleDeveloperTools:
				return .concatenate(focus, .send(.ui(.paneCommand(.developerTools, paneID))))

			case .captureViewport:
				return .concatenate(focus, .send(.delegate(.commandFromPane(.captureViewport, paneID))))

			case .captureRegion:
				return .concatenate(focus, .send(.delegate(.commandFromPane(.captureRegion, paneID))))

			case let .captureDevice(style):
				guard state.deviceCaptureEnabled else { return .none }
				state.deviceCaptureStyle = style
				return .concatenate(focus, .send(.delegate(.deviceCaptureFromPane(style, paneID))))

			case .console:
				return .concatenate(
					focus,
					.send(.viewer(.command(.showDeveloperToolsPanel(.console), in: paneID, tabID: tabID)))
				)

			case .network:
				return .concatenate(
					focus,
					.send(.viewer(.command(.showDeveloperToolsPanel(.network), in: paneID, tabID: tabID)))
				)

			case .inspectElement:
				return .concatenate(focus, .send(.viewer(.command(.inspectElementMode, in: paneID, tabID: tabID))))

			case .focus:
				return focus

			case let .split(edge):
				// The split turns to the edge's orientation, so that's where the room must be.
				let orientation: ViewerFeature.Orientation = edge.isHorizontal ? .horizontal : .vertical
				guard
					!state.transferInProgress,
					!state.archive.isWorking,
					state.viewer.panes.count + state.hiddenSplitMemberCount < SplitLayout.maximumPanes,
					state.viewer.panes.count < state.viewer.capacity.panes(orientation)
				else { return .none }
				let insertion = edge == .leading || edge == .top ? index : index + 1
				return .concatenate(
					.send(.viewer(.splitEmpty(at: insertion, orientation: orientation))),
					.send(.ui(.presentNewPaneCommand))
				)
			}
		}

		Pullback(\.ui.presentNewPaneCommand) { state in
			guard state.viewer.isSplit, state.viewer.item.tab == nil else { return .none }
			return .send(.ui(.paneCommand(.newTab, state.viewer.activePaneID)))
		}

		Pullback(\.ui.splitURL) { state, url in
			guard
				!state.viewer.isSplit,
				!state.isClosing,
				!state.transferInProgress,
				!state.archive.isWorking
			else { return .none }

			let tab = BrowserCore.Tab(
				id: .init(rawValue: uuid()),
				profileID: state.sidebar.space.profileID,
				restoration: .init(title: url.host() ?? url.absoluteString, url: url)
			)
			let spaceID = state.sidebar.spaceID

			// Right after the tab it splits with (DEV-1325).
			let opener = state.sidebar.organization.spaces[id: spaceID]?.selectedTabID
			state.sidebar.edit { organization in
				guard let index = organization.spaces.index(id: spaceID) else { return }
				organization.tabs.append(tab)
				organization.placeOpenedTab(tab.id, inSpaceAt: index, opener: opener)
			}
			state.knownTabIDs.insert(tab.id)
			return .merge(
				.send(.viewer(.split(tab))),
				.send(.delegate(.organizationChanged(state.sidebar.organization)))
			)
		}

		Pullback(\.ui.focusOtherPane) { _ in .send(.viewer(.ui(.focusOtherPane))) }
		Pullback(\.ui.closePane) { state in .send(.viewer(.ui(.closePane(state.viewer.activePaneID)))) }
		Pullback(\.ui.swapPanes) { _ in .send(.viewer(.ui(.swapPanes))) }
		Pullback(\.ui.toggleSplitOrientation) { _ in .send(.viewer(.ui(.toggleOrientation))) }

		Pullback(\.viewer) { state, action in
			switch action {
			case .ui, .split, .insert, .layout, .show, .showInLayout, .selectSpace, .unloadIfUnchanged:
				guard state.viewer.spaceID == state.sidebar.spaceID else { return .none }
				if let tab = state.viewer.item.tab {
					state.sidebar.select(tab.id)
				} else if let index = state.sidebar.organization.spaces.index(id: state.sidebar.spaceID) {
					state.sidebar.organization.spaces[index].selectedTabID = nil
				}

			default: return .none
			}
			if case .ui(.resize) = action { return .none }
			if case .ui(.capacityChanged) = action { return .none }
			return state.viewer.preservesPresentation ? .send(.delegate(.presentationChanged)) : .none
		}

		Pullback(\.ui.paneCommand) { state, value in
			let (command, paneID) = value
			guard
				let pane = state.viewer.panes[id: paneID],
				let context = state.commandContext(in: paneID),
				command.isEnabled(in: context)
			else { return .none }

			let tab = pane.item.tab.flatMap { item in state.sidebar.organization.tabs[id: item.id] }
			switch command {
			case .goBack, .goForward, .reload, .clearCacheAndReload, .reloadBypassingCache,
				.zoomIn, .zoomOut, .actualSize, .developerTools, .inspectElement, .javaScriptConsole, .stopLoading:
				guard let tab, let engineCommand = command.engineCommand else { return .none }
				return .send(.viewer(.command(engineCommand, in: paneID, tabID: tab.id)))

			case .viewSource:
				guard
					pane.item.navigation.showsWebPage,
					let url = pane.item.navigation.url,
					let source = URL(string: "view-source:" + url.absoluteString)
				else { return .none }
				return .send(.ui(.openInNewTab(source)))

			case .findInPage, .findNext, .findPrevious:
				guard let action = command.findAction else { return .none }
				let find: Effect<Action> = .send(.viewer(.panes(.element(id: paneID, action: .item(.ui(action))))))

				// ⌘F from the URL bar closes it, as Esc does, so the find field under it can take
				// the keyboard (DEV-1222); MainView hands the keyboard to the open Find bar.
				guard command == .findInPage, state.commandBar.isPresented else { return find }
				return .concatenate(find, .send(.commandBar(.ui(.dismissed))))

			case .readingMode:
				guard let action = command.readerAction else { return .none }
				return .send(.viewer(.panes(.element(id: paneID, action: .item(.ui(action))))))

			case .newSplit:
				return .concatenate(
					.send(.viewer(.split(nil))),
					.send(.ui(.presentNewPaneCommand))
				)

			case .focusOtherPane:
				// The next pane, wrapping, so three or four panes are all reachable.
				guard
					state.viewer.isSplit,
					let index = state.viewer.panes.index(id: paneID)
				else { return .none }
				let next = state.viewer.panes[(index + 1) % state.viewer.panes.count]
				return .send(.viewer(.ui(.focus(next.id))))

			case .closePane: return .send(.viewer(.ui(.closePane(paneID))))

			case .swapPanes: return .send(.viewer(.ui(.swapPanes)))

			case .toggleSplitOrientation: return .send(.viewer(.ui(.toggleOrientation)))

			case .copyURL where state.commandBarContext != nil && state.commandBar.offersCopyURL:
				// Over an open bar, Copy URL copies the highlighted result's address (DEV-810).
				return .send(.commandBar(.ui(.actionRequested(CommandBarFeature.State.copyURLActionID))))

			case .copyURL:
				guard let url = pane.item.navigation.url ?? tab?.restoration.url else { return .none }
				return .send(.delegate(.copyURL(url)))

			case .closeTab:
				guard let tab else { return .none }
				let id = SidebarItem.ID.tab(tab.id.rawValue)
				return .send(.sidebar(.ui(.sidebar(tab.savedDestination == nil ? .close(id) : .reset(id)))))

			case .archiveSelectedTabs:
				let selected = state.archiveSelection(fallback: tab?.id)
				guard !selected.isEmpty else { return .none }
				return .send(.ui(.archiveSelectedTabs(selected)))

			case .pinTab:
				guard let tab else { return .none }
				return .send(.sidebar(.ui(.sidebar(.move(.tab(tab.id.rawValue), .savedRoot)))))

			case .duplicateTab:
				guard let tab else { return .none }
				var copy = BrowserCore.Tab(
					id: .init(rawValue: uuid()),
					profileID: tab.profileID,
					restoration: tab.restoration,
					customTitle: tab.customTitle,
					icon: tab.icon
				)
				copy.restoration.url = pane.item.navigation.url ?? tab.restoration.url
				if !pane.item.navigation.title.isEmpty { copy.restoration.title = pane.item.navigation.title }
				let spaceID = state.sidebar.spaceID

				// Right below the pane's tab, as the sidebar's Duplicate lists it (DEV-1325).
				state.sidebar.edit { organization in
					guard let index = organization.spaces.index(id: spaceID) else { return }
					organization.tabs.append(copy)
					organization.placeOpenedTab(copy.id, inSpaceAt: index, opener: tab.id)
				}
				state.knownTabIDs.insert(copy.id)

				// The copy's first page takes the tab's back/forward history before it opens (DEV-878).
				return .concatenate(
					.run { @MainActor [engine, copyID = copy.id] _ in engine.cloneNavigation(tab, copyID) },
					.merge(
						.send(.viewer(.show(copy, in: paneID))),
						.send(.delegate(.organizationChanged(state.sidebar.organization)))
					)
				)

			case .commandBar where state.commandBar.isPresented:
				// ⌘K over an open bar shows or hides the highlighted result's actions (DEV-810).
				return .send(.commandBar(.ui(.actionsToggled)))

			case .newTab, .address, .commandBar:
				state.commandBarPaneID = paneID
				var origin = state
				origin.viewer.activePaneID = paneID
				let mode: CommandBarFeature.Mode = switch command {
				case .newTab: .newTab
				case .address: .currentTab
				default: .commands
				}
				state.commandBarContext = .init(window: state, paneID: paneID, mode: mode)
				state.commandBarEmptyPaneID = state.emptySplitPane(paneID, mode: mode)
				state.prepareCommandBar()
				return .send(.commandBar(.present(
					mode,
					mode == .currentTab ? (pane.item.navigation.url?.absoluteString ?? "") : "",
					origin.commandCandidates + MainActor.assumeIsolated { [settingsRows] in settingsRows.entries() }
				)))

			default: return .none
			}
		}
	}
}

extension MainFeature.State {
	internal func canPresent(_ id: BrowserCore.Tab.ID) -> Bool {
		canPresent(at: sidebar.organization.location(of: id))
	}

	/// The tabs this window can show in a pane, resolved with one location pass.
	internal var presentableTabs: [BrowserCore.Tab] {
		let locations = sidebar.organization.tabLocations
		return sidebar.organization.tabs.filter { tab in
			let location = locations[tab.id]
			guard canPresent(at: location) else { return false }

			// Another window's open tabs stay out of this window's Split View menu (DEV-822).
			guard case .unpinned = location else { return true }
			return sidebar.openTabFilter.shows(tab.id)
		}.elements
	}

	private func canPresent(at location: BrowserOrganization.TabLocation?) -> Bool {
		switch location {
		case .favorite(sidebar.space.profileID), .unpinned(sidebar.spaceID), .pinned(sidebar.spaceID, _): true
		default: false
		}
	}

	internal mutating func viewerSynchronization(
		selected: BrowserCore.Tab?,
		paneID: UUID? = nil
	) -> Effect<MainFeature.Action> {
		viewer.requestedSpaceID = sidebar.spaceID
		if viewer.spaceID != sidebar.spaceID {
			return .send(.delegate(.requestSpacePresentation(
				sidebar.spaceID,
				selected: selected?.id,
				selectRequested: paneID != nil
			)))
		}
		if let effect = splitGroupSynchronization(selected: selected, paneID: paneID) { return effect }
		guard viewer.isSplit else {
			return selected?.id == viewer.item.tab?.id ? .none : .send(.viewer(.item(.show(selected))))
		}
		let invalid = viewer.panes.filter { $0.item.tab.map { !canPresent($0.id) } ?? false }
		let retained = viewer.panes.filter { pane in !invalid.contains(where: { $0.id == pane.id }) }

		// Closing the active tab must keep the other placement instead of clearing it
		// merely because the sidebar no longer has a selection.
		let selected = selected ?? (!invalid.isEmpty ? retained.first?.item.tab : nil)
		let survivor = retained.first?.id ?? viewer.activePaneID
		let closed = invalid.filter { $0.id != survivor }
		let target = paneID.flatMap { id in closed.contains(where: { $0.id == id }) ? nil : id }
		?? (closed.contains(where: { $0.id == viewer.activePaneID }) ? survivor : viewer.activePaneID)
		var actions: [Effect<MainFeature.Action>] = closed.map { .send(.viewer(.ui(.closePane($0.id)))) }
		if let selected, let owner = retained.first(where: { $0.item.tab?.id == selected.id }) {
			if owner.id != viewer.activePaneID { actions.append(.send(.viewer(.ui(.focus(owner.id))))) }
		} else if selected?.id != viewer.panes[id: target]?.item.tab?.id {
			actions.append(.send(.viewer(.show(selected, in: target))))
		}
		return .concatenate(actions)
	}
}

extension MainFeature.State {
	/// A selected group member shows its whole group; selecting another tab while a group is
	/// shown leaves the group in the sidebar and shows that tab alone. An empty pane waiting
	/// for a tab, and splits that aren't groups, keep the pane-by-pane behavior.
	internal func splitGroupSynchronization(
		selected: BrowserCore.Tab?,
		paneID: UUID?
	) -> Effect<MainFeature.Action>? {
		guard let selected else { return nil }

		// A pane waiting for a tab takes the selection, grouped or not; that adds it to the split.
		let target = paneID ?? viewer.activePaneID
		let fillsEmptyPane = viewer.isSplit && viewer.panes[id: target].map { $0.item.tab == nil } == true
		if fillsEmptyPane { return nil }

		if let group = sidebar.organization.split(containing: selected.id), group.spaceID == sidebar.spaceID {
			let tabs = group.tabIDs.compactMap { sidebar.organization.tabs[id: $0] }
			guard tabs.count == group.tabIDs.count else { return nil }
			let shown = viewer.panes.map { $0.item.tab?.id }
			let isShown = shown == group.tabIDs.map(Optional.some)
			&& viewer.orientation == group.orientation
			&& viewer.fractions == group.fractions

			if isShown {
				guard
					let owner = viewer.panes.first(where: { $0.item.tab?.id == selected.id }),
					owner.id != viewer.activePaneID
				else { return Effect.none }
				return .send(.viewer(.ui(.focus(owner.id))))
			}
			return .send(.viewer(.layout(.init(
				tabs: tabs,
				activeTabID: selected.id,
				orientation: group.orientation,
				fractions: group.fractions
			))))
		}

		// Panes still showing a group, or what's left of one after a member left, give way to
		// the selected tab alone. A split of tabs in no group keeps its pane-by-pane behavior.
		let showsGroupMembers = viewer.panes.contains { pane in
			pane.item.tab.map { sidebar.organization.split(containing: $0.id) != nil } ?? false
		}

		// Only an actual new selection: a synchronize after an unrelated edit keeps the panes.
		let isShown = viewer.panes.contains { $0.item.tab?.id == selected.id }
		guard viewer.isSplit, showsGroupMembers, !isShown else { return nil }
		return .send(.viewer(.layout(.init(tabs: [selected], activeTabID: selected.id))))
	}
}
