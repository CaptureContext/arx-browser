#if DEBUG
@testable import AppFeature
import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _ComposableArchitecture

@Suite(.dependencies)
@MainActor
internal struct AutomationSmokeTests {
	@Test
	func fixtureAcceptsOnlyTheOwnedDisposableProfileAndLoopbackOrigin() async throws {
		let root = try fixtureDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let profile = root.appendingPathComponent("profile")
		let base = URL(string: "http://127.0.0.1:48123/index.html")!
		try AutomationSmokeFixture.validate(root: root, profile: profile, baseURL: base, preferences: .init())
		let rejected = [
			"https://capturecontext.dev/index.html",
			"http://localhost:48123/index.html",
			"http://127.0.0.1/index.html",
			"http://127.0.0.1:48123/other.html",
			"http://user:secret@127.0.0.1:48123/index.html",
			"http://127.0.0.1:48123/index.html?existing=true",
			"http://127.0.0.1:48123/index.html#existing",
		]
		for raw in rejected {
			#expect(throws: AutomationSmokeFailure.invalidFixture) {
				try AutomationSmokeFixture.validate(root: root, profile: profile, baseURL: URL(string: raw)!, preferences: .init())
			}
		}
		#expect(throws: AutomationSmokeFailure.invalidFixture) {
			try AutomationSmokeFixture.validate(root: root, profile: root, baseURL: base, preferences: .init())
		}
	}

	@Test(arguments: [
		"root-permissions", "profile-permissions", "marker-permissions",
		"marker-content", "marker-oversize", "missing-marker",
		"profile-symlink", "marker-symlink", "root-symlink",
	])
	func fixtureRejectsUntrustedFilesystemLayout(change: String) async throws {
		var root = try fixtureDirectory()
		let ownedRoot = root
		defer { try? FileManager.default.removeItem(at: ownedRoot) }
		var profile = root.appendingPathComponent("profile")
		let marker = root.appendingPathComponent(".arx-mcp-smoke")
		switch change {
		case "root-permissions":
			try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

		case "profile-permissions":
			try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profile.path)

		case "marker-permissions":
			try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)

		case "marker-content":
			try Data("Unrelated private workspace marker\n".utf8).write(to: marker)

		case "marker-oversize":
			try Data(repeating: 65, count: 8192).write(to: marker)

		case "missing-marker":
			try FileManager.default.removeItem(at: marker)

		case "profile-symlink":
			let target = root.appendingPathComponent("real-profile")
			try FileManager.default.moveItem(at: profile, to: target)
			try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)

		case "marker-symlink":
			let target = root.appendingPathComponent("real-marker")
			try FileManager.default.moveItem(at: marker, to: target)
			try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)

		default:
			let alias = root.appendingPathComponent("app-smoke-alias")
			try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
			root = alias
			profile = alias.appendingPathComponent("profile")
		}
		#expect(throws: AutomationSmokeFailure.invalidFixture) {
			try AutomationSmokeFixture.validate(
				root: root,
				profile: profile,
				baseURL: URL(string: "http://127.0.0.1:48123/index.html")!,
				preferences: .init()
			)
		}
	}

	@Test
	func fixtureRejectsExistingAuthorizationBeforeAnyFilesystemAccess() async throws {
		for preferences in [AutomationPreferences(isEnabled: true), .init(clients: [client()])] {
			#expect(throws: AutomationSmokeFailure.existingAuthorization) {
				try AutomationSmokeFixture.validate(
					root: URL(fileURLWithPath: "/absent"),
					profile: URL(fileURLWithPath: "/absent/profile"),
					baseURL: URL(string: "http://127.0.0.1:48123/index.html")!,
					preferences: preferences
				)
			}
		}
	}

	@Test
	func configurationKeepsOnlyTheExpectedGeneratedCredentialAndHelper() async throws {
		let client = client()
		let helper = URL(fileURLWithPath: "/fixture/Arx.app/Contents/Helpers/ArxMCP")
		let socket = "/tmp/fixture.sock"
		let json = AutomationConfiguration.make(
			clientID: client.id,
			token: String(repeating: "a", count: 64),
			socket: socket,
			helper: helper.path
		)
		let configuration = try AutomationSmokeConfiguration(json: json, helper: helper, socket: socket, client: client)
		expectNoDifference(Set(configuration.environment.keys), ["ARX_MCP_SOCKET", "ARX_MCP_CLIENT_ID", "ARX_MCP_CREDENTIAL"])
		let otherSocket = AutomationConfiguration.make(
			clientID: client.id,
			token: String(repeating: "a", count: 64),
			socket: "/tmp/other.sock",
			helper: helper.path
		)
		let tampered = [
			json.replacingOccurrences(of: "ArxMCP", with: "OtherHelper"),
			otherSocket,
			json.replacingOccurrences(of: client.id.uuidString, with: UUID().uuidString),
			json.replacingOccurrences(of: String(repeating: "a", count: 64), with: String(repeating: "b", count: 64)),
			"malformed",
		]
		for changed in tampered {
			#expect(throws: AutomationSmokeFailure.invalidResponse) {
				try AutomationSmokeConfiguration(json: changed, helper: helper, socket: socket, client: client)
			}
		}
	}

	@Test
	func responseRequiresMatchingStructuredContentAndTypedBoundedPayload() async throws {
		let item = AutomationInventoryItem(
			id: UUID(),
			kind: .tab,
			title: "Fixture",
			profileID: UUID(),
			url: "http://127.0.0.1:48123/mcp-start.html",
			sessionState: .ready,
			revision: String(repeating: "a", count: 64)
		)
		let value: Value = .object(["untrustedData": .bool(true), "result": .object([
			"kind": .string("inventory"), "items": try Value([item]), "nextCursor": .null,
		])])
		let result = try response(value)
		expectNoDifference(try AutomationSmokeResponse.decode(result), .inventory(.init(items: [item])))
		let mismatched = CallTool.Result(content: result.content, structuredContent: .some(.object([:])), isError: false)
		#expect(throws: AutomationSmokeFailure.invalidResponse) { try AutomationSmokeResponse.decode(mismatched) }
		let incorrectlyFailed = CallTool.Result(
			content: result.content,
			structuredContent: result.structuredContent,
			isError: true
		)
		#expect(throws: AutomationSmokeFailure.invalidResponse) { try AutomationSmokeResponse.decode(incorrectlyFailed) }
		let duplicate = try response(.object(["untrustedData": .bool(true), "result": .object([
			"kind": .string("inventory"), "items": try Value([item, item]),
		])]))
		#expect(throws: AutomationSmokeFailure.invalidResponse) { try AutomationSmokeResponse.decode(duplicate) }
		let trusted = try response(.object([
			"untrustedData": .bool(false),
			"result": .object(["kind": .string("inventory"), "items": .array([])]),
		]))
		#expect(throws: AutomationSmokeFailure.invalidResponse) { try AutomationSmokeResponse.decode(trusted) }
	}

	@Test
	func responseDistinguishesAcceptedNavigationAndExplicitDenial() async throws {
		let operation = UUID()
		let target = UUID()
		let command = try response(.object(["untrustedData": .bool(true), "result": .object([
			"kind": .string("command"),
			"operationID": .string(operation.uuidString),
			"targetID": .string(target.uuidString),
			"status": .string("acceptedLoading"),
		])]))
		expectNoDifference(
			try AutomationSmokeResponse.decode(command),
			.command(.init(operationID: operation, status: .acceptedLoading, targetID: target))
		)
		let denied = try response(.object(["untrustedData": .bool(true), "result": .object([
			"kind": .string("error"), "code": .string("invalidCredential"),
		])]), isError: true)
		expectNoDifference(try AutomationSmokeResponse.decode(denied), .failure(.invalidCredential))
		let unknown = try response(.object(["untrustedData": .bool(true), "result": .object([
			"kind": .string("error"), "code": .string("raw credential-bearing diagnostics"),
		])]), isError: true)
		#expect(throws: AutomationSmokeFailure.invalidResponse) { try AutomationSmokeResponse.decode(unknown) }
	}

	@Test(.timeLimit(.minutes(1)))
	func deadlineDisconnectsAnUncooperativePendingRequestAndRejectsItsLateSuccess() async throws {
		let suspended = SuspendedRequest()
		var expirations = 0
		do {
			let _: Int = try await AutomationSmokeDeadline.run(
				for: .milliseconds(30),
				expire: {
					expirations += 1
					suspended.continuation?.resume(returning: 42)
					suspended.continuation = nil
				},
				operation: {
					await withCheckedContinuation { suspended.continuation = $0 }
				}
			)
			Issue.record("A late success escaped the expired deadline")
		} catch {
			expectNoDifference(error as? AutomationSmokeFailure, .timedOut)
		}
		expectNoDifference(expirations, 1)
		#expect(suspended.continuation == nil)
	}

	@Test(.timeLimit(.minutes(1)))
	func completedRequestCancelsDeadlineWithoutDisconnecting() async throws {
		var expired = false
		let value = try await AutomationSmokeDeadline.run(
			for: .seconds(30),
			expire: { expired = true },
			operation: { 42 }
		)
		expectNoDifference(value, 42)
		#expect(!expired)
	}

	@Test(.timeLimit(.minutes(1)))
	func cancellationAlsoDisconnectsBeforeAwaitingUncooperativeRequest() async throws {
		let suspended = SuspendedRequest()
		let started = AsyncStream<Void>.makeStream()
		var expired = false
		let task = Task {
			try await AutomationSmokeDeadline.run(
				for: .seconds(30),
				expire: {
					expired = true
					suspended.continuation?.resume(returning: 42)
					suspended.continuation = nil
				},
				operation: {
					await withCheckedContinuation {
						suspended.continuation = $0
						started.continuation.yield()
					}
				}
			)
		}
		for await _ in started.stream { break }
		task.cancel()
		do {
			_ = try await task.value
			Issue.record("Cancelled operation returned a success")
		} catch {
			#expect(error is CancellationError)
		}
		#expect(expired)
		#expect(suspended.continuation == nil)
	}

	@Test(.timeLimit(.minutes(1)))
	func preCancelledDeadlineNeverStartsAnUncooperativeOperation() async throws {
		let entry = AsyncStream<Void>.makeStream()
		var invoked = false
		let task = Task {
			for await _ in entry.stream { break }
			return try await AutomationSmokeDeadline.run(
				for: .seconds(30),
				expire: {},
				operation: {
					invoked = true
					return await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in
						Issue.record("A cancelled caller entered an uncooperative operation")
					}
				}
			)
		}
		task.cancel()
		entry.continuation.finish()
		do {
			_ = try await task.value
			Issue.record("Pre-cancelled deadline succeeded")
		} catch {
			#expect(error is CancellationError)
		}
		#expect(!invoked)
	}

	@Test(.timeLimit(.minutes(1)))
	func disableAwaitsHostStopAfterPublishedStateAlreadyLooksDisabled() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var preferences = BrowserPreferences()
		preferences.automation.isEnabled = true
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let initialState = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			),
			automation: preferences.automation
		)
		let store = Store(initialState: initialState) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.automationControl.stop = {
				started.continuation.yield()
				for await _ in release.stream { break }
			}
		}
		var finished = false
		let task = Task {
			await AutomationSmoke.disable(store: store)
			finished = true
		}
		for await _ in started.stream { break }
		#expect(!store.automationPreferences.isEnabled)
		#expect(store.automation.socketPath == nil)
		#expect(!finished)
		release.continuation.yield()
		await task.value
		#expect(finished)
	}

	private func fixtureDirectory() throws -> URL {
		let root = URL.temporaryDirectory.appendingPathComponent("app-smoke-" + UUID().uuidString)
		try FileManager.default.createDirectory(
			at: root,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		try FileManager.default.createDirectory(
			at: root.appendingPathComponent("profile"),
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		let marker = root.appendingPathComponent(".arx-mcp-smoke")
		try Data(AutomationSmokeFixture.sentinel.utf8).write(to: marker)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
		return root
	}

	private func client() -> AutomationClient {
		.init(
			id: UUID(),
			name: "Fixture",
			credentialDigest: AutomationSecurity.digest(Data(String(repeating: "a", count: 64).utf8)),
			grantRevision: UUID()
		)
	}

	private func response(
		_ value: Value,
		isError: Bool = false
	) throws -> CallTool.Result {
		let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
		return .init(
			content: [.text(text: text, annotations: nil, _meta: nil)],
			structuredContent: .some(value),
			isError: isError
		)
	}

	private final class SuspendedRequest {
		var continuation: CheckedContinuation<Int, Never>?
	}
}
#endif
