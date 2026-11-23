import AgentClient
import AppUI
import SwiftUI
import _ComposableArchitecture

// Pieces the panel is built from that carry behavior: focus, ⌘↩, the model menu, the ⋯ menu,
// the notes a chat can show and the chat list's filters and sections.

/// What ``ChatStudioPanel`` needs besides the store: the window's attachables and the panel's
/// actions, built once by ``ChatPanelView``.
internal struct ChatPanelContext {
	internal var attachables: [ChatAttachable]
	internal var actions: [ChatAction]
	internal var placement: ChatPlacement
	internal var onHide: () -> Void

	internal init(
		attachables: [ChatAttachable],
		actions: [ChatAction],
		placement: ChatPlacement = .panel,
		onHide: @escaping () -> Void
	) {
		self.attachables = attachables
		self.actions = actions
		self.placement = placement
		self.onHide = onHide
	}

	/// The tab the window shows, which a new chat's suggestions are about.
	internal var currentTab: AgentContextAttachment.Tab? {
		attachables.first { $0.id == ChatAttachable.currentID }?.tabs.first
	}

	/// A new chat's suggestions about ``currentTab``.
	internal var suggestions: [ChatSuggestion] {
		currentTab.map(ChatSuggestion.suggestions(for:)) ?? []
	}
}

extension ChatFeature.State {
	/// The chat's model by name, or its provider's when it uses the default.
	internal var modelTitle: String {
		guard
			let modelID,
			let model = models[provider]?.first(where: { $0.id == modelID })
		else { return provider.title }

		return model.title
	}

	/// Whether the shown chat is still new: nothing asked yet. A chat with a failure is never
	/// new, so its failure always shows (DEV-643).
	internal var isNewChat: Bool {
		(selected?.messages.isEmpty ?? true) && failure == nil
	}
}

// MARK: - Transcript

/// A scrolling transcript that follows new text to the bottom, with the chat's notes after it.
/// The panel's header pins over it as a bar, which the transcript scrolls under into Arx's
/// progressive edge, with no line (DEV-807, DEV-826). The composer floats over its bottom, and
/// the transcript scrolls and overscrolls under it, visible through its material (DEV-826).
internal struct ChatScrollingTranscript<Header: View, Content: View, Composer: View>: View {
	internal let store: StoreOf<ChatFeature>
	internal let spacing: CGFloat
	internal let padding: EdgeInsets
	internal let header: Header
	internal let content: Content
	internal let composer: Composer

	internal init(
		store: StoreOf<ChatFeature>,
		spacing: CGFloat,
		padding: EdgeInsets = .init(
			top: 0,
			leading: ChatMetrics.padding,
			bottom: ChatMetrics.padding,
			trailing: ChatMetrics.padding
		),
		@ViewBuilder header: () -> Header,
		@ViewBuilder content: () -> Content,
		@ViewBuilder composer: () -> Composer
	) {
		self.store = store
		self.spacing = spacing
		self.padding = padding
		self.header = header()
		self.content = content()
		self.composer = composer()
	}

	internal var body: some View {
		ScrollViewReader { reader in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: spacing) {
					content
					ChatNotes(store: store)
						.id(ChatScrollAnchor.bottom)
				}
				.padding(padding)

				// A readable width in a wide chat tab, centered (DEV-798).
				.frame(maxWidth: ChatMetrics.transcriptMaxWidth + padding.leading + padding.trailing)
				.frame(maxWidth: .infinity)
			}
			.defaultScrollAnchor(.bottom)

			// Over the panel's own tint and grain, so the bar brings no background.
			.arxScrollBar(background: nil) { header } footer: { composer }
			.onChange(of: store.selected?.messages.last?.text) {
				reader.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
			}
		}
	}
}

private enum ChatScrollAnchor: Hashable {
	case bottom
}

/// A failure, a usage warning, the browser tools note and a temporary chat's note.
internal struct ChatNotes: View {
	internal let store: StoreOf<ChatFeature>

	internal init(store: StoreOf<ChatFeature>) {
		self.store = store
	}

