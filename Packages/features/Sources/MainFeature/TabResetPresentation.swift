import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// Presentation identities captured before unloading a saved page. Contains no native ownership.
public struct TabPresentationReset: Equatable, Sendable {
	public let tabID: BrowserCore.Tab.ID
	public let generations: [UUID: Int]
	public let presentations: [BrowserSpacePresentation]

	public init(
		tabID: BrowserCore.Tab.ID,
		window: MainFeature.State
	) {
		self.tabID = tabID
		self.generations = Dictionary(uniqueKeysWithValues: window.viewer.panes.compactMap { pane in
			pane.item.tab?.id == tabID ? (pane.id, pane.item.generation) : nil
		})
		self.presentations = window.viewer.allPresentations
	}

	public func matches(_ window: MainFeature.State) -> Bool {
		window.viewer.panes.allSatisfy { pane in
			pane.item.tab?.id != tabID || generations[pane.id] == pane.item.generation
		}
	}
}

@Reducer
internal struct TabResetPresentation {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal var body: some ReducerOf<Self> {
		Pullback(\.unloadResetTab) { state, reset in
			guard reset.matches(state) else { return .none }
			return .run { @MainActor [engine] send in
				guard engine.snapshot(reset.tabID) == nil else { return }
				send(.applyResetTab(reset))
			}
		}

		Pullback(\.applyResetTab) { state, reset in
			guard reset.matches(state) else { return .none }
			state.clearResetTabPlacements(reset)
			let effects: [Effect<Action>] = reset.generations.map { paneID, generation in
				.send(.viewer(.unload(reset.tabID, in: paneID, generation: generation)))
			}
			return .concatenate(.merge(effects), .send(.delegate(.presentationChanged)))
		}
	}
}

extension MainFeature.State {
	/// Clears captured metadata placements; the caller separately unloads matching viewer generations.
	public mutating func clearResetTabPlacements(_ reset: TabPresentationReset) {
		guard reset.matches(self) else { return }
		for index in sidebar.organization.spaces.indices
		where sidebar.organization.spaces[index].selectedTabID == reset.tabID {
			sidebar.organization.spaces[index].selectedTabID = nil
		}
		for index in viewer.presentations.indices {
			let captured = reset.presentations.first { $0.id == viewer.presentations[index].id }
			for pane in viewer.presentations[index].panes.indices {
				let placement = viewer.presentations[index].panes[pane]
				if placement.tabID == reset.tabID, captured?.panes.contains(placement) == true {
					viewer.presentations[index].panes[pane].tabID = nil
				}
			}
		}
	}
}
