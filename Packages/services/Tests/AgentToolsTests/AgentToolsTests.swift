import BrowserAutomationClient
import Foundation
import Testing
import _TestSupport

@testable import AgentToolsClient

/// Everything runs in a temporary home folder with stand-in helpers, never the person's own
/// `~/.local/bin` or agent configuration.
internal struct CommandLineToolTests {
	// MARK: - Install, update, uninstall

	@Test
	internal func installCopiesTheBundledHelper() async throws {
		let world: World = try .init()
		defer { world.remove() }
		let client: CommandLineToolClient = world.client()
		#expect(await client.status().installation == .notInstalled)

		try await client.install()

		#expect(await client.status().installation == .current)
		#expect(try String(contentsOf: world.installed, encoding: .utf8) == "arx-tool 1")
		#expect(try world.permissions(of: world.installed) == 0o755)
		#expect((try? FileManager.default.destinationOfSymbolicLink(atPath: world.installed.path)) == nil)
	}

	@Test
	internal func aNewerBundledHelperOffersUpdateAndUpdateReplacesIt() async throws {
		let world: World = try .init()
		defer { world.remove() }
		let client: CommandLineToolClient = world.client()
		try await client.install()

		try world.writeBundled("arx-tool 2")
		#expect(await client.status().installation == .outdated)

		try await client.install()
		#expect(await client.status().installation == .current)
		#expect(try String(contentsOf: world.installed, encoding: .utf8) == "arx-tool 2")
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: world.installed.deletingLastPathComponent().path)
		#expect(leftovers == ["arx"])
	}

	@Test
	internal func anOlderSetupLinkIsReplacedWithACopy() async throws {
		let world: World = try .init()
		defer { world.remove() }
		try FileManager.default.createDirectory(at: world.installed.deletingLastPathComponent(), withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(at: world.installed, withDestinationURL: world.bundled)
		let client: CommandLineToolClient = world.client()
		#expect(await client.status().installation == .outdated)

		try await client.install()

		#expect((try? FileManager.default.destinationOfSymbolicLink(atPath: world.installed.path)) == nil)
		#expect(await client.status().installation == .current)
	}

	@Test
	internal func uninstallRemovesOnlyArxsCopy() async throws {
		let world: World = try .init()
		defer { world.remove() }
		let client: CommandLineToolClient = world.client()
		try await client.install()

		try await client.uninstall()

		#expect(!FileManager.default.fileExists(atPath: world.installed.path))
		#expect(await client.status().installation == .notInstalled)
		// Uninstalling again is a no-op.
		try await client.uninstall()
	}

	@Test
	internal func someoneElsesArxIsNeverReplacedOrRemoved() async throws {
		let world: World = try .init()
		defer { world.remove() }
		try FileManager.default.createDirectory(at: world.installed.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("#!/bin/sh\necho mine\n".utf8).write(to: world.installed)
		let client: CommandLineToolClient = world.client()
		#expect(await client.status().installation == .blocked)

		await #expect(throws: CommandLineTool.Failure.occupied) { try await client.install() }
		await #expect(throws: CommandLineTool.Failure.occupied) { try await client.uninstall() }

		#expect(try String(contentsOf: world.installed, encoding: .utf8) == "#!/bin/sh\necho mine\n")
	}

	@Test
	internal func withoutABundledHelperNothingIsOffered() async throws {
		let world: World = try .init()
		defer { world.remove() }
		let client: CommandLineToolClient = .files(
			home: world.home,
			bundled: nil,
			shell: "/bin/zsh",
			loginPath: { nil },
			isArxTool: World.isArxTool
		)

		#expect(await client.status() == .unavailable)
		await #expect(throws: CommandLineTool.Failure.missingHelper) { try await client.install() }
		#expect(!FileManager.default.fileExists(atPath: world.installed.path))
	}

	// MARK: - PATH

	@Test
	internal func pathDetectionMatchesTheInstallFolderHoweverItIsWritten() {
		let home: URL = .init(fileURLWithPath: "/Users/someone", isDirectory: true)
		let folder: URL = CommandLineTool.url(home: home).deletingLastPathComponent()

		#expect(CommandLineTool.isOnPath(folder, path: "/usr/bin:/Users/someone/.local/bin:/bin", home: home))
		#expect(CommandLineTool.isOnPath(folder, path: "/Users/someone/.local/bin/", home: home))
		#expect(CommandLineTool.isOnPath(folder, path: "~/.local/bin:/usr/bin", home: home))
		#expect(!CommandLineTool.isOnPath(folder, path: "/usr/bin:/bin:/usr/sbin:/sbin", home: home))
		#expect(!CommandLineTool.isOnPath(folder, path: "/Users/someone/.local/bin/arx", home: home))
		#expect(!CommandLineTool.isOnPath(folder, path: "", home: home))
	}

	@Test
	internal func statusReportsThePathAndTheLineToAdd() async throws {
		let world: World = try .init()
		defer { world.remove() }

		let missing: CommandLineToolClient.Status = await world.client(path: "/usr/bin:/bin").status()
		#expect(missing.isOnPath == false)
		#expect(missing.pathAdvice == .init(profile: "~/.zshrc", line: #"export PATH="$HOME/.local/bin:$PATH""#))
		#expect(missing.location == "~/.local/bin/arx")

		let present: CommandLineToolClient.Status = await world.client(path: world.home.path + "/.local/bin:/usr/bin").status()
		#expect(present.isOnPath == true)

		let unknown: CommandLineToolClient.Status = await world.client(path: nil).status()
		#expect(unknown.isOnPath == nil)
	}

	@Test
	internal func eachShellGetsItsOwnProfile() {
		#expect(CommandLineTool.pathAdvice(shell: "/bin/bash").profile == "~/.bash_profile")
		#expect(CommandLineTool.pathAdvice(shell: "/opt/homebrew/bin/fish") == .init(
			profile: "~/.config/fish/config.fish",
			line: "fish_add_path $HOME/.local/bin"
		))
		#expect(CommandLineTool.pathAdvice(shell: nil).profile == "~/.profile")
	}

	// MARK: - Automated runs

	@Test
	internal func automatedRunsNeverTouchTheSystem() {
		let app: String = "/Applications/Arx.app"
		#expect(AgentToolsRun.isAllowed(environment: [:], arguments: ["Arx"], bundlePath: app))
		#expect(!AgentToolsRun.isAllowed(environment: [:], arguments: ["xctest"], bundlePath: "/usr/bin"))
		#expect(!AgentToolsRun.isAllowed(environment: [:], arguments: ["Tests"], bundlePath: "/tmp/Tests.xctest"))
		#expect(!AgentToolsRun.isAllowed(environment: ["XCTestConfigurationFilePath": "x"], arguments: ["Arx"], bundlePath: app))
		#expect(!AgentToolsRun.isAllowed(environment: ["ARX_ENGINE_PROFILE": "smoke"], arguments: ["Arx"], bundlePath: app))
		#expect(!AgentToolsRun.isAllowed(environment: ["ARX_SKIP_AGENT_TOOLS": "1"], arguments: ["Arx"], bundlePath: app))
		#expect(!AgentToolsRun.isAllowed(environment: [:], arguments: ["Arx", "--headless"], bundlePath: app))
		#expect(!AgentToolsRun.isAllowed(environment: [:], arguments: ["Arx", "--arx-smoke"], bundlePath: app))
	}

	/// Reaching a live client from a test is a test failure, and the client it returns is inert.
	/// This is what let an early test write `~/.cursor/mcp.json`: `swift test` sets no XCTest keys.
	/// Only read-only calls are made, so a broken guard can't change anything.
	@Test
	internal func liveClientsFailLoudlyInTests() async {
		await withKnownIssue {
			#expect(await CommandLineToolClient.liveValue.status() == .unavailable)
		}
		await withKnownIssue {
			#expect(await AgentAppsClient.liveValue.detect().isEmpty)
		}
	}

	// MARK: - Real home folder

	@Test
	internal func theGuardRecognizesTheRealHomeFolderHoweverItIsWritten() throws {
		let home: URL = .init(fileURLWithPath: "/Users/someone", isDirectory: true)

		#expect(RealHomeGuard.isInside(home, home: home))
		#expect(RealHomeGuard.isInside(home.appending(path: ".cursor/mcp.json"), home: home))
		#expect(RealHomeGuard.isInside(URL(fileURLWithPath: "/Users/someone/x/../.codex/config.toml"), home: home))
		#expect(!RealHomeGuard.isInside(URL(fileURLWithPath: "/Users/someoneelse/.cursor/mcp.json"), home: home))
		#expect(!RealHomeGuard.isInside(URL(fileURLWithPath: "/private/var/folders/x/T/home/.cursor"), home: home))

		// A temporary folder linked into the home folder still counts as inside it.
		let world: World = try .init()
		defer { world.remove() }
		let linkedHome: URL = world.home.appending(path: "someone", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: linkedHome, withIntermediateDirectories: true)
		let link: URL = world.home.appending(path: "link")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linkedHome)
		#expect(RealHomeGuard.isInside(link.appending(path: ".cursor/mcp.json"), home: linkedHome))
	}

	@Test
	internal func testsCantReachTheRealHomeFolder() async throws {
		let realHome: URL = FileManager.default.homeDirectoryForCurrentUser
		#expect(!RealHomeGuard.isInside(FileManager.default.temporaryDirectory, home: realHome))

		withKnownIssue {
			#expect(throws: RealHomeGuard.Violation.self) {
				try RealHomeGuard.check(realHome.appending(path: ".cursor/mcp.json"))
			}
		}

		// Uninstalling from a folder that doesn't exist: even a broken guard has nothing to remove.
		let world: World = try .init()
		defer { world.remove() }
		let missing: URL = realHome.appending(path: ".arx-guard-test-" + UUID().uuidString + "/arx")
		withKnownIssue {
			#expect(throws: RealHomeGuard.Violation.self) {
				try CommandLineTool.uninstall(missing, bundled: world.bundled, isArxTool: World.isArxTool)
			}
		}

		// Claude Code edits its own ~/.claude.json whatever home it's given; the runner only records.
		let claudeFolder: URL = world.home.appending(path: "bin")
		try FileManager.default.createDirectory(at: claudeFolder, withIntermediateDirectories: true)
		let claude: URL = claudeFolder.appending(path: "claude")
		try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claude)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
		let client: AgentAppsClient = .files(
			home: realHome,
			applicationFolders: [],
			commandFolders: [claudeFolder],
			run: { _, _ in
				Issue.record("Nothing should run against the real home folder")
				return 0
			}
		)
		await withKnownIssue {
			await #expect(throws: RealHomeGuard.Violation.self) { try await client.add(.claude) }
		}
	}
}

