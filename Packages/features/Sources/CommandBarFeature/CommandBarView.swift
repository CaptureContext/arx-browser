import AppUI
import SwiftUI
import _ComposableArchitecture

public struct CommandBarView: View {
	private let style: CommandBarStyle
	private let maximumResultsHeight: CGFloat?
	private let onClose: (() -> Void)?

	/// Little Arx's profile picker at the bar's bottom-left corner (DEV-1331); nil elsewhere.
	private let profilePicker: CommandBarProfilePickerContent?

	@Bindable
	public var store: StoreOf<CommandBarFeature>

	public init(
		store: StoreOf<CommandBarFeature>,
		style: CommandBarStyle = .palette,
		maximumResultsHeight: CGFloat? = nil,
		profilePicker: CommandBarProfilePickerContent? = nil,
		onClose: (() -> Void)? = nil
	) {
		self.style = style
		self.maximumResultsHeight = maximumResultsHeight
		self.profilePicker = profilePicker
		self.onClose = onClose
		self.store = store
	}

	public var body: some View {
		CommandBar(
			query: $store.query.sending(\.ui.queryChanged),
			selectedID: $store.selectedID.sending(\.ui.highlighted),
			results: store.entries.map(\.presentation),
			style: style,
			placeholder: store.siteSearchKeyword.map { String.localized(.appUI.search.sitePrompt($0)) }
				?? (store.mode == .history ? String.localized(.appUI.command.historyPlaceholder) : nil),
			chip: store.state.pageActionEntries.isEmpty ? nil : String.localized(.appUI.command.actions),
			inputIcon: store.state.addressSiteIcon,
			inputSymbol: store.state.isAddress ? "globe" : "magnifyingglass",
			scopeIcon: store.state.scopeSiteIcon,
			// Tab never follows a result. A shortcut keyword starts a site search; anything else
			// is reserved for chat (DEV-720), so focus stays here.
			onTab: {
				store.send(.ui(.tabPressed))
				return true
			},
			onDeleteWhenEmpty: { store.send(.ui(.deletedWhenEmpty)) },
			// Clicking the hint is pressing Tab, so it can never disagree with the key.
			onAskAgent: store.state.showsAgentHint ? { store.send(.ui(.tabPressed)) } : nil,
			focusRequest: store.focusRequest,
			inputRefocusRequest: store.inputRefocusRequest,
			// ⌘K reaches the bar through the host's command routing; the button is the pointer's way.
			onShowActions: { store.send(.ui(.actionsToggled)) },
			actionsKey: store.actionsShortcut,
			actionsPanel: actionsPanel,
			profilePicker: profilePicker,
			onShortcut: runShortcut,
			maximumResultsHeight: maximumResultsHeight,
			onClose: onClose,
			onSelect: { store.send(.ui(.selected($0))) },
			// ⌘-click does what ⌘↩ does with the row highlighted (DEV-1319).
			onCommandSelect: { store.send(.ui(.commandClicked($0))) },
			onDismiss: { store.send(.ui(.dismissed)) }
		)
	}

	/// Runs the action a key names on the panel's or the highlighted result, if it has one.
	private func runShortcut(_ key: String) -> Bool {
		if let profilePicker, profilePicker.key == key {
			profilePicker.onToggle()
			return true
		}
		guard let id = store.state.actionID(forShortcut: key) else { return false }
		store.send(.ui(.actionRequested(id)))
		return true
	}

	private var actionsPanel: CommandBarActionsContent? {
		guard
			let panel = store.actionPanel,
			let entry = store.state.actionPanelEntry
		else { return nil }

		return .init(
			title: entry.presentation.title,
			query: Binding(
				get: { panel.query },
				set: { store.send(.ui(.actionQueryChanged($0))) }
			),
			selectedID: Binding(
				get: { store.actionPanel?.selectedID },
				set: { store.send(.ui(.actionHighlighted($0))) }
			),
			actions: store.state.actionPanelActions.map(\.presentation),
			onSelect: { store.send(.ui(.actionSelected($0))) },
			onDismiss: { store.send(.ui(.actionsDismissed)) },
			onShortcut: runShortcut
		)
	}
}
