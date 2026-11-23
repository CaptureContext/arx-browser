import AppUI
import BrowserCore
import Foundation
import _ComposableArchitecture

@Reducer
internal struct ExplicitURLRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		Pullback(\.routePreview.ui.present) { state, candidate in
			guard state.routePreview == nil, state.routePreviewHostExists(for: candidate.source)
			else { return .none }

			state.routePreview = .init(
				id: uuid(),
				candidate: candidate,
				decision: state.routeDecision(for: candidate)
			)
			if state.routePreviewCandidate(for: candidate.source.target)?.source != candidate.source {
				state.routePreview?.failure = .sourceChanged
			}
			return .none
		}

		Pullback(\.routePreview.ui.choose) { state, value in
			let (id, destination) = value
			guard var preview = state.routePreview, preview.id == id else { return .none }
			preview.override = destination
			state.refreshRoutePreview(&preview)
			state.routePreview = preview
			return .none
		}

		Pullback(\.routePreview.ui.refresh) { state, id in
			guard var preview = state.routePreview, preview.id == id else { return .none }
			state.refreshRoutePreview(&preview)
			state.routePreview = preview
			return .none
		}

		Pullback(\.routePreview.ui.confirm) { state, id in
			guard var preview = state.routePreview, preview.id == id else { return .none }

			let currentSource = state.routePreviewCandidate(for: preview.candidate.source.target)?.source
			guard currentSource == preview.candidate.source else {
				state.routePreview?.failure = .sourceChanged
				return .none
			}
			let decision = state.routeDecision(for: preview.candidate, override: preview.override)
			guard case let .success(target) = decision.result else {
				preview.decision = decision
				preview.failure = nil
				state.routePreview = preview
				return .none
			}
			guard preview.decision.result == .success(target) else {
				state.routePreview?.failure = .destinationChanged
				return .none
			}
			state.routingInbox.requests.append(.init(
				id: uuid(),
				url: preview.candidate.url,
				currentSpaceID: preview.candidate.source.spaceID,
				override: .init(scope: .space(target.spaceID), mode: target.mode),
				expectedTarget: target
			))
			state.routePreview = nil
			return .send(.processRouteQueue)
		}

		Pullback(\.routePreview.ui.cancel) { state, id in
			if state.routePreview?.id == id { state.routePreview = nil }
			return .none
		}

		Pullback(\.routePreview.ui.presentationChanged) { state, value in
			if value.value == nil, state.routePreview?.id == value.id { state.routePreview = nil }
			return .none
		}

		// This reducer follows host teardown reducers; declined close requests retain the sheet.
		Pullback(\.ui.closeWindow) { state in
			state.clearClosedRoutePreview()
			return .none
		}

		Pullback(\.ui.closeAdditionalWindow) { state, _ in
			state.clearClosedRoutePreview()
			return .none
		}

		Pullback(\.event.additionalWindowClosed) { state, _ in
			state.clearClosedRoutePreview()
			return .none
		}

		Pullback(\.littleWindows) { state, _ in
			state.clearClosedRoutePreview()
			return .none
		}

		Pullback(\.peeks) { state, _ in
			state.clearClosedRoutePreview()
			return .none
		}

		Pullback(\.event.peekReleased) { state, _ in
			state.clearClosedRoutePreview()
			return .none
		}

		Pullback(\.event.littlePromotionReady) { state, _ in
			state.clearClosedRoutePreview()
			return .none
		}
	}
}

extension AppFeature.State {
	public func routePreviewCandidate(for target: AppFeature.CommandTarget) -> RoutePreview.Candidate? {
		guard
			let context = commandContext(for: target),
			BrowserCommand.routeCurrentURL.isEnabled(in: context)
		else { return nil }

		let source: RoutePreview.Source
		let url: URL
		switch target {
		case let .peek(id):
			guard let peek = peeks[id: id] else { return nil }
			source = .init(
				target: target,
				windowID: peek.source.windowID,
				tabID: peek.tab.id,
				profileID: peek.tab.profileID,
				spaceID: peek.source.spaceID
			)
			url = peek.viewer.navigation.url ?? peek.tab.restoration.url

		case let .window(id, paneID):
			if let little = littleWindows[id: id] {
				source = .init(
					target: target,
					windowID: id,
					tabID: little.tab.id,
					profileID: little.tab.profileID,
					spaceID: little.spaceID
				)
				url = little.viewer.navigation.url ?? little.tab.restoration.url
			} else {
				guard
					let window = id == main.id ? (windowIsOpen ? main : nil) : windows[id: id],
					let pane = window.viewer.panes[id: paneID ?? window.viewer.activePaneID],
					let tab = pane.item.tab,
					workspace.tabs[id: tab.id]?.profileID == tab.profileID
				else { return nil }
				source = .init(
					target: .window(id, paneID: pane.id),
					windowID: id,
					tabID: tab.id,
					profileID: tab.profileID,
					spaceID: window.sidebar.spaceID
				)
				url = pane.item.navigation.url ?? tab.restoration.url
			}

		default:
			return nil
		}

		guard
			routePreviewHostExists(for: source),
			workspace.profiles.ids.contains(source.profileID),
			workspace.spaces[id: source.spaceID]?.profileID == source.profileID
		else { return nil }

		return .init(url: url, source: source)
	}

	internal subscript(routePreviewPresentation id: UUID?) -> RoutePreview.Presentation {
		.init(id: id, value: routePreview?.id == id ? routePreview : nil)
	}

	fileprivate func routeDecision(
		for candidate: RoutePreview.Candidate,
		override: RoutingDestination? = nil
	) -> RoutingDecision {
		URLRouter.decide(
			candidate.url,
			preferences: settings.routingPreferences,
			organization: workspace,
			currentSpaceID: candidate.source.spaceID,
			recentSpaceIDs: recentSpaceIDs,
			override: override
		)
	}

	fileprivate func refreshRoutePreview(_ preview: inout RoutePreview) {
		let currentSource = routePreviewCandidate(for: preview.candidate.source.target)?.source
		guard currentSource == preview.candidate.source else {
			preview.failure = .sourceChanged
			return
		}
		preview.decision = routeDecision(for: preview.candidate, override: preview.override)
		preview.failure = nil
	}

	fileprivate mutating func clearClosedRoutePreview() {
		guard let preview = routePreview else { return }
		if !routePreviewHostExists(for: preview.candidate.source) { routePreview = nil }
	}

	fileprivate func routePreviewHostExists(for source: RoutePreview.Source) -> Bool {
		let id = source.windowID
		let exists = id == main.id ? windowIsOpen : windows[id: id] != nil || littleWindows[id: id] != nil
		guard exists else { return false }

		if case let .peek(id) = source.target { return peeks[id: id] != nil }
		return true
	}
}
