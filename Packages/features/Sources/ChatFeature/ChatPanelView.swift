import AgentClient
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

public enum ChatMetrics {
	public static let panelWidth: CGFloat = 360
	public static let cornerRadius: CGFloat = BrowserMetrics.PageCard.cornerRadius
	public static let headerButton: CGFloat = 30
	public static let avatar: CGFloat = 34
	public static let padding: CGFloat = 12
}

/// The chat panel in a window's right sidebar.
///
/// The window owns only whether it's shown. Everything else belongs to the profile's
/// ``ChatFeature``, so hiding the panel or closing the window never stops a turn.
public struct ChatPanelView: View {
	@Bindable
	public var store: StoreOf<ChatFeature>

	/// Tabs and folders of the window's space that the + picker offers.
	public let attachables: [ChatAttachable]
	public let onHide: () -> Void

	/// Where it shows: a window's panel, a panel pinned to a tab, or a chat tab (DEV-761).
	public let placement: ChatPlacement

	@SwiftUI.State
	private var isRenaming: Bool

	@SwiftUI.State
	private var renameText: String

	@SwiftUI.State
	private var pendingConfirmation: ChatConfirmation?

	public init(
		store: StoreOf<ChatFeature>,
		attachables: [ChatAttachable],
		placement: ChatPlacement = .panel,
		onHide: @escaping () -> Void
	) {
		self.store = store
		self.attachables = attachables
		self.placement = placement
		self.onHide = onHide
		self._isRenaming = .init(initialValue: false)
		self._renameText = .init(initialValue: "")
		self._pendingConfirmation = .init(initialValue: nil)
	}

	public var body: some View {
		content
			.alert(String.localized(.appUI.chat.renameTitle), isPresented: $isRenaming) {
				TextField(String.localized(.appUI.common.name), text: $renameText)
				Button(String.localized(.appUI.common.cancel), role: .cancel) {}
				Button(String.localized(.appUI.common.save)) { store.send(.ui(.renamed(renameText))) }
					.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
			.confirmationDialog(
				pendingConfirmation?.title ?? "",
				isPresented: isConfirming,
				presenting: pendingConfirmation
			) { confirmation in
				confirmationButton(confirmation)
			} message: { confirmation in
				Text(confirmation.message(provider: store.provider.title))
			}
	}

	@ViewBuilder
	private func confirmationButton(_ confirmation: ChatConfirmation) -> some View {
		switch confirmation {
		case .archive:
			Button(String.localized(.appUI.chat.archiveShort)) { store.send(.ui(.archiveTapped)) }

		case .delete:
			Button(String.localized(.appUI.chat.deleteShort), role: .destructive) { store.send(.ui(.deleteTapped)) }
		}
	}

	private var content: some View {
		VStack(spacing: 0) {
			if store.screen == .info {
				ChatInfoView(
					store: store,
					actions: chatActions,
					onHide: onHide
				)
			} else {
				ChatStudioPanel(store: store, context: context)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)

		// The window's own tint and grain, a step lighter, so the card reads as part of the window.
		.background {
			ZStack {
				BrowserChromeBackground(textured: true)
				BrowserTheme.fill
			}
			.clipShape(.rect(cornerRadius: ChatMetrics.cornerRadius, style: .continuous))
			.shadow(color: .black.opacity(0.08), radius: 6, y: 2)
		}
		.overlay {
			RoundedRectangle(cornerRadius: ChatMetrics.cornerRadius, style: .continuous)
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
		}
		.task { store.send(.ui(.task)) }
		.onKeyPress(.escape, phases: .down) { press in

			// A chat tab isn't hidden: it closes like any tab.
			guard press.modifiers.contains(.shift), placement.kind != .tab
			else { return .ignored }

			onHide()
			return .handled
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.chat.panel))
	}

	private var context: ChatPanelContext {
		.init(
			attachables: attachables,
			actions: chatActions,
			placement: placement,
			onHide: onHide
		)
	}

	private var isConfirming: Binding<Bool> {
		$pendingConfirmation.isChatConfirmationPresented
	}

	private var chatActions: [ChatAction] {
		let selected = store.selected
		var actions: [ChatAction] = []
		if let selected {
			actions.append(.init(
				group: .thisChat,
				title: String.localized(.appUI.chat.copyAnswer),
				shortTitle: String.localized(.appUI.chat.copyAnswer),
				symbol: "doc.on.doc",
				shortcut: "↩",
				isEnabled: selected.lastAnswer != nil
			) { store.send(.ui(.copyAnswerTapped)) })
			actions.append(.init(
				group: .thisChat,
				title: String.localized(selected.isKept ? .appUI.chat.unpin : .appUI.chat.pin),
				shortTitle: String.localized(selected.isKept ? .appUI.chat.unpinShort : .appUI.chat.pinShort),
				symbol: selected.isKept ? "pin.slash" : "pin"
			) { store.send(.ui(.pinTapped)) })
			actions.append(.init(
				group: .thisChat,
				title: String.localized(.appUI.chat.rename),
				symbol: "pencil"
			) {
				renameText = selected.title
				isRenaming = true
			})
			actions.append(.init(
				group: .thisChat,
				title: String.localized(selected.archivedAt == nil ? .appUI.chat.archive : .appUI.chat.unarchive),
				shortTitle: String.localized(selected.archivedAt == nil ? .appUI.chat.archiveShort : .appUI.chat.unarchive),
				symbol: "archivebox",
				// Only kept chats are archived; a temporary one simply expires.
				isEnabled: selected.isKept
			) {
				if selected.archivedAt == nil {
					pendingConfirmation = .archive
				} else {
					store.send(.ui(.archiveTapped))
				}
			})
			actions.append(.init(
				group: .thisChat,
				title: String.localized(.appUI.chat.delete),
				symbol: "trash",
				role: .destructive
			) { pendingConfirmation = .delete })
		}
		actions.append(.init(
			group: .chats,
			title: String.localized(.appUI.chat.newChat),
			symbol: "square.and.pencil"
		) { store.send(.ui(.newChatTapped)) })
		actions.append(.init(
			group: .chats,
			title: String.localized(.appUI.chat.history),
			symbol: "clock.arrow.circlepath"
		) { store.send(.ui(.historyTapped)) })
		actions.append(contentsOf: placementActions(selected?.id))
		if placement.kind != .tab {
			actions.append(.init(
				group: .chats,
				title: String.localized(.appUI.chat.hide),
				symbol: "xmark",
				shortcut: "⇧ esc",
				perform: onHide
			))
		}
		return actions
	}
}

extension ChatPanelView {
	/// Pin to This Tab or Unpin, Open in Tab and Move to Sidebar, as the placement allows.
	fileprivate func placementActions(_ selectedID: AgentConversation.ID?) -> [ChatAction] {
		var actions: [ChatAction] = []
		if placement.kind == .pinned, let unpin = placement.unpin {
			actions.append(.init(
				group: .chats,
				title: String.localized(.appUI.chat.unpinFromTab),
				symbol: "pin.slash",
				perform: unpin
			))
		} else if let pinToTab = placement.pinToTab, let selectedID {
			actions.append(.init(
				group: .chats,
				title: String.localized(.appUI.chat.pinToTab),
				symbol: "pin",
				perform: { pinToTab(selectedID) }
			))
		}
		if let openInTab = placement.openInTab {
			actions.append(.init(
				group: .chats,
				title: String.localized(.appUI.chat.openInTab),
				symbol: "macwindow",
				perform: { openInTab(selectedID) }
			))
		}
		if let moveToSidebar = placement.moveToSidebar {
			actions.append(.init(
				group: .chats,
				title: String.localized(.appUI.chat.moveToSidebar),
				symbol: "sidebar.right",
				perform: { moveToSidebar(selectedID) }
			))
		}
		return actions
	}
}

internal enum ChatConfirmation: Equatable, Identifiable {
	case archive
	case delete

