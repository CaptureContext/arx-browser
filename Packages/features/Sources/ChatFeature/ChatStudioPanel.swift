import AgentClient
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The chat panel's body: a tactile, quiet panel ("Studio"). Every button is a raised tile
/// (AppUI's `ArxRaisedButtonStyle`) and related ones share a tile. The header is a list button,
/// a centered title tile with the model under it, and the chat's actions. A new chat's body stays
/// empty down to suggestions by the composer, a raised card with the model in a grouped tile.
/// Your Chats lists chats by month, each with its latest answer and time.
internal struct ChatStudioPanel: View {
	@Bindable
	internal var store: StoreOf<ChatFeature>

	internal let context: ChatPanelContext

	@SwiftUI.State
	private var isActionsPresented: Bool

	@SwiftUI.State
	private var isDropTargeted: Bool = false

	internal init(
		store: StoreOf<ChatFeature>,
		context: ChatPanelContext
	) {
		self.store = store
		self.context = context
		self._isActionsPresented = .init(initialValue: false)
	}

	internal var body: some View {
		VStack(spacing: 0) {
			if store.screen == .chats {
				ChatStudioList(store: store, context: context)
			} else {
				if store.isNewChat {
					header
					ChatStudioEmpty(store: store, context: context)
					composer
				} else {
					ChatScrollingTranscript(
						store: store,
						spacing: 14,
						padding: .init(top: 4, leading: 14, bottom: 14, trailing: 14)
					) {
						header
					} content: {
						if let conversation = store.selected {
							ForEach(conversation.messages) { message in
								ChatStudioMessage(
									message: message,
									turn: store.turn?.replyID == message.id ? store.turn : nil,
									profileID: store.id
								)
								.id(message.id)
							}
						}
					} composer: {
						composer
					}
				}
			}
		}
		.controlSize(.large)
		.chatFileDrop(isTargeted: $isDropTargeted, store: store)
	}

	private var composer: some View {
		ChatStudioComposer(
			store: store,
			attachables: context.attachables,
			capture: context.placement.capture,
			isDropTargeted: isDropTargeted
		)
	}

	private var header: some View {
		HStack(spacing: 8) {
			Button { store.send(.ui(.historyTapped)) } label: {
				Image(systemName: "line.3.horizontal")
			}
			.buttonStyle(.arxRaised(.square))
			.focusEffectDisabled()
			.help(String.localized(.appUI.chat.history))
			.accessibilityLabel(String.localized(.appUI.chat.history))
			Spacer(minLength: 0)
			if context.placement.kind == .pinned, let unpin = context.placement.unpin {
				// Shows the chat is pinned to this tab; clicking it unpins.
				Button(action: unpin) {
					Image(systemName: "pin.fill")
						.fontWeight(.medium)
				}
				.buttonStyle(.arxRaised(.square))
				.focusEffectDisabled()
				.help(String.localized(.appUI.chat.unpinFromTab))
				.accessibilityLabel(String.localized(.appUI.chat.pinnedToTab))
				.accessibilityHint(String.localized(.appUI.chat.unpinFromTab))
			}
			ArxRaisedGroup {
				// Equal square hit areas with the same glyph weight, so ⋯ and × read as a pair.
				ChatActionsButton(actions: context.actions, isPresented: $isActionsPresented) {
					Image(systemName: "ellipsis")
						.fontWeight(.medium)
				}
				.buttonStyle(.arxRaised(.item, isSquare: true))

				// A chat tab closes like any tab, so it has no ×.
				if context.placement.kind != .tab {
					Button(action: context.onHide) {
						Image(systemName: "xmark")
							.fontWeight(.medium)
					}
					.buttonStyle(.arxRaised(.item, isSquare: true))
					.help(String.localized(.appUI.chat.hide))
					.accessibilityLabel(String.localized(.appUI.chat.hide))
				}
			}
		}
		.overlay {
			// The title tile, centered whatever the sides hold.
			Button { store.send(.ui(.infoTapped)) } label: {
				VStack(spacing: 0) {
					Text(store.selected?.title ?? String.localized(.appUI.chat.newChat))
						.font(.system(size: 12.5, weight: .semibold))
						.lineLimit(1)
					if store.selected != nil {
						HStack(spacing: 3) {
							ChatProviderMark(store.provider)
							Text(store.modelTitle)
						}
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
					}
				}
				.padding(.horizontal, 6)
				.frame(maxWidth: 180)
				.fixedSize(horizontal: true, vertical: false)
			}
			.buttonStyle(.arxRaised)
			.allowsHitTesting(store.selected != nil)
		}
		.foregroundStyle(BrowserTheme.text)
		.padding(.horizontal, 12)
		.padding(.top, 12)
		.padding(.bottom, 8)
	}
}

