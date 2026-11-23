import BrowserCore
import BrowserSurfaceClient
import Foundation
import MainFeature
import _ComposableArchitecture

@Reducer
internal struct SplitPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.main.delegate.requestSplit) { state, tabID in
			state.split(tabID, in: state.main.id)
		}
		Pullback(\.main.delegate.requestSpacePresentation) { state, value in
			state.restoreSpace(value.0, selected: value.1, selectRequested: value.2, in: state.main.id)
		}
		Pullback(\.windows) { state, action in
			switch action {
			case let .element(id, .delegate(.requestSplit(tabID))): return state.split(tabID, in: id)
			case let .element(id, .delegate(.requestSpacePresentation(spaceID, selected, selectRequested))):
				return state.restoreSpace(spaceID, selected: selected, selectRequested: selectRequested, in: id)
			default: return .none
			}
		}
	}
}

extension AppFeature.State {
	fileprivate func restoreSpace(
		_ spaceID: Space.ID,
		selected: BrowserCore.Tab.ID?,
		selectRequested: Bool,
		in sourceID: UUID
	) -> Effect<AppFeature.Action> {
		guard
			let source = sourceID == main.id ? main : windows[id: sourceID],
			!source.isClosing,
			source.sidebar.spaceID == spaceID,
			source.viewer.requestedSpaceID == spaceID
		else { return .none }

		let otherWindows = ((windowIsOpen ? [main] : []) + Array(windows)).filter { $0.id != sourceID }
		let claimedPanes = otherWindows.flatMap { $0.viewer.panes.compactMap { $0.item.tab?.id } }

		// Nor may it take another window's open tabs back (DEV-822).
		let claimed = Set(claimedPanes + peeks.map { $0.tab.id }).union(otherWindowsOpenTabs(for: sourceID))
		let tab = source.sidebar.organization.tabs[id: selected]
		let action = MainFeature.Action.viewer(.selectSpace(
			spaceID,
			source.sidebar.organization,
			selected: tab,
			selectRequested: selectRequested,
			excluding: claimed
		))
		return sourceID == main.id ? .send(.main(action)) : .send(.windows(.element(id: sourceID, action: action)))
	}

	fileprivate mutating func split(
		_ tabID: BrowserCore.Tab.ID,
		in sourceID: UUID
	) -> Effect<AppFeature.Action> {
		guard let source = sourceID == main.id ? main : windows[id: sourceID], !source.isClosing
		else { return .none }

		if let peek = peeks.first(where: { $0.tab.id == tabID }) {
			focusedWindowID = peek.source.windowID

			@Dependency(\.browserSurface)
			var surface

			return .run { _ in await surface.focus(tabID) }
		}

		let owners = (windowIsOpen ? [main] : []) + Array(windows)
		let owner = owners.first { $0.viewer.panes.contains { $0.item.tab?.id == tabID } }
		if let owner, let pane = owner.viewer.panes.first(where: { $0.item.tab?.id == tabID }) {
			focusedWindowID = owner.id
			let action = MainFeature.Action.viewer(.ui(.focus(pane.id)))
			return owner.id == main.id ? .send(.main(action)) : .send(.windows(.element(id: owner.id, action: action)))
		}
		guard source.sidebar.organization.tabs[id: tabID] != nil else { return .none }

		// The tab enters a new pane here; the window unpins a pinned one first (DEV-992).
		let action = MainFeature.Action.addPane(tabID)
		return sourceID == main.id ? .send(.main(action)) : .send(.windows(.element(id: sourceID, action: action)))
	}
}

extension AppFeature.State {
	/// Tells the window about to lay out a group, or take a dropped tab, which tabs other
	/// windows and Peek show.
	internal mutating func prepareGroupLayout(for action: AppFeature.Action) {
		let target: UUID
		switch action {
		case .main(.viewer(.layout)), .main(.ui(.dropTabInViewer)): target = main.id
		case let .windows(.element(id, .viewer(.layout))), let .windows(.element(id, .ui(.dropTabInViewer))): target = id
		default: return
		}

		let hosts = ((windowIsOpen ? [main] : []) + Array(windows)).filter { $0.id != target && !$0.isClosing }
		var elsewhere = hosts.reduce(into: Set(peeks.map(\.tab.id))) { result, host in
			result.formUnion(host.viewer.panes.compactMap { $0.item.tab?.id })
		}

		// Another window's open tabs stay out of this window's layout, split members included
		// (DEV-822).
		elsewhere.formUnion(otherWindowsOpenTabs(for: target))
		if target == main.id {
			main.viewer.tabsShownElsewhere = elsewhere
		} else {
			windows[id: target]?.viewer.tabsShownElsewhere = elsewhere
		}
	}
}
