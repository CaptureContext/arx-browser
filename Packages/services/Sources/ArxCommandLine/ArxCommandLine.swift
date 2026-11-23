import AgentToolsClient
import BrowserMCPServer
import Foundation
import _CommandLine

/// The `arx` command: connects agents to Arx's MCP server, and is that server for them.
///
/// Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person.
public enum ArxCommandLine {
	/// Started bare with the variables the app's copied configuration sets, this is that server.
	public static func main(
		arguments: [String] = Array(CommandLine.arguments.dropFirst()),
		environment: [String: String] = ProcessInfo.processInfo.environment
	) async -> Int32 {
		guard !arguments.isEmpty else {
			if environment["ARX_MCP_SOCKET"] != nil {
				await BrowserMCPServer.run(environment: environment)
				return ExitCode.success.rawValue
			}
			Terminal.fail(ArxCommand.helpMessage() + "\n")
			return ExitCode.usage.rawValue
		}

		do {
			var command = try ArxCommand.parseAsRoot(arguments)
			if var command = command as? any AsyncParsableCommand {
				try await command.run()
			} else {
				try command.run()
			}
			return ExitCode.success.rawValue
		} catch {
			return report(error)
		}
	}

	private static func report(_ error: any Error) -> Int32 {
		let code = ArxCommand.exitCode(for: error)
		let message = ArxCommand.fullMessage(for: error)
		if !message.isEmpty {
			if code == .success {
				Terminal.write(message + "\n")
			} else {
				Terminal.fail(message + "\n")
			}
		}

		// ArgumentParser's own usage failures use sysexits; `arx` documents 2.
		return code == .validationFailure ? ExitCode.usage.rawValue : code.rawValue
	}
}

extension ExitCode {
	internal static let usage: ExitCode = .init(2)
	internal static let needsPerson: ExitCode = .init(3)
}

internal struct ArxCommand: ParsableCommand {
	internal static let configuration: CommandConfiguration = .init(
		commandName: "arx",
		abstract: "Arx, the browser, from a terminal.",
		discussion: "Exit codes: 0 done, 1 failed, 2 usage, 3 needs you.",
		subcommands: [
			SetupCommand.self,
			RemoveCommand.self,
			StatusCommand.self,
			GuideCommand.self,
			MCPCommand.self,
		]
	)

	internal init() {}
}

internal struct GuideCommand: ParsableCommand {
	internal static let configuration: CommandConfiguration = .init(
		commandName: "guide",
		abstract: "How to use this, for an agent."
	)

	private static let text: String = """
	Arx is a browser. Its MCP server gives an agent tools for tabs, spaces and pages.

	Connect with `arx setup claude`, `arx setup claude-desktop`, `arx setup codex` or
	`arx setup cursor`. A person confirms it in Arx, and the new client can do nothing until they grant it access under Settings > Advanced >
	Local assistants (MCP). Restart the agent afterwards. Changing a grant disconnects its session.

	An agent can't approve its own setup or grants. Exit code 3 means a person didn't approve.
	`arx status --json` reports whether the server is running. `arx remove` undoes everything.
	For Claude Code and Codex, `arx setup` also installs the \(AgentSkill.name) skill (version \(AgentSkill.version)), printed below,
	and a skill for each of these sites. `arx guide <name>` prints one:
	\(AgentSiteSkill.all.map { "- \($0.name): \($0.sites.joined(separator: ", "))" }.joined(separator: "\n"))

	"""

	@Argument(help: "A site skill to print, such as arx-google-sheets. Leave it out for the guide.")
	internal var skill: String?

	internal init() {}

	internal func validate() throws {
		guard let skill, AgentSiteSkill.named(skill) == nil
		else { return }

		throw ValidationError(
			"No site skill named \(skill). Name one of: \(AgentSiteSkill.all.map(\.name).joined(separator: ", "))."
		)
	}

	internal func run() {
		if let skill = skill.flatMap(AgentSiteSkill.named) {
			Terminal.write(skill.text + "\n")
			return
		}
		Terminal.write(Self.text + "\n" + AgentSkill.text + "\n")
	}
}

internal enum Terminal {
	internal static var home: URL {
		let environment = ProcessInfo.processInfo.environment
		return URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
	}

	internal static var isInteractive: Bool {
		isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
	}

	internal static func write(_ text: String) {
		FileHandle.standardOutput.write(Data(text.utf8))
	}

	internal static func fail(_ text: String) {
		FileHandle.standardError.write(Data(text.utf8))
	}
}
