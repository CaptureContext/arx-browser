import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import PeekFeature
import _ComposableArchitecture

internal struct SavedPageResetRequest: Equatable {
	internal var id: UUID
	internal var windows: [UUID: TabPresentationReset]
	internal var peeks: [UUID: Int]
}

/// Closing a favorite leaves its metadata intact, so ordinary organization reconciliation cannot unload other hosts.
@Reducer
internal struct SavedPageReset {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		Pullback(\.main) { state, action in handle(action, sourceID: state.main.id, state: &state) }
		Pullback(\.windows) { state, action in
			guard case let .element(id, action) = action else { return .none }
			return handle(action, sourceID: id, state: &state)
		}
		Pullback(\.finishSavedPageReset) { state, value in
			let (sourceID, tabID, requestID, wasUnloaded) = value
			guard let request = state.savedPageResets[sourceID]?[tabID], request.id == requestID
			else { return .none }
			state.savedPageResets[sourceID]?[tabID] = nil
			if state.savedPageResets[sourceID]?.isEmpty == true { state.savedPageResets[sourceID] = nil }
			return wasUnloaded ? complete(request, tabID: tabID, state: &state) : .none
		}
	}

	private func handle(
		_ action: MainFeature.Action,
		sourceID: UUID,
		state: inout State
	) -> Effect<Action> {
		switch action {
		case let .sidebar(.delegate(.resetTab(tabID))):
			let source = sourceID == state.main.id ? state.main : state.windows[id: sourceID]
			guard let source, source.pendingTabCloses.contains(tabID) else { return .none }

			let windows = ([state.main] + Array(state.windows))
				.filter { source.isPrivate ? $0.id == sourceID : !$0.isPrivate }
			let peeks = state.peeks
				.filter { !$0.isTemporary && $0.tab.id == tabID }
				.map { ($0.id, $0.viewer.generation) }
			state.savedPageResets[sourceID, default: [:]][tabID] = .init(
				id: uuid(),
				windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, .init(tabID: tabID, window: $0)) }),
				peeks: Dictionary(uniqueKeysWithValues: peeks)
			)
			return .none

		case let .event(.tabResetCompleted(tabID)):
			guard let request = state.savedPageResets[sourceID]?[tabID] else { return .none }
			return .run { @MainActor [engine, requestID = request.id] send in
				send(.finishSavedPageReset(
					sourceID: sourceID,
					tabID: tabID,
					requestID: requestID,
					wasUnloaded: engine.snapshot(tabID) == nil
				))
			}

		default: return .none
		}
	}

	private func complete(
		_ request: SavedPageResetRequest,
		tabID: BrowserCore.Tab.ID,
		state: inout State
	) -> Effect<Action> {
		// A new native session or presentation may have opened while close returned to the reducer.
		guard ([state.main] + Array(state.windows)).allSatisfy({ window in
				!window.viewer.panes.contains(where: { $0.item.tab?.id == tabID }) || request.windows[window.id]?.matches(window) == true
			}),
			state.peeks.filter({ $0.tab.id == tabID }).allSatisfy({
				request.peeks[$0.id] == $0.viewer.generation && $0.phase == .idle
			})
		else { return .none }
		let windows: [Effect<Action>] = request.windows.map { id, reset in
			if id == state.main.id { return .send(.main(.unloadResetTab(reset))) }
			guard state.windows[id: id] != nil else { return .none }
			return .send(.windows(.element(id: id, action: .unloadResetTab(reset))))
		}
		let peeks: [Effect<Action>] = request.peeks.map { id, generation in
			.send(.resetPeekPresentation(id, tabID: tabID, generation: generation))
		}
		return .merge(windows + peeks)
	}
}