// MARK: - Transcript

/// A message: the person's on a raised card at the trailing side, an answer as plain text with
/// the browser's work in a pale chip above it.
internal struct ChatStudioMessage: View {
	internal let message: AgentMessage
	internal let turn: ChatTurn?
	internal let profileID: Profile.ID?

	@SwiftUI.State
	private var isHovered: Bool = false

	internal init(
		message: AgentMessage,
		turn: ChatTurn?,
		profileID: Profile.ID? = nil
	) {
		self.message = message
		self.turn = turn
		self.profileID = profileID
	}

	internal var body: some View {
		switch message.role {
		case .user:
			VStack(alignment: .trailing, spacing: 6) {
				Text(message.text)
					.font(.system(size: 13))
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.horizontal, 12)
					.padding(.vertical, 9)
					.background { ArxRaisedTile(cornerRadius: 14) }
				if !message.attachments.isEmpty {
					ChatAttachmentChips(attachments: message.attachments, profileID: profileID)
						.fixedSize(horizontal: true, vertical: false)
				}
			}
			.frame(maxWidth: .infinity, alignment: .trailing)
			.padding(.leading, 36)
			.padding(.top, 6)
			.foregroundStyle(BrowserTheme.text)

		case .assistant:
			VStack(alignment: .leading, spacing: 8) {
				if !message.tools.isEmpty {
					ChatStudioTools(tools: message.tools, turn: turn)
				}
				if !message.text.isEmpty {
					ChatMarkdownView(markdown: message.text, size: 13.5, isStreaming: turn != nil)
				}
				if let turn {
					ChatProgress(turn: turn)
				} else if !message.text.isEmpty {
					copyButton
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 2)
			.foregroundStyle(BrowserTheme.text)
			.onHover { isHovered = $0 }
			.accessibilityAction(named: String.localized(.appUI.chat.copyMessage)) {
				ChatPasteboard.copy(message.text)
			}
		}
	}
}

extension ChatStudioMessage {
	/// Copies the answer as it was written, Markdown and all; selecting its text copies what's
	/// drawn. It shows while the pointer is over the answer.
	private var copyButton: some View {
		Button {
			ChatPasteboard.copy(message.text)
		} label: {
			Image(systemName: "doc.on.doc")
				.font(.system(size: 11, weight: .medium))
				.frame(width: 14, height: 14)
		}
		.buttonStyle(.arx(.plain, size: .small))
		.help(String.localized(.appUI.chat.copyMessage))
		.opacity(isHovered ? 1 : 0)
		.accessibilityHidden(true)
	}
}

/// The browser tools a reply used: a pale accent chip naming what the browser did, or what's
/// running now.
internal struct ChatStudioTools: View {
	internal let tools: [AgentToolActivity]
	internal let turn: ChatTurn?

	internal init(
		tools: [AgentToolActivity],
		turn: ChatTurn?
	) {
		self.tools = tools
		self.turn = turn
	}

