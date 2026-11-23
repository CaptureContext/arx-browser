import BrowserCore
import Foundation
import MainFeature
import SidebarFeature
import _ComposableArchitecture

/// Independent windows (DEV-822, `ARX_INDEPENDENT_WINDOWS`): every browser window shares the
/// profiles' spaces, Favorites and pinned tabs, and keeps its own open tabs. The organization stays
/// whole in every window; `windowTabOwners` says which additional window each open tab is in, and
/// each sidebar's `openTabFilter` shows only the window's own.
@Reducer
internal struct IndependentWindows {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		// Another window's open tab chosen from the command bar or a shortcut: that window comes
		// forward with it. A tab of the closed main window comes to the window that chose it.
		Pullback(\.main.delegate.selectTabInOtherWindow) { state, tabID in
			state.selectTabInOwningWindow(tabID, from: state.main.id)
		}

		Pullback(\.windows) { state, action in
			switch action {
			case let .element(id, .delegate(.selectTabInOtherWindow(tabID))):
				return state.selectTabInOwningWindow(tabID, from: id)

			case let .element(id, .delegate(.takeOpenTabsFromOtherWindows(tabs))):
				return state.takeDroppedOpenTabs(tabs, into: id)

			default:
				return .none
			}
		}

		// Another window's open tabs dropped among this window's: this window keeps them, and the
		// windows they left let them go, as Move to Window does.
		Pullback(\.main.delegate.takeOpenTabsFromOtherWindows) { state, tabs in
			state.takeDroppedOpenTabs(tabs, into: state.main.id)
		}

		// A closed window's open tabs go back to the main window, as they are. Reopen Closed Window
		// takes them back while they're still there.
		Pullback(\.event.additionalWindowClosed) { state, id in
			guard state.windowTabOwners.values.contains(id) else { return .none }

			state.windowTabOwners = state.windowTabOwners.filter { $0.value != id }
			return .none
		}
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Keeps every window's open-tab filter in step with which window each tab is in, new windows
	/// included, and saves a change of owner with the window layouts. Only a difference reaches a
	/// sidebar.
	internal func filteringWindowTabs() -> some Reducer<State, Action> {
		self
			.onChange(of: { OpenTabFilterKey($0) }, reduce: { state, _, _ in
				state.applyOpenTabFilters()
				return .none
			})
			.onChange(of: { $0.windowTabOwners }, reduce: { state, _, _ in
				state.persistWindowPresentations()
			})
	}
}

/// What the windows' open-tab filters are made from.
private struct OpenTabFilterKey: Equatable {
	internal var isOn: Bool
	internal var owners: [BrowserCore.Tab.ID: UUID]
	internal var windows: [UUID]
	internal var privateWindows: Set<UUID>

	internal init(_ state: AppFeature.State) {
		self.isOn = state.independentWindows
		self.owners = state.windowTabOwners
		self.windows = [state.main.id] + state.windows.ids
		self.privateWindows = Set(([state.main] + Array(state.windows)).filter(\.isPrivate).map(\.id))
	}
}

extension AppFeature.State {
	/// Turns independent windows on or off, as the feature flag says at launch. Off, every window
	/// shows every open tab, and no window keeps any.
	public mutating func setIndependentWindows(_ isOn: Bool) {
		independentWindows = isOn
		if !isOn { windowTabOwners = [:] }
		applyOpenTabFilters()
		guard isOn else { return }

		// A restored window starts from the shared organization, whose other spaces may still
		// select another window's tab. Its own selection is what it shows.
		for id in [main.id] + windows.ids {
			guard var window = self.window(id), !window.isPrivate else { continue }

			let shown = Set(window.viewer.panes.compactMap { $0.item.tab?.id })
			for index in window.sidebar.organization.spaces.indices {
				guard
					let selected = window.sidebar.organization.spaces[index].selectedTabID,
					!shown.contains(selected),
					!window.sidebar.windowShows(selected)
				else { continue }

				window.sidebar.organization.spaces[index].selectedTabID = nil
			}
			if id == main.id { main = window } else { windows[id: id] = window }
		}
	}

	/// The window an open tab is in: an additional window that keeps it, else the main window.
	internal func windowOwning(_ tabID: BrowserCore.Tab.ID) -> UUID {
		windowTabOwners[tabID] ?? main.id
	}

