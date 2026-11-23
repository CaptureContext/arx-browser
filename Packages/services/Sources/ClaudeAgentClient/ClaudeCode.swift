import AgentClient
import Foundation

/// How Arx runs the person's own, unmodified Claude Code.
///
/// Anthropic doesn't let other apps offer a Claude sign-in or hold Claude credentials, but a
/// person may sign in to the unmodified Claude Code binary with their own subscription
/// (https://code.claude.com/docs/en/legal-and-compliance). So Arx never signs anyone in and
/// never reads a token: the person runs `claude auth login`, and Arx starts `claude` in print
/// mode for each turn (https://code.claude.com/docs/en/headless).
public enum ClaudeCode {
	/// Where the `claude` command is looked for, the same places as Arx's agent setup.
	public static func commandFolders(home: URL) -> [URL] {
		[
			home.appending(path: ".local/bin", directoryHint: .isDirectory),
			URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
			URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
			home.appending(path: ".claude/local", directoryHint: .isDirectory),
		]
	}

	public static func locate(in folders: [URL]) -> URL? {
		folders
			.map { $0.appending(path: "claude") }
			.first { FileManager.default.isExecutableFile(atPath: $0.path) }
	}

	/// The only variables `claude` receives.
	///
	/// Anything that would switch Claude Code to separately billed usage, such as
	/// `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` or a cloud
	/// provider switch, is left out, so a turn can only use the person's own sign-in.
	public static func environment(
		from base: [String: String],
		home: URL,
		executable: URL
	) -> [String: String] {
		let kept: Set<String> = ["USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SHELL"]
		var environment: [String: String] = base.filter { kept.contains($0.key) }
		environment["HOME"] = home.path
		environment["PATH"] = [
			executable.deletingLastPathComponent().path,
			"/usr/bin",
			"/bin",
			"/usr/sbin",
			"/sbin",
		].joined(separator: ":")
		return environment
	}

	/// The arguments for one turn. The prompt goes to standard input.
	///
	/// - Parameters:
	///   - session: Starts a new session with this identifier, or resumes it.
	///   - modelID: A Claude Code model alias or full name; `nil` uses the person's default.
	///   - effort: `nil` uses ``defaultEffort``.
	///   - toolConfiguration: The MCP configuration file with Arx's browser tools, if any.
	///   - input: ``InputFormat/streamJSON`` when the turn carries images or PDFs.
	public static func turnArguments(
		session: Session,
		modelID: String?,
		effort: AgentEffort?,
		toolConfiguration: URL?,
		input: InputFormat = .text
	) -> [String] {
		var arguments: [String] = [
			"--print",
			"--output-format", "stream-json",
			"--verbose",
			"--include-partial-messages",
			"--input-format", input.rawValue,
			// None of Claude Code's own tools: no shell, files or web access, only Arx's tools.
			"--tools", "",
			// Only settings from the empty working directory: the person's own hooks, plugins
			// and MCP servers stay out of browser chats.
			"--setting-sources", "local",
			"--strict-mcp-config",
			"--disable-slash-commands",
			// Anything not allowed below is refused instead of waiting for an answer.
			"--permission-mode", "dontAsk",
			"--system-prompt", AgentPrompt.guidance,
			// A quick assistant: modest reasoning and a few tool steps per message.
			"--effort", (effort ?? defaultEffort).rawValue,
			"--max-turns", String(maxTurns),
		]

		switch session {
		case let .new(id):
			arguments += ["--session-id", id.uuidString.lowercased()]

		case let .resume(token):
			arguments += ["--resume", token]
		}

		if let modelID {
			arguments += ["--model", modelID]
		}

		if let toolConfiguration {
			// Arx checks every call against the embedded agent's grants, the same as for outside agents.
			arguments += [
				"--mcp-config", toolConfiguration.path,
				"--allowedTools", "mcp__" + AgentBrowserAccess.Connection.serverName,
			]
		}

		return arguments
	}

	public static let defaultEffort: AgentEffort = .low

	/// How the prompt reaches standard input.
	public enum InputFormat: String, Sendable {
		/// The rendered prompt as plain text.
		case text

		/// One user message as JSON, with images and PDFs as content blocks
		/// (https://code.claude.com/docs/en/headless).
		case streamJSON = "stream-json"
	}

	/// The input format a turn with `attachments` needs.
	public static func inputFormat(for attachments: [AgentContextAttachment]) -> InputFormat {
		AgentPrompt.images(in: attachments).isEmpty && AgentPrompt.documents(in: attachments).isEmpty
		? .text
		: .streamJSON
	}

