import BrowserAutomationClient
import Foundation
import _Dependencies

/// Finds the agent apps on this Mac and adds Arx to the ones that have a documented way.
///
/// Every app's entry runs the installed `arx` command as `arx mcp --client <agent>`, so a
/// configuration holds no secret: the app writes the agent's credential to its own private
/// file when the agent is connected (``AgentSetup``).
public struct AgentAppsClient: Sendable {
	/// Every supported app, installed or not, with how Arx would be added to it.
	public var detect: @Sendable () async -> [AgentApp]

	/// Adds Arx to the app the way ``AgentApp/change`` describes. Callers only invoke this
	/// after the person has seen that change and confirmed it.
	public var add: @Sendable (AgentSetup.Agent) async throws -> Void

	public init(
		detect: @escaping @Sendable () async -> [AgentApp],
		add: @escaping @Sendable (AgentSetup.Agent) async throws -> Void
	) {
		self.detect = detect
		self.add = add
	}
}

// MARK: - Types

public struct AgentApp: Equatable, Identifiable, Sendable {
	public var agent: AgentSetup.Agent

	/// Whether the app or its command was found on this Mac.
	public var isInstalled: Bool

	/// Whether its configuration already lists Arx.
	public var isConfigured: Bool

	/// What Add would change, or `nil` when the app has no supported way and only the snippet is offered.
	public var change: Change?

	/// What a person can paste to set it up by hand.
	public var snippet: String

	public init(
		agent: AgentSetup.Agent,
		isInstalled: Bool,
		isConfigured: Bool,
		change: Change?,
		snippet: String
	) {
		self.agent = agent
		self.isInstalled = isInstalled
		self.isConfigured = isConfigured
		self.change = change
		self.snippet = snippet
	}

	public var id: AgentSetup.Agent { agent }

	public enum Change: Equatable, Sendable {
		/// Runs the app's own command, which edits `file`.
		case command(line: String, file: String)

		/// Adds `entry` to `file` and keeps every other entry.
		case file(path: String, entry: String)

		/// The file that changes, written with `~` for the home folder.
		public var file: String {
			switch self {
			case let .command(_, file): file
			case let .file(path, _): path
			}
		}
	}
}

public enum AgentAppsFailure: Error, Equatable, Sendable {
	/// This run may not change other apps' configuration.
	case unavailable

	/// The app has no supported way to add Arx automatically.
	case unsupported

	/// The app's own command didn't succeed.
	case commandFailed
}

extension AgentAppsClient {
	/// A client that finds nothing and changes nothing, for automated runs.
	public static var unavailable: Self {
		.init(
			detect: { [] },
			add: { _ in throw AgentAppsFailure.unavailable }
		)
	}

	/// Works on `home` only, so tests can point it at a temporary folder.
	///
	/// - Parameters:
	///   - applicationFolders: Where app bundles are looked for, such as `/Applications`.
	///   - commandFolders: Where command-line tools such as `claude` are looked for.
	///   - run: Runs a command and returns its exit status.
	public static func files(
		home: URL,
		applicationFolders: [URL],
		commandFolders: [URL],
		run: @escaping @Sendable (URL, [String]) async -> Int32?
	) -> Self {
		let search: AgentAppsSearch = .init(
			home: home,
			applicationFolders: applicationFolders,
			commandFolders: commandFolders
		)
		return .init(
			detect: {
				AgentSetup.Agent.allCases.map(search.app)
			},
			add: { agent in
				switch agent {
				case .claude:
					guard let claude = search.command("claude")
					else { throw AgentAppsFailure.unsupported }

					// `claude` edits its own ~/.claude.json whatever `home` is, so a test may only
					// run a stand-in from outside the real home folder.
					try RealHomeGuard.check(home.appending(path: ".claude.json"))
					try RealHomeGuard.check(claude)

					// Clears an earlier registration; failing because there is none is expected.
					_ = await run(claude, AgentSetup.claudeRemoveArguments)
					let status: Int32? = await run(claude, AgentSetup.claudeAddArguments(command: search.launcher.path))
					guard status == 0
					else { throw AgentAppsFailure.commandFailed }

				case .claudeDesktop, .codex, .cursor:
					try AgentConfigFiles.add(agent, launcher: search.launcher, home: home)
				}

				// The connection stands without the skill; the server's instructions cover the basics.
				_ = try? AgentSkill.install(for: agent, home: home)
			}
		)
	}
}

/// Where each app and command is looked for under one home folder.
internal struct AgentAppsSearch: Sendable {
	internal var home: URL
	internal var applicationFolders: [URL]
	internal var commandFolders: [URL]

	internal init(
		home: URL,
		applicationFolders: [URL],
		commandFolders: [URL]
	) {
		self.home = home
		self.applicationFolders = applicationFolders
		self.commandFolders = commandFolders
	}

	/// The installed `arx` command every entry runs.
	internal var launcher: URL {
		CommandLineTool.url(home: home)
	}

