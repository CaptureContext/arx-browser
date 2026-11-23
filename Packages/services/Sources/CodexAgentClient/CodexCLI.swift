import AgentClient
import Foundation
import PDFKit

/// How Arx runs the person's own, unmodified Codex CLI.
///
/// The person signs in with `codex login`, OpenAI's own flow, and Codex keeps the login under
/// `~/.codex`. Arx never signs anyone in and never reads a credential: it only asks
/// `codex login status`, then starts `codex exec` for each turn, which reuses that sign-in
/// (https://learn.chatgpt.com/docs/non-interactive-mode).
public enum CodexCLI {
	/// Where the `codex` command is looked for.
	public static func commandFolders(home: URL) -> [URL] {
		[
			home.appending(path: ".local/bin", directoryHint: .isDirectory),
			URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
			URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
		]
	}

	public static func locate(in folders: [URL]) -> URL? {
		folders
			.map { $0.appending(path: "codex") }
			.first { FileManager.default.isExecutableFile(atPath: $0.path) }
	}

	/// The only variables `codex` receives.
	///
	/// Anything that would switch Codex to separately billed usage or other credentials, such
	/// as `CODEX_API_KEY`, `OPENAI_API_KEY`, `CODEX_ACCESS_TOKEN` or `CODEX_HOME`, is left out,
	/// so a turn can only use the person's own ChatGPT sign-in in `~/.codex`.
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

	/// The folder Codex keeps its sign-in and sessions in. Arx never sets `CODEX_HOME`.
	public static func configurationDirectory(home: URL) -> URL {
		home.appending(path: ".codex", directoryHint: .isDirectory)
	}

	// MARK: - Turns

