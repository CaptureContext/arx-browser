import BrowserAutomationClient
import BrowserCore
import Foundation
import _Dependencies

/// How the embedded agent reaches the browser: through the same bundled MCP helper,
/// authenticated socket, grants and approvals as outside agents.
///
/// The app registers one automation client per profile for the embedded agent and grants it
/// that profile only. Arx checks every tool call against that client's grants, so the
/// embedded agent can't do anything an outside agent with the same grants couldn't.
public struct AgentBrowserAccess: Sendable {
	/// The profile's embedded-agent client, issued by the app. Throws when the person hasn't
	/// granted the embedded agent anything in that profile.
	public var connection: @Sendable (Profile.ID) async throws -> Connection

	public init(connection: @escaping @Sendable (Profile.ID) async throws -> Connection) {
		self.connection = connection
	}

	public struct Connection: Equatable, Sendable {
		/// The bundled `ArxMCP` helper inside the app.
		public var helper: URL

		/// The automation client's credential. It goes only into the helper's environment,
		/// never into the provider's own process, a log or another profile's files.
		public var credential: AgentSetup.Credential

		public init(
			helper: URL,
			credential: AgentSetup.Credential
		) {
			self.helper = helper
			self.credential = credential
		}

		/// The MCP server name the provider sees. Tool names start with it.
		public static let serverName: String = "arx"
	}

	public enum Failure: Error, Equatable, Sendable {
		/// The person hasn't granted the embedded agent access to this profile.
		case notGranted

		/// The app hasn't provided browser access, such as in a test or headless run.
		case unavailable
	}
}

extension AgentBrowserAccess: DependencyKey {
	/// The app supplies the real value with `prepareDependencies`, because only it can
	/// register automation clients.
	public static var liveValue: Self {
		.init { _ in throw Failure.unavailable }
	}

	public static var testValue: Self {
		.init(connection: IssueReporting.unimplemented("AgentBrowserAccess.connection"))
	}
}

extension DependencyValues {
	public var agentBrowserAccess: AgentBrowserAccess {
		get { self[AgentBrowserAccess.self] }
		set { self[AgentBrowserAccess.self] = newValue }
	}
}
