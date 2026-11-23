import BrowserAutomationClient
import Foundation
import Testing

@testable import ArxCommandLine

internal struct ArxCommandLineTests {
	@Test(arguments: [
		["setup", "bogus"],
		["remove", "bogus"],
		["status", "--bogus"],
		["mcp", "--client", "bogus"],
		["guide", "bogus"],
		["bogus"],
	])
	internal func usageMistakesExitWithTwo(arguments: [String]) async {
		#expect(await ArxCommandLine.main(arguments: arguments, environment: [:]) == 2)
	}

	@Test
	internal func bareWithoutTheServerVariablesIsAUsageMistake() async {
		#expect(await ArxCommandLine.main(arguments: [], environment: [:]) == 2)
	}

	@Test(arguments: [["--help"], ["help"], ["guide"], ["guide", "arx-google-sheets"], ["setup", "--help"]])
	internal func helpAndGuideExitWithZero(arguments: [String]) async {
		#expect(await ArxCommandLine.main(arguments: arguments, environment: [:]) == 0)
	}

	@Test
	internal func aTargetIsParsedAndCanBeLeftOut() throws {
		let named = try #require(try ArxCommand.parseAsRoot(["setup", "command"]) as? SetupCommand)
		#expect(named.target == .command)
		#expect(named.target?.agent == nil)

		let open = try #require(try ArxCommand.parseAsRoot(["remove"]) as? RemoveCommand)
		#expect(open.target == nil)
	}

	@Test
	internal func codexKeepsItsSettingsAndPermissionsAndCanBeUndone() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let original = "model = \"gpt\"\n"
		let file = home.appending(path: ".codex/config.toml")
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try original.write(to: file, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
		let launcher = home.appending(path: ".local/bin/arx")

		try await AgentConfiguration.add(.codex, launcher: launcher, home: home)

		let added = try String(contentsOf: file, encoding: .utf8)
		#expect(added.contains("model = \"gpt\""))
		#expect(added.contains(launcher.path))
		#expect(try permissions(of: file) == 0o600)

		try await AgentConfiguration.remove(.codex, home: home)

		#expect(try String(contentsOf: file, encoding: .utf8).contains(launcher.path) == false)
		#expect(try permissions(of: file) == 0o600)
	}

	@Test
	internal func aLinkedConfigurationStaysLinked() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let target = home.appending(path: "dotfiles-mcp.json")
		try Data("{\"mcpServers\":{\"other\":{}}}".utf8).write(to: target)
		let link = home.appending(path: ".cursor/mcp.json")
		try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

		try await AgentConfiguration.add(.cursor, launcher: home.appending(path: "arx"), home: home)

		#expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
		let written = try String(contentsOf: target, encoding: .utf8)
		#expect(written.contains("other"))
		#expect(written.contains("arx"))
	}

	@Test
	internal func unreadableConfigurationIsNotOverwritten() async throws {
		let home = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let file = home.appending(path: ".cursor/mcp.json")
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("not json".utf8).write(to: file)

		await #expect(throws: (any Error).self) {
			try await AgentConfiguration.add(.cursor, launcher: home.appending(path: "arx"), home: home)
		}

		#expect(try String(contentsOf: file, encoding: .utf8) == "not json")
	}

	private func temporaryHome() throws -> URL {
		let home = FileManager.default.temporaryDirectory
			.appending(path: UUID().uuidString, directoryHint: .isDirectory)
			.resolvingSymlinksInPath()
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
		return home
	}

	private func permissions(of url: URL) throws -> Int {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		return try #require(attributes[.posixPermissions] as? Int)
	}
}
