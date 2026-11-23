import Foundation

/// What the `arx` command and the running app share to connect an agent.
///
/// The app writes each agent's credential to a private file, so an agent's own configuration
/// only names the file's owner and never holds the secret.
public enum AgentSetup {
	public enum Agent: String, CaseIterable, Codable, Sendable {
		case claude
		case claudeDesktop = "claude-desktop"
		case codex
		case cursor

		public var title: String {
			switch self {
			case .claude: "Claude Code"
			case .claudeDesktop: "Claude Desktop"
			case .codex: "Codex"
			case .cursor: "Cursor"
			}
		}
	}

	/// A command's request for a person to connect an agent in the running app.
	public struct Request: Equatable, Sendable {
		public var id: UUID
		public var agent: Agent

		public init(
			id: UUID,
			agent: Agent
		) {
			self.id = id
			self.agent = agent
		}

		public var userInfo: [String: String] {
			["id": id.uuidString, "agent": agent.rawValue]
		}

		public init?(userInfo: [AnyHashable: Any]?) {
			guard
				let id = (userInfo?["id"] as? String).flatMap(UUID.init(uuidString:)),
				let agent = (userInfo?["agent"] as? String).flatMap(Agent.init(rawValue:))
			else { return nil }
			self.init(id: id, agent: agent)
		}
	}

	public struct Credential: Codable, Equatable, Sendable {
		public var socket: String
		public var clientID: UUID
		public var token: String

		public init(
			socket: String,
			clientID: UUID,
			token: String
		) {
			self.socket = socket
			self.clientID = clientID
			self.token = token
		}

		public var environment: [String: String] {
			[
				"ARX_MCP_SOCKET": socket,
				"ARX_MCP_CLIENT_ID": clientID.uuidString,
				"ARX_MCP_CREDENTIAL": token,
			]
		}
	}

	/// The answer to a request. No credential means the person declined.
	public struct Reply: Codable, Equatable, Sendable {
		public var requestID: UUID
		public var credential: Credential?

		public init(
			requestID: UUID,
			credential: Credential?
		) {
			self.requestID = requestID
			self.credential = credential
		}
	}

	public static let requestNotification: Notification.Name = .init("dev.capturecontext.arx.agentSetup.request")
	public static let revokeNotification: Notification.Name = .init("dev.capturecontext.arx.agentSetup.revoke")

	public static func directory(home: URL) -> URL {
		home.appending(path: "Library/Application Support/Arx/AgentClients", directoryHint: .isDirectory)
	}

	public static func file(
		for agent: Agent,
		home: URL
	) -> URL {
		directory(home: home).appending(path: agent.rawValue + ".json")
	}

	public static func read(
		_ agent: Agent,
		home: URL
	) -> Reply? {
		guard let data = try? Data(contentsOf: file(for: agent, home: home)) else { return nil }
		return try? JSONDecoder().decode(Reply.self, from: data)
	}

	/// Only this user can read the credential, including while it is being written.
	public static func write(
		_ reply: Reply,
		for agent: Agent,
		home: URL
	) throws {
		try RealHomeGuard.check(file(for: agent, home: home))
		let manager = FileManager.default
		let directory = directory(home: home)
		try manager.createDirectory(
			at: directory,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

		let temporary = directory.appending(path: UUID().uuidString)
		let data = try JSONEncoder().encode(reply)
		let isCreated = manager.createFile(
			atPath: temporary.path,
			contents: data,
			attributes: [.posixPermissions: 0o600]
		)
		guard isCreated else { throw CocoaError(.fileWriteUnknown) }

		let destination = file(for: agent, home: home)
		do {
			_ = try manager.replaceItemAt(destination, withItemAt: temporary)
		} catch {
			try? manager.removeItem(at: temporary)
			throw error
		}
	}

	public static func arguments(for agent: Agent) -> [String] {
		["mcp", "--client", agent.rawValue]
	}

	/// Adds or replaces Arx in a Codex `config.toml`, leaving everything else as it was.
	public static func addingCodexServer(
		command: String,
		to configuration: String
	) -> String {
		let kept = removingCodexServer(from: configuration)
		let block = codexServer(command: command)
		return kept.isEmpty ? block : kept.trimmingCharacters(in: .newlines) + "\n\n" + block
	}

	/// Removes Arx and its subtables from a Codex `config.toml`.
	public static func removingCodexServer(from configuration: String) -> String {
		var kept: [Substring] = []
		var isInArx = false
		for line in configuration.split(separator: "\n", omittingEmptySubsequences: false) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("[") {
				isInArx = trimmed == "[mcp_servers.arx]" || trimmed.hasPrefix("[mcp_servers.arx.")
			}
			if !isInArx { kept.append(line) }
		}
		let result = kept.joined(separator: "\n").trimmingCharacters(in: .newlines)
		return result.isEmpty ? "" : result + "\n"
	}