	internal var id: Self { self }

	internal var title: String {
		switch self {
		case .archive: String.localized(.appUI.chat.archiveConfirm)
		case .delete: String.localized(.appUI.chat.deleteConfirm)
		}
	}

	internal func message(provider: String) -> String {
		switch self {
		case .archive: String.localized(.appUI.chat.archiveDetail)
		case .delete: String.localized(.appUI.chat.deleteDetail(provider))
		}
	}
}

extension Optional where Wrapped == ChatConfirmation {
	internal var isChatConfirmationPresented: Bool {
		get { self != nil }
		set {
			guard !newValue
			else { return }

			self = nil
		}
	}
}

/// Provider and model choices for the shown chat.
internal struct ChatModelMenu: View {
	internal let store: StoreOf<ChatFeature>

	@Dependency(\.agentProviders)
	private var providers

	internal init(store: StoreOf<ChatFeature>) {
		self.store = store
	}

	internal var body: some View {
		if providers.providers.count > 1 {
			Section(String.localized(.appUI.chat.provider)) {
				ForEach(providers.providers, id: \.self) { provider in
					ChatMenuChoice(title: provider.title, isSelected: store.provider == provider) {
						store.send(.ui(.providerSelected(provider)))
					}
					.disabled(!store.canChangeProvider)
				}
			}
		}
		Section(String.localized(.appUI.chat.model)) {
			ChatMenuChoice(title: String.localized(.appUI.chat.modelDefault), isSelected: store.modelID == nil) {
				store.send(.ui(.modelSelected(nil)))
			}
			ForEach(store.models[store.provider] ?? []) { model in
				ChatMenuChoice(title: model.title, isSelected: store.modelID == model.id) {
					store.send(.ui(.modelSelected(model.id)))
				}
			}
		}
	}
}

/// A menu item that shows a checkmark when it's the current choice.
internal struct ChatMenuChoice: View {
	internal let title: String
	internal let isSelected: Bool
	internal let action: () -> Void

	internal init(
		title: String,
		isSelected: Bool,
		action: @escaping () -> Void
	) {
		self.title = title
		self.isSelected = isSelected
		self.action = action
	}

	internal var body: some View {
		Button(action: action) {
			if isSelected {
				Label(title, systemImage: "checkmark")
			} else {
				Text(title)
			}
		}
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}
