import BrowserAutomationClient
import Files
import Foundation

/// Each agent app's documented MCP configuration file, and adding Arx to it without
/// touching anything else in the file.
///
/// Writes go through Files, so a linked file stays linked and keeps its permissions,
/// and a file that can't be read is never replaced.
public enum AgentConfigFiles {
	/// The user-level file, relative to the home folder. `nil` for Claude Code, whose own
	/// `claude mcp add` is the documented way to add a server.
	///
	/// - Claude Desktop: https://modelcontextprotocol.io/docs/develop/connect-local-servers
	/// - Codex: https://learn.chatgpt.com/docs/extend/mcp (the CLI, IDE extension and app share it)
	/// - Cursor: https://cursor.com/docs/context/mcp
	public static func relativePath(for agent: AgentSetup.Agent) -> String? {
		switch agent {
		case .claude: nil
		case .claudeDesktop: "Library/Application Support/Claude/claude_desktop_config.json"
		case .codex: ".codex/config.toml"
		case .cursor: ".cursor/mcp.json"
		}
	}

	public static func url(
		for agent: AgentSetup.Agent,
		home: URL
	) -> URL? {
		relativePath(for: agent).map { home.appending(path: $0) }
	}

	/// Arx's own entry, exactly as ``add(_:launcher:home:)`` writes it.
	public static func entry(
		for agent: AgentSetup.Agent,
		launcher: URL
	) -> String {
		switch agent {
		case .codex:
			AgentSetup.codexServer(command: launcher.path)

		case .claude, .claudeDesktop, .cursor:
			AgentSetup.jsonServerEntry(command: launcher.path, agent: agent)
		}
	}

	/// Adds or replaces Arx in the agent's file, creating the file and its folder if needed.
	public static func add(
		_ agent: AgentSetup.Agent,
		launcher: URL,
		home: URL
	) throws {
		guard let path = relativePath(for: agent)
		else { return }

		try RealHomeGuard.check(home.appending(path: path))
		let file = try createFile(at: path, home: home)
		switch agent {
		case .codex:
			try file.write(AgentSetup.addingCodexServer(command: launcher.path, to: file.readAsString()))

		case .claude, .claudeDesktop, .cursor:
			try file.write(AgentSetup.addingJSONServer(command: launcher.path, agent: agent, to: file.read()))
		}
	}

	/// Removes Arx from the agent's file, if the file exists.
	public static func remove(
		_ agent: AgentSetup.Agent,
		home: URL
	) throws {
		guard
			let path = relativePath(for: agent),
			let file = try? Folder(path: home.path).file(at: path)
		else { return }

		try RealHomeGuard.check(home.appending(path: path))
		switch agent {
		case .codex:
			try file.write(AgentSetup.removingCodexServer(from: file.readAsString()))

		case .claude, .claudeDesktop, .cursor:
			try file.write(AgentSetup.removingJSONServer(from: file.read()))
		}
	}

	/// Whether the agent's configuration already lists Arx. Claude Code keeps user-level
	/// servers in `~/.claude.json`, which is only read here, never written.
	public static func isConfigured(
		_ agent: AgentSetup.Agent,
		home: URL
	) -> Bool {
		switch agent {
		case .claude:
			return AgentSetup.containsJSONServer(try? Data(contentsOf: home.appending(path: ".claude.json")))

		case .codex:
			guard
				let url = url(for: agent, home: home),
				let text = try? String(contentsOf: url, encoding: .utf8)
			else { return false }

			return AgentSetup.containsCodexServer(text)

		case .claudeDesktop, .cursor:
			return AgentSetup.containsJSONServer(url(for: agent, home: home).flatMap { try? Data(contentsOf: $0) })
		}
	}

	private static func createFile(
		at path: String,
		home: URL
	) throws -> File {
		let components: [String] = path.split(separator: "/").map(String.init)
		let folder: Folder = try components.dropLast().reduce(Folder(path: home.path)) { folder, name in
			try folder.createSubfolderIfNeeded(withName: name)
		}
		return try folder.createFileIfNeeded(withName: components.last ?? path)
	}
}