	internal var body: some View {
		if let failure = store.failure {
			ChatFailureView(
				failure: failure,
				provider: store.provider,
				account: store.accounts[store.provider],
				retry: { store.send(.ui(.retryTapped)) },
				dismiss: { store.send(.ui(.dismissFailureTapped)) }
			)
		}
		if let warning = store.turn?.usageWarning {
			ChatNote(symbol: "gauge.with.dots.needle.67percent") {
				Text(localized: .appUI.chat.usageWarning(store.provider.title))
				if let resetsAt = warning.resetsAt {
					Text(localized: .appUI.chat.failureUsageLimitResets(resetsAt.formatted(.relative(presentation: .named))))
				}
			}
		}
		if store.browserAccess == .notGranted {
			ChatNote(symbol: "hand.raised") {
				Text(localized: .appUI.chat.browserTools).fontWeight(.medium)
				Text(localized: .appUI.chat.browserToolsDetail).foregroundStyle(.secondary)
				Button(String.localized(.appUI.chat.browserToolsAllow)) {
					store.send(.ui(.allowBrowserToolsTapped))
				}
				.controlSize(.small)
			}
		}
		if let conversation = store.selected, !conversation.isKept, !conversation.messages.isEmpty {
			Text(localized: .appUI.chat.ephemeralNote)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity)
				.multilineTextAlignment(.center)
		}
	}
}

// MARK: - Composer

/// The composer's text field: the draft, focus on request, and ⌘↩ to send.
internal struct ChatComposerField: View {
	@Bindable
	internal var store: StoreOf<ChatFeature>

	internal let placeholder: String
	internal let font: Font
	internal let lineLimit: ClosedRange<Int>
	internal var isFocused: FocusState<Bool>.Binding

	internal init(
		store: StoreOf<ChatFeature>,
		placeholder: String,
		font: Font = .system(size: 13),
		lineLimit: ClosedRange<Int> = 1...6,
		isFocused: FocusState<Bool>.Binding
	) {
		self.store = store
		self.placeholder = placeholder
		self.font = font
		self.lineLimit = lineLimit
		self.isFocused = isFocused
	}

	internal var body: some View {
		TextField(placeholder, text: $store.draft.sending(\.ui.draftChanged), axis: .vertical)
			.textFieldStyle(.plain)
			.font(font)
			.lineLimit(lineLimit)
			.focused(isFocused)

			// Only while the composer has focus, so ⌘↩ on a page stays the page's.
			.onKeyPress(.return, phases: .down) { press in
				guard press.modifiers.contains(.command)
				else { return .ignored }

				store.send(.ui(.sendTapped))
				return .handled
			}
			.onChange(of: store.focusRequest, initial: true) {
				isFocused.wrappedValue = true
			}
	}
}

/// The provider and model menu around any label.
internal struct ChatModelPicker<Label: View>: View {
	internal let store: StoreOf<ChatFeature>
	internal let label: Label

	internal init(
		store: StoreOf<ChatFeature>,
		@ViewBuilder label: () -> Label
	) {
		self.store = store
		self.label = label()
	}

	internal var body: some View {
		Menu {
			ChatModelMenu(store: store)
		} label: {
			label
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
		.help(String.localized(.appUI.chat.model))
	}
}

/// The ⋯ menu's searchable actions in a popover, around any label.
internal struct ChatActionsButton<Label: View>: View {
	internal let actions: [ChatAction]
	internal let label: Label
	internal var isPresented: Binding<Bool>

	internal init(
		actions: [ChatAction],
		isPresented: Binding<Bool>,
		@ViewBuilder label: () -> Label
	) {
		self.actions = actions
		self.isPresented = isPresented
		self.label = label()
	}

	internal var body: some View {
		// No style of its own: the caller's (the header's raised item) applies, so ⋯ gets the same
		// tile and hit area as the buttons beside it.
		Button { isPresented.wrappedValue = true } label: { label }
			.help(String.localized(.appUI.chat.more))
			.accessibilityLabel(String.localized(.appUI.chat.more))
			.popover(isPresented: isPresented, arrowEdge: .bottom) {
				ChatActionsMenu(actions: actions) { isPresented.wrappedValue = false }
			}
	}
}

// MARK: - Chat list

/// Your Chats' three views of the same list, picked from the list's header.
internal enum ChatListFilter: CaseIterable, Hashable {
	case all
	case unread
	case archived

