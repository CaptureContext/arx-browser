import BrowserCore
import Foundation
import _ComposableArchitecture

extension ViewerFeature.State {
	public var currentPresentation: BrowserSpacePresentation? {
		guard let spaceID else { return nil }
		return .init(
			id: spaceID,
			panes: panes.map { .init(id: $0.id, tabID: $0.item.tab?.id) },
			activePaneID: activePaneID,
			orientation: orientation,
			fractions: fractions
		)
	}

	public var allPresentations: [BrowserSpacePresentation] {
		guard let current = currentPresentation else { return presentations }
		return presentations.filter { $0.id != current.id } + [current]
	}

	@discardableResult
	public mutating func apply(
		_ presentation: BrowserSpacePresentation,
		tabs: IdentifiedArrayOf<BrowserCore.Tab>
	) -> Bool {
		preserveObservationGeneration()
		let observationCount = presentation.panes.filter { placement in
			tabs[id: placement.tabID] != nil
		}.count

		// Reserve the invalidation epoch and every observation before replacing any
		// placement. A split must never exhaust the counter after only its first pane.
		let required = observationCount + 1
		guard observationGeneration <= Int.max - required else { return false }
		observationGeneration += 1

		// A page already on screen keeps its pane, so its host view, observation and page state
		// carry over. A Favorite shown in both spaces stays the same live page (DEV-771).
		var shown: [BrowserCore.Tab.ID: ViewerPaneFeature.State] = [:]
		for pane in panes where pane.item.isObserving {
			guard let id = pane.item.tab?.id else { continue }
			shown[id] = pane
		}
		let placementIDs = Set(presentation.panes.map(\.id))
		var activePaneID = presentation.activePaneID
		var continuing: Set<UUID> = []
		panes = .init(uniqueElements: presentation.panes.map { placement in
			let tab = tabs[id: placement.tabID]
			let current = tab.flatMap { shown.removeValue(forKey: $0.id) }

			// Another placement's identity stays its own, so panes stay unique.
			let keepsCurrent = current.map { $0.id == placement.id || !placementIDs.contains($0.id) } ?? false
			if keepsCurrent, let tab, var pane = current {
				if placement.id == presentation.activePaneID { activePaneID = pane.id }
				pane.item.tab = tab
				continuing.insert(pane.id)
				return pane
			}
			return .init(
				id: placement.id,
				item: .init(
					tab: tab,
					navigation: .init(
						url: tab?.restoration.url,
						title: tab?.restoration.title ?? ""
					),
					generation: observationGeneration
				)
			)
		})
		self.activePaneID = activePaneID
		continuingPaneIDs = continuing
		orientation = presentation.orientation
		fractions = SplitLayout.sanitized(presentation.fractions, count: panes.count)
		spaceID = presentation.id
		requestedSpaceID = presentation.id
		return true
	}

	internal mutating func preserveObservationGeneration() {
		observationGeneration = max(observationGeneration, panes.map(\.item.generation).max() ?? 0)
	}
}
