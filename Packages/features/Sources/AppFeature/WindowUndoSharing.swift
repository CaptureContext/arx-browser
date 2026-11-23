import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

/// ⌘Z across windows (DEV-1030). Each window takes back its own steps; a step that touched another
/// window too (Move to Window, Open in New Window), or none in particular (Settings, an agent), is
/// in every window it belongs to, and once one window takes it back the others drop it.
///
/// Taking back Move to Window or Open in New Window gives the tabs back to the window they left
/// (DEV-1156), from whichever window takes the step back. Without `ARX_WINDOW_UNDO` only the
/// window they left has the step, as before.
@Reducer
internal struct WindowUndoSharing {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.main.delegate.undid) { state, step in
			state.undid(step, in: state.main.id)
		}

		Pullback(\.main.delegate.shareUndo) { state, value in
			let (step, windowID) = value
			return state.share(step, with: windowID)
		}

		Pullback(\.windows) { state, action in
			switch action {
			case let .element(id, .delegate(.undid(step))):
				return state.undid(step, in: id)

			case let .element(_, .delegate(.shareUndo(step, windowID))):
				return state.share(step, with: windowID)

			default:
				return .none
			}
		}
	}
}

extension AppFeature.State {
	/// Whether ⌘Z is one history per window that outlasts changes made elsewhere,
	/// `ARX_WINDOW_UNDO` (DEV-1030). Every window takes the main window's.
	internal var windowUndo: Bool {
		main.sidebar.windowUndo
	}

	/// The windows whose ⌘Z covers the workspace: every one but private windows.
	internal var undoWindowIDs: [UUID] {
		[main.id] + windows.filter { !$0.isPrivate }.map(\.id)
	}

	/// Adds a step made outside the windows, by Settings or an agent, to each of them.
	internal func appendUndo(_ step: OrganizationUndo) -> Effect<AppFeature.Action> {
		guard windowUndo else { return .none }

		return .merge(undoWindowIDs.map { send(.appendUndo(step), to: $0) })
	}

	fileprivate func share(
		_ step: OrganizationUndo,
		with windowID: UUID
	) -> Effect<AppFeature.Action> {
		guard
			windowUndo,
			let window = openWindow(windowID),
			!window.isPrivate
		else { return .none }

		var shared = step
		shared.spaceID = nil
		shared.restoresSelection = false
		let superseded = step.windowMove.map { handOff($0.tabs, to: windowID, keeping: step) } ?? .none
		return .concatenate(superseded, send(.appendUndo(shared), to: windowID))
	}

	/// The window each open tab `previous` has and `organization` doesn't is in, closed, pinned or
	/// in a deleted space, for a step that brings them back to their windows (DEV-1030). Empty
	/// while windows share their tabs.
	internal func openTabOwners(
		removedFrom previous: BrowserOrganization,
		in organization: BrowserOrganization
	) -> [BrowserCore.Tab.ID: UUID] {
		guard independentWindows else { return [:] }

		let kept = Set(organization.spaces.flatMap(\.unpinnedTabs))
		let removed = previous.spaces.flatMap(\.unpinnedTabs).filter { !kept.contains($0) }
		return Dictionary(removed.map { ($0, windowOwning($0)) }) { first, _ in first }
	}

	/// Forgets, in every window but the one each tab is in now, the steps that made these open tabs.
	internal mutating func dropStepsMaking(
		_ tabs: Set<BrowserCore.Tab.ID>,
		keptBy owners: [BrowserCore.Tab.ID: UUID]
	) {
		for id in undoWindowIDs {
			let others = tabs.filter { (owners[$0] ?? main.id) != id }
			guard !others.isEmpty else { continue }

			if id == main.id {
				main.sidebar.dropStepsMaking(others)
			} else {
				windows[id: id]?.sidebar.dropStepsMaking(others)
			}
		}
	}

	/// Gives the open tabs a step brought back to the windows they were in: those published
	/// already now, the rest as they're published (`claimOpenedTabs`).
	private mutating func restoreOpenTabOwners(_ owners: [BrowserCore.Tab.ID: UUID]) {
		restoredOpenTabOwners = [:]
		guard independentWindows, !owners.isEmpty else { return }

		let open = Set(workspace.spaces.flatMap(\.unpinnedTabs))
		var current = windowTabOwners
		for (tab, owner) in owners {
			guard openWindow(owner) != nil else { continue }

			if open.contains(tab) {
				current[tab] = owner == main.id ? nil : owner
			} else {
				restoredOpenTabOwners[tab] = owner
			}
		}
		guard current != windowTabOwners else { return }

		windowTabOwners = current
		applyOpenTabFilters()
	}

