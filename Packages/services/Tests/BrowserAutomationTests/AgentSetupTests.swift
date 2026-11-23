import BrowserAutomationClient
import CustomDump
import Foundation
import Testing

internal struct AgentSetupTests {
	@Test
	internal func codexKeepsEverythingElseAndCanBeUndone() {
		let original = """
		model = "gpt"

		[mcp_servers.other]
		command = "other"

		[tui]
		theme = "dark"

		"""
		let added = AgentSetup.addingCodexServer(command: "/Users/me/.local/bin/arx", to: original)
		#expect(added.contains("[mcp_servers.arx]"))
		#expect(added.contains(#"args = ["mcp", "--client", "codex"]"#))
		#expect(added.contains("tool_timeout_sec = 900"))
		#expect(added.contains("[mcp_servers.other]"))
		#expect(added.contains(#"theme = "dark""#))

		// Running it again replaces rather than duplicates.
		let again = AgentSetup.addingCodexServer(command: "/elsewhere/arx", to: added)
		expectNoDifference(again.components(separatedBy: "[mcp_servers.arx]").count, 2)
		#expect(again.contains("/elsewhere/arx"))
		#expect(!again.contains("/Users/me"))

		expectNoDifference(AgentSetup.removingCodexServer(from: added), original)
	}

	@Test
	internal func codexRemovalTakesSubtablesAndStopsAtTheNextTable() {
		let configuration = """
		[mcp_servers.arx]
		command = "arx"
		[mcp_servers.arx.env]
		A = "1"
		[mcp_servers.arxiv]
		command = "keep"

		"""
		let removed = AgentSetup.removingCodexServer(from: configuration)
		expectNoDifference(removed, "[mcp_servers.arxiv]\ncommand = \"keep\"\n")
	}

	@Test
	internal func jsonKeepsOtherServersAndSettings() throws {
		let original = Data(#"{"mcpServers":{"other":{"command":"o"}},"theme":"dark"}"#.utf8)
		let added = try AgentSetup.addingJSONServer(command: "/bin/arx", agent: .cursor, to: original)
		let object = try #require(try JSONSerialization.jsonObject(with: added) as? [String: Any])
		expectNoDifference(object["theme"] as? String, "dark")
		let servers = try #require(object["mcpServers"] as? [String: Any])
		#expect(servers["other"] != nil)
		let arx = try #require(servers["arx"] as? [String: Any])
		expectNoDifference(arx["args"] as? [String], ["mcp", "--client", "cursor"])

		let removed = try AgentSetup.removingJSONServer(from: added)
		let remaining = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
		#expect((remaining["mcpServers"] as? [String: Any])?["arx"] == nil)
		#expect((remaining["mcpServers"] as? [String: Any])?["other"] != nil)

		// A file that isn't an object is reported rather than overwritten.
		#expect(throws: (any Error).self) {
			try AgentSetup.addingJSONServer(command: "/bin/arx", agent: .cursor, to: Data("[]".utf8))
		}
	}

	@Test
	internal func credentialFileIsPrivateAndRoundTrips() throws {
		let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: home) }
		let reply = AgentSetup.Reply(
			requestID: UUID(),
			credential: .init(socket: "/tmp/ipc.sock", clientID: UUID(), token: "secret")
		)
		try AgentSetup.write(reply, for: .claude, home: home)
		expectNoDifference(AgentSetup.read(.claude, home: home), reply)

		let attributes = try FileManager.default.attributesOfItem(atPath: AgentSetup.file(for: .claude, home: home).path)
		expectNoDifference(attributes[.posixPermissions] as? Int, 0o600)
		let directory = try FileManager.default.attributesOfItem(atPath: AgentSetup.directory(home: home).path)
		expectNoDifference(directory[.posixPermissions] as? Int, 0o700)

		// Setting up again replaces the file.
		try AgentSetup.write(.init(requestID: reply.requestID, credential: nil), for: .claude, home: home)
		#expect(AgentSetup.read(.claude, home: home)?.credential == nil)
		expectNoDifference(reply.credential?.environment["ARX_MCP_CREDENTIAL"], "secret")
	}

	@Test
	internal func requestRoundTripsThroughItsNotification() {
		let request = AgentSetup.Request(id: UUID(), agent: .codex)
		expectNoDifference(AgentSetup.Request(userInfo: request.userInfo), request)
		#expect(AgentSetup.Request(userInfo: ["id": "nope", "agent": "codex"]) == nil)
		#expect(AgentSetup.Request(userInfo: nil) == nil)
	}
}
