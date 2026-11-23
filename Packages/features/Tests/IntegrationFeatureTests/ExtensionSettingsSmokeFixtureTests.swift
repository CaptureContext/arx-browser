#if DEBUG
@testable import AppFeature
import BrowserWorkspaceClient
import Foundation
import Testing

@Suite(.dependencies)
internal struct ExtensionSettingsSmokeFixtureTests {
	@Test
	func explicitFreshRootSeedsOnlyTheTwoOwnedProfilesAndRecordsOneCleanExit() throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let loaded = try #require(try fixture.load())
		try loaded.seedWorkspace()
		let saved = try BrowserWorkspaceClient(file: loaded.profile.appendingPathComponent("arx-workspace.json"))
			.loadWithRecovery()
		#expect(
			saved.organization?.profiles.map(\.id)
			== [ExtensionSettingsSmokeFixture.profileA, ExtensionSettingsSmokeFixture.profileB]
		)
		#expect(saved.organization?.spaces.map(\.id) == [ExtensionSettingsSmokeFixture.spaceA, ExtensionSettingsSmokeFixture.spaceB])
		#expect(saved.organization?.tabs.isEmpty == true)
		#expect(throws: ExtensionSettingsSmokeFixture.Failure.invalidFixture) { try fixture.load() }
		try loaded.recordCleanExit()
		#expect(
			try String(contentsOf: fixture.root.appendingPathComponent("completion.json"), encoding: .utf8)
			== "{\"status\":\"cleanExit\"}\n"
		)
		#expect(throws: ExtensionSettingsSmokeFixture.Failure.cleanup) { try loaded.recordCleanExit() }
	}

	@Test
	func relaunchReopensTheCleanlyExitedProfileWithoutReseedingAndRecordsItsOwnExit() throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let initial = try #require(try fixture.load())
		#expect(initial.phase == .initial)
		try initial.seedWorkspace()
		#expect(throws: ExtensionSettingsSmokeFixture.Failure.invalidFixture) { try fixture.load(relaunch: true) }
		try initial.recordCleanExit()

		let workspace = fixture.profile.appendingPathComponent("arx-workspace.json")
		let saved = try Data(contentsOf: workspace)
		let relaunch = try #require(try fixture.load(relaunch: true))
		#expect(relaunch.phase == .relaunch)
		#expect(relaunch.profile == initial.profile)
		try relaunch.seedWorkspace()
		#expect(try Data(contentsOf: workspace) == saved)
		#expect(throws: ExtensionSettingsSmokeFixture.Failure.invalidFixture) { try fixture.load() }

		try relaunch.recordCleanExit()
		#expect(
			try String(contentsOf: fixture.root.appendingPathComponent("relaunch-completion.json"), encoding: .utf8)
			== "{\"status\":\"cleanExit\"}\n"
		)
		#expect(throws: ExtensionSettingsSmokeFixture.Failure.invalidFixture) { try fixture.load(relaunch: true) }
	}

	@Test(arguments: ["missing-workspace", "missing-completion", "completion-permissions", "duplicate-relaunch-argument"])
	func relaunchRequiresTheInitialRunsProfileAndCleanExit(change: String) throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let initial = try #require(try fixture.load())
		try initial.seedWorkspace()
		try initial.recordCleanExit()
		var arguments = fixture.arguments + [ExtensionSettingsSmokeFixture.relaunchArgument]
		let completion = fixture.root.appendingPathComponent("completion.json")
		switch change {
		case "missing-workspace":
			try FileManager.default.moveItem(
				at: fixture.profile.appendingPathComponent("arx-workspace.json"),
				to: fixture.profile.appendingPathComponent("other.json")
			)

		case "missing-completion":
			try FileManager.default.removeItem(at: completion)

		case "completion-permissions":
			try fixture.permissions(completion, 0o644)

		default:
			arguments += [ExtensionSettingsSmokeFixture.relaunchArgument]
		}
		#expect(throws: (any Error).self) {
			try ExtensionSettingsSmokeFixture.load(
				environment: fixture.environment,
				arguments: arguments,
				application: fixture.application
			)
		}
	}

	@Test(arguments: [
		"environment", "argument", "duplicate-argument", "profile", "used-profile", "profile-symlink",
		"root-permissions", "marker-permissions", "marker-content", "configuration-symlink", "oversized-configuration",
		"package-symlink", "package-permissions", "mixed-mcp", "mixed-routing", "mixed-retirement", "mixed-external",
		"mixed-retirement-argument", "mixed-external-argument", "mixed-smoke", "wrong-application",
		"unpacked-symlink", "readable-unreadable-folder", "present-missing-folder",
	])
	func unsafeStartupCannotSeedOrFallBackToAnotherProfile(change: String) throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		var environment = fixture.environment
		var arguments = fixture.arguments
		var application = fixture.application
		switch change {
		case "environment":
			environment.removeValue(forKey: "ARX_EXTENSION_SETTINGS_SMOKE_ROOT")

		case "argument":
			arguments = ["Arx"]

		case "duplicate-argument":
			arguments += [ExtensionSettingsSmokeFixture.argument, fixture.root.path]

		case "profile":
			environment["ARX_ENGINE_PROFILE"] = fixture.root.path

		case "used-profile":
			try Data([1]).write(to: fixture.profile.appendingPathComponent("existing"))

		case "profile-symlink":
			try FileManager.default.removeItem(at: fixture.profile)
			try FileManager.default.createSymbolicLink(at: fixture.profile, withDestinationURL: fixture.root)

		case "root-permissions":
			try fixture.permissions(fixture.root, 0o755)

		case "marker-permissions":
			try fixture.permissions(fixture.marker, 0o644)

		case "marker-content":
			try Data([1]).write(to: fixture.marker)

		case "configuration-symlink":
			try FileManager.default.removeItem(at: fixture.configurationFile)
			try FileManager.default.createSymbolicLink(at: fixture.configurationFile, withDestinationURL: fixture.marker)

		case "oversized-configuration":
			try Data(repeating: 32, count: 8193).write(to: fixture.configurationFile)

		case "package-symlink":
			let package = fixture.root.appendingPathComponent("v1.crx")
			try FileManager.default.removeItem(at: package)
			try FileManager.default.createSymbolicLink(at: package, withDestinationURL: fixture.marker)

		case "package-permissions":
			try fixture.permissions(fixture.root.appendingPathComponent("v1.crx"), 0o644)

		case "unpacked-symlink":
			let folder = fixture.root.appendingPathComponent(ExtensionSettingsSmokeFixture.unpackedFolder)
			try FileManager.default.removeItem(at: folder)
			try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: fixture.profile)

		case "readable-unreadable-folder":
			try fixture.permissions(fixture.root.appendingPathComponent(ExtensionSettingsSmokeFixture.unreadableFolder), 0o700)

		case "present-missing-folder":
			try FileManager.default.createDirectory(
				at: fixture.root.appendingPathComponent(ExtensionSettingsSmokeFixture.missingFolder),
				withIntermediateDirectories: false
			)

		case "mixed-mcp":
			environment["ARX_MCP_SMOKE_ROOT"] = fixture.root.path

		case "mixed-routing":
			environment["ARX_ROUTING_SMOKE_ROOT"] = fixture.root.path

		case "mixed-retirement":
			environment["ARX_RETIREMENT_SMOKE_ROOT"] = fixture.root.path

		case "mixed-external":
			environment["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT"] = fixture.root.path

		case "mixed-retirement-argument":
			arguments += [ProfileRetirementSmoke.argument, fixture.root.path]

		case "mixed-external-argument":
			arguments += [ExternalConsentFixture.argument, fixture.root.path]

		case "mixed-smoke":
			environment["ARX_ENGINE_SMOKE_TITLE"] = "Unexpected"

		default:
			application = fixture.root.appendingPathComponent("other.app")
		}
		#expect(throws: (any Error).self) {
			try ExtensionSettingsSmokeFixture.load(environment: environment, arguments: arguments, application: application)
		}
		#expect(!FileManager.default.fileExists(atPath: fixture.profile.appendingPathComponent("arx-workspace.json").path))
	}

	@Test(arguments: [
		"zero-port", "remote-host", "https", "credentials", "query", "fragment",
		"path", "version", "identity", "package-hash", "extra-package",
	])
	func fixtureMetadataCannotSubstituteURLsIdentityOrPackageSet(change: String) throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.configurationFile)) as? [String: Any])
		var environment = fixture.environment
		var base = "http://127.0.0.1:48123/index.html"
		switch change {
		case "zero-port":
			base = "http://127.0.0.1:0/index.html"

		case "remote-host":
			base = "http://capturecontext.dev:48123/index.html"

		case "https":
			base = "https://127.0.0.1:48123/index.html"

		case "credentials":
			base = "http://user@127.0.0.1:48123/index.html"

		case "query":
			base += "?foreign=1"

		case "fragment":
			base += "#foreign"

		case "path":
			base = "http://127.0.0.1:48123/other.html"

		case "version":
			object["version"] = 2

		case "identity":
			object["extensionID"] = String(repeating: "q", count: 32)

		default:
			var packages = try #require(object["packages"] as? [String: String])
			packages[change == "extra-package" ? "foreign.crx" : "v1.crx"] = "invalid"
			object["packages"] = packages
		}
		object["baseURL"] = base
		environment["ARX_ENGINE_URL"] = base
		try JSONSerialization.data(withJSONObject: object).write(to: fixture.configurationFile)
		#expect(throws: (any Error).self) {
			try ExtensionSettingsSmokeFixture.load(environment: environment, arguments: fixture.arguments, application: fixture.application)
		}
	}

	@Test
	func applicationAuthorityFollowsActualBundleFileIdentity() throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let alias = fixture.root.appendingPathComponent("alias.app")
		try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.application)
		#expect(try ExtensionSettingsSmokeFixture.load(
			environment: fixture.environment,
			arguments: fixture.arguments,
			application: alias
		) != nil)
		let alternateCase = fixture.root.appendingPathComponent("arx.app")
		if FileManager.default.fileExists(atPath: alternateCase.path) {
			#expect(try ExtensionSettingsSmokeFixture.load(
				environment: fixture.environment,
				arguments: fixture.arguments,
				application: alternateCase
			) != nil)
		}
	}

	@Test
	func ordinaryStartupDoesNotOptIntoTheFixture() throws {
		#expect(try ExtensionSettingsSmokeFixture.load(
			environment: ["ARX_ENGINE_PROFILE": "/unused"],
			arguments: ["Arx"],
			application: URL(filePath: "/unused/Arx.app")
		) == nil)
	}

	private struct Fixture {
		internal let root: URL
		internal var application: URL { root.appendingPathComponent("Arx.app") }
		internal var profile: URL { root.appendingPathComponent("profile") }
		internal var marker: URL { root.appendingPathComponent(".arx-extension-settings-smoke") }
		internal var configurationFile: URL { root.appendingPathComponent("fixture.json") }
		internal var environment: [String: String] {
			[
				"ARX_EXTENSION_SETTINGS_SMOKE_ROOT": root.path,
				"ARX_ENGINE_PROFILE": profile.path,
				"ARX_ENGINE_URL": "http://127.0.0.1:48123/index.html",
			]
		}
		internal var arguments: [String] { ["Arx", ExtensionSettingsSmokeFixture.argument, root.path] }

		internal init() throws {
			self.root = URL.temporaryDirectory
				.resolvingSymlinksInPath()
				.appendingPathComponent("app-extension-install-smoke-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
			try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
			for path in [root, profile] { try permissions(path, 0o700) }
			try Data(ExtensionSettingsSmokeFixture.sentinel.utf8).write(to: marker)
			let packages = Dictionary(uniqueKeysWithValues: ExtensionSettingsSmokeFixture.packageNames.map { name in
				(name, String(repeating: "0", count: 64))
			})
			let configuration = ExtensionSettingsSmokeFixture.Configuration(
				application: application,
				baseURL: URL(string: "http://127.0.0.1:48123/index.html")!,
				extensionID: String(repeating: "a", count: 32),
				packages: packages
			)
			try JSONEncoder().encode(configuration).write(to: configurationFile)
			for name in ExtensionSettingsSmokeFixture.packageNames {
				let package = root.appendingPathComponent(name)
				try Data([1]).write(to: package)
				try permissions(package, 0o600)
			}
			for path in [marker, configurationFile] { try permissions(path, 0o600) }
			for (name, mode) in [
				(ExtensionSettingsSmokeFixture.unpackedFolder, 0o700),
				(ExtensionSettingsSmokeFixture.invalidFolder, 0o700),
				(ExtensionSettingsSmokeFixture.unreadableFolder, 0),
			] {
				let folder = root.appendingPathComponent(name)
				try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
				try permissions(folder, mode)
			}
		}

		internal func load(relaunch: Bool = false) throws -> ExtensionSettingsSmokeFixture? {
			let arguments = relaunch ? self.arguments + [ExtensionSettingsSmokeFixture.relaunchArgument] : self.arguments
			return try ExtensionSettingsSmokeFixture.load(environment: environment, arguments: arguments, application: application)
		}

		internal func permissions(
			_ url: URL,
			_ value: Int
		) throws {
			try FileManager.default.setAttributes([.posixPermissions: value], ofItemAtPath: url.path)
		}

		internal func remove() {
			try? permissions(root.appendingPathComponent(ExtensionSettingsSmokeFixture.unreadableFolder), 0o700)
			do {
				try FileManager.default.removeItem(at: root)
			} catch {
				Issue.record(error)
			}
		}
	}
}
#endif
