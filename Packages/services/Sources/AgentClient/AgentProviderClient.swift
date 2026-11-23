import Foundation
import _Dependencies

/// One provider's adapter. Claude and ChatGPT each build one; features only use this type.
///
/// Cancelling the task that iterates ``send`` stops the turn: the adapter asks the provider
/// to stop and the stream ends. A turn keeps running while its consumer keeps iterating, so
/// dismissing the chat UI doesn't stop it unless the UI owns the consuming task.
public struct AgentProviderClient: Sendable {
	public var provider: AgentProvider

	/// The app-wide connection. Never starts a sign-in: people sign in with the provider's own app.
	public var account: @Sendable () async -> AgentAccount

	public var models: @Sendable () async -> [AgentModel]

	/// Runs one turn. The stream throws ``AgentFailure`` when the turn can't finish.
	public var send: @Sendable (AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, any Error>

	/// Removes what the provider kept on this Mac for a conversation, such as its transcript.
	public var discard: @Sendable (_ resumeToken: String) async throws -> Void

	public init(
		provider: AgentProvider,
		account: @escaping @Sendable () async -> AgentAccount,
		models: @escaping @Sendable () async -> [AgentModel],
		send: @escaping @Sendable (AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, any Error>,
		discard: @escaping @Sendable (_ resumeToken: String) async throws -> Void
	) {
		self.provider = provider
		self.account = account
		self.models = models
		self.send = send
		self.discard = discard
	}
}

extension AgentProviderClient {
	/// A provider that does nothing, for runs that may not use agents.
	public static func unavailable(_ provider: AgentProvider) -> Self {
		.init(
			provider: provider,
			account: { .init(provider: provider, status: .unavailable) },
			models: { [] },
			send: { _ in
				AsyncThrowingStream { $0.finish(throwing: AgentFailure.runtimeMissing) }
			},
			discard: { _ in }
		)
	}

	/// Fails the test on any call, so tests supply exactly the behavior they rely on.
	public static func unimplemented(_ provider: AgentProvider) -> Self {
		.init(
			provider: provider,
			account: IssueReporting.unimplemented(
				"AgentProviderClient.account",
				placeholder: .init(provider: provider, status: .unavailable)
			),
			models: IssueReporting.unimplemented("AgentProviderClient.models", placeholder: []),
			send: IssueReporting.unimplemented(
				"AgentProviderClient.send",
				placeholder: AsyncThrowingStream { $0.finish(throwing: AgentFailure.runtimeMissing) }
			),
			discard: IssueReporting.unimplemented("AgentProviderClient.discard")
		)
	}
}

extension AgentProviderClient {
	/// Whether this launch may run agents. Test, smoke and headless runs never do.
	public static func isEnabled(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		guard !isTesting
		else { return false }

		let automationKeys: [String] = [
			"ARX_SKIP_AGENTS",
			"ARX_ENGINE_PROFILE",
			"XCTestConfigurationFilePath",
			"XCTestBundlePath",
			"XCTestSessionIdentifier",
		]
		guard automationKeys.allSatisfy({ environment[$0] == nil })
		else { return false }

		return !arguments.dropFirst().contains { argument in
			argument == "--headless" || argument.hasPrefix("--arx-")
		}
	}
}
