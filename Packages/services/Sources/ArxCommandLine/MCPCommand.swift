import BrowserAutomationClient
import BrowserMCPServer
import Foundation
import _CommandLine

internal struct MCPCommand: AsyncParsableCommand {
	internal static let configuration: CommandConfiguration = .init(
		commandName: "mcp",
		abstract: "Arx's tools over MCP, on stdin and stdout."
	)

	@Option(help: "The connected agent to serve: claude, claude-desktop, codex or cursor.")
	internal var client: AgentSetup.Agent?

	internal init() {}

	internal func run() async throws {
		guard let client else {
			await BrowserMCPServer.run(environment: ProcessInfo.processInfo.environment)
			return
		}
		guard let credential = AgentSetup.read(client, home: Terminal.home)?.credential else {
			Terminal.fail("\(client.title) isn't connected to Arx. Run: arx setup \(client.rawValue)\n")
			throw ExitCode.needsPerson
		}
		await BrowserMCPServer.run(environment: credential.environment)
	}
}

extension AgentSetup.Agent: ExpressibleByArgument {}
