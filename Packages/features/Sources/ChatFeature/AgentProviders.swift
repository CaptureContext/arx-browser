import AgentClient
import ClaudeAgentClient
import CodexAgentClient
import Foundation
import _ComposableArchitecture

/// Every provider adapter the chat can pick from, in the order the pickers list them.
///
/// Each adapter target builds one ``AgentProviderClient``: Claude through the person's own
/// Claude Code (DEV-644) and ChatGPT through their own Codex CLI (DEV-643). Adding a provider
/// means adding its client to ``liveValue``; the panel, the per-chat picker and Settings read
/// this list and need no other change.
public struct AgentProviders: Sendable {
	public var clients: [AgentProviderClient]

	/// Whether this launch may run agents. Test, smoke and headless runs never do,
	/// so the app skips the launch and quit sweeps there.
	public var isEnabled: Bool

	public init(
		clients: [AgentProviderClient],
		isEnabled: Bool
	) {
		self.clients = clients
		self.isEnabled = isEnabled
	}

	public var providers: [AgentProvider] {
		clients.map(\.provider)
	}

	/// The provider's adapter, or one that reports it unavailable when this build has none.
	public subscript(_ provider: AgentProvider) -> AgentProviderClient {
		clients.first { $0.provider == provider } ?? .unavailable(provider)
	}

	/// The first provider, for a profile that hasn't picked one.
	public var defaultProvider: AgentProvider {
		providers.first ?? .claude
	}

	/// Discards a transcript with every provider. A profile's ledger doesn't record which
	/// provider kept a transcript, and each adapter ignores handles it doesn't recognize.
	public var discardingEverywhere: AgentProviderClient {
		let clients: [AgentProviderClient] = self.clients
		return .init(
			provider: defaultProvider,
			account: { .init(provider: .claude, status: .unavailable) },
			models: { [] },
			send: { _ in AsyncThrowingStream { $0.finish(throwing: AgentFailure.runtimeMissing) } },
			discard: { token in
				for client in clients {
					try await client.discard(token)
				}
			}
		)
	}
}

extension AgentProviders: DependencyKey {
	public static var liveValue: Self {
		@Dependency(\.claudeAgent)
		var claude

		@Dependency(\.codexAgent)
		var codex

		return .init(
			clients: [claude, codex],
			isEnabled: AgentProviderClient.isEnabled(
				environment: ProcessInfo.processInfo.environment,
				arguments: CommandLine.arguments
			)
		)
	}

	public static var testValue: Self {
		.init(
			clients: [.unimplemented(.claude)],
			isEnabled: false
		)
	}
}

extension DependencyValues {
	public var agentProviders: AgentProviders {
		get { self[AgentProviders.self] }
		set { self[AgentProviders.self] = newValue }
	}
}

extension AgentProvider {
	/// The name people know the service by.
	public var title: String {
		switch self {
		case .claude: "Claude"
		case .openAI: "ChatGPT"
		default: rawValue.capitalized
		}
	}

	public var symbol: String {
		switch self {
		case .claude: "asterisk"
		case .openAI: "circle.hexagongrid"
		default: "sparkles"
		}
	}

	/// The provider's own tool that Arx runs and that people sign in to.
	public var toolName: String {
		switch self {
		case .claude: "Claude Code"
		case .openAI: "Codex"
		default: title
		}
	}
}