	internal var body: some View {
		HStack(spacing: 6) {
			if isRunning {
				ProgressView().controlSize(.mini)
			} else {
				Image(systemName: hasFailed ? "exclamationmark.circle" : "globe")
					.font(.system(size: 11))
			}
			Text(summary)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
		}
		.font(.system(size: 11.5, weight: .medium))
		.foregroundStyle(hasFailed ? Color.orange : Color.accentColor)
		.padding(.horizontal, 9)
		.padding(.vertical, 5)
		.background(
			(hasFailed ? Color.orange : Color.accentColor).opacity(0.1),
			in: .rect(cornerRadius: 8, style: .continuous)
		)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(tools.map { ChatToolStatus($0, turn: turn).title($0) }.formatted(.list(type: .and)))
	}

	private var isRunning: Bool {
		tools.contains { ChatToolStatus($0, turn: turn) == .running }
	}

	private var hasFailed: Bool {
		!isRunning && tools.contains { ChatToolStatus($0, turn: turn) == .failed }
	}

	/// "Used page snapshot, find text", or what's running now.
	private var summary: String {
		if let running = tools.last(where: { ChatToolStatus($0, turn: turn) == .running }) {
			return ChatToolStatus.running.title(running)
		}
		var names: [String] = []
		for tool in tools {
			let name: String = ChatToolName.readable(tool.name)
			if !names.contains(name) {
				names.append(name)
			}
		}
		return String.localized(.appUI.chat.toolDone(names.formatted(.list(type: .and))))
	}
}

// MARK: - Empty state

/// A new chat: an empty body down to suggestions by the composer, the first one in the accent,
/// then the latest chats.
private struct ChatStudioEmpty: View {
	internal let store: StoreOf<ChatFeature>
	internal let context: ChatPanelContext

	/// A symbol for each of a tab's three suggestions: summarize, takeaways, explain.
	private static let symbols: [String] = [
		"text.alignleft", "list.bullet", "lightbulb",
	]

	internal var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Spacer(minLength: 0)
			let suggestions = context.suggestions
			if !suggestions.isEmpty {
				sectionTitle(.appUI.chat.suggestions)
				ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
					ChatStudioRow(
						symbol: Self.symbols[index % Self.symbols.count],
						title: suggestion.prompt,
						isProminent: index == 0
					) {
						store.send(.ui(.suggestionTapped(suggestion)))
					}
				}
			}
			let recents = store.conversations
				.filter { $0.archivedAt == nil && !$0.messages.isEmpty }
				.sorted { $0.updatedAt > $1.updatedAt }
				.prefix(3)
			if !recents.isEmpty {
				sectionTitle(.appUI.chat.recentChats)
					.padding(.top, suggestions.isEmpty ? 0 : 10)
				ForEach(Array(recents)) { conversation in
					ChatStudioRow(symbol: "bubble.left", title: conversation.title, isProminent: false) {
						store.send(.ui(.chatSelected(conversation.id)))
					}
				}
			}
		}
		.disabled(store.isRunning)
		.foregroundStyle(BrowserTheme.text)
		.padding(.horizontal, 20)
		.padding(.bottom, 6)
		.frame(maxWidth: ChatMetrics.composerMaxWidth + 16, maxHeight: .infinity, alignment: .bottomLeading)
		.frame(maxWidth: .infinity)
	}

	private func sectionTitle(_ title: _XCStringResource) -> some View {
		Text(localized: title)
			.font(.system(size: 13, weight: .semibold))
			.padding(.bottom, 2)
	}
}

/// A suggestion or a recent chat: a thin icon and a label, in the accent with a › when prominent.
private struct ChatStudioRow: View {
	internal let symbol: String
	internal let title: String
	internal let isProminent: Bool
	internal let action: () -> Void

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(systemName: symbol)
					.font(.system(size: 13, weight: .light))
					.frame(width: 18)
					.foregroundStyle(isProminent ? Color.accentColor : .secondary)
				Text(title)
					.font(.system(size: 13))
					.lineLimit(1)
					.foregroundStyle(isProminent ? Color.accentColor : BrowserTheme.text)
				Spacer(minLength: 8)