	/// The open tabs a window doesn't show because other windows keep them, which its panes may
	/// not take when it restores a space or lays out a split. Empty while windows share.
	internal func otherWindowsOpenTabs(for windowID: UUID) -> Set<BrowserCore.Tab.ID> {
		guard independentWindows, let window = window(windowID), !window.isPrivate
		else { return [] }

		let filter = window.sidebar.openTabFilter
		return Set(workspace.spaces.flatMap(\.unpinnedTabs).filter { !filter.shows($0) })
	}

	/// Carries owners over to the new IDs a space's open tabs get when it moves to another
	/// profile, matched by their place in the space.
	internal mutating func remapOpenTabOwners(
		from previous: BrowserOrganization,
		to current: BrowserOrganization
	) {
		guard independentWindows, !windowTabOwners.isEmpty else { return }

		var owners = windowTabOwners
		for space in current.spaces {
			guard
				let old = previous.spaces[id: space.id],
				old.profileID != space.profileID,
				old.unpinnedTabs.count == space.unpinnedTabs.count
			else { continue }

			for (oldID, newID) in zip(old.unpinnedTabs, space.unpinnedTabs) where oldID != newID {
				guard let owner = owners[oldID] else { continue }
				owners[oldID] = nil
				owners[newID] = owner
			}
		}
		let open = Set(current.spaces.flatMap(\.unpinnedTabs))
		owners = owners.filter { open.contains($0.key) }
		guard owners != windowTabOwners else { return }

		windowTabOwners = owners
		applyOpenTabFilters()
	}

	/// Carries owners over to open tabs' new IDs, as a space another Mac moved to another
	/// profile gives them.
	internal mutating func replaceOwnedTabs(_ replacements: [BrowserCore.Tab.ID: BrowserCore.Tab.ID]) {
		guard independentWindows, !windowTabOwners.isEmpty, !replacements.isEmpty else { return }

		var owners = windowTabOwners
		for (old, new) in replacements {
			guard let owner = windowTabOwners[old] else { continue }
			owners[old] = nil
			owners[new] = owner
		}
		guard owners != windowTabOwners else { return }

		windowTabOwners = owners
		applyOpenTabFilters()
	}

	/// Whether an ordinary window other than `excluded` shows the tab or has it selected in the
	/// space it shows: it's on screen there, so it stays where it is.
	internal func isInUse(
		_ tabID: BrowserCore.Tab.ID,
		excluding excluded: UUID
	) -> Bool {
		guard presentingWindow(of: tabID, excluding: excluded) == nil else { return true }

		let hosts = (windowIsOpen ? [main] : []) + Array(windows)
		return hosts.contains { $0.id != excluded && !$0.isPrivate && $0.sidebar.selectedTab?.id == tabID }
	}

	/// The open tabs an additional window keeps, in the sidebar's order.
	internal func openTabs(ownedBy windowID: UUID) -> [BrowserCore.Tab.ID] {
		guard independentWindows, windowID != main.id, windowTabOwners.values.contains(windowID)
		else { return [] }

		return workspace.spaces.flatMap(\.unpinnedTabs).filter { windowTabOwners[$0] == windowID }
	}

