import AgentClient
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// "Thinking…", or the retry under way, under the reply a turn is writing.
internal struct ChatProgress: View {
	internal let turn: ChatTurn

	internal init(turn: ChatTurn) {
		self.turn = turn
	}

	internal var body: some View {
		HStack(spacing: 6) {
			ProgressView().controlSize(.mini)
			if let retry = turn.retry {
				Text(localized: .appUI.chat.retrying(retry.attempt, retry.maxAttempts))
			} else {
				Text(localized: .appUI.chat.thinking)
			}
		}
		.font(.system(size: 11))
		.foregroundStyle(.secondary)
		.accessibilityElement(children: .combine)
	}
}

/// Where a tool call stands in its turn.
internal enum ChatToolStatus: Equatable {
	case running
	case failed
	case done

	internal init(
		_ tool: AgentToolActivity,
		turn: ChatTurn?
	) {
		if turn?.runningTools.contains(tool.id) == true {
			self = .running
		} else if turn?.failedTools.contains(tool.id) == true {
			self = .failed
		} else {
			self = .done
		}
	}

	/// "Using page snapshot", "Used page snapshot" or "click didn't work".
	internal func title(_ tool: AgentToolActivity) -> String {
		let name: String = ChatToolName.readable(tool.name)
		switch self {
		case .running: return String.localized(.appUI.chat.toolRunning(name))
		case .failed: return String.localized(.appUI.chat.toolFailed(name))
		case .done: return String.localized(.appUI.chat.toolDone(name))
		}
	}
}

internal enum ChatToolName {
	/// `browser_page_snapshot` reads as "page snapshot".
	internal static func readable(_ name: String) -> String {
		let trimmed: Substring = name.hasPrefix("browser_") ? name.dropFirst("browser_".count) : Substring(name)
		return trimmed.replacingOccurrences(of: "_", with: " ")
	}
}

/// Why a turn stopped, with the kept prompt and a way forward.
internal struct ChatFailureView: View {
	internal let failure: ChatFailure
	internal let provider: AgentProvider
	internal let account: AgentAccount?
	internal let retry: () -> Void
	internal let dismiss: () -> Void

	internal init(
		failure: ChatFailure,
		provider: AgentProvider,
		account: AgentAccount?,
		retry: @escaping () -> Void,
		dismiss: @escaping () -> Void
	) {
		self.failure = failure
		self.provider = provider
		self.account = account
		self.retry = retry
		self.dismiss = dismiss
	}

	internal var body: some View {
		let text = ChatFailureText(failure.reason, provider: provider, account: account)
		ChatNote(symbol: "exclamationmark.triangle", tint: .orange) {
			Text(text.title).fontWeight(.medium)
			if let detail = text.detail {
				Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
			}
			Text(localized: .appUI.chat.failurePromptKept).foregroundStyle(.secondary)
			HStack {
				Button(String.localized(.appUI.chat.retry), action: retry)
				Button(String.localized(.appUI.chat.dismiss), action: dismiss)
			}
			.controlSize(.small)
		}
	}
}

/// Plain-language text for each ``AgentFailure``.
internal struct ChatFailureText: Equatable {
	internal var title: String
	internal var detail: String?

	internal init(
		_ failure: AgentFailure,
		provider: AgentProvider,
		account: AgentAccount?
	) {
		let name: String = provider.title
		let signIn: String = {
			if case let .signedOut(instructions) = account?.status { return instructions }
			return String.localized(.appUI.chat.failureSignInDetail)
		}()
		switch failure {
		case .runtimeMissing:
			self.title = String.localized(.appUI.chat.failureRuntimeMissing(name))
			self.detail = signIn

		case .signedOut:
			self.title = String.localized(.appUI.chat.failureSignedOut(name))
			self.detail = signIn

		case .loginExpired:
			self.title = String.localized(.appUI.chat.failureLoginExpired(name))
			self.detail = signIn

		case let .unsupportedSignIn(method):
			self.title = String.localized(.appUI.chat.failureUnsupportedSignIn(name, method))
			self.detail = String.localized(.appUI.chat.failureUnsupportedSignInDetail)

		case let .usageLimit(limit):
			self.title = String.localized(.appUI.chat.failureUsageLimit(name))
			self.detail = limit.resetsAt.map { date in
				String.localized(.appUI.chat.failureUsageLimitResets(date.formatted(.relative(presentation: .named))))
			}

		case .usageCreditsRequired:
			self.title = String.localized(.appUI.chat.failureUsageCredits)
			self.detail = String.localized(.appUI.chat.failureUsageCreditsDetail)

		case .billing:
			self.title = String.localized(.appUI.chat.failureBilling(name))
			self.detail = nil

		case .modelUnavailable:
			self.title = String.localized(.appUI.chat.failureModelUnavailable)
			self.detail = String.localized(.appUI.chat.failureModelUnavailableDetail)

		case .turnLimitReached:
			self.title = String.localized(.appUI.chat.failureTurnLimit)
			self.detail = String.localized(.appUI.chat.failureTurnLimitDetail)

		case .browserToolsUnavailable:
			self.title = String.localized(.appUI.chat.failureBrowserTools)
			self.detail = String.localized(.appUI.chat.failureBrowserToolsDetail)

		case .interrupted:
			self.title = String.localized(.appUI.chat.failureInterrupted)
			self.detail = nil

		case .timedOut:
			self.title = String.localized(.appUI.chat.failureTimedOut(name))
			self.detail = String.localized(.appUI.chat.failureTimedOutDetail(provider.toolName))

		case .runtimeFailed:
			// The provider's own message can echo anything; it's never shown or logged.
			self.title = String.localized(.appUI.chat.failureRuntimeFailed(name))
			self.detail = nil
		}
	}
}