				// Every row's chevron, in one column at the trailing edge (DEV-798).
				Image(systemName: "chevron.right")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(chevronStyle)
					.frame(width: 12, alignment: .trailing)
					.accessibilityHidden(true)
			}
			.padding(.vertical, 5)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.onHover { isHovered = $0 }
	}

	private var chevronStyle: Color {
		if isProminent { return Color.accentColor.opacity(0.6) }
		return isHovered ? BrowserTheme.text : Color.secondary.opacity(0.6)
	}
}

// MARK: - Composer

/// A raised card: the text, then + and the model in a grouped tile, and send.
private struct ChatStudioComposer: View {
	@Bindable
	internal var store: StoreOf<ChatFeature>

	internal let attachables: [ChatAttachable]
	internal let capture: (@MainActor (_ area: Bool) -> Void)?
	internal let isDropTargeted: Bool

	@SwiftUI.State
	private var isAttachPresented: Bool = false

	internal var body: some View {
		VStack(spacing: 6) {
			VStack(alignment: .leading, spacing: 10) {
				if !store.attachments.isEmpty {
					ChatAttachmentChips(attachments: store.attachments, profileID: store.id) { index in
						store.send(.ui(.detached(index)))
					}
				}
				if let issue = store.attachmentIssue {
					ChatAttachmentIssueView(issue: issue) {
						store.send(.ui(.attachmentIssueDismissed))
					}
				}
				ChatComposerInput(
					store: store,
					placeholder: String.localized(
						store.selected == nil ? .appUI.chat.composerNew : .appUI.chat.composerFollowUp
					)
				)
				.frame(minHeight: 34, alignment: .topLeading)
				.padding(.horizontal, 4)
				HStack(spacing: 6) {
					Button { isAttachPresented = true } label: {
						Image(systemName: "plus")
					}
					.buttonStyle(.arxRaised(size: .regular))
					.help(String.localized(.appUI.chat.attach))
					.accessibilityLabel(String.localized(.appUI.chat.attach))
					.popover(isPresented: $isAttachPresented, arrowEdge: .top) {
						ChatStudioAttachMenu(
							attachables: attachables,
							profileID: store.id,
							sources: ChatAttachSource.available(canCapture: capture != nil)
						) { attachable in
							isAttachPresented = false
							store.send(.ui(.attached(attachable.attachment)))
						} pick: { source in
							isAttachPresented = false
							switch source {
							case .files:
								ChatFilePicker.present { store.send(.ui(.filesAdded($0))) }

							case .captureVisible:
								capture?(false)

							case .captureArea:
								capture?(true)
							}
						}
					}
					ArxRaisedGroup {
						ChatModelPicker(store: store) {
							HStack(spacing: 5) {
								ChatProviderMark(store.provider)
									.frame(width: 18, height: 18)
									.background(BrowserTheme.fill, in: .rect(cornerRadius: 5, style: .continuous))
								Text(store.modelTitle).font(.system(size: 12))
								Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
							}
						}
						.buttonStyle(.arxRaised(.item))
					}
					.controlSize(.regular)
					Spacer(minLength: 4)
					sendButton
				}
			}
			.padding(10)

			// See-through, so a transcript scrolled under it stays visible (DEV-826).
			.background { ArxRaisedTile(cornerRadius: 16, isTranslucent: true) }
			.overlay {
				if isDropTargeted {
					RoundedRectangle(cornerRadius: 16, style: .continuous)
						.strokeBorder(Color.accentColor, lineWidth: 2)
				}
			}

			if store.selected == nil {
				Text(localized: .appUI.chat.planNote(store.provider.title))
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
			}
		}

		// A readable width in a wide chat tab, centered (DEV-798).
		.frame(maxWidth: ChatMetrics.composerMaxWidth)
		.frame(maxWidth: .infinity)
		.padding(.horizontal, 12)
		.padding(.bottom, 12)
		.padding(.top, 4)
	}