	/// Gives a window the open tabs it took from `previous` to `current`: those it opened,
	/// restored or unpinned. Tabs that were opened in the main window, or that are no longer open,
	/// lose their owner. Run before the other windows reconcile, so none of them shows the new tabs
	/// for a moment.
	internal mutating func claimOpenedTabs(
		from originID: UUID,
		previous: BrowserOrganization,
		current: BrowserOrganization
	) {
		guard independentWindows else { return }

		let open = Set(current.spaces.flatMap(\.unpinnedTabs))
		let wasOpen = Set(previous.spaces.flatMap(\.unpinnedTabs))

		// New IDs of a space moved to another profile aren't new tabs; `remapOpenTabOwners` keeps
		// their windows.
		let reidentified = Set(current.spaces.filter { space in
			previous.spaces[id: space.id].map { $0.profileID != space.profileID } ?? false
		}.flatMap(\.unpinnedTabs))
		var owners = windowTabOwners.filter { open.contains($0.key) }
		let isOrdinary = originID == main.id || windows[id: originID]?.isPrivate == false
		defer {
			// A tab that opens in one window, unpinned there, say, is that window's: a step another
			// window made that made it would close it there (DEV-1030).
			let opened = open.subtracting(wasOpen).subtracting(reidentified)
			if windowUndo, isOrdinary, !opened.isEmpty { dropStepsMaking(opened, keptBy: windowTabOwners) }
		}
		for id in open.subtracting(wasOpen).subtracting(reidentified) where isOrdinary {
			// A tab ⌘Z brought back goes to the window it was in (DEV-1030).
			if let restored = restoredOpenTabOwners.removeValue(forKey: id), openWindow(restored) != nil {
				owners[id] = restored == main.id ? nil : restored
				continue
			}

			// A pinned tab another window shows stays with that window when it's unpinned here.
			let owner = presentingWindow(of: id, excluding: originID) ?? originID
			owners[id] = owner == main.id ? nil : owner
		}
		guard owners != windowTabOwners else { return }

		windowTabOwners = owners
		applyOpenTabFilters()

		// A pinned tab another window unpinned leaves this window's multi-selection too.
		pruneHiddenMoveSelections(openIn: current)
	}

	/// Gives a window open tabs that other windows keep, and has each of those windows let its
	/// tabs go: their split panes close and the selection moves to a neighbour.
	internal mutating func takeOpenTabs(
		_ tabs: [BrowserCore.Tab.ID],
		into windowID: UUID
	) -> Effect<AppFeature.Action> {
		guard independentWindows else { return .none }

		let sources = Dictionary(grouping: tabs.filter { windowOwning($0) != windowID }, by: windowOwning)
		guard !sources.isEmpty else { return .none }

		giveOpenTabs(tabs, to: windowID)
		return .merge(sources.compactMap { source, tabs in
			window(source) == nil ? nil : send(.releaseTabsForWindowMove(tabs), to: source)
		})
	}

	/// Undo of a Move to Window: the window the tabs left takes its open tabs back, and every other
	/// window that shows or selects one of the rest lets it go too, wherever it moved on to, as a
	/// pinned tab shows in one window at a time. The tab the window showed before the move shows
	/// there again once no other window does (DEV-1156).
	internal mutating func undoWindowMove(
		_ tabs: [BrowserCore.Tab.ID],
		into windowID: UUID,
		selecting selected: BrowserCore.Tab.ID?
	) -> Effect<AppFeature.Action> {
		if let selected { pendingWindowSelections[windowID] = selected }
		let taken = takeOpenTabs(tabs, into: windowID)
		let open = Set(workspace.spaces.flatMap(\.unpinnedTabs))
		let shared = tabs.filter { !open.contains($0) }
		guard !shared.isEmpty else { return taken }

		let releases: [Effect<AppFeature.Action>] = ([main.id] + windows.ids).compactMap { id in
			guard id != windowID, let host = openWindow(id), !host.isPrivate else { return nil }

			let held = shared.filter { tab in
				host.sidebar.selectedTab?.id == tab || host.viewer.panes.contains { $0.item.tab?.id == tab }
			}
			return held.isEmpty ? nil : send(.releaseTabsForWindowMove(held), to: id)
		}
		return .merge([taken] + releases)
	}

	/// Hands open tabs to a window: an additional window keeps them, the main window takes them
	/// back. Favorites and pinned tabs stay shared.
	internal mutating func giveOpenTabs(
		_ tabs: [BrowserCore.Tab.ID],
		to windowID: UUID
	) {
		guard independentWindows else { return }

		let open = Set(workspace.spaces.flatMap(\.unpinnedTabs))
		for id in tabs where open.contains(id) {
			windowTabOwners[id] = windowID == main.id ? nil : windowID
		}
		applyOpenTabFilters()
		pruneHiddenMoveSelections(openIn: workspace)
	}

	/// Drops from every window's multi-selection the open tabs it no longer shows, so Archive
	/// Selected and the other bulk actions can't reach them. Reads which tabs are open from the
	/// organization being published, as windows that haven't reconciled yet hold an older one.
	internal mutating func pruneHiddenMoveSelections(openIn organization: BrowserOrganization) {
		let open = Set(organization.spaces.flatMap(\.unpinnedTabs))
		for id in [main.id] + self.windows.ids {
			guard var host = window(id), !host.isPrivate else { continue }

			let filter = host.sidebar.openTabFilter
			let kept = host.sidebar.moveSelection.filter { item in
				guard case let .tab(uuid) = item else { return true }
				let tab = BrowserCore.Tab.ID(rawValue: uuid)
				return !open.contains(tab) || filter.shows(tab)
			}
			guard kept != host.sidebar.moveSelection else { continue }

			host.sidebar.moveSelection = kept
			if id == main.id { main = host } else { self.windows[id: id] = host }
		}
	}