/// A quiet card inside the conversation.
internal struct ChatNote<Content: View>: View {
	internal let symbol: String
	internal let tint: Color
	internal let content: Content

	internal init(
		symbol: String,
		tint: Color = .secondary,
		@ViewBuilder content: () -> Content
	) {
		self.symbol = symbol
		self.tint = tint
		self.content = content()
	}

	internal var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: symbol).foregroundStyle(tint)
			VStack(alignment: .leading, spacing: 6) { content }
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.font(.system(size: 12))
		.padding(12)
		.background { ArxRaisedTile(cornerRadius: 14) }
		.accessibilityElement(children: .contain)
	}
}

/// The attachments under a message or in the composer (DEV-798): a tab with its favicon, an
/// image as a thumbnail, a file with its icon and name. In the composer each has a ×.
internal struct ChatAttachmentChips: View {
	internal let attachments: [AgentContextAttachment]
	internal var profileID: Profile.ID?
	internal var remove: ((Int) -> Void)?

	internal init(
		attachments: [AgentContextAttachment],
		profileID: Profile.ID? = nil,
		remove: ((Int) -> Void)? = nil
	) {
		self.attachments = attachments
		self.profileID = profileID
		self.remove = remove
	}

	internal var body: some View {
		ScrollView(.horizontal) {
			HStack(alignment: .center, spacing: 6) {
				ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
					chip(attachment, index: index)
				}
			}
			.padding(.vertical, 1)
		}
		.scrollIndicators(.hidden)
	}

	@ViewBuilder
	private func chip(
		_ attachment: AgentContextAttachment,
		index: Int
	) -> some View {
		if let file = attachment.file, file.kind == .image, let preview = file.preview.flatMap(NSImage.init(data:)) {
			ChatImageChip(image: preview, label: attachment.label, remove: remove.map { remove in { remove(index) } })
		} else {
			HStack(spacing: 5) {
				icon(attachment)
				Text(attachment.label).lineLimit(1)
				removeButton(attachment, index: index)
			}
			.font(.system(size: 11))
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(BrowserTheme.fill, in: .capsule)
		}
	}

	@ViewBuilder
	private func icon(_ attachment: AgentContextAttachment) -> some View {
		switch attachment {
		case let .tabs(tabs) where tabs.count == 1:
			BrowserSiteIcon(key: siteIcon(tabs[0]), size: 12)

		case .tabs:
			Image(systemName: "rectangle.stack").font(.system(size: 9))

		case let .file(file):
			Image(systemName: ChatAttachmentSymbol.symbol(file)).font(.system(size: 10))

		case .page, .selection:
			Image(systemName: "doc.text").font(.system(size: 9))
		}
	}

	@ViewBuilder
	private func removeButton(
		_ attachment: AgentContextAttachment,
		index: Int
	) -> some View {
		if let remove {
			Button { remove(index) } label: {
				Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
			}
			.buttonStyle(.plain)
			.accessibilityLabel(String.localized(.appUI.chat.attachRemove(attachment.label)))
		}
	}

	private func siteIcon(_ tab: AgentContextAttachment.Tab) -> SidebarItem.SiteIcon? {
		guard let profileID, let url = URL(string: tab.url)
		else { return nil }

		return .init(profileID: profileID.rawValue, pageURL: url)
	}
}

/// An image's thumbnail, with its × over the corner in the composer.
private struct ChatImageChip: View {
	internal let image: NSImage
	internal let label: String
	internal let remove: (() -> Void)?

	internal var body: some View {
		Image(nsImage: image)
			.resizable()
			.interpolation(.high)
			.scaledToFill()
			.frame(width: 44, height: 44)
			.clipShape(.rect(cornerRadius: 8, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.strokeBorder(BrowserTheme.border, lineWidth: 0.5)
			}
			.overlay(alignment: .topTrailing) {
				if let remove {
					Button(action: remove) {
						Image(systemName: "xmark")
							.font(.system(size: 7, weight: .bold))
							.foregroundStyle(.white)
							.frame(width: 16, height: 16)
							.background(.black.opacity(0.6), in: .circle)
					}
					.buttonStyle(.plain)
					.offset(x: 4, y: -4)
					.accessibilityLabel(String.localized(.appUI.chat.attachRemove(label)))
				}
			}
			.padding(.top, remove == nil ? 0 : 4)
			.padding(.trailing, remove == nil ? 0 : 4)
			.help(label)
			.accessibilityElement(children: .contain)
			.accessibilityLabel(label)
	}
}

internal enum ChatAttachmentSymbol {
	internal static func symbol(_ file: AgentFileAttachment) -> String {
		switch file.kind {
		case .image: "photo"
		case .pdf: "doc.richtext"
		case .text: "doc.plaintext"
		}
	}
}

internal enum ChatDateText {
	/// "Today 5:53 PM", "Yesterday 9:10 AM" or a date.
	internal static func divider(_ date: Date) -> String {
		let time: String = date.formatted(date: .omitted, time: .shortened)
		let calendar: Calendar = .current
		if calendar.isDateInToday(date) { return String.localized(.appUI.chat.today(time)) }
		if calendar.isDateInYesterday(date) { return String.localized(.appUI.chat.yesterday(time)) }
		return date.formatted(date: .abbreviated, time: .shortened)
	}

	/// A card's time: the time today, "Yesterday", or a short date.
	internal static func card(_ date: Date) -> String {
		let calendar: Calendar = .current
		if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
		if calendar.isDateInYesterday(date) {
			// The language's own capitals at the start of a line, not English title case.
			let style: Date.RelativeFormatStyle = .init(presentation: .named, capitalizationContext: .standalone)
			return date.formatted(style)
		}
		return date.formatted(.dateTime.month(.abbreviated).day())
	}
}