	/// Open tabs dropped from another window's sidebar: this window keeps them (DEV-822), and no
	/// older step pulls them back from it or closes them there (DEV-1030).
	internal mutating func takeDroppedOpenTabs(
		_ tabs: [BrowserCore.Tab.ID],
		into windowID: UUID
	) -> Effect<AppFeature.Action> {
		let handedOver = independentWindows ? tabs.filter { windowOwning($0) != windowID } : []
		let taken = takeOpenTabs(tabs, into: windowID)
		return .concatenate(taken, handOff(handedOver, to: windowID, keeping: nil))
	}

	/// Tabs handed to `receiver`, by Move to Window or a drop: an earlier window move of them, but
	/// `kept`, goes from every window, so ⌘Z never pulls them back from where they went last, and
	/// a step that made them goes from every window but `receiver`, so ⌘Z elsewhere never closes
	/// them there.
	private func handOff(
		_ tabs: [BrowserCore.Tab.ID],
		to receiver: UUID,
		keeping kept: OrganizationUndo?
	) -> Effect<AppFeature.Action> {
		guard windowUndo, !tabs.isEmpty else { return .none }

		return .merge(undoWindowIDs.flatMap { id -> [Effect<AppFeature.Action>] in
			let moves = send(.dropWindowMoves(tabs, keeping: kept), to: id)
			return id == receiver ? [moves] : [moves, send(.dropStepsMaking(tabs), to: id)]
		})
	}

	fileprivate mutating func undid(
		_ step: OrganizationUndo,
		in windowID: UUID
	) -> Effect<AppFeature.Action> {
		guard windowUndo else {
			guard let move = step.windowMove, let window = openWindow(windowID) else { return .none }

			// As before: the window the tabs left takes them back, and shows again the tab it
			// showed (DEV-1156).
			let selected = step.before.spaces[id: window.sidebar.spaceID]?.selectedTabID
				.flatMap { move.tabs.contains($0) ? $0 : nil }
			return undoWindowMove(move.tabs, into: windowID, selecting: selected)
		}

		restoreOpenTabOwners(step.openTabOwners)
		let drops = undoWindowIDs
			.filter { $0 != windowID }
			.map { send(.dropUndo(step), to: $0) }
		guard let move = step.windowMove else { return .merge(drops) }

		return .merge(drops + [moveBack(move, of: step, undoneIn: windowID)])
	}

	/// Gives the tabs Move to Window sent away back to the window they came from, which shows its
	/// selected one again, once the window they went to lets them go.
	private mutating func moveBack(
		_ move: OrganizationUndo.WindowMove,
		of step: OrganizationUndo,
		undoneIn windowID: UUID
	) -> Effect<AppFeature.Action> {
		// The window that took the step back has the workspace as it is now; the others hear of
		// it once it publishes.
		guard let current = openWindow(windowID)?.sidebar.organization else { return .none }

		// Only tabs back where they were: one moved on since to another space stays where it went.
		// One moved on to a third window took this step away (`dropWindowMoves`); a pinned tab
		// another window shows comes back, as a pinned tab shows in one window at a time
		// (DEV-1156).
		let tabs = move.tabs.filter { tab in
			current.tabs[id: tab] != nil && current.location(of: tab) == step.before.location(of: tab)
		}
		guard
			let first = tabs.first,
			let source = openWindow(move.source),
			!source.isClosing
		else { return .none }

		focusedWindowID = move.source
		var effects: [Effect<AppFeature.Action>] = []

		// The window shows the tabs' space again if it moved on to another.
		let space: Space.ID? = switch current.location(of: first) {
		case let .unpinned(id), let .pinned(id, _): id
		case .favorite, nil: nil
		}
		if let space, space != source.sidebar.spaceID, source.sidebar.organization.spaces[id: space] != nil {
			effects.append(send(.sidebar(.ui(.spaceSelected(space))), to: move.source))
		}

		// Shared windows keep no open tabs of their own, so the window the tabs went to lets go of
		// those its panes show; independent ones hand them over below.
		let leaving = Set(tabs)
		if
			!independentWindows,
			let target = openWindow(move.target),
			target.viewer.panes.contains(where: { $0.item.tab.map { leaving.contains($0.id) } == true })
		{
			effects.append(send(.releaseTabsForWindowMove(tabs), to: move.target))
		}
		let selected = step.spaceID
			.flatMap { step.before.spaces[id: $0]?.selectedTabID }
			.flatMap { leaving.contains($0) ? $0 : nil }

		// Taken back here, the window shows again the tab it showed, as before (DEV-1156); from the
		// window they went to, it comes forward with the first of them.
		effects.append(undoWindowMove(tabs, into: move.source, selecting: selected ?? (windowID == move.source ? nil : first)))
		return .concatenate(effects)
	}
}
