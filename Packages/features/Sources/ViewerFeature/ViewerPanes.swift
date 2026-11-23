import BrowserCore
import BrowserEngineClient
import Foundation
import ViewerItemFeature
import _ComposableArchitecture

@Reducer
internal struct ViewerPanes {
	internal typealias State = ViewerFeature.State
	internal typealias Action = ViewerFeature.Action

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.split) { state, tab in
				if let tab, let existing = state.panes.first(where: { $0.item.tab?.id == tab.id }) {
					state.activePaneID = existing.id
					return .none
				}
				guard state.canAddPane else { return .none }
				state.preservesPresentation = true
				let id = uuid()
				state.panes.append(.init(id: id))
				state.activePaneID = id
				state.fractions = SplitLayout.equal(state.panes.count)
				return .send(.show(tab, in: id))
			}

			Pullback(\.splitEmpty) { state, value in
				let (index, orientation) = value
				guard state.panes.count < state.capacity.panes(orientation) else { return .none }
				state.preservesPresentation = true
				state.orientation = orientation
				let id = uuid()
				state.panes.insert(.init(id: id), at: min(max(0, index), state.panes.count))
				state.activePaneID = id
				state.fractions = SplitLayout.equal(state.panes.count)
				return .send(.show(nil, in: id))
			}

			Pullback(\.insert) { state, value in
				let (tab, index, orientation) = value
				guard
					!state.panes.contains(where: { $0.item.tab?.id == tab.id }),
					state.panes.count < state.capacity.panes(orientation)
				else { return .none }
				state.preservesPresentation = true
				state.orientation = orientation
				let id = uuid()
				state.panes.insert(.init(id: id), at: min(max(0, index), state.panes.count))
				state.activePaneID = id
				state.fractions = SplitLayout.equal(state.panes.count)
				return .send(.show(tab, in: id))
			}

			Pullback(\.layout) { state, layout in

				// A tab another window shows stays there; the rest of the group still opens.
				var layout = layout
				let kept = layout.tabs.indices.filter { !state.tabsShownElsewhere.contains(layout.tabs[$0].id) }
				if kept.count != layout.tabs.count {
					let fractions = kept.compactMap { layout.fractions.indices.contains($0) ? layout.fractions[$0] : nil }
					layout.tabs = kept.map { layout.tabs[$0] }
					layout.fractions = SplitLayout.sanitized(
						fractions + (layout.addsEmptyPane ? [1 / Double(kept.count + 1)] : []),
						count: kept.count + (layout.addsEmptyPane ? 1 : 0)
					)
				}
				guard !layout.tabs.isEmpty else { return .none }
				let current = state.panes
				let wanted = layout.tabs.map(\.id)

				// Panes no longer needed lend their identity to new tabs in order, so a layout sent
				// twice lands the same way. A single tab takes the active pane, as selection always has.
				var spare = current
					.filter { pane in pane.item.tab.map { !wanted.contains($0.id) } ?? true }
					.map(\.id)
				if layout.tabs.count == 1, let index = spare.firstIndex(of: state.activePaneID) {
					spare.insert(spare.remove(at: index), at: 0)
				}

				var panes: IdentifiedArrayOf<ViewerPaneFeature.State> = []
				var shows: [(BrowserCore.Tab, UUID)] = []
				for tab in layout.tabs {
					if let pane = current.first(where: { $0.item.tab?.id == tab.id }) {
						panes.append(pane)
					} else {
						let id = spare.isEmpty ? uuid() : spare.removeFirst()
						panes.append(current[id: id] ?? .init(id: id))
						shows.append((tab, id))
					}
				}
				if layout.addsEmptyPane {
					let id = spare.isEmpty ? uuid() : spare.removeFirst()
					panes.append(.init(id: id))
				}
				state.panes = panes
				state.orientation = layout.orientation
				state.fractions = SplitLayout.sanitized(layout.fractions, count: panes.count)
				if layout.addsEmptyPane, let empty = panes.last {
					state.activePaneID = empty.id
				} else if let active = panes.first(where: { $0.item.tab?.id == layout.activeTabID })
					?? shows.first(where: { $0.0.id == layout.activeTabID }).flatMap({ panes[id: $0.1] }) {
					state.activePaneID = active.id
				} else if panes[id: state.activePaneID] == nil, let first = panes.first {
					state.activePaneID = first.id
				}
				if panes.count > 1 { state.preservesPresentation = true }
				return .merge(shows.map { tab, id in .send(.showInLayout(tab, in: id)) })
			}

			Pullback(\.resume) { state in
				let continuing = state.continuingPaneIDs
				state.continuingPaneIDs = []
				return .merge(state.panes.filter { !continuing.contains($0.id) }.map { pane in
					.send(.panes(.element(id: pane.id, action: .item(.show(pane.item.tab)))))
				})
			}

			Pullback(\.selectSpace) { state, value in
				let (spaceID, organization, selected, selectRequested, claimed) = value
				guard state.requestedSpaceID == spaceID else { return .none }
				if state.preservesPresentation, let current = state.currentPresentation {
					state.presentations.removeAll { $0.id == current.id }
					state.presentations.append(current)
				}
				let stored = state.presentations.first { $0.id == spaceID }
				var presentation = stored ?? .init(
					id: spaceID,
					panes: [.init(id: spaceID.rawValue, tabID: selected?.id)],
					activePaneID: spaceID.rawValue
				)

				// Replace the saved active placement before pruning stale identities, so an
				// explicit move/Undo selection cannot overwrite an unrelated surviving pane.
				let requestedSelection: BrowserCore.Tab? = selected.flatMap { tab in
					selectRequested && !claimed.contains(tab.id) ? tab : nil
				}
				if let selected = requestedSelection, let space = organization.spaces[id: spaceID] {
					switch organization.location(of: selected.id) {
					case .favorite(space.profileID), .unpinned(spaceID), .pinned(spaceID, _):
						let activeIndex = presentation.panes.firstIndex(where: { $0.id == presentation.activePaneID })
						?? presentation.panes.indices.first

						if let existing = presentation.panes.first(where: { $0.tabID == selected.id }) {
							presentation.activePaneID = existing.id

						} else if let index = activeIndex {
							presentation.panes[index].tabID = selected.id
							presentation.activePaneID = presentation.panes[index].id

						} else {
							presentation.panes = [.init(id: spaceID.rawValue, tabID: selected.id)]
							presentation.activePaneID = spaceID.rawValue
						}

					default:
						break
					}
				}
				guard let valid = presentation.sanitized(in: organization, excluding: claimed)
				else { return .none }
				guard state.apply(valid, tabs: organization.tabs) else { return .none }
				return .send(.resume)
			}

			Pullback(\.suspend) { state in
				state.continuingPaneIDs = []
				return .merge(state.panes.map { .send(.panes(.element(id: $0.id, action: .item(.suspend)))) })
			}

			Pullback(\.ui.focus) { state, id in
				guard state.panes[id: id] != nil else { return .none }
				state.activePaneID = id
				return .none
			}

			Pullback(\.ui.focusOtherPane) { state in
				guard
					state.isSplit,
					let index = state.panes.index(id: state.activePaneID)
				else { return .none }
				state.activePaneID = state.panes[(index + 1) % state.panes.count].id
				return .none
			}

			Pullback(\.ui.closePane) { state, id in
				guard state.isSplit, let index = state.panes.index(id: id) else { return .none }

				// Shares that never described these panes keep meaning "equal".
				if state.fractions.count == state.panes.count {
					var fractions = state.fractions
					fractions.remove(at: index)
					state.fractions = SplitLayout.sanitized(fractions, count: state.panes.count - 1)
				}
				state.panes.remove(id: id)
				if state.activePaneID == id {
					state.activePaneID = state.panes[min(index, state.panes.count - 1)].id
				}
				return .none
			}

			Pullback(\.ui.swapPanes) { state in
				guard state.isSplit else { return .none }
				state.panes = .init(uniqueElements: state.panes.reversed())
				if state.fractions.count == state.panes.count { state.fractions.reverse() }
				return .none
			}

			Pullback(\.ui.toggleOrientation) { state in
				let orientation: ViewerFeature.Orientation = state.orientation == .horizontal ? .vertical : .horizontal

				// Turning must leave every pane at least the minimum length.
				guard state.panes.count <= state.capacity.panes(orientation) else { return .none }
				state.orientation = orientation
				return .none
			}

			Pullback(\.ui.resize) { state, value in
				guard
					value.count == state.panes.count,
					value.allSatisfy(\.isFinite)
				else { return .none }
				state.fractions = SplitLayout.sanitized(value, count: state.panes.count)
				return .none
			}

			Pullback(\.ui.equalize) { state in
				state.fractions = SplitLayout.equal(state.panes.count)
				return .none
			}

			Pullback(\.ui.capacityChanged) { state, capacity in
				state.capacity = capacity
				return .none
			}
		}
		.forEach(\.panes, action: \.panes) { ViewerPaneFeature() }
	}
}
