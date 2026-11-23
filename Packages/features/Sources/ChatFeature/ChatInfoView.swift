import AgentClient
import AppUI
import SwiftUI
import _ComposableArchitecture

/// Chat info, opened from the title tile (DEV-799): a header bar with raised ‹ and ✕,
/// the assistant's face over the chat's title, its provider and start, Pin, Copy Answer and
/// Archive as raised tiles, the chat's details in a grouped list, and the expiry or plan note
/// under it.
internal struct ChatInfoView: View {
	internal let store: StoreOf<ChatFeature>
	internal let actions: [ChatAction]
	internal let onHide: () -> Void

	internal init(
		store: StoreOf<ChatFeature>,
		actions: [ChatAction],
		onHide: @escaping () -> Void
	) {
		self.store = store
		self.actions = actions
		self.onHide = onHide
	}

	internal var body: some View {
		VStack(spacing: 0) {
			if let conversation = store.selected {
				ScrollView {
					VStack(spacing: 18) {
						identity(conversation)
						quickActionTiles
						details(conversation)
					}
					.padding(.horizontal, ChatMetrics.padding)
					.padding(.top, 6)
					.padding(.bottom, ChatMetrics.padding)
				}
				.scrollBounceBehavior(.basedOnSize)

				// The details scroll under the header into Arx's progressive edge, with no line (DEV-807,
				// DEV-826).
				.arxScrollBar(background: nil) { header }
			} else {
				header
				Spacer(minLength: 0)
			}
		}
		.controlSize(.large)
		.foregroundStyle(BrowserTheme.text)
	}

	/// The shared header bar's raised square ‹ and ✕ and its title. They take no keyboard
	/// shortcuts: ⌘[ and Escape belong to the page beside the panel.
	private var header: some View {
		HStack(spacing: ArxHeaderBarMetrics.spacing) {
			ArxHeaderIconButton(String.localized(.appUI.chat.back), systemImage: "chevron.left") {
				store.send(.ui(.backTapped))
			}
			Text(localized: .appUI.chat.info)
				.font(ArxHeaderBarMetrics.titleFont)
				.lineLimit(1)
				.accessibilityAddTraits(.isHeader)
				.frame(maxWidth: .infinity, alignment: .leading)
			ArxHeaderIconButton(String.localized(.appUI.chat.hide), systemImage: "xmark", action: onHide)
		}
		.padding(.horizontal, ChatMetrics.padding)
		.padding(.top, ChatMetrics.padding)
		.padding(.bottom, 8)
	}

	private func identity(_ conversation: AgentConversation) -> some View {
		VStack(spacing: 8) {
			ChatAvatar(isWorking: store.isRunning, size: 52)
			VStack(spacing: 3) {
				Text(conversation.title)
					.font(.system(size: 15, weight: .bold))
					.multilineTextAlignment(.center)
					.lineLimit(3)
				HStack(spacing: 4) {
					ChatProviderMark(conversation.provider)
					Text(localized: .appUI.chat.started(
						conversation.provider.title,
						ChatDateText.divider(conversation.createdAt)
					))
				}
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
			}
			.accessibilityElement(children: .combine)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 4)
	}

	/// Pin, Copy Answer and Archive as equal raised tiles, each its icon over its short title.
	private var quickActionTiles: some View {
		HStack(spacing: 8) {
			ForEach(quickActions) { action in
				Button(action: action.perform) {
					VStack(spacing: 5) {
						Image(systemName: action.symbol)
							.font(.system(size: 15))
							.frame(height: 18)
						Text(action.shortTitle)
							.font(.system(size: 11, weight: .medium))
					}
					.padding(.vertical, 9)
					.frame(maxWidth: .infinity)
				}
				.buttonStyle(.arxRaised)
				.disabled(!action.isEnabled)
				.help(action.title)
				.accessibilityLabel(Text(verbatim: action.title))
			}
		}
	}

	/// Provider, start, messages and how long it's kept, then the expiry or plan note.
	private func details(_ conversation: AgentConversation) -> some View {
		SettingsSection {
			ChatInfoRow(String.localized(.appUI.chat.provider), value: conversation.provider.title)
			ChatInfoRow(String.localized(.appUI.chat.infoStarted), value: ChatDateText.divider(conversation.createdAt))
			ChatInfoRow(String.localized(.appUI.chat.infoMessages), value: conversation.messages.count.formatted())
			ChatInfoRow(String.localized(.appUI.chat.infoKept), value: retention(conversation))
		} footer: {
			Text(localized: conversation.isKept
			? .appUI.chat.planNote(conversation.provider.title)
			: .appUI.chat.ephemeralNote)
		}
	}

	private func retention(_ conversation: AgentConversation) -> String {
		if conversation.archivedAt != nil { return String.localized(.appUI.chat.filterArchived) }
		return String.localized(conversation.isKept ? .appUI.chat.kept : .appUI.chat.infoTemporary)
	}

	/// Pin, Copy Answer and Archive, as in the ⋯ menu.
	private var quickActions: [ChatAction] {
		let order: [String] = [
			"pin", "pin.slash", "doc.on.doc", "archivebox",
		]
		return actions
			.filter { $0.group == .thisChat && order.contains($0.symbol) }
			.sorted { (order.firstIndex(of: $0.symbol) ?? 0) < (order.firstIndex(of: $1.symbol) ?? 0) }
	}
}

// MARK: - Parts

/// A quiet details row: its title on the left, its value in secondary text on the right.
private struct ChatInfoRow: View {
	internal let title: String
	internal let value: String

	internal init(
		_ title: String,
		value: String
	) {
		self.title = title
		self.value = value
	}

	internal var body: some View {
		HStack(spacing: 12) {
			Text(verbatim: title)
			Spacer(minLength: 12)
			Text(verbatim: value)
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.font(.system(size: 12))
		.frame(minHeight: 34)
		.accessibilityElement(children: .combine)
	}
}

/// The assistant's face. It looks busy while a turn runs.
internal struct ChatAvatar: View {
	internal let isWorking: Bool
	internal var size: CGFloat

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal init(
		isWorking: Bool,
		size: CGFloat = ChatMetrics.avatar
	) {
		self.isWorking = isWorking
		self.size = size
	}

	internal var body: some View {
		Canvas { context, canvasSize in
			let side: CGFloat = min(canvasSize.width, canvasSize.height)
			let disc = CGRect(
				x: (canvasSize.width - side) / 2,
				y: (canvasSize.height - side) / 2,
				width: side,
				height: side
			)
			context.fill(Path(ellipseIn: disc), with: .color(.black))

			// The ring, and inside it the face every Arx smiley shares.
			let ring = disc.insetBy(dx: side * 0.18, dy: side * 0.18)
			let ringWidth: CGFloat = side * 0.07
			context.stroke(
				Path(ellipseIn: ring.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)),
				with: .color(.white),
				lineWidth: ringWidth
			)
			let face = ring.insetBy(dx: ringWidth, dy: ringWidth)
			context.fill(ArxFace.eyes(in: face), with: .color(.white))
			context.stroke(
				ArxFace.smile(in: face),
				with: .color(.white),
				style: .init(lineWidth: face.width * ArxFace.smileWidth, lineCap: .round)
			)
		}
		.frame(width: size, height: size)
		.phaseAnimator([false, true], trigger: isWorking) { content, phase in
			content.scaleEffect(isWorking && !reduceMotion && phase ? 1.08 : 1)
		} animation: { _ in
			.easeInOut(duration: 0.5)
		}
		.accessibilityLabel(String.localized(.appUI.chat.avatar))
	}
}