	/// The arguments for one turn. The prompt goes to standard input.
	///
	/// - Parameters:
	///   - session: Starts a new thread, or resumes one by its identifier.
	///   - modelID: A Codex model slug; `nil` uses Codex's default.
	///   - effort: `nil` uses ``defaultEffort``.
	///   - trustedFolder: The turn's folder, when it holds Arx's browser tools in
	///     `.codex/config.toml`. Codex reads project configuration only from trusted folders.
	///   - images: Image files attached to the prompt, in order.
	public static func turnArguments(
		session: Session,
		modelID: String?,
		effort: AgentEffort?,
		trustedFolder: URL?,
		images: [URL] = []
	) -> [String] {
		// Images go first: `exec`'s `--image` takes several values, and the next flag ends them.
		var arguments: [String] = images.flatMap { ["--image", $0.path] }
		arguments += [
			"--json",
			"--skip-git-repo-check",
			// The person's own config.toml, with its MCP servers, hooks and features, stays out.
			// The sign-in still comes from ~/.codex.
			"--ignore-user-config",
			"--ignore-rules",
		]

		// None of Codex's own tools: no shell, images, sub-agents, goals, web or plugins.
		for feature in disabledFeatures {
			arguments += ["--disable", feature]
		}

		var settings: [String] = [
			// Writes are refused before they touch disk. `apply_patch` has no switch of its own.
			#"sandbox_mode="read-only""#,
			#"approval_policy="never""#,
			#"web_search="disabled""#,
			"tools.experimental_request_user_input.enabled=false",
			"skills.include_instructions=false",
			"skills.bundled.enabled=false",
			"project_root_markers=[]",
			// A quick assistant: modest reasoning.
			"model_reasoning_effort=" + tomlString((effort ?? defaultEffort).rawValue),
			"developer_instructions=" + tomlString(AgentPrompt.guidance),
		]
		if let trustedFolder {
			// Codex looks trust up by the canonical path of its working folder.
			settings.append("projects={" + tomlString(canonicalPath(trustedFolder)) + #"={trust_level="trusted"}}"#)
		}
		for setting in settings {
			arguments += ["-c", setting]
		}

		if let modelID {
			arguments += ["--model", modelID]
		}

		switch session {
		case .new:
			return ["exec"] + arguments + ["-"]

		case let .resume(threadID):
			return ["exec", "resume"] + arguments + [threadID, "-"]
		}
	}

	/// Where a turn's attached images go, inside the turn's own folder, removed with it.
	public static func imageFile(
		_ image: AgentFileAttachment,
		in folder: URL
	) -> URL {
		let fileExtension: String = switch image.mediaType {
		case "image/jpeg": "jpg"
		case "image/gif": "gif"
		case "image/webp": "webp"
		default: "png"
		}
		return folder
			.appending(path: "Attachments", directoryHint: .isDirectory)
			.appending(path: image.id.uuidString.lowercased() + "." + fileExtension)
	}

	/// Codex takes no documents, so a PDF reaches it as its text.
	public static func readable(_ attachments: [AgentContextAttachment]) -> [AgentContextAttachment] {
		attachments.map { attachment in
			guard
				let file = attachment.file,
				file.kind == .pdf,
				!file.data.isEmpty
			else { return attachment }

			let text: String = PDFDocument(data: file.data)?.string ?? ""
			var converted: AgentFileAttachment = file
			converted.kind = .text
			converted.mediaType = "text/plain"
			converted.data = Data(text.utf8)
			return .file(converted)
		}
	}

	/// Features that add Codex's own tools or load the person's own setup.
	public static let disabledFeatures: [String] = [
		"shell_tool",
		"unified_exec",
		"view_image",
		"image_generation",
		"multi_agent",
		"goals",
		"apps",
		"plugins",
		"hooks",
		"memories",
	]

	public static let defaultEffort: AgentEffort = .low

	/// Browser tool calls a single message may make. Codex has no turn cap of its own, so the
	/// adapter stops the turn when the agent starts one more.
	public static let maxTurns: Int = 12

	public enum Session: Equatable, Sendable {
		case new
		case resume(String)
	}

	/// Where a turn's tool configuration goes, inside the turn's own folder.
	public static func toolConfigurationFile(in folder: URL) -> URL {
		folder.appending(path: ".codex/config.toml")
	}

	/// A project configuration that runs Arx's helper with the profile's credential.
	///
	/// It's written to a private file, so the credential never appears in a process listing,
	/// and the helper gets it in its own environment, not Codex's. Tools are listed directly
	/// instead of behind tool search, and Codex doesn't ask before calling them: Arx checks
	/// every call against the embedded agent's grants, the same as for outside agents.
	public static func toolConfiguration(_ connection: AgentBrowserAccess.Connection) -> Data {
		let name: String = AgentBrowserAccess.Connection.serverName
		var lines: [String] = [
			"[mcp_servers.\(name)]",
			"command = " + tomlString(connection.helper.path),
			"args = []",
			"required = true",
			#"omit_tools_from = ["deferred", "code_mode"]"#,
			#"default_tools_approval_mode = "approve""#,
			"",
			"[mcp_servers.\(name).env]",
		]
		lines += connection.credential.environment
			.sorted { $0.key < $1.key }
			.map { tomlString($0.key) + " = " + tomlString($0.value) }
		return Data((lines.joined(separator: "\n") + "\n").utf8)
	}

	/// The path with every symbolic link resolved, such as `/var` to `/private/var`.
	public static func canonicalPath(_ url: URL) -> String {
		guard let resolved = realpath(url.path, nil)
		else { return url.path }

		defer { free(resolved) }
		return String(cString: resolved)
	}

	/// A TOML basic string.
	public static func tomlString(_ value: String) -> String {
		var result: String = "\""
		for scalar in value.unicodeScalars {
			switch scalar {
			case "\"": result += "\\\""
			case "\\": result += "\\\\"
			case "\n": result += "\\n"
			case "\r": result += "\\r"
			case "\t": result += "\\t"
			case _ where scalar.value < 0x20 || scalar.value == 0x7F:
				result += String(format: "\\u%04X", scalar.value)
			default: result.unicodeScalars.append(scalar)
			}
		}
		return result + "\""
	}

	/// Instructions shown when nobody is signed in. Sign-in always happens in Codex itself.
	public static let signInInstructions: String = "Open Terminal and run: codex login"
}

// MARK: - Sign-in status

extension CodexCLI {
	/// Runs `codex login status`, which prints to standard error, through `/bin/sh` so its
	/// text arrives on standard output.
	public static func authStatusInvocation(
		executable: URL,
		environment: [String: String]
	) -> AgentProcessInvocation {
		.init(
			executable: URL(fileURLWithPath: "/bin/sh"),
			arguments: ["-c", #"exec "$0" login status 2>&1"#, executable.path],
			environment: environment
		)
	}

	/// Reads `codex login status`, which exits with 1 when nobody is signed in.
	///
	/// Only a ChatGPT sign-in counts. API keys, access tokens and cloud providers are billed
	/// or managed separately, so Arx reports them instead of using them.
	public static func account(
		from output: AgentProcessOutput,
		home: URL
	) -> AgentAccount {
		let text: String = String(decoding: output.standardOutput, as: UTF8.self)
		guard output.status == 0, !text.contains("Not logged in")
		else { return .init(provider: .openAI, status: .signedOut(instructions: signInInstructions)) }

		guard text.contains("Logged in using ChatGPT") else {
			return .init(provider: .openAI, status: .unsupportedSignIn(method: signInMethod(text)))
		}

		let identity: AgentAccount.Identity = .init(id: configurationDirectory(home: home).path)
		return .init(provider: .openAI, status: .signedIn(identity))
	}

	private static func signInMethod(_ text: String) -> String {
		// More specific markers first: "Amazon Bedrock API key" also mentions an API key.
		let methods: [(marker: String, method: String)] = [
			("Bedrock", "bedrock"),
			("workload identity", "workload_identity"),
			("personal access token", "personal_access_token"),
			("access token", "access_token"),
			("API key", "api_key"),
		]
		return methods.first { text.contains($0.marker) }?.method ?? "unknown"
	}
}

// MARK: - Models and sessions

extension CodexCLI {
	/// `codex debug models` prints the catalog Codex itself picks from, refreshed for the
	/// signed-in plan. It's a debugging command, so any failure just leaves the default model.
	public static let modelsArguments: [String] = ["debug", "models"]