	/// Sets every ordinary window's open-tab filter: the main window leaves out the tabs other
	/// windows keep, and every other window shows only its own. Private windows show their own
	/// organization whole.
	internal mutating func applyOpenTabFilters() {
		var owned: [UUID: Set<BrowserCore.Tab.ID>] = [:]
		if independentWindows {
			for (tab, window) in windowTabOwners { owned[window, default: []].insert(tab) }
		}

		let mainFilter: OpenTabFilter = !independentWindows || main.isPrivate
		? .all
		: .excluding(Set(windowTabOwners.keys))
		if main.sidebar.openTabFilter != mainFilter { main.sidebar.openTabFilter = mainFilter }

		for window in windows {
			let filter: OpenTabFilter = !independentWindows || window.isPrivate
			? .all
			: .only(owned[window.id] ?? [])
			if window.sidebar.openTabFilter != filter { windows[id: window.id]?.sidebar.openTabFilter = filter }
		}
	}

	/// Remembers the ordinary window with the keyboard, which keeps it as the window used last
	/// while Little Arx, Peek or Settings has the keyboard (DEV-1155). Private windows don't count,
	/// and the main window is kept as nil, so nothing changes while it's the only one.
	internal mutating func rememberOrdinaryWindow() {
		guard
			independentWindows,
			let id = focusedWindowID,
			let window = openWindow(id),
			!window.isPrivate
		else { return }

		let remembered = id == main.id ? nil : id
		if lastOrdinaryWindowID != remembered { lastOrdinaryWindowID = remembered }
	}

	/// The window Open in Arx from Little Arx puts its tab in: the ordinary window used last
	/// while it's open, else the main window (DEV-1155).
	internal var littlePromotionWindowID: UUID {
		guard
			independentWindows,
			let id = lastOrdinaryWindowID,
			let window = windows[id: id],
			!window.isPrivate,
			!window.isClosing
		else { return main.id }

		return id
	}

	/// The space a new window opens on: the front ordinary window's, else the main window's.
	internal var newWindowSpaceID: Space.ID {
		guard
			independentWindows,
			let id = focusedWindowID,
			let window = openWindow(id),
			!window.isPrivate,
			workspace.spaces[id: window.sidebar.spaceID] != nil
		else { return main.sidebar.spaceID }

		return window.sidebar.spaceID
	}

	/// Brings forward the window that keeps an open tab, with the tab selected. A tab of the
	/// closed main window comes to the window that chose it instead.
	fileprivate mutating func selectTabInOwningWindow(
		_ tabID: BrowserCore.Tab.ID,
		from sourceID: UUID
	) -> Effect<AppFeature.Action> {
		guard
			independentWindows,
			case let .unpinned(spaceID) = workspace.location(of: tabID)
		else { return .none }

		let ownerID = windowOwning(tabID)
		guard ownerID != sourceID else { return .none }

		guard let owner = openWindow(ownerID), !owner.isClosing else {
			// The main window is closed, or the owner is gone: the tab moves here.
			guard let source = openWindow(sourceID), !source.isPrivate else { return .none }

			giveOpenTabs([tabID], to: sourceID)
			guard source.sidebar.spaceID != spaceID else { return send(.ui(.selectTab(tabID)), to: sourceID) }

			return .concatenate(
				send(.sidebar(.ui(.spaceSelected(spaceID))), to: sourceID),
				send(.ui(.selectTab(tabID)), to: sourceID)
			)
		}

		focusedWindowID = ownerID
		guard owner.sidebar.spaceID != spaceID else { return send(.ui(.selectTab(tabID)), to: ownerID) }

		return .concatenate(
			send(.sidebar(.ui(.spaceSelected(spaceID))), to: ownerID),
			send(.ui(.selectTab(tabID)), to: ownerID)
		)
	}
}
