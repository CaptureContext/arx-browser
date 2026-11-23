import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

@Reducer
internal struct WindowPresentationPersistence {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.event.windowGeometryChanged) { state, value in
			let (id, geometry) = value
			guard id == state.main.id || state.windows[id: id]?.isPrivate == false
			else { return .none }
			_ = state.persistWindowPresentations()
			guard
				let index = state.windowLayout.windowPresentations.firstIndex(where: { $0.id == id }),
				state.windowLayout.windowPresentations[index].geometry != geometry
			else { return .none }
			state.$windowLayout.withLock { $0.windowPresentations[index].geometry = geometry }
			return state.saveWorkspace()
		}

		Pullback(\.main.delegate.presentationChanged) { state in state.persistWindowPresentations() }

		Pullback(\.windows) { state, action in
			guard
				case let .element(id, .delegate(.presentationChanged)) = action,
				state.windows[id: id]?.isPrivate == false
			else { return .none }
			return state.persistWindowPresentations()
		}

		Pullback(\.main.delegate.sidebarWidthChanged) { state, width in
			state.rememberSidebarWidth(width)
		}

		Pullback(\.windows) { state, action in
			guard
				case let .element(id, .delegate(.sidebarWidthChanged(width))) = action,
				state.windows[id: id]?.isPrivate == false
			else { return .none }
			return state.rememberSidebarWidth(width)
		}

		Pullback(\.main.ui.task) { state in
			.merge(state.windows.filter { $0.viewer.preservesPresentation }.map {
				.send(.windows(.element(id: $0.id, action: .ui(.task))))
			})
		}

		Pullback(\.event.additionalWindowClosed) { state, id in
			guard
				state.windows[id: id] == nil,
				state.windowLayout.windowPresentations.contains(where: { $0.id == id })
			else { return .none }
			state.$windowLayout.withLock { $0.windowPresentations.removeAll { $0.id == id } }
			state.unsavedOrganization = state.workspace
			return .send(.delegate(.save(state.workspace)))
		}
	}
}

extension AppFeature.State {
	internal mutating func restoreWindowPresentations() {
		let stored = windowLayout.windowPresentations
		main.sidebarWidth = newWindowSidebarWidth

		// Turned off in Settings: launch opens one window on the selected space, and the first
		// change saves that over the layouts from before.
		guard !stored.isEmpty, settings.general.restoresWindowsAtStartup else { return }
		var windowIDs: Set<UUID> = [main.id]
		let additional = stored.filter { saved in
			windowIDs.insert(saved.id).inserted && workspace.spaces.ids.contains(saved.activeSpaceID)
		}

		// The open tabs each window kept, before any layout (DEV-822): a tab shows in the window
		// that keeps it, even when another window's record showed it last.
		let kept = restoreKeptOpenTabs(additional)
		func keptElsewhere(_ windowID: UUID) -> Set<BrowserCore.Tab.ID> {
			Set(kept.filter { $0.value != windowID }.keys)
		}

		var claimed: Set<BrowserCore.Tab.ID> = []
		if let saved = stored.first(where: { $0.id == main.id }) {
			main.restore(saved, excluding: keptElsewhere(main.id))
			claimed.formUnion(main.viewer.panes.compactMap { $0.item.tab?.id })
		} else if let selected = main.sidebar.selectedTab, kept[selected.id] == nil { claimed.insert(selected.id) }
		var legacy: [MainFeature.State] = []
		for saved in additional {
			var window = MainFeature.State(organization: workspace, spaceID: saved.activeSpaceID, id: saved.id)
			window.commandBar.bangs = settings.bangs
			window.sidebarWidth = newWindowSidebarWidth
			window.sidebar.windowUndo = windowUndo
			window.restore(saved, excluding: claimed.union(keptElsewhere(saved.id)))
			claimed.formUnion(window.viewer.panes.compactMap { $0.item.tab?.id })
			windows.append(window)
			if saved.openTabs == nil { legacy.append(window) }
		}
		restoreLegacyOpenTabOwners(legacy, shown: claimed)
	}

	/// The open tabs each restored window's record kept (DEV-822). Those no longer open stay with
	/// no window, and a tab of a window that isn't restored is the main window's. Dropped again at
	/// launch unless the feature flag is on.
	private mutating func restoreKeptOpenTabs(
		_ records: [BrowserWindowPresentation]
	) -> [BrowserCore.Tab.ID: UUID] {
		let open = Set(workspace.spaces.flatMap(\.unpinnedTabs))
		for record in records {
			for tab in record.openTabs ?? [] where open.contains(tab) && windowTabOwners[tab] == nil {
				windowTabOwners[tab] = record.id
			}
		}
		return windowTabOwners
	}

	/// A record from before keeps no list, so the open tabs its panes show are its own: first
	/// those its active panes show, then those its other spaces' layouts hold that no window
	/// shows, so no window keeps a tab another one displays.
	private mutating func restoreLegacyOpenTabOwners(
		_ legacy: [MainFeature.State],
		shown: Set<BrowserCore.Tab.ID>
	) {
		let open = Set(workspace.spaces.flatMap(\.unpinnedTabs))
		func keep(_ tabs: [BrowserCore.Tab.ID], in windowID: UUID) {
			for tab in tabs where open.contains(tab) && windowTabOwners[tab] == nil {
				windowTabOwners[tab] = windowID
			}
		}

		for window in legacy {
			keep(window.viewer.panes.compactMap { $0.item.tab?.id }, in: window.id)
		}
		for window in legacy {
			let cached = window.viewer.allPresentations.flatMap { $0.panes.compactMap(\.tabID) }
			keep(cached.filter { !shown.contains($0) }, in: window.id)
		}
	}

