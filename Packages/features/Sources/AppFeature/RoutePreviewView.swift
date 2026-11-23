import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

internal struct RoutePreviewPresentation: ViewModifier {
	@Bindable
	private var store: StoreOf<AppFeature>

	private let windowID: UUID

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID
	) {
		self.store = store
		self.windowID = windowID
	}

	internal func body(content: Content) -> some View {
		let preview = store.routePreview
		let id = preview?.candidate.source.windowID == windowID ? preview?.id : nil
		let presentation = $store[routePreviewPresentation: id].sending(\.routePreview.ui.presentationChanged)
		content.sheet(item: presentation.value) { presented in
			if let current = store.routePreview, current.id == presented.id {
				RoutePreviewView(store: store, preview: current)
			}
		}
	}
}

private struct RoutePreviewView: View {
	private let store: StoreOf<AppFeature>
	private let preview: RoutePreview

	internal init(
		store: StoreOf<AppFeature>,
		preview: RoutePreview
	) {
		self.store = store
		self.preview = preview
	}

	private var matchedRule: RoutingRule? {
		guard let id = preview.decision.matchedRuleID else { return nil }
		return store.settings.routingPreferences.rules.first { $0.id == id }
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(BrowserCommand.routeCurrentURL.title).font(.headline)
			Text(preview.candidate.url.absoluteString).font(.body.monospaced()).textSelection(.enabled)
				.lineLimit(5).truncationMode(.middle)
			Text(localized: .appUI.routing.previewDescription).foregroundStyle(.secondary)
			if let rule = matchedRule {
				Text(String.localized(.appUI.links.matched(rule.name)))
			}
			switch preview.decision.result {
			case let .success(target):
				let profile = store.workspace.profiles[id: target.profileID]?.name
				let destination = RoutingDestination(scope: .space(target.spaceID), mode: target.mode)
					.routingTitle(in: store.workspace)
				Text(profile.map { String.localized(.appUI.routing.profileAndDestination($0, destination)) } ?? destination)
					.font(.body.bold())
			case let .failure(error):
				Text(routingErrorMessage(error)).foregroundStyle(.red)
			}
			HStack {
				RoutingDestinationMenu(
					organization: store.workspace,
					destination: preview.override ?? preview.decision.destination
				) {
					store.send(.routePreview(.ui(.choose(preview.id, $0))))
				}
				Button(String.localized(.appUI.routing.useRules)) {
					store.send(.routePreview(.ui(.choose(preview.id, nil))))
				}
			}
			if let failure = preview.failure {
				Text(String.localized(failure == .sourceChanged ? .appUI.routing.sourceChanged : .appUI.routing.destinationChanged))
					.foregroundStyle(.red)
			}
			HStack {
				Button(String.localized(.appUI.routing.refreshDestination)) { store.send(.routePreview(.ui(.refresh(preview.id)))) }
				Spacer()
				Button(String.localized(.appUI.routing.cancel)) { store.send(.routePreview(.ui(.cancel(preview.id)))) }
					.keyboardShortcut(.cancelAction)
				Button(String.localized(.appUI.routing.openDestination)) { store.send(.routePreview(.ui(.confirm(preview.id)))) }
					.keyboardShortcut(.defaultAction)
					.disabled(!canConfirm)
			}
		}
		.padding(24)
		.frame(width: 520)
	}

	private var canConfirm: Bool {
		guard preview.failure == nil, case .success = preview.decision.result else { return false }
		return true
	}
}
