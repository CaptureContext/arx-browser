import Foundation
import Testing

@testable import ChromiumHost

internal struct HostSmokeConfigurationTests {
	@Test
	internal func ordinaryHostDoesNotRequestMockKeychain() throws {
		let configuration = try HostSmokeConfiguration.resolve(
			arguments: ["host"],
			environment: ["ARX_ENGINE_PROFILE": "/ordinary/profile"],
			workDirectory: .temporaryDirectory
		)
		#expect(configuration == nil)
	}

	@Test
	internal func acceptsOnlyExplicitFreshRunnerFixture() throws {
		try withFixture { root, environment in
			let value = try HostSmokeConfiguration.resolve(
				arguments: ["host", HostSmokeConfiguration.argument, root.path],
				environment: environment,
				workDirectory: root.deletingLastPathComponent()
			)
			#expect(value?.profileDirectory.path == root.appending(path: "profile").path)
			#expect(throws: (any Error).self) {
				try HostSmokeConfiguration.resolve(
					arguments: ["host"],
					environment: environment,
					workDirectory: root.deletingLastPathComponent()
				)
			}
		}
	}

	@Test(arguments: [
		"existingProfile",
		"profileElsewhere",
		"remoteFixture",
		"credentials",
		"missingMarker",
		"symlinkFixture",
		"outsideWork",
		"wrongMode",
		"oversizeFixture",
	])
	internal func rejectsUnsafeOrUnownedFixture(_ mutation: String) throws {
		try withFixture { root, initial in
			var environment = initial
			var work = root.deletingLastPathComponent()
			let files = FileManager.default
			switch mutation {
			case "existingProfile":
				try files.createDirectory(at: root.appending(path: "profile"), withIntermediateDirectories: false)

			case "profileElsewhere":
				environment["ARX_ENGINE_PROFILE"] = "/ordinary/profile"

			case "remoteFixture":
				environment["ARX_ENGINE_URL"] = "https://capturecontext.dev/index.html"

			case "credentials":
				environment["ARX_ENGINE_URL"] = "http://user:password@127.0.0.1:1234/index.html"

			case "missingMarker":
				try files.removeItem(at: root.appending(path: ".arx-engine-smoke"))

			case "symlinkFixture":
				try files.removeItem(at: root.appending(path: "index.html"))
				try files.createSymbolicLink(
					atPath: root.appending(path: "index.html").path,
					withDestinationPath: "/missing-fixture"
				)

			case "outsideWork":
				work = work.appending(path: "elsewhere")

			case "wrongMode":
				try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

			case "oversizeFixture":
				try Data(repeating: 65, count: 4097).write(to: root.appending(path: "index.html"))

			default:
				Issue.record("Unknown fixture mutation")
			}
			#expect(throws: (any Error).self) {
				try HostSmokeConfiguration.resolve(
					arguments: ["host", HostSmokeConfiguration.argument, root.path],
					environment: environment,
					workDirectory: work
				)
			}
		}
	}

	private func withFixture(
		_ body: (URL, [String: String]) throws -> Void
	) throws {
		let files = FileManager.default
		let work = URL.temporaryDirectory.resolvingSymlinksInPath().appending(path: "arx-host-test-" + UUID().uuidString)
		let root = work.appending(path: "smoke-fixture")
		try files.createDirectory(
			at: root,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)

		// Best-effort cleanup of a temporary folder.
		defer { try? files.removeItem(at: work) }
		try Data(HostSmokeConfiguration.marker.utf8).write(to: root.appending(path: ".arx-engine-smoke"))
		try Data("<!doctype html><title>Arx engine smoke</title>".utf8).write(to: root.appending(path: "index.html"))
		try body(root, [
			"ARX_ENGINE_PROFILE": root.appending(path: "profile").path,
			"ARX_ENGINE_SMOKE_TITLE": "Arx engine smoke",
			"ARX_ENGINE_URL": "http://127.0.0.1:1234/index.html",
		])
	}
}
