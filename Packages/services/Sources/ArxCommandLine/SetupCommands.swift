import AgentToolsClient
import AppKit
import BrowserAutomationClient
import BrowserCore
import Foundation
import _CommandLine

/// What `arx setup` and `arx remove` act on: an agent, or the command itself.
internal enum SetupTarget: String, CaseIterable, ExpressibleByArgument, Sendable {
	case claude
	case claudeDesktop = "claude-desktop"
	case codex
	case cursor
	case command

	internal var agent: AgentSetup.Agent? {
		AgentSetup.Agent(rawValue: rawValue)
	}

	internal var title: String {
		agent?.title ?? "The arx command"
	}

	/// Asks only at a terminal, so an agent running this never waits on a prompt.
	/// Choosing here isn't approval: connecting an agent is still confirmed in Arx.
	internal static func resolve(
		_ target: Self?,
		asking message: String
	) throws -> Self {
		if let target { return target }
		guard Terminal.isInteractive else {
			Terminal.fail("Name one of: \(allCases.map(\.rawValue).joined(separator: ", ")).\n")
			throw ExitCode.usage
		}
		do {
			return try Promptberry.select(
				message,
				options: allCases.map { SelectOption(value: $0, label: $0.title) }
			)
		} catch is PromptCancelled {
			throw ExitCode.needsPerson
		}
	}
}

internal struct SetupCommand: AsyncParsableCommand {
	internal static let configuration: CommandConfiguration = .init(
		commandName: "setup",
		abstract: "Connect an agent, or put arx on the PATH."
	)

	private static let approvalTimeout: Duration = .seconds(180)

	@Argument(help: "What to set up. Asks at a terminal when left out.")
	internal var target: SetupTarget?

	internal init() {}

	internal func run() async throws {
		let target = try SetupTarget.resolve(target, asking: "What should Arx set up?")
		let home = Terminal.home
		do {
			let launcher = try Launcher.install(home: home)
			guard let agent = target.agent else {
				Terminal.write("arx is at \(launcher.path)\n")
				if !Launcher.isOnPath(launcher) {
					Terminal.write("Add \(launcher.deletingLastPathComponent().path) to your PATH to run it from anywhere.\n")
				}
				return
			}
			guard await requestApproval(for: agent, home: home) else {
				Terminal.fail("Not connected: nobody approved it in Arx.\n")
				throw ExitCode.needsPerson
			}
			try await AgentConfiguration.add(agent, launcher: launcher, home: home)
			if let skill = AgentConfiguration.addSkill(agent, home: home) {
				Terminal.write(
					"Installed the \(AgentSkill.name) skill at \(skill.path), with \(AgentSiteSkill.all.count) site skills beside it.\n"
				)
			}
			Terminal.write("Connected \(agent.title). Grant it access in Arx under Settings > Advanced > Local assistants (MCP), then restart it.\n")
		} catch let exit as ExitCode {
			throw exit
		} catch {
			Terminal.fail("Setup failed: \(error)\n")
			throw ExitCode.failure
		}
	}

	/// Waits for the running app's answer, opening Arx first if it isn't running.
	private func requestApproval(
		for agent: AgentSetup.Agent,
		home: URL
	) async -> Bool {
		let request = AgentSetup.Request(id: UUID(), agent: agent)
		if !ArxApplication.isRunning {
			await ArxApplication.open()
			try? await Task.sleep(for: .seconds(3))
		}
		Terminal.write("Confirm connecting \(agent.title) in Arx…\n")
		DistributedNotificationCenter.default().postNotificationName(
			AgentSetup.requestNotification,
			object: nil,
			userInfo: request.userInfo,
			deliverImmediately: true
		)
		let deadline = ContinuousClock.now + Self.approvalTimeout
		while ContinuousClock.now < deadline {
			if let reply = AgentSetup.read(agent, home: home), reply.requestID == request.id {
				if reply.credential == nil {
					try? FileManager.default.removeItem(at: AgentSetup.file(for: agent, home: home))
				}
				return reply.credential != nil
			}
			try? await Task.sleep(for: .milliseconds(250))
		}
		return false
	}
}

internal struct RemoveCommand: AsyncParsableCommand {
	internal static let configuration: CommandConfiguration = .init(
		commandName: "remove",
		abstract: "Take an agent or the arx command out again."
	)

	@Argument(help: "What to remove. Asks at a terminal when left out.")
	internal var target: SetupTarget?

	internal init() {}

	internal func run() async throws {
		let target = try SetupTarget.resolve(target, asking: "What should Arx remove?")
		let home = Terminal.home
		do {
			guard let agent = target.agent else {
				try Launcher.remove(home: home)
				Terminal.write("Removed \(Launcher.url(home: home).path)\n")
				return
			}
			try await AgentConfiguration.remove(agent, home: home)
			if let clientID = AgentSetup.read(agent, home: home)?.credential?.clientID {
				DistributedNotificationCenter.default().postNotificationName(
					AgentSetup.revokeNotification,
					object: nil,
					userInfo: ["clientID": clientID.uuidString],
					deliverImmediately: true
				)
			}
			try? FileManager.default.removeItem(at: AgentSetup.file(for: agent, home: home))
			Terminal.write("Removed \(agent.title).\n")
		} catch {
			Terminal.fail("Remove failed: \(error)\n")
			throw ExitCode.failure
		}
	}
}

internal struct StatusCommand: ParsableCommand {
	internal static let configuration: CommandConfiguration = .init(
		commandName: "status",
		abstract: "Whether Arx and its MCP server are running, and who's connected."
	)

	@Flag(help: "Print JSON.")
	internal var json: Bool = false

	internal init() {}

	internal func run() throws {
		let home = Terminal.home
		let isRunning = ArxApplication.isRunning
		let connected = AgentSetup.Agent.allCases.filter { AgentSetup.read($0, home: home)?.credential != nil }
		let socket = connected.lazy.compactMap { AgentSetup.read($0, home: home)?.credential?.socket }.first
		let isServing = isRunning && socket.map(FileManager.default.fileExists(atPath:)) == true
		guard json else {
			Terminal.write("Arx: \(isRunning ? "running" : "not running")\n")
			Terminal.write("MCP server: \(isServing ? "running" : "not confirmed running")\n")
			Terminal.write("Agents: \(connected.isEmpty ? "none" : connected.map(\.title).joined(separator: ", "))\n")
			return
		}
		let object: [String: Any] = [
			"running": isRunning,
			"serving": isServing,
			"agents": connected.map(\.rawValue),
		]
		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		Terminal.write(String(decoding: data, as: UTF8.self) + "\n")
	}
}

internal enum ArxApplication {
	/// The app around this command, or the installed Arx for a copy in `~/.local/bin`.
	private static let bundleID: String = ArxEdition.current.bundleIdentifier

	internal static var isRunning: Bool {
		!NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
	}

	internal static func open() async {
		_ = try? await Subprocess.run(
			.path("/usr/bin/open"),
			arguments: ["-b", bundleID],
			output: .discarded,
			error: .discarded
		)
	}
}
