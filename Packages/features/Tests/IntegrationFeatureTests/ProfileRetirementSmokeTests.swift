#if DEBUG
import BrowserCore
import BrowserWorkspaceClient
import Foundation
import Testing

@testable import AppFeature

extension IntegrationFeatureTests {
	@Test
	internal func retirementSmokeRequiresExactOwnedBundleArgumentsAndPhase() throws {
		let fixture = try RetirementSmokeInputs()
		defer { fixture.remove() }
		let value = try ProfileRetirementSmoke.load(
			environment: fixture.environment,
			arguments: fixture.arguments,
			application: fixture.application
		)
		let loaded = try #require(value)
		try loaded.seedWorkspace()
		let workspace = try BrowserWorkspaceClient(
			file: fixture.profile.appendingPathComponent("arx-workspace.json")
		).load()
		#expect(workspace?.profiles.count == 3)
		#expect(workspace?.legacyProfileID == ProfileRetirementSmoke.legacy)
		#expect(workspace?.spaces.map(\.profileID) == [ProfileRetirementSmoke.survivor])
		#expect(throws: (any Error).self) {
			try ProfileRetirementSmoke.load(
				environment: fixture.environment,
				arguments: fixture.arguments + [ProfileRetirementSmoke.argument, fixture.root.path],
				application: fixture.application
			)
		}
		var environment = fixture.environment
		environment["ARX_RETIREMENT_SMOKE_PHASE"] = "erased"
		#expect(throws: (any Error).self) {
			try ProfileRetirementSmoke.load(
				environment: environment,
				arguments: fixture.arguments,
				application: fixture.application
			)
		}
	}

	@Test
	internal func retirementSmokeCannotSkipPriorCleanPhaseOrWriteThroughProfileAlias() throws {
		let fixture = try RetirementSmokeInputs()
		defer { fixture.remove() }
		var environment = fixture.environment
		environment["ARX_RETIREMENT_SMOKE_PHASE"] = "quarantine"
		var arguments = fixture.arguments
		arguments[arguments.count - 1] = "quarantine"
		#expect(throws: (any Error).self) {
			try ProfileRetirementSmoke.load(
				environment: environment,
				arguments: arguments,
				application: fixture.application
			)
		}
		let preserved = fixture.root.appendingPathComponent("preserved-profile")
		try FileManager.default.moveItem(at: fixture.profile, to: preserved)
		try FileManager.default.createSymbolicLink(at: fixture.profile, withDestinationURL: preserved)
		#expect(throws: (any Error).self) {
			try ProfileRetirementSmoke.load(
				environment: fixture.environment,
				arguments: fixture.arguments,
				application: fixture.application
			)
		}
	}
}

private struct RetirementSmokeInputs {
	internal let root: URL
	internal let profile: URL
	internal let application: URL

	internal init() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("retirement-smoke-\(UUID().uuidString)")
			.resolvingSymlinksInPath()
		self.root = root
		self.profile = root.appendingPathComponent("profile")
		self.application = root.appendingPathComponent("Arx.app")
		try FileManager.default.createDirectory(
			at: root,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try FileManager.default.createDirectory(
			at: profile,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
		try Data(ProfileRetirementSmoke.sentinel.utf8).write(
			to: root.appendingPathComponent(".arx-retirement-smoke")
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: root.appendingPathComponent(".arx-retirement-smoke").path
		)
		let configuration: [String: Any] = [
			"version": 1,
			"application": application.absoluteString,
			"baseURL": "http://127.0.0.1:48123/identity",
		]
		try JSONSerialization.data(withJSONObject: configuration).write(
			to: root.appendingPathComponent("fixture.json")
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: root.appendingPathComponent("fixture.json").path
		)
	}

	internal var environment: [String: String] {
		[
			"ARX_RETIREMENT_SMOKE_ROOT": root.path,
			"ARX_ENGINE_PROFILE": profile.path,
			"ARX_RETIREMENT_SMOKE_PHASE": "queue",
		]
	}

	internal var arguments: [String] {
		["Arx", ProfileRetirementSmoke.argument, root.path, ProfileRetirementSmoke.phaseArgument, "queue"]
	}

	internal func remove() {
		try? FileManager.default.removeItem(at: root)
	}
}
#endif
