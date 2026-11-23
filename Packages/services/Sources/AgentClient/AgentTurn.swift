import BrowserCore
import Foundation

/// One message a person sends, with everything the adapter needs to run it.
public struct AgentTurnRequest: Equatable, Sendable {
	public var profileID: Profile.ID
	public var conversationID: AgentConversation.ID

	/// The provider's handle for the conversation, from an earlier ``AgentEvent/started(resumeToken:modelID:)``.
	/// `nil` starts a new conversation.
	public var resumeToken: String?

	public var prompt: String

	/// Context the person attached explicitly. Typing never attaches page content by itself.
	public var attachments: [AgentContextAttachment]

	/// `nil` uses the provider's default model.
	public var modelID: String?

	/// How hard the model thinks. `nil` uses the adapter's default, which favors quick answers.
	public var effort: AgentEffort?

	/// The profile's browser tools. `nil` runs the turn without any browser access.
	public var browserAccess: AgentBrowserAccess.Connection?

	public init(
		profileID: Profile.ID,
		conversationID: AgentConversation.ID,
		resumeToken: String? = nil,
		prompt: String,
		attachments: [AgentContextAttachment] = [],
		modelID: String? = nil,
		effort: AgentEffort? = nil,
		browserAccess: AgentBrowserAccess.Connection? = nil
	) {
		self.profileID = profileID
		self.conversationID = conversationID
		self.resumeToken = resumeToken
		self.prompt = prompt
		self.attachments = attachments
		self.modelID = modelID
		self.effort = effort
		self.browserAccess = browserAccess
	}
}

/// How much reasoning a turn may spend. Providers map it to their own levels.
public enum AgentEffort: String, Codable, Sendable {
	case low
	case medium
	case high
}

/// Browser context a person chose to share with the agent.
public enum AgentContextAttachment: Equatable, Codable, Sendable {
	case page(title: String, url: String, text: String)
	case selection(text: String, url: String)
	case tabs([Tab])

	/// A file, image or page capture (DEV-798).
	case file(AgentFileAttachment)

	public struct Tab: Equatable, Codable, Sendable {
		public var title: String
		public var url: String

		public init(
			title: String,
			url: String
		) {
			self.title = title
			self.url = url
		}
	}
}

/// What a running turn reports, in order.
public enum AgentEvent: Equatable, Sendable {
	/// The provider accepted the turn. Store `resumeToken` to continue the conversation later.
	case started(resumeToken: String, modelID: String?)

	/// Text the agent wrote since the previous event.
	case text(String)

	/// The agent called a browser tool. Arx checks the call like any outside agent's.
	case toolStarted(AgentToolActivity)

	case toolFinished(id: String, isError: Bool)

	/// The provider refused a tool call before it reached Arx.
	case toolDenied(name: String)

	/// The provider says the plan is close to its limit.
	case usageWarning(AgentUsageLimit)

	/// The provider is retrying a failed request on its own.
	case retrying(attempt: Int, maxAttempts: Int, reason: AgentFailure)

	case completed(AgentTurnSummary)
}

public struct AgentToolActivity: Identifiable, Equatable, Codable, Sendable {
	public var id: String

	/// The browser tool's name without the provider's prefix, such as `browser_tabs`.
	public var name: String

	/// The call's arguments as JSON.
	public var input: String

	public init(
		id: String,
		name: String,
		input: String
	) {
		self.id = id
		self.name = name
		self.input = input
	}
}

public struct AgentUsageLimit: Equatable, Sendable {
	/// When the provider says the limit resets, if it says so.
	public var resetsAt: Date?

	/// How much of the limit is used, from 0 to 1, if the provider says so.
	public var utilization: Double?

	public init(
		resetsAt: Date? = nil,
		utilization: Double? = nil
	) {
		self.resetsAt = resetsAt
		self.utilization = utilization
	}
}

public struct AgentTurnSummary: Equatable, Sendable {
	public var resumeToken: String
	public var inputTokens: Int?
	public var outputTokens: Int?

	public init(
		resumeToken: String,
		inputTokens: Int? = nil,
		outputTokens: Int? = nil
	) {
		self.resumeToken = resumeToken
		self.inputTokens = inputTokens
		self.outputTokens = outputTokens
	}
}

/// Why a turn stopped. The prompt that started it is never lost: callers keep it to retry.
public enum AgentFailure: Error, Equatable, Sendable {
	/// The provider's app or command isn't installed.
	case runtimeMissing

	/// Nobody is signed in to the provider's app.
	case signedOut

	/// The sign-in expired and the provider's app couldn't renew it.
	case loginExpired

	/// The provider's app is signed in with a method Arx won't use, such as a separately billed API key.
	case unsupportedSignIn(method: String)

	/// The plan's usage limit was reached.
	case usageLimit(AgentUsageLimit)

	/// Continuing would draw from paid usage credits instead of the plan. Arx never does that silently.
	case usageCreditsRequired

	/// The provider reported a billing problem with the account.
	case billing

	case modelUnavailable(String?)

	/// The turn used every step it may take before answering. The assistant is for quick
	/// tasks; bigger jobs belong in a full agent app.
	case turnLimitReached

	/// The profile's browser tools couldn't start.
	case browserToolsUnavailable

	/// The provider's app stopped before finishing the turn.
	case interrupted

	/// The provider's app sent nothing for too long, so Arx stopped waiting (DEV-643).
	case timedOut

	/// The provider's app reported a failure Arx doesn't recognize.
	case runtimeFailed(String)
}
