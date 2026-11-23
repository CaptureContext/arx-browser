import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

internal struct RoutingInboxView: View {
	internal let store: StoreOf<AppFeature>

	internal init(store: StoreOf<AppFeature>) {
		self.store = store
	}

	internal var body: some View {
		if store.routingInbox.requests.contains(where: { $0.status != .choosingProfile }) {
			ScrollView {
				VStack(alignment: .leading, spacing: 12) {
					Text(localized: .appUI.routing.pendingLinks).font(.headline)

					// The picker at the pointer asks about its link; the list shows the rest.
					ForEach(store.routingInbox.requests.filter { $0.status != .choosingProfile }) { request in
						requestView(request)
						Divider()
					}
				}
				.padding()
			}
			.frame(maxWidth: 580, maxHeight: 260)
			.pagePopupSurface()
		}
	}

	private func requestView(_ request: RoutingRequest) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(request.url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
			if let rule = store.settings.routingPreferences.rules.first(where: { $0.id == request.matchedRuleID }) {
				Text(rule.name).font(.callout.bold())
			}
			Text(status(request)).font(.callout).foregroundStyle(.secondary)
			HStack {
				RoutingDestinationMenu(organization: store.workspace, destination: request.override) {
					store.send(.ui(.chooseRouteDestination(request.id, $0)))
				}
				.disabled(isOpening(request))
				Button(String.localized(.appUI.persistence.retry)) { store.send(.ui(.retryRoute(request.id))) }
					.disabled(isOpening(request) || !store.routingInbox.isReady)
				Button(String.localized(.appUI.links.copyOriginal)) {
					store.send(.ui(.copyLinks(.original, items: [.init(title: "", url: request.url)])))
				}
				Button(String.localized(.appUI.routing.cancel)) { store.send(.ui(.cancelRoute(request.id))) }
			}
		}
	}

	private func isOpening(_ request: RoutingRequest) -> Bool {
		if case .opening = request.status { return true }
		return false
	}

	private func status(_ request: RoutingRequest) -> String {
		switch request.status {
		case .queued, .choosingProfile: String.localized(.appUI.routing.waiting)
		case let .opening(target, _):
			String.localized(.appUI.routing.opening(
				RoutingDestination(scope: .space(target.spaceID), mode: target.mode).routingTitle(in: store.workspace)
			))
		case let .needsDestination(error): routingErrorMessage(error)
		case let .failed(message): message
		}
	}
}