	@ViewBuilder
	private var sendButton: some View {
		if store.isRunning {
			Button { store.send(.ui(.stopTapped)) } label: {
				Image(systemName: "stop.circle.fill")
					.font(.system(size: 17))
			}
			.buttonStyle(.arxRaised(size: .regular))
			.help(String.localized(.appUI.chat.stop))
			.accessibilityLabel(String.localized(.appUI.chat.stop))
		} else {
			Button { store.send(.ui(.sendTapped)) } label: {
				Image(systemName: "arrow.up.circle.fill")
					.font(.system(size: 17))
					.foregroundStyle(store.canSend ? BrowserTheme.text : Color.secondary)
			}
			.buttonStyle(.arxRaised(size: .regular))
			.disabled(!store.canSend)
			.help(String.localized(.appUI.chat.sendHelp))
			.accessibilityLabel(String.localized(.appUI.chat.send))
		}
	}
}

/// The + menu: search first, then This Tab, Folders and Tabs under small headings.
private struct ChatStudioAttachMenu: View {
	internal let attachables: [ChatAttachable]
	internal let profileID: Profile.ID
	internal let sources: [ChatAttachSource]
	internal let choose: (ChatAttachable) -> Void
	internal let pick: (ChatAttachSource) -> Void

	@SwiftUI.State
	private var query: String = ""

	@SwiftUI.State
	private var highlighted: String?

