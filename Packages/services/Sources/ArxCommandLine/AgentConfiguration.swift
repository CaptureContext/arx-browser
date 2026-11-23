import AgentToolsClient
import BrowserAutomationClient
import Foundation
import _CommandLine

/// Adds and removes Arx in each agent's own configuration, leaving the rest of it alone.
internal enum AgentConfiguration {
	internal static func add(
		_ agent: AgentSetup.Agent,
		launcher: URL,
		home: URL
	) async throws {
		switch agent {
		case .claude:
			// Clears an earlier registration; failing because there is none is expected.
			_ = try? await runClaude(AgentSetup.claudeRemoveArguments)
			guard try await runClaude(AgentSetup.claudeAddArguments(command: launcher.path))
			else { throw Failure.claudeRefused }

		case .claudeDesktop, .codex, .cursor:
			try AgentConfigFiles.add(agent, launcher: launcher, home: home)
		}
	}

	/// Installs the `arx-browser` skill for agents that load skills from a folder. A failure
	/// here doesn't undo the connection: the server's own instructions cover the basics.
	internal static func addSkill(
		_ agent: AgentSetup.Agent,
		home: URL
	) -> URL? {
		do {
			return try AgentSkill.install(for: agent, home: home)
		} catch {
			Terminal.fail("Couldn't install the \(AgentSkill.name) skill: \(error)\n")
			return nil
		}
	}

	internal static func remove(
		_ agent: AgentSetup.Agent,
		home: URL
	) async throws {
		switch agent {
		case .claude:
			_ = try? await runClaude(AgentSetup.claudeRemoveArguments)

		case .claudeDesktop, .codex, .cursor:
			try AgentConfigFiles.remove(agent, home: home)
		}

		// Best effort: a skill that can't be deleted must not stop the credential being revoked.
		do {
			try AgentSkill.remove(for: agent, home: home)
		} catch {
			Terminal.fail("Couldn't remove the \(AgentSkill.name) skill: \(error)\n")
		}
	}

	private static func runClaude(_ arguments: [String]) async throws -> Bool {
		try await Subprocess.run(
			.name("claude"),
			arguments: .init(arguments),
			output: .discarded,
			error: .discarded
		).terminationStatus.isSuccess
	}

	private enum Failure: Error, CustomStringConvertible {
		case claudeRefused

		internal var description: String {
			"`claude mcp add` didn't succeed."
		}
	}
}

/// The `arx` command at `~/.local/bin/arx`: a copy of the app's helper, the same one
/// Arx's Install button puts there, so agents keep working if Arx moves.
internal enum Launcher {
	internal static func url(home: URL) -> URL {
		CommandLineTool.url(home: home)
	}

	internal static func install(home: URL) throws -> URL {
		let launcher = url(home: home)

		// Run from the PATH, `arguments[0]` is only "arx"; this is the file itself.
		guard let helper = Bundle.main.executableURL?.resolvingSymlinksInPath()
		else { throw CocoaError(.fileNoSuchFile) }

		// Already running the installed copy: there's nothing newer to copy.
		guard helper.standardizedFileURL != launcher.resolvingSymlinksInPath().standardizedFileURL
		else { return launcher }

		guard helper.lastPathComponent == CommandLineTool.helperName
		else { throw CocoaError(.fileNoSuchFile) }

		try CommandLineTool.install(from: helper, to: launcher, isArxTool: CommandLineTool.isSignedArxTool)
		return launcher
	}

	internal static func remove(home: URL) throws {
		let launcher = url(home: home)
		guard let helper = Bundle.main.executableURL?.resolvingSymlinksInPath()
		else { return }

		try CommandLineTool.uninstall(launcher, bundled: helper, isArxTool: CommandLineTool.isSignedArxTool)
	}

	internal static func isOnPath(_ launcher: URL) -> Bool {
		CommandLineTool.isOnPath(
			launcher.deletingLastPathComponent(),
			path: ProcessInfo.processInfo.environment["PATH"] ?? "",
			home: Terminal.home
		)
	}
}
