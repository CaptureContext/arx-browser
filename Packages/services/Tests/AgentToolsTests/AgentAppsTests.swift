import BrowserAutomationClient
import Foundation
import Testing
import _TestSupport

@testable import AgentToolsClient

/// Every configuration is written in a temporary home folder, never the person's own.
internal struct AgentAppsTests {
	// MARK: - Merging into existing files

	@Test
	internal func cursorKeepsItsOtherServersAndSettings() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }
		try world.write(".cursor/mcp.json", #"{"mcpServers":{"github":{"command":"gh-mcp","args":["serve"]}},"theme":"dark"}"#)

		try await world.client().add(.cursor)

		let root = try world.json(".cursor/mcp.json")
		#expect(root["theme"] as? String == "dark")
		let servers = try #require(root["mcpServers"] as? [String: Any])
		let github = try #require(servers["github"] as? [String: Any])
		#expect(github["command"] as? String == "gh-mcp")
		#expect(github["args"] as? [String] == ["serve"])
		let arx = try #require(servers["arx"] as? [String: Any])
		#expect(arx["command"] as? String == world.launcher.path)
		#expect(arx["args"] as? [String] == ["mcp", "--client", "cursor"])
		#expect(arx["type"] as? String == "stdio")
	}

	@Test
	internal func claudeDesktopKeepsItsOtherEntriesAndAddingAgainDoesNotDuplicate() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }
		let path: String = "Library/Application Support/Claude/claude_desktop_config.json"
		try world.write(path, #"{"globalShortcut":"Cmd+Space","mcpServers":{"files":{"command":"npx","args":["-y","fs"]}}}"#)

		try await world.client().add(.claudeDesktop)
		try await world.client().add(.claudeDesktop)

		let root = try world.json(path)
		#expect(root["globalShortcut"] as? String == "Cmd+Space")
		let servers = try #require(root["mcpServers"] as? [String: Any])
		#expect(Set(servers.keys) == ["files", "arx"])
		#expect((servers["arx"] as? [String: Any])?["args"] as? [String] == ["mcp", "--client", "claude-desktop"])
		// Written without escaped slashes, so the file stays readable.
		#expect(try world.read(path).contains(#"\/"#) == false)
	}

	@Test
	internal func codexKeepsItsOtherServers() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }
		let original: String = """
		model = "gpt-5"

		[mcp_servers.docs]
		command = "docs-mcp"
		args = []

		"""
		try world.write(".codex/config.toml", original)

		try await world.client().add(.codex)

		let written: String = try world.read(".codex/config.toml")
		#expect(written.hasPrefix(original.trimmingCharacters(in: .newlines)))
		#expect(written.contains("[mcp_servers.docs]\ncommand = \"docs-mcp\""))
		#expect(written.contains("[mcp_servers.arx]\ncommand = \"\(world.launcher.path)\""))
	}

	@Test
	internal func aFileThatIsNotJSONIsNeverReplaced() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }
		try world.write(".cursor/mcp.json", "// my notes\n")

		await #expect(throws: (any Error).self) { try await world.client().add(.cursor) }

		#expect(try world.read(".cursor/mcp.json") == "// my notes\n")
	}

	@Test
	internal func aMissingFileAndFolderAreCreated() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }

		try await world.client().add(.claudeDesktop)

		#expect(AgentConfigFiles.isConfigured(.claudeDesktop, home: world.home))
	}

	// MARK: - Detection and the shown change

	@Test
	internal func detectionFindsAppsAndShowsTheExactChange() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }
		try FileManager.default.createDirectory(at: world.applications.appending(path: "Cursor.app"), withIntermediateDirectories: true)
		try world.write(".codex/config.toml", "[mcp_servers.arx]\ncommand = \"arx\"\n")

		let apps: [AgentApp] = await world.client().detect()

		#expect(apps.map(\.agent) == AgentSetup.Agent.allCases)
		let cursor = try #require(apps.first { $0.agent == .cursor })
		#expect(cursor.isInstalled)
		#expect(!cursor.isConfigured)
		#expect(cursor.change == .file(
			path: "~/.cursor/mcp.json",
			entry: AgentSetup.jsonServerEntry(command: world.launcher.path, agent: .cursor)
		))

		let codex = try #require(apps.first { $0.agent == .codex })
		#expect(codex.isInstalled)
		#expect(codex.isConfigured)

		let desktop = try #require(apps.first { $0.agent == .claudeDesktop })
		#expect(!desktop.isInstalled)

		// Without its command, Claude Code only gets the snippet.
		let claude = try #require(apps.first { $0.agent == .claude })
		#expect(claude.change == nil)
		#expect(claude.snippet.hasPrefix("claude mcp add --scope user --transport stdio arx -- "))
	}

	// MARK: - Claude Code

	@Test
	internal func claudeCodeIsAddedThroughItsOwnCommand() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }
		let claude: URL = try world.makeCommand("claude")
		let calls: LockIsolated<[[String]]> = .init([])

		let client: AgentAppsClient = world.client { executable, arguments in
			#expect(executable == claude)
			calls.withValue { $0.append(arguments) }
			return 0
		}
		let app = try #require(await client.detect().first { $0.agent == .claude })
		#expect(app.isInstalled)
		#expect(app.change == .command(line: app.snippet, file: "~/.claude.json"))

		try await client.add(.claude)

		#expect(calls.value == [
			["mcp", "remove", "--scope", "user", "arx"],
			["mcp", "add", "--scope", "user", "--transport", "stdio", "arx", "--", world.launcher.path, "mcp", "--client", "claude"],
		])
	}

	@Test
	internal func aFailedClaudeCommandIsReported() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }
		_ = try world.makeCommand("claude")

		await #expect(throws: AgentAppsFailure.commandFailed) {
			try await world.client { _, _ in 1 }.add(.claude)
		}
	}

	@Test
	internal func claudeCodeWithoutItsCommandIsNotChanged() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }

		await #expect(throws: AgentAppsFailure.unsupported) {
			try await world.client { _, _ in
				Issue.record("Nothing should run")
				return 0
			}.add(.claude)
		}
	}
}

// MARK: - World

internal struct AppsWorld {
	internal let home: URL

	internal init() throws {
		self.home = FileManager.default.temporaryDirectory
			.appending(path: "AgentAppsTests-" + UUID().uuidString, directoryHint: .isDirectory)
			.resolvingSymlinksInPath()
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
	}

	internal var launcher: URL { CommandLineTool.url(home: home) }

	internal var applications: URL { home.appending(path: "Applications") }

	internal var commands: URL { home.appending(path: "bin") }

	internal func client(
		run: @escaping @Sendable (URL, [String]) async -> Int32? = { _, _ in
			Issue.record("Nothing should run")
			return nil
		}
	) -> AgentAppsClient {
		.files(
			home: home,
			applicationFolders: [applications],
			commandFolders: [commands],
			run: run
		)
	}

	internal func write(
		_ path: String,
		_ contents: String
	) throws {
		let url: URL = home.appending(path: path)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(contents.utf8).write(to: url)
	}

	internal func read(_ path: String) throws -> String {
		try String(contentsOf: home.appending(path: path), encoding: .utf8)
	}

	internal func json(_ path: String) throws -> [String: Any] {
		let data: Data = try Data(contentsOf: home.appending(path: path))
		return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
	}

	internal func makeCommand(_ name: String) throws -> URL {
		let url: URL = commands.appending(path: name)
		try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
		try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
		return url
	}

	internal func remove() {
		try? FileManager.default.removeItem(at: home)
	}
}