	/// The open tabs a window's record keeps, or nil for the main window and while windows share
	/// their open tabs (DEV-822).
	fileprivate func savedOpenTabs(of windowID: UUID) -> [BrowserCore.Tab.ID]? {
		guard independentWindows, windowID != main.id else { return nil }
		return openTabs(ownedBy: windowID)
	}

	/// New windows inherit this; open windows keep their own width.
	internal var newWindowSidebarWidth: Double {
		BrowserSidebarWidth.sanitized(windowLayout.lastSidebarWidth)
	}

	fileprivate mutating func rememberSidebarWidth(_ width: Double) -> Effect<AppFeature.Action> {
		$windowLayout.withLock { $0.lastSidebarWidth = width }
		return persistWindowPresentations(force: true)
	}

	internal mutating func persistWindowPresentations(force: Bool = false) -> Effect<AppFeature.Action> {
		let previous = windowLayout.windowPresentations
		let records = ([main] + windows.filter { !$0.isPrivate }).compactMap { window in
			guard window.viewer.spaceID != window.sidebar.spaceID else {
				var record = window.windowPresentation
				record.geometry = previous.first { $0.id == window.id }?.geometry
				record.openTabs = savedOpenTabs(of: window.id)
				return record
			}
			var record = previous.first { $0.id == window.id }
			record?.sidebarWidth = window.sidebarWidth
			record?.chatWidth = window.chatWidth
			record?.chatPins = window.savedChatPins
			record?.openTabs = savedOpenTabs(of: window.id)
			return record
		}
		guard force || records != windowLayout.windowPresentations else { return .none }
		$windowLayout.withLock { $0.windowPresentations = records }

		// Saved now rather than when the document's change arrives, so a quit right after keeps it.
		unsavedOrganization = workspace
		return .send(.delegate(.save(workspace)))
	}
}

extension MainFeature.State {
	/// The window's pins in a stable order, or nil when there are none, so older snapshots
	/// compare equal.
	fileprivate var savedChatPins: [BrowserChatPin]? {
		guard !chatPins.isEmpty
		else { return nil }

		return chatPins
			.map { BrowserChatPin(tabID: $0.key, conversationID: $0.value) }
			.sorted { $0.tabID.rawValue.uuidString < $1.tabID.rawValue.uuidString }
	}

	fileprivate var windowPresentation: BrowserWindowPresentation {
		.init(
			id: id,
			activeSpaceID: sidebar.spaceID,
			spaces: savedPresentations,
			sidebarWidth: sidebarWidth,
			chatWidth: chatWidth,
			chatPins: savedChatPins
		)
	}

	/// A window that never split shows its sidebar's selection. A new window saves its geometry,
	/// and with it this record, before its view first shows that tab, so its one pane is still
	/// empty then. The selection stands in for it: an empty saved pane deselects the tab on the
	/// next launch, and its page is never created.
	fileprivate var savedPresentations: [BrowserSpacePresentation] {
		var presentations = viewer.allPresentations
		guard
			!viewer.preservesPresentation,
			let selected = sidebar.organization.spaces[id: sidebar.spaceID]?.selectedTabID,
			sidebar.organization.tabs[id: selected] != nil,
			!viewer.tabsShownElsewhere.contains(selected),
			let index = presentations.lastIndex(where: { $0.id == sidebar.spaceID }),
			presentations[index].panes.count == 1,
			presentations[index].panes[0].tabID == nil
		else { return presentations }

		presentations[index].panes[0].tabID = selected
		return presentations
	}

	fileprivate mutating func restore(
		_ saved: BrowserWindowPresentation,
		excluding claimed: Set<BrowserCore.Tab.ID>
	) {
		if let width = saved.sidebarWidth { sidebarWidth = BrowserSidebarWidth.sanitized(width) }
		if let width = saved.chatWidth { chatWidth = BrowserChatWidth.sanitized(width) }
		for pin in saved.chatPins ?? [] where sidebar.organization.tabs[id: pin.tabID] != nil {
			chatPins[pin.tabID] = pin.conversationID
		}
		var spaces: Set<Space.ID> = []
		let layouts = saved.spaces.compactMap { value -> BrowserSpacePresentation? in
			guard spaces.insert(value.id).inserted else { return nil }
			return value.sanitized(in: sidebar.organization, excluding: claimed)
		}
		guard let active = layouts.first(where: { $0.id == saved.activeSpaceID }) ?? layouts.first
		else { return }
		guard viewer.apply(active, tabs: sidebar.organization.tabs) else { return }

		sidebar.selectSpace(active.id)
		viewer.presentations = layouts
		viewer.preservesPresentation = true
		if let id = viewer.item.tab?.id {
			sidebar.select(id)
		} else if let index = sidebar.organization.spaces.index(id: active.id) {
			sidebar.organization.spaces[index].selectedTabID = nil
		}
	}
}