	internal func app(_ agent: AgentSetup.Agent) -> AgentApp {
		let launcher: String = launcher.path
		let isConfigured: Bool = AgentConfigFiles.isConfigured(agent, home: home)
		switch agent {
		case .claude:
			let line: String = Self.commandLine(["claude"] + AgentSetup.claudeAddArguments(command: launcher))
			let claude: URL? = command("claude")
			return .init(
				agent: agent,
				isInstalled: claude != nil || exists(".claude"),
				isConfigured: isConfigured,
				change: claude == nil ? nil : .command(line: line, file: "~/.claude.json"),
				snippet: line
			)

		case .claudeDesktop:
			let entry: String = AgentConfigFiles.entry(for: agent, launcher: self.launcher)
			return .init(
				agent: agent,
				isInstalled: application("Claude") || exists("Library/Application Support/Claude"),
				isConfigured: isConfigured,
				change: .file(path: displayPath(for: agent), entry: entry),
				snippet: entry
			)

		case .codex:
			let entry: String = AgentConfigFiles.entry(for: agent, launcher: self.launcher)
			return .init(
				agent: agent,
				isInstalled: application("Codex") || command("codex") != nil || exists(".codex"),
				isConfigured: isConfigured,
				change: .file(path: displayPath(for: agent), entry: entry),
				snippet: entry
			)

		case .cursor:
			let entry: String = AgentConfigFiles.entry(for: agent, launcher: self.launcher)
			return .init(
				agent: agent,
				isInstalled: application("Cursor") || command("cursor") != nil || exists(".cursor"),
				isConfigured: isConfigured,
				change: .file(path: displayPath(for: agent), entry: entry),
				snippet: entry
			)
		}
	}

	/// The first executable named `name` in `commandFolders`.
	internal func command(_ name: String) -> URL? {
		commandFolders
			.map { $0.appending(path: name) }
			.first { FileManager.default.isExecutableFile(atPath: $0.path) }
	}

	private func application(_ name: String) -> Bool {
		applicationFolders.contains { folder in
			FileManager.default.fileExists(atPath: folder.appending(path: name + ".app").path)
		}
	}

	private func exists(_ relativePath: String) -> Bool {
		FileManager.default.fileExists(atPath: home.appending(path: relativePath).path)
	}

	private func displayPath(for agent: AgentSetup.Agent) -> String {
		AgentConfigFiles.relativePath(for: agent).map { "~/" + $0 } ?? ""
	}

	/// A shell command line, quoting arguments with spaces or shell characters.
	private static func commandLine(_ arguments: [String]) -> String {
		arguments.map { argument in
			let isPlain: Bool = argument.allSatisfy { character in
				character.isLetter || character.isNumber || "-_./:=@".contains(character)
			}
			return isPlain ? argument : "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
		}
		.joined(separator: " ")
	}
}

// MARK: - Dependency

extension AgentAppsClient: DependencyKey {
	/// The person's own home folder and apps. Automated runs get ``unavailable``,
	/// so they never read or write another app's configuration.
	public static var liveValue: Self {
		guard !isTesting else {
			reportIssue("AgentAppsClient.liveValue was used in a test. Supply AgentAppsClient.files(home:…) over a temporary folder.")
			return .unavailable
		}

		guard
			AgentToolsRun.isAllowed(
				environment: ProcessInfo.processInfo.environment,
				arguments: CommandLine.arguments,
				bundlePath: Bundle.main.bundlePath
			)
		else { return .unavailable }

		let home: URL = FileManager.default.homeDirectoryForCurrentUser
		return .files(
			home: home,
			applicationFolders: [
				URL(fileURLWithPath: "/Applications"),
				home.appending(path: "Applications"),
			],
			// Claude Code's native installer puts `claude` in ~/.local/bin; Homebrew and npm use the others.
			commandFolders: [
				home.appending(path: ".local/bin"),
				URL(fileURLWithPath: "/opt/homebrew/bin"),
				URL(fileURLWithPath: "/usr/local/bin"),
				home.appending(path: ".claude/local"),
			],
			run: { executable, arguments in
				await AgentToolsRun.run(executable, arguments: arguments, timeout: .seconds(30))?.status
			}
		)
	}

	/// Tests must supply their own client, so an unexpected call fails the test.
	public static var testValue: Self {
		.init(
			detect: unimplemented("AgentAppsClient.detect", placeholder: []),
			add: unimplemented("AgentAppsClient.add")
		)
	}

	/// Previews show every app installed and change nothing.
	public static var previewValue: Self {
		let search: AgentAppsSearch = .init(
			home: URL(fileURLWithPath: "/Users/preview", isDirectory: true),
			applicationFolders: [],
			commandFolders: []
		)
		return .init(
			detect: {
				AgentSetup.Agent.allCases.map { agent in
					var app: AgentApp = search.app(agent)
					app.isInstalled = true
					return app
				}
			},
			add: { _ in }
		)
	}
}

extension DependencyValues {
	public var agentApps: AgentAppsClient {
		get { self[AgentAppsClient.self] }
		set { self[AgentAppsClient.self] = newValue }
	}
}
