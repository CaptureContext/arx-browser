import AppUI
import SwiftUI

/// One entry of the ⋯ menu and chat info.
internal struct ChatAction: Identifiable {
	internal enum Group: CaseIterable {
		case thisChat
		case chats

		internal var title: String {
			switch self {
			case .thisChat: String.localized(.appUI.chat.thisChat)
			case .chats: String.localized(.appUI.chat.chats)
			}
		}
	}

	internal var id: String { title }
	internal var group: Group
	internal var title: String

	/// The label under a round button in chat info.
	internal var shortTitle: String
	internal var symbol: String
	internal var shortcut: String?
	internal var role: ButtonRole?
	internal var isEnabled: Bool
	internal var perform: () -> Void

	internal init(
		group: Group,
		title: String,
		shortTitle: String? = nil,
		symbol: String,
		shortcut: String? = nil,
		role: ButtonRole? = nil,
		isEnabled: Bool = true,
		perform: @escaping () -> Void
	) {
		self.group = group
		self.title = title
		self.shortTitle = shortTitle ?? title
		self.symbol = symbol
		self.shortcut = shortcut
		self.role = role
		self.isEnabled = isEnabled
		self.perform = perform
	}
}

/// The ⋯ menu: a searchable list of actions in two groups. Arrows move the highlight,
/// Return runs it and Escape closes the menu.
internal struct ChatActionsMenu: View {
	internal let actions: [ChatAction]
	internal let dismiss: () -> Void

	@SwiftUI.State
	private var query: String

	@SwiftUI.State
	private var highlighted: String?

	@FocusState
	private var isSearchFocused: Bool

	internal init(
		actions: [ChatAction],
		dismiss: @escaping () -> Void
	) {
		self.actions = actions
		self.dismiss = dismiss
		self._query = .init(initialValue: "")
		self._highlighted = .init(initialValue: nil)
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			TextField(String.localized(.appUI.chat.searchActions), text: $query)
				.textFieldStyle(.plain)
				.font(.system(size: 14))
				.padding(.horizontal, 14)
				.padding(.vertical, 12)
				.focused($isSearchFocused)
				.onSubmit(runHighlighted)
				.onKeyPress(.downArrow) { move(by: 1) }
				.onKeyPress(.upArrow) { move(by: -1) }
			Divider()
			ScrollView {
				VStack(alignment: .leading, spacing: 2) {
					ForEach(ChatAction.Group.allCases, id: \.self) { group in
						let items = visible.filter { $0.group == group }
						if !items.isEmpty {
							Text(group.title)
								.font(.system(size: 11, weight: .semibold))
								.foregroundStyle(.secondary)
								.padding(.horizontal, 10)
								.padding(.top, 8)
								.padding(.bottom, 2)
							ForEach(items) { action in row(action) }
						}
					}
				}
				.padding(6)
			}
			.frame(maxHeight: 360)
		}
		.frame(width: 280)
		.onAppear {
			highlighted = visible.first?.id
			isSearchFocused = true
		}
		.onChange(of: query) { highlighted = visible.first?.id }
	}

	private var visible: [ChatAction] {
		let text: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
		return actions.filter { action in
			action.isEnabled && (text.isEmpty || action.title.localizedCaseInsensitiveContains(text))
		}
	}

	private func row(_ action: ChatAction) -> some View {
		Button { run(action) } label: {
			HStack(spacing: 10) {
				Image(systemName: action.symbol)
					.frame(width: 18)
				Text(action.title)
				Spacer(minLength: 8)
				if let shortcut = action.shortcut {
					Text(shortcut)
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(.secondary)
						.padding(.horizontal, 5)
						.padding(.vertical, 2)
						.background(BrowserTheme.fill, in: ArxControlShape())
				}
			}
			.font(.system(size: 13))
			.foregroundStyle(action.role == .destructive ? Color.red : BrowserTheme.text)
			.padding(.horizontal, 10)
			.padding(.vertical, 7)
			.background(
				highlighted == action.id ? BrowserTheme.hover : .clear,
				in: .rect(cornerRadius: 6, style: .continuous)
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.onHover { if $0 { highlighted = action.id } }
		.accessibilityAddTraits(highlighted == action.id ? .isSelected : [])
	}

	private func move(by step: Int) -> KeyPress.Result {
		let items: [ChatAction] = ChatAction.Group.allCases.flatMap { group in visible.filter { $0.group == group } }
		guard !items.isEmpty
		else { return .ignored }

		let index: Int = items.firstIndex { $0.id == highlighted } ?? -1
		highlighted = items[(index + step + items.count) % items.count].id
		return .handled
	}

	private func runHighlighted() {
		guard let action = visible.first(where: { $0.id == highlighted }) ?? visible.first
		else { return }

		run(action)
	}

	private func run(_ action: ChatAction) {
		dismiss()
		action.perform()
	}
}
