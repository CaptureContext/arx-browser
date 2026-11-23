import Foundation

/// A service that runs the agent, such as Claude or ChatGPT.
///
/// Each provider has its own adapter target that builds an ``AgentProviderClient``. The rest
/// of Arx only sees the shared types in this module.
public struct AgentProvider: RawRepresentable, Hashable, Codable, Sendable {
	public var rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}

	public static let claude: Self = .init(rawValue: "claude")
	public static let openAI: Self = .init(rawValue: "openai")
}

/// The provider connection on this Mac. Connections are app-wide: every profile sees the same one.
public struct AgentAccount: Equatable, Sendable {
	public var provider: AgentProvider
	public var status: Status

	public init(
		provider: AgentProvider,
		status: Status
	) {
		self.provider = provider
		self.status = status
	}

	public var isConnected: Bool {
		guard case .signedIn = status
		else { return false }

		return true
	}

	public enum Status: Equatable, Sendable {
		/// Signed in through the provider's own app with a subscription.
		case signedIn(Identity)

		/// The provider's app is installed but nobody is signed in, or the sign-in expired.
		/// `instructions` tell the person how to sign in with the provider's own flow.
		case signedOut(instructions: String)

		/// Signed in with a method Arx refuses to use, such as an API key that is billed separately.
		case unsupportedSignIn(method: String)

		/// The provider's app or command isn't installed.
		case runtimeMissing

		/// This run may not use agents, such as a test, smoke or headless run.
		case unavailable
	}

	public struct Identity: Equatable, Sendable {
		/// Stable for this connection, such as the provider's configuration folder.
		public var id: String

		/// What the provider reports about the account, when it does.
		public var label: String?

		/// The plan the provider reports, when it does.
		public var plan: String?

		public init(
			id: String,
			label: String? = nil,
			plan: String? = nil
		) {
			self.id = id
			self.label = label
			self.plan = plan
		}
	}
}

/// A model a person can pick for a profile.
public struct AgentModel: Identifiable, Equatable, Sendable {
	/// What the adapter passes to the provider.
	public var id: String
	public var title: String
	public var capabilities: Set<Capability>

	public init(
		id: String,
		title: String,
		capabilities: Set<Capability>
	) {
		self.id = id
		self.title = title
		self.capabilities = capabilities
	}

	public enum Capability: String, Codable, Sendable {
		/// Can call Arx's browser tools.
		case browserTools

		/// Streams text while it's written.
		case streaming

		/// Accepts page context attached to a prompt.
		case attachments
	}
}

/// A profile's agent settings. Saved per profile, never shared between profiles.
public struct AgentProfileSettings: Equatable, Codable, Sendable {
	public var provider: AgentProvider

	/// The connection the profile picked, matching ``AgentAccount/Identity/id``.
	public var accountID: String?

	/// `nil` uses the provider's default model.
	public var modelID: String?

	/// Whether this profile's chats are kept.
	public var retention: AgentRetention

	public init(
		provider: AgentProvider,
		accountID: String? = nil,
		modelID: String? = nil,
		retention: AgentRetention = .ephemeral
	) {
		self.provider = provider
		self.accountID = accountID
		self.modelID = modelID
		self.retention = retention
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			provider: try values.decode(AgentProvider.self, forKey: .provider),
			accountID: try values.decodeIfPresent(String.self, forKey: .accountID),
			modelID: try values.decodeIfPresent(String.self, forKey: .modelID),
			retention: try values.decodeIfPresent(AgentRetention.self, forKey: .retention) ?? .ephemeral
		)
	}

	private enum CodingKeys: String, CodingKey {
		case provider, accountID, modelID, retention
	}
}

/// How long chats last. The assistant is a quick utility, so chats are ephemeral unless a
/// person chooses to keep them.
public enum AgentRetention: String, Codable, Sendable {
	/// A chat disappears ``ephemeralLifetime`` after its last activity, or when the browser
	/// quits. Nothing about it stays on this Mac afterwards, including the provider's transcript.
	case ephemeral

	/// Chats are kept in the profile until the person deletes them.
	case persistent

	public static let ephemeralLifetime: TimeInterval = 20 * 60
}