	/// What the turn writes to standard input: the rendered prompt, or for
	/// ``InputFormat/streamJSON`` one user message whose images and PDFs come before the text,
	/// as the Messages API recommends.
	public static func input(
		prompt: String,
		attachments: [AgentContextAttachment]
	) throws -> Data {
		let text: String = AgentPrompt.render(prompt, attachments: attachments)
		guard inputFormat(for: attachments) == .streamJSON
		else { return Data(text.utf8) }

		var content: [[String: Any]] = []
		for image in AgentPrompt.images(in: attachments) {
			content.append([
				"type": "image",
				"source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()],
			])
		}
		for document in AgentPrompt.documents(in: attachments) {
			content.append([
				"type": "document",
				"title": document.name,
				"source": ["type": "base64", "media_type": "application/pdf", "data": document.data.base64EncodedString()],
			])
		}
		content.append(["type": "text", "text": text])
		let message: [String: Any] = [
			"type": "user",
			"message": ["role": "user", "content": content],
		]
		var data: Data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
		data.append(0x0A)
		return data
	}

	/// Tool steps a single message may take, plus the final answer
	/// (https://code.claude.com/docs/en/agent-sdk/agent-loop).
	public static let maxTurns: Int = 12

	public enum Session: Equatable, Sendable {
		case new(UUID)
		case resume(String)
	}

	/// An MCP configuration that runs Arx's helper with the profile's credential.
	/// It's written to a private file so the credential never appears in a process listing.
	public static func toolConfiguration(_ connection: AgentBrowserAccess.Connection) throws -> Data {
		let server: [String: Any] = [
			"type": "stdio",
			"command": connection.helper.path,
			"args": [String](),
			"env": connection.credential.environment,
		]
		return try JSONSerialization.data(
			withJSONObject: ["mcpServers": [AgentBrowserAccess.Connection.serverName: server]],
			options: [.sortedKeys, .withoutEscapingSlashes]
		)
	}

	/// Claude Code's model aliases (https://code.claude.com/docs/en/cli-reference).
	/// Which ones a plan may use is up to Anthropic; an unavailable one fails the turn.
	public static let models: [AgentModel] = [
		.init(id: "opus", title: "Claude Opus", capabilities: modelCapabilities),
		.init(id: "sonnet", title: "Claude Sonnet", capabilities: modelCapabilities),
		.init(id: "haiku", title: "Claude Haiku", capabilities: modelCapabilities),
		.init(id: "fable", title: "Claude Fable", capabilities: modelCapabilities),
	]

	private static let modelCapabilities: Set<AgentModel.Capability> = [.browserTools, .streaming, .attachments]

	/// Instructions shown when nobody is signed in. Sign-in always happens in Claude Code itself.
	public static let signInInstructions: String = "Open Terminal and run: claude auth login"
}

// MARK: - Sign-in status

extension ClaudeCode {
	public static let authStatusArguments: [String] = ["auth", "status"]

	/// Reads `claude auth status`, which prints JSON and exits with 1 when nobody is signed in.
	///
	/// Only a claude.ai sign-in counts. API keys, key helpers and cloud providers are billed
	/// separately, so Arx reports them instead of using them.
	public static func account(from output: AgentProcessOutput) -> AgentAccount {
		let object: [String: Any] = (try? JSONSerialization.jsonObject(with: output.standardOutput)) as? [String: Any] ?? [:]
		let method: String? = object["authMethod"] as? String

		guard output.status == 0, let method, method != "none"
		else { return .init(provider: .claude, status: .signedOut(instructions: signInInstructions)) }

		guard method == "claude.ai"
		else { return .init(provider: .claude, status: .unsupportedSignIn(method: method)) }

		let identity: AgentAccount.Identity = .init(
			id: object["configDirectory"] as? String ?? "default",
			label: object["email"] as? String,
			plan: object["subscriptionType"] as? String
		)
		return .init(provider: .claude, status: .signedIn(identity))
	}

	/// The folder Claude Code keeps its sessions in, from `claude auth status`.
	public static func configurationDirectory(
		from output: AgentProcessOutput,
		home: URL
	) -> URL {
		let object: [String: Any]? = (try? JSONSerialization.jsonObject(with: output.standardOutput)) as? [String: Any]
		guard let path = object?["configDirectory"] as? String
		else { return home.appending(path: ".claude", directoryHint: .isDirectory) }

		return URL(fileURLWithPath: path, isDirectory: true)
	}

	/// The files Claude Code keeps for a session: `projects/<project>/<session>.jsonl` and
	/// a folder of the same name beside it.
	public static func transcripts(
		of session: UUID,
		in configuration: URL
	) -> [URL] {
		let projects: URL = configuration.appending(path: "projects", directoryHint: .isDirectory)
		let folders: [URL] = (try? FileManager.default.contentsOfDirectory(
			at: projects,
			includingPropertiesForKeys: nil
		)) ?? []
		let name: String = session.uuidString.lowercased()
		return folders.flatMap { folder in
			[folder.appending(path: name + ".jsonl"), folder.appending(path: name, directoryHint: .isDirectory)]
				.filter { FileManager.default.fileExists(atPath: $0.path) }
		}
	}
}