// MARK: - World

/// A temporary home folder and a stand-in bundled helper.
internal struct World {
	internal let home: URL
	internal let bundled: URL

	internal init() throws {
		self.home = FileManager.default.temporaryDirectory
			.appending(path: "AgentToolsTests-" + UUID().uuidString, directoryHint: .isDirectory)
			.resolvingSymlinksInPath()
		self.bundled = home.appending(path: "Arx.app/Contents/Helpers/ArxMCP")
		try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
		try writeBundled("arx-tool 1")
	}

	internal var installed: URL {
		CommandLineTool.url(home: home)
	}

	/// Stand-ins are recognized by their contents instead of a code signature.
	internal static let isArxTool: @Sendable (URL) -> Bool = { url in
		(try? String(contentsOf: url, encoding: .utf8))?.hasPrefix("arx-tool") == true
	}

	internal func writeBundled(_ contents: String) throws {
		try Data(contents.utf8).write(to: bundled)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
	}

	internal func client(path: String? = "/usr/bin:/bin") -> CommandLineToolClient {
		.files(
			home: home,
			bundled: bundled,
			shell: "/bin/zsh",
			loginPath: { path },
			isArxTool: Self.isArxTool
		)
	}

	internal func permissions(of url: URL) throws -> Int {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		return try #require(attributes[.posixPermissions] as? Int)
	}

	internal func remove() {
		try? FileManager.default.removeItem(at: home)
	}
}
