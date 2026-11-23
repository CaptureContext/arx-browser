import AgentClient
import AppUI
import BrowserCore
import Foundation

/// A turn that is running now. Its text reaches the reply in batches, never per token.
public struct ChatTurn: Equatable, Sendable {
	public var prompt: String
	public var attachments: [AgentContextAttachment]
	public var promptID: UUID
	public var replyID: UUID

	/// Browser tools the agent called and that haven't finished yet.
	public var runningTools: Set<String>

	/// Browser tools that ended with an error or were refused before reaching Arx.
	public var failedTools: Set<String>

	public var usageWarning: AgentUsageLimit?
	public var retry: Retry?

	public init(
		prompt: String,
		attachments: [AgentContextAttachment],
		promptID: UUID,
		replyID: UUID,
		runningTools: Set<String> = [],
		failedTools: Set<String> = [],
		usageWarning: AgentUsageLimit? = nil,
		retry: Retry? = nil
	) {
		self.prompt = prompt
		self.attachments = attachments
		self.promptID = promptID
		self.replyID = replyID
		self.runningTools = runningTools
		self.failedTools = failedTools
		self.usageWarning = usageWarning
		self.retry = retry
	}

	public struct Retry: Equatable, Sendable {
		public var attempt: Int
		public var maxAttempts: Int

		public init(
			attempt: Int,
			maxAttempts: Int
		) {
			self.attempt = attempt
			self.maxAttempts = maxAttempts
		}
	}
}

/// A turn that stopped without finishing. The prompt stays in the transcript, so nothing the
/// person wrote is lost, and Try Again sends it once more under the same message (DEV-643).
public struct ChatFailure: Equatable, Sendable {
	public var reason: AgentFailure
	public var prompt: String
	public var attachments: [AgentContextAttachment]

	/// The transcript message that holds the prompt.
	public var promptID: UUID

	public init(
		reason: AgentFailure,
		prompt: String,
		attachments: [AgentContextAttachment],
		promptID: UUID
	) {
		self.reason = reason
		self.prompt = prompt
		self.attachments = attachments
		self.promptID = promptID
	}
}

/// Whether the profile's embedded agent may use the browser tools.
public enum ChatBrowserAccess: Equatable, Sendable {
	/// Not checked yet.
	case unknown

	/// The profile's assistant client is registered and the MCP server is running.
	case granted

	/// The person hasn't allowed the assistant in this profile yet, or the MCP server is off.
	case notGranted

	/// This run can't offer browser tools, such as a test or smoke run.
	case unavailable
}

/// Something a person can attach with the + picker. Attaching is the only way page context
/// reaches the agent; typing never sends page content.
public struct ChatAttachable: Identifiable, Equatable, Sendable {
	public var id: String
	public var title: String
	public var symbol: String
	public var tabs: [AgentContextAttachment.Tab]

	public init(
		id: String,
		title: String,
		symbol: String,
		tabs: [AgentContextAttachment.Tab]
	) {
		self.id = id
		self.title = title
		self.symbol = symbol
		self.tabs = tabs
	}

	public var attachment: AgentContextAttachment {
		.tabs(tabs)
	}

	/// The id of the window's current tab, listed first.
	public static let currentID: String = "current"
}

extension AgentContextAttachment {
	/// A short name for the chip shown in the composer and under a message.
	public var label: String {
		switch self {
		case let .page(title, url, _):
			title.isEmpty ? url : title

		case let .selection(text, _):
			String(text.prefix(40))

		case let .tabs(tabs) where tabs.count == 1:
			tabs[0].title.isEmpty ? tabs[0].url : tabs[0].title

		case let .tabs(tabs):
			String.localized(.appUI.chat.attachTabCount(tabs.count))

		case let .file(file):
			file.name
		}
	}
}

extension AgentConversation {
	/// The latest answer, for Copy Answer and the Your Chats cards.
	public var lastAnswer: String? {
		messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text
	}

	public var isKept: Bool {
		retention == .persistent
	}

	/// A title from the first prompt: its first line, shortened.
	public static func title(from prompt: String) -> String {
		let line: Substring = prompt
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.split(whereSeparator: \.isNewline)
			.first ?? ""
		guard line.count > titleLimit
		else { return String(line) }

		return String(line.prefix(titleLimit - 1)) + "…"
	}

	public static let titleLimit: Int = 48
}