	/// The models Codex lists, in its own order. Hidden models are left out.
	public static func models(from output: AgentProcessOutput) -> [AgentModel] {
		guard
			output.status == 0,
			let object = (try? JSONSerialization.jsonObject(with: output.standardOutput)) as? [String: Any],
			let entries = object["models"] as? [[String: Any]]
		else { return [] }

		return entries
			.filter { $0["visibility"] as? String == "list" }
			.sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
			.compactMap { entry in
				guard let slug = entry["slug"] as? String
				else { return nil }

				return .init(
					id: slug,
					title: entry["display_name"] as? String ?? slug,
					capabilities: modelCapabilities
				)
			}
	}

	/// `codex exec --json` reports whole messages, not text as it's written.
	private static let modelCapabilities: Set<AgentModel.Capability> = [.browserTools, .attachments]

	/// Deletes a thread's transcript and its index rows. `--force` skips the confirmation
	/// Codex asks for in a terminal.
	public static func deleteInvocation(
		threadID: UUID,
		executable: URL,
		environment: [String: String]
	) -> AgentProcessInvocation {
		.init(
			executable: URL(fileURLWithPath: "/bin/sh"),
			arguments: [
				"-c", #"exec "$0" delete --force "$1" 2>&1"#,
				executable.path,
				threadID.uuidString.lowercased(),
			],
			environment: environment
		)
	}

	/// Whether `codex delete` succeeded or the thread was already gone.
	public static func isDeleted(_ output: AgentProcessOutput) -> Bool {
		output.status == 0
		|| String(decoding: output.standardOutput, as: UTF8.self).contains("No active or archived session found")
	}
}