	@FocusState
	private var isSearchFocused: Bool

	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.foregroundStyle(.secondary)
				TextField(String.localized(.appUI.chat.attachSearch), text: $query)
					.textFieldStyle(.plain)
					.focused($isSearchFocused)
					.onSubmit(chooseHighlighted)
					.onKeyPress(.downArrow) { move(by: 1) }
					.onKeyPress(.upArrow) { move(by: -1) }
			}
			.font(.system(size: 13.5))
			.padding(.horizontal, 14)
			.padding(.vertical, 12)
			Divider()
			ScrollView {
				VStack(alignment: .leading, spacing: 1) {
					if query.isEmpty, !sources.isEmpty {
						ForEach(sources, id: \.self) { source in sourceRow(source) }
						Divider().padding(.vertical, 4)
					}
					if visible.isEmpty {
						Text(localized: .appUI.chat.attachNothing)
							.foregroundStyle(.secondary)
							.padding(10)
					}
					ForEach(ChatAttachable.Kind.allCases, id: \.self) { kind in
						let items = visible.filter { $0.kind == kind }
						if !items.isEmpty {
							Text(localized: title(kind))
								.font(.system(size: 10.5, weight: .semibold))
								.textCase(.uppercase)
								.tracking(0.5)
								.foregroundStyle(.secondary)
								.padding(.horizontal, 10)
								.padding(.top, 10)
								.padding(.bottom, 3)
							ForEach(items) { attachable in row(attachable) }
						}
					}
				}
				.padding(6)
			}
			.frame(maxHeight: 320)
		}
		.frame(width: 290)
		.onAppear {
			highlighted = ordered.first?.id
			isSearchFocused = true
		}
		.onChange(of: query) { highlighted = ordered.first?.id }
	}

	private func title(_ kind: ChatAttachable.Kind) -> _XCStringResource {
		switch kind {
		case .current: .appUI.chat.attachSectionCurrent
		case .folder: .appUI.chat.attachSectionFolders
		case .tab: .appUI.chat.attachSectionTabs
		}
	}

	private var visible: [ChatAttachable] {
		let text: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty
		else { return attachables }

		return attachables.filter { attachable in
			attachable.title.localizedCaseInsensitiveContains(text)
			|| attachable.tabs.contains { $0.url.localizedCaseInsensitiveContains(text) }
		}
	}

	/// The visible items in the order the sections show them.
	private var ordered: [ChatAttachable] {
		ChatAttachable.Kind.allCases.flatMap { kind in visible.filter { $0.kind == kind } }
	}

	/// Files…, Capture Visible Area and Capture Area…, above the tabs.
	private func sourceRow(_ source: ChatAttachSource) -> some View {
		Button { pick(source) } label: {
			HStack(spacing: 10) {
				Image(systemName: source.symbol)
					.font(.system(size: 13, weight: .light))
					.frame(width: 18)
				Text(source.title).lineLimit(1)
				Spacer(minLength: 8)
			}
			.font(.system(size: 13))
			.padding(.horizontal, 10)
			.frame(height: 32)
			.contentShape(.rect)
		}
		.buttonStyle(ChatMenuRowStyle())
		.foregroundStyle(BrowserTheme.text)
	}

	@ViewBuilder
	private func icon(_ attachable: ChatAttachable) -> some View {
		if attachable.kind == .folder {
			Image(systemName: attachable.symbol)
				.font(.system(size: 13, weight: .light))
		} else {
			// A tab's favicon, not a generic globe (DEV-798).
			BrowserSiteIcon(
				key: attachable.tabs.first.flatMap { tab in
					URL(string: tab.url).map { .init(profileID: profileID.rawValue, pageURL: $0) }
				},
				size: 15,
				fallback: attachable.symbol
			)
		}
	}

	private func row(_ attachable: ChatAttachable) -> some View {
		Button { choose(attachable) } label: {
			HStack(spacing: 10) {
				icon(attachable)
					.frame(width: 18)
				Text(attachable.title).lineLimit(1)
				Spacer(minLength: 8)
				if attachable.kind == .folder {
					Text(tabCount(attachable.tabs.count))
						.foregroundStyle(.secondary)
				}
			}
			.font(.system(size: 13))
			.padding(.horizontal, 10)
			.frame(height: 32)
			.background(
				highlighted == attachable.id ? BrowserTheme.hover : .clear,
				in: .rect(cornerRadius: 8, style: .continuous)
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.foregroundStyle(BrowserTheme.text)
		.onHover { if $0 { highlighted = attachable.id } }
		.accessibilityAddTraits(highlighted == attachable.id ? .isSelected : [])
	}

	private func tabCount(_ count: Int) -> String {
		String.localized(.appUI.chat.attachTabCount(count))
	}

	private func move(by step: Int) -> KeyPress.Result {
		let items: [ChatAttachable] = ordered
		guard !items.isEmpty
		else { return .ignored }

		let index: Int = items.firstIndex { $0.id == highlighted } ?? -1
		highlighted = items[(index + step + items.count) % items.count].id
		return .handled
	}

	private func chooseHighlighted() {
		guard let attachable = ordered.first(where: { $0.id == highlighted }) ?? ordered.first
		else { return }

		choose(attachable)
	}
}

// MARK: - Your Chats

/// Your Chats by month: each chat's title over its latest answer, and its time on the right,
/// with hairlines only between chats of the same month.
private struct ChatStudioList: View {
	@Bindable
	internal var store: StoreOf<ChatFeature>

	internal let context: ChatPanelContext

	internal var body: some View {
		ScrollView {
			list
		}

		// The chats scroll under the title row and search into Arx's progressive edge, with no
		// line (DEV-807, DEV-826).
		.arxScrollBar(background: nil) { bar }
		.foregroundStyle(BrowserTheme.text)
	}

	private var bar: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 8) {
				Button { store.send(.ui(.backTapped)) } label: {
					Image(systemName: "chevron.left")
				}
				.buttonStyle(.arxRaised(.square))
				.focusEffectDisabled()
				.help(String.localized(.appUI.chat.back))
				.accessibilityLabel(String.localized(.appUI.chat.back))
				Button { store.send(.ui(.newChatTapped)) } label: {
					Image(systemName: "plus")
						.fontWeight(.medium)
				}
				.buttonStyle(.arxRaised(.square))
				.focusEffectDisabled()
				.help(String.localized(.appUI.chat.newChat))
				.accessibilityLabel(String.localized(.appUI.chat.newChat))
				Text(localized: store.showsArchived ? .appUI.chat.archivedChats : .appUI.chat.chats)
					.font(.system(size: 15, weight: .bold))
					.padding(.leading, 2)
				Spacer(minLength: 0)

				// A switcher, each segment's title in a tooltip under it (DEV-797).
				ArxSegmentedControl(
					ChatListFilter.allCases.map { filter in
						ArxSegment(filter, title: filter.title, systemImage: symbol(filter))
					},
					selection: ChatListFilter(store.state)
				) { filter in
					for action in filter.actions(from: ChatListFilter(store.state)) {
						store.send(.ui(action))
					}
				}
			}
			.padding(.horizontal, 12)
			.padding(.top, 12)
			.padding(.bottom, 10)

			// Above the search field, which a segment's tooltip hangs over.
			.zIndex(1)

			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 12, weight: .light))
					.foregroundStyle(.secondary)
				TextField(
					String.localized(.appUI.chat.searchChats),
					text: $store.chatsQuery.sending(\.ui.chatsQueryChanged)
				)
				.textFieldStyle(.plain)
				.font(.system(size: 13))
			}
			.padding(.horizontal, 10)
			.frame(height: 32)
			.background { ArxGlassTile(cornerRadius: ArxRaisedShape.cornerRadius(forSide: 32)) }
			.padding(.horizontal, 12)
		}
	}

	@ViewBuilder
	private var list: some View {
		if store.listedConversations.isEmpty {
			ChatListEmpty(showsArchived: store.showsArchived)
		} else {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(ChatTimelineSection.sections(store.listedConversations, now: .now)) { section in
					Text(section.title)
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(.secondary)
						.padding(.horizontal, 6)
						.padding(.top, 14)
						.padding(.bottom, 4)
					ForEach(Array(section.conversations.enumerated()), id: \.element.id) { index, conversation in
						if index > 0 {
							Divider()
								.padding(.leading, 44)
								.padding(.trailing, 6)
						}
						ChatStudioChatRow(
							conversation: conversation,
							isUnread: store.unreadIDs.contains(conversation.id),
							isRunning: store.turns[conversation.id] != nil
						) {
							store.send(.ui(.chatSelected(conversation.id)))
						}
					}
				}
			}
			.padding(.horizontal, 8)
			.padding(.bottom, 10)
		}
	}

	private func symbol(_ filter: ChatListFilter) -> String {
		switch filter {
		case .all: "tray"
		case .unread: "envelope.badge"
		case .archived: "archivebox"
		}
	}
}

