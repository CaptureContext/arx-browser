import AppUI
import BrowserCore
import Foundation
import MainFeature
import SwiftUI
import _ComposableArchitecture

/// The tab menu's Move to Window and Open in New Window (DEV-883). A window shows one space, so
/// moving tabs to a window of the same profile moves them to its space; the window then shows the
/// first of them as soon as no other window does.
@Reducer
internal struct WindowTabMoves {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.main.delegate.moveTabsToWindow) { state, value in
			let (tabs, window, spaceID) = value
			return moveTabs(tabs, from: state.main.id, spaceID: spaceID, to: window, state: &state)
		}

		Pullback(\.windows) { state, action in
			guard case let .element(source, .delegate(.moveTabsToWindow(tabs, window, spaceID))) = action
			else { return .none }

			return moveTabs(tabs, from: source, spaceID: spaceID, to: window, state: &state)
		}
	}

	private func moveTabs(
		_ tabs: [BrowserCore.Tab.ID],
		from sourceID: UUID,
		spaceID: Space.ID,
		to targetID: UUID?,
		state: inout State
	) -> Effect<Action> {
		guard
			let first = tabs.first,
			let source = state.window(sourceID),
			!source.isPrivate
		else { return .none }

		// A space's sidebar also lists tabs another of its windows shows; only the window that
		// shows a tab, or none, can hand it over. The window that already shows the first tab
		// takes the rest without waiting.
		let owner = state.presentingWindow(of: first, excluding: sourceID)
		guard owner == nil || owner == targetID else { return .none }

		// Nor may any other tab of the selection be on screen in a third window.
		let isShownElsewhere = tabs.dropFirst().contains { tab in
			let shower = state.presentingWindow(of: tab, excluding: sourceID)
			return shower != nil && shower != targetID
		}
		guard !isShownElsewhere else { return .none }

		// A headless run shows no window, so nothing may open one or hand tabs to one; the tabs
		// stay where they are.
		guard !state.automation.isUnattended else { return .none }

		// With independent windows, Undo in this window brings the tabs back to it (DEV-1156); with
		// one ⌘Z per window, Undo in either window does (DEV-1030).
		let previous = state.independentWindows || state.windowUndo ? source.sidebar.organization : nil

		guard let targetID else {
			// Launch onboarding comes first; a browser window opens when it ends (DEV-838).
			guard !state.mainWindowWaitsForOnboarding else {
				state.bringOnboardingForward()
				return .none
			}

			let id = uuid()
			state.appendBrowserWindow(id, spaceID: spaceID)

			// The new window keeps the moved open tabs (DEV-822).
			state.giveOpenTabs(tabs, to: id)
			state.pendingWindowSelections[id] = first
			return .concatenate(
				state.send(.releaseTabsForWindowMove(tabs), to: sourceID),
				state.send(
					.completeWindowMove(tabs, spaceID: nil, previous: previous, handedOver: tabs, target: id),
					to: sourceID
				)
			)
		}

		guard
			targetID != sourceID,
			let target = state.openWindow(targetID),
			!target.isPrivate,
			let destination = state.workspace.spaces[id: target.sidebar.spaceID]
		else { return .none }

		// Only windows of the tabs' profile are listed; another profile's take Move to… instead.
		let sameProfile = tabs.allSatisfy { state.workspace.tabs[id: $0]?.profileID == destination.profileID }
		guard sameProfile else { return .none }

		// Tabs the window already shows only bring it forward, so undo leaves them there.
		let handedOver = tabs.filter { state.presentingWindow(of: $0, excluding: sourceID) != targetID }
		state.focusedWindowID = targetID
		state.giveOpenTabs(tabs, to: targetID)
		if owner == nil { state.pendingWindowSelections[targetID] = first }

		// Only now, with the move allowed, does the source window let the tabs go.
		return .concatenate(
			state.send(.releaseTabsForWindowMove(tabs), to: sourceID),
			state.send(.completeWindowMove(
				tabs,
				spaceID: destination.id == spaceID ? nil : destination.id,
				previous: previous,
				handedOver: handedOver,
				target: targetID
			), to: sourceID)
		)
	}
}

extension AppFeature.State {
	/// The window, while it's open.
	internal func openWindow(_ id: UUID) -> MainFeature.State? {
		if id == main.id { return windowIsOpen ? main : nil }
		return windows[id: id]
	}

	/// The open window other than `excluded` whose panes show the tab.
	internal func presentingWindow(
		of tab: BrowserCore.Tab.ID,
		excluding excluded: UUID
	) -> UUID? {
		let owners = (windowIsOpen ? [main] : []) + Array(windows)
		return owners.first { owner in
			owner.id != excluded && owner.viewer.panes.contains { $0.item.tab?.id == tab }
		}?.id
	}

	/// Shows each moved tab in its window once no other window shows it, and drops waits whose
	/// window or tab went away (DEV-883).
	internal mutating func applyPendingWindowSelections() -> Effect<AppFeature.Action> {
		guard !pendingWindowSelections.isEmpty else { return .none }

		var effects: [Effect<AppFeature.Action>] = []
		for (windowID, tabID) in pendingWindowSelections {
			guard
				let window = openWindow(windowID),
				!window.isClosing,
				workspace.tabs[id: tabID] != nil
			else {
				pendingWindowSelections[windowID] = nil
				continue
			}

			guard window.sidebar.organization.tabOrder(in: window.sidebar.spaceID).contains(tabID)
			else { continue }

			guard presentingWindow(of: tabID, excluding: windowID) == nil else { continue }

			pendingWindowSelections[windowID] = nil
			focusedWindowID = windowID
			effects.append(send(.ui(.selectTab(tabID)), to: windowID))
		}
		return .merge(effects)
	}

	/// The other open windows of the same profile a tab menu's Move to Window lists, each named
	/// by its space and the page it shows (DEV-883).
	public func sidebarWindowTargets(from windowID: UUID) -> [SidebarWindowTarget] {
		guard let source = openWindow(windowID), !source.isPrivate
		else { return [] }

		let profileID = source.sidebar.space.profileID
		let owners = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		return owners
			.filter { $0.id != windowID && !$0.isClosing && $0.sidebar.space.profileID == profileID }
			.map { window in
				let space = window.sidebar.space.name
				guard let page = window.sidebar.selectedTab?.displayTitle, !page.isEmpty
				else { return .init(id: window.id, title: space) }

				return .init(id: window.id, title: String.localized(.appUI.sidebar.windowTitle(space, page)))
			}
	}
}
