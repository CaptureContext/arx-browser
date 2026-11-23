import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The profile picker's content: the Runway (DEV-858), regular or compact as Settings › Links ›
/// Air Traffic Control › Runway appearance chooses, with the profiles most recent first.
internal struct RoutingProfilePickerView: View {
	private let store: StoreOf<AppFeature>
	private let picker: RoutingProfilePicker

	@FocusState
	private var isSearching: Bool

	internal init(
		store: StoreOf<AppFeature>,
		picker: RoutingProfilePicker
	) {
		self.store = store
		self.picker = picker
	}

	/// The store's picker while it's this one; the panel keeps the last one while it closes.
	private var current: RoutingProfilePicker {
		guard let live = store.routingInbox.picker, live.requestID == picker.requestID
		else { return picker }
		return live
	}

	internal var body: some View {
		let current = current
		RunwayView(
			appearance: store.settings.linkClicks.runwayAppearance,
			url: picker.url,
			options: current.results.map(\.runwayOption),
			selectedID: current.selection?.id,
			query: Binding(
				get: { current.query },
				set: { store.send(.profilePicker(.ui(.setQuery($0)))) }
			),
			isSearching: $isSearching,
			onOpen: { id in
				store.send(.profilePicker(.ui(.highlight(id))))
				store.send(.profilePicker(.ui(.confirm)))
			},
			onDrop: { store.send(.profilePicker(.ui(.cancel))) }
		)
		.padding(BrowserMetrics.LittleArx.Runway.shadowInset)
		.frame(maxHeight: .infinity, alignment: .top)

		// The search field is the only thing here that takes the keyboard: the arrow keys move
		// the selection without any focus ring, Tab stays put, and nothing else draws one (DEV-953).
		.focusEffectDisabled()
		.onAppear { isSearching = true }
		.onKeyPress(.upArrow) { send(.move(-1)) }
		.onKeyPress(.downArrow) { send(.move(1)) }
		.onKeyPress(.return) { send(.confirm) }
		.onKeyPress(keys: [.tab, Self.backTab]) { _ in .handled }
		.onExitCommand { store.send(.profilePicker(.ui(.cancel))) }
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.routing.pickProfile))
	}

	/// Shift-Tab, which arrives as the back-tab character.
	private static let backTab: KeyEquivalent = .init("\u{19}")

	private func send(_ action: RoutingProfilePickerAction.UI) -> KeyPress.Result {
		store.send(.profilePicker(.ui(action)))
		return .handled
	}
}

extension RoutingProfilePicker.Option {
	fileprivate var runwayOption: RunwayOption {
		.init(id: id, name: name, spaceName: spaceName, spaceIcon: spaceIcon)
	}
}