	/// The arguments `claude mcp add` takes to register Arx for every project of this user.
	public static func claudeAddArguments(command: String) -> [String] {
		["mcp", "add", "--scope", "user", "--transport", "stdio", "arx", "--", command] + arguments(for: .claude)
	}

	/// The arguments `claude mcp remove` takes to unregister Arx for this user.
	public static let claudeRemoveArguments: [String] = ["mcp", "remove", "--scope", "user", "arx"]

	/// Arx's own block in a Codex `config.toml`, exactly as ``addingCodexServer(command:to:)`` writes it.
	public static func codexServer(command: String) -> String {
		let arguments = arguments(for: .codex).map { "\"\($0)\"" }.joined(separator: ", ")
		return """
		[mcp_servers.arx]
		command = "\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
		args = [\(arguments)]
		tool_timeout_sec = 900

		"""
	}

	/// Arx's entry under `mcpServers`, as JSON text exactly as ``addingJSONServer(command:agent:to:)`` writes it.
	public static func jsonServerEntry(
		command: String,
		agent: Agent
	) -> String {
		let root: [String: Any] = ["mcpServers": ["arx": jsonServer(command: command, agent: agent)]]
		let data = try? JSONSerialization.data(withJSONObject: root, options: jsonOptions)
		return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
	}

	/// Adds or replaces Arx in a JSON `mcpServers` file, leaving everything else as it was.
	public static func addingJSONServer(
		command: String,
		agent: Agent,
		to configuration: Data?
	) throws -> Data {
		var root = try object(from: configuration)
		var servers = root["mcpServers"] as? [String: Any] ?? [:]
		servers["arx"] = jsonServer(command: command, agent: agent)
		root["mcpServers"] = servers
		return try JSONSerialization.data(withJSONObject: root, options: jsonOptions)
	}

	/// Whether a JSON `mcpServers` file already lists Arx.
	public static func containsJSONServer(_ configuration: Data?) -> Bool {
		guard let root = try? object(from: configuration)
		else { return false }

		return (root["mcpServers"] as? [String: Any])?["arx"] != nil
	}

	/// Whether a Codex `config.toml` already has Arx's table.
	public static func containsCodexServer(_ configuration: String) -> Bool {
		configuration
			.split(separator: "\n")
			.contains { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.arx]" }
	}

	/// Cursor's documentation marks `type` as required for stdio servers; Claude Desktop's examples leave it out.
	private static func jsonServer(
		command: String,
		agent: Agent
	) -> [String: Any] {
		var server: [String: Any] = ["command": command, "args": arguments(for: agent)]
		if agent == .cursor {
			server["type"] = "stdio"
		}
		return server
	}

	private static let jsonOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

	public static func removingJSONServer(from configuration: Data?) throws -> Data {
		var root = try object(from: configuration)
		var servers = root["mcpServers"] as? [String: Any] ?? [:]
		servers["arx"] = nil
		root["mcpServers"] = servers
		return try JSONSerialization.data(withJSONObject: root, options: jsonOptions)
	}

	private static func object(from configuration: Data?) throws -> [String: Any] {
		guard let configuration, !configuration.isEmpty else { return [:] }
		guard let object = try JSONSerialization.jsonObject(with: configuration) as? [String: Any]
		else { throw CocoaError(.fileReadCorruptFile) }
		return object
	}
}
