import BrowserCore
import SidebarFeature
import _ComposableArchitecture

/// The window's ⌘Z history (DEV-1030). The sidebar keeps the steps and takes them back; this
/// shows the space a step was made in again, and passes steps to and from the other windows
/// through the app.
@Reducer
internal struct WindowUndo {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.sidebar.delegate.undid) { state, step in
			guard !state.isPrivate else { return .none }

			let undid: Effect<Action> = .send(.delegate(.undid(step)))
			guard
				state.sidebar.windowUndo,
				let spaceID = step.spaceID,
				spaceID != state.sidebar.spaceID,
				state.sidebar.organization.spaces[id: spaceID] != nil
			else { return undid }

			return .concatenate(.send(.sidebar(.ui(.spaceSelected(spaceID)))), undid)
		}

		Pullback(\.appendUndo) { state, step in
			guard !state.isPrivate, state.sidebar.windowUndo else { return .none }

			state.sidebar.appendUndo(step)
			return .none
		}

		Pullback(\.dropUndo) { state, step in
			state.sidebar.undo.removeAll { $0.isSameChange(as: step) }
			return .none
		}

		Pullback(\.dropWindowMoves) { state, value in
			let (tabs, kept) = value
			let moved = Set(tabs)

			// The whole older step goes: its workspaces hold the moved-on tabs' move too, so taking
			// back the rest would pull them from where they went (DEV-1190).
			state.sidebar.undo.removeAll { step in
				guard
					let move = step.windowMove,
					kept.map({ !step.isSameChange(as: $0) }) ?? true
				else { return false }

				return !moved.isDisjoint(with: move.tabs)
			}
			return .none
		}

		Pullback(\.dropStepsMaking) { state, tabs in
			state.sidebar.dropStepsMaking(Set(tabs))
			return .none
		}
	}
}