	internal init(_ state: ChatFeature.State) {
		if state.showsArchived {
			self = .archived
		} else if state.showsUnreadOnly {
			self = .unread
		} else {
			self = .all
		}
	}

	internal var title: String {
		switch self {
		case .all: String.localized(.appUI.chat.filterAll)
		case .unread: String.localized(.appUI.chat.filterUnread)
		case .archived: String.localized(.appUI.chat.filterArchived)
		}
	}

	/// The toggles that move the list from `current` to this filter.
	internal func actions(from current: Self) -> [ChatFeature.Action.UI] {
		var actions: [ChatFeature.Action.UI] = []
		if (current == .unread) != (self == .unread) {
			actions.append(.unreadOnlyToggled)
		}
		if (current == .archived) != (self == .archived) {
			actions.append(.archivedToggled)
		}
		return actions
	}
}

/// Your Chats' text when nothing matches.
internal struct ChatListEmpty: View {
	internal let showsArchived: Bool

	internal init(showsArchived: Bool) {
		self.showsArchived = showsArchived
	}

	internal var body: some View {
		VStack(spacing: 6) {
			Text(localized: showsArchived ? .appUI.chat.noArchived : .appUI.chat.noChats)
				.font(.system(size: 13, weight: .semibold))
			if !showsArchived {
				Text(localized: .appUI.chat.noChatsDetail)
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
			}
		}
		.multilineTextAlignment(.center)
		.frame(maxWidth: .infinity)
		.padding(.top, 40)
		.padding(.horizontal, ChatMetrics.padding)
	}
}

/// Chats by how long ago they were last updated, as a document library lists them: today, the
/// past week, the past month, then each month by name, with the year when it isn't this one.
internal struct ChatTimelineSection: Identifiable, Equatable {
	internal enum Period: Hashable {
		case today
		case week
		case month
		case calendarMonth(year: Int, month: Int)
	}

	internal var period: Period
	internal var title: String
	internal var conversations: [AgentConversation]

	internal var id: Period { period }

	/// Sections newest first, each newest first, leaving out empty ones.
	internal static func sections(
		_ conversations: [AgentConversation],
		now: Date,
		calendar: Calendar = .current
	) -> [Self] {
		let startOfToday: Date = calendar.startOfDay(for: now)
		let startOfWeek: Date = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
		let startOfMonth: Date = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
		let currentYear: Int = calendar.component(.year, from: now)
		var sections: [Self] = []
		for conversation in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
			let date: Date = conversation.updatedAt
			let period: Period
			if date >= startOfToday {
				period = .today
			} else if date >= startOfWeek {
				period = .week
			} else if date >= startOfMonth {
				period = .month
			} else {
				let components = calendar.dateComponents([.year, .month], from: date)
				period = .calendarMonth(year: components.year ?? currentYear, month: components.month ?? 1)
			}
			if sections.last?.period == period {
				sections[sections.count - 1].conversations.append(conversation)
			} else {
				sections.append(.init(
					period: period,
					title: title(period, date: date, currentYear: currentYear, calendar: calendar),
					conversations: [conversation]
				))
			}
		}
		return sections
	}

	private static func title(
		_ period: Period,
		date: Date,
		currentYear: Int,
		calendar: Calendar
	) -> String {
		switch period {
		case .today:
			return String.localized(.appUI.chat.recentsToday)

		case .week:
			return String.localized(.appUI.chat.recentsWeek)

		case .month:
			return String.localized(.appUI.chat.recentsMonth)

		case let .calendarMonth(year, _):
			var style: Date.FormatStyle = .dateTime.month(.wide)
			style.calendar = calendar
			style.timeZone = calendar.timeZone
			if year != currentYear {
				style = style.year()
			}
			return date.formatted(style)
		}
	}
}

extension ChatAttachable {
	/// Where the + picker lists it.
	internal enum Kind: CaseIterable, Hashable {
		case current
		case folder
		case tab
	}

	internal var kind: Kind {
		if id == Self.currentID { return .current }
		if symbol == "folder" { return .folder }
		return .tab
	}
}