private struct ChatStudioChatRow: View {
	internal let conversation: AgentConversation
	internal let isUnread: Bool
	internal let isRunning: Bool
	internal let open: () -> Void

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		Button(action: open) {
			HStack(spacing: 10) {
				// A small page, as a document's thumbnail, with the provider's mark.
				ChatProviderMark(conversation.provider)
					.foregroundStyle(.secondary)
					.frame(width: 28, height: 34)
					.background { ArxRaisedTile(cornerRadius: 5) }
					.overlay(alignment: .topTrailing) {
						if isUnread {
							Circle()
								.fill(Color.accentColor)
								.frame(width: 7, height: 7)
								.offset(x: 2, y: -2)
						}
					}
				VStack(alignment: .leading, spacing: 2) {
					Text(conversation.title)
						.font(.system(size: 13, weight: isUnread ? .semibold : .regular))
						.lineLimit(1)
					Text(detail)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Spacer(minLength: 6)
				if isRunning {
					ProgressView().controlSize(.mini)
				}
				Text(ChatDateText.card(conversation.updatedAt))
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 6)
			.padding(.vertical, 8)
			.background(isHovered ? BrowserTheme.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.onHover { isHovered = $0 }
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityValue(isUnread ? String.localized(.appUI.chat.unread) : "")
	}

	/// The provider, whether it's pinned and the latest answer, separated by dots.
	private var detail: String {
		var parts: [String] = [conversation.provider.title]
		if conversation.isKept {
			parts.append(String.localized(.appUI.chat.kept))
		}
		if let answer = conversation.lastAnswer {
			parts.append(answer)
		}
		return parts.joined(separator: " · ")
	}
}
