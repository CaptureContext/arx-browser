import BrowserCore
import Foundation
import _Dependencies

public struct AutomationControlClient: Sendable {
	public var start: @MainActor @Sendable () async throws -> String
	public var stop: @MainActor @Sendable () async -> Void
	public var respond: @MainActor @Sendable (UUID, AutomationResult) -> Void
	public var revoke: @MainActor @Sendable (UUID) -> Void
	public var authorize: @MainActor @Sendable (UUID) -> Bool
	public var beginScroll: @MainActor @Sendable (UUID) -> Bool
	public var beginForm: @MainActor @Sendable (UUID) -> Bool
	public var beginClick: @MainActor @Sendable (UUID) -> Bool

	/// Tells the request's call that Arx asks the user, so it can say so instead of blocking (DEV-1024).
	public var waitForUser: @MainActor @Sendable (UUID, AutomationUserWait) -> Void
	public var credential: @Sendable () throws -> AutomationCredential

	/// Hands a person's answer to the `arx` command waiting for it.
	public var replyToAgentSetup: @Sendable (AgentSetup.Reply, AgentSetup.Agent) throws -> Void

	public init(
		start: @escaping @MainActor @Sendable () async throws -> String = { throw AutomationFailure.appUnavailable },
		stop: @escaping @MainActor @Sendable () async -> Void = {},
		respond: @escaping @MainActor @Sendable (UUID, AutomationResult) -> Void = { _, _ in },
		revoke: @escaping @MainActor @Sendable (UUID) -> Void = { _ in },
		authorize: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in false },
		beginForm: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in false },
		beginScroll: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in false },
		beginClick: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in false },
		waitForUser: @escaping @MainActor @Sendable (UUID, AutomationUserWait) -> Void = { _, _ in },
		credential: @escaping @Sendable () throws -> AutomationCredential = { try AutomationSecurity.credential() },
		replyToAgentSetup: @escaping @Sendable (AgentSetup.Reply, AgentSetup.Agent) throws -> Void = { _, _ in }
	) {
		self.start = start
		self.stop = stop
		self.respond = respond
		self.revoke = revoke
		self.authorize = authorize
		self.beginForm = beginForm
		self.beginScroll = beginScroll
		self.beginClick = beginClick
		self.waitForUser = waitForUser
		self.credential = credential
		self.replyToAgentSetup = replyToAgentSetup
	}
}

extension AutomationControlClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self {
		.init(credential: { throw AutomationFailure.appUnavailable })
	}
}

extension DependencyValues {
	public var automationControl: AutomationControlClient {
		get { self[AutomationControlClient.self] }
		set { self[AutomationControlClient.self] = newValue }
	}
}
