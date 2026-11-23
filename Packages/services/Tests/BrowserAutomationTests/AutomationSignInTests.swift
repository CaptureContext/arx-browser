import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
@testable import BrowserMCPServer

internal struct AutomationSignInTests {
	@Test
	internal func schemaHasNoCredentialOrImplicitTargetFallbackAndResultIsOpaque() async throws {
		let id = UUID()
		let target = UUID()
		let arguments: [String: Value] = [
			"operationID": .string(id.uuidString),
			"action": .string("begin"),
			"targetID": .string(target.uuidString),
			"expectedRevision": .string(String(repeating: "a", count: 64)),
			"origin": .string("http://127.0.0.1:34567"),
		]
		let operation = try AutomationTools.operation(name: "browser_sign_in", arguments: arguments)
		expectNoDifference(
			operation,
			.signIn(.init(
				operationID: id,
				action: .begin,
				targetID: target,
				expectedRevision: String(repeating: "a", count: 64),
				origin: "http://127.0.0.1:34567"
			))
		)
		for key in ["password", "otp", "token", "account", "provider", "focus", "cookie"] {
			var changed = arguments
			changed[key] = .string("DISPOSABLE_SECRET_SENTINEL")
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(name: "browser_sign_in", arguments: changed)
			}
		}
		let result = try BrowserMCPServer.payload(.signIn(.init(operationID: id, status: .userConfirmed)))
		expectNoDifference(
			result,
			.object([
				"kind": .string("signIn"),
				"operationID": .string(id.uuidString),
				"status": .string("userConfirmed"),
			])
		)
	}

	@Test
	@MainActor
	internal func quarantineBlocksNewRequestsAndAlreadyCapturedLateRepliesAtTheServiceBoundary() async throws {
		let root = URL(fileURLWithPath: "/tmp/arx-sign-in-ipc-" + UUID().uuidString.prefix(10))
		defer { try? FileManager.default.removeItem(at: root) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let state = State(preferences: .init(isEnabled: true, clients: [client]))
		let host = BrowserAutomationHost(directory: root)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { state.preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let socket = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: socket, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		envelope.epoch = epoch
		let requestID = UUID()
		envelope.payload = .request(requestID, .inventory(cursor: nil, limit: 10))
		let captured = envelope
		let pending = Task { try await LocalAutomationSocket.exchange(path: socket, envelope: captured) }
		for await event in events {
			if case .request = event { break }
		}
		state.preferences.authenticationLockID = UUID()
		host.respond(requestID, result: .inventory(.init(items: [], nextCursor: nil)))
		guard case .failure(.authenticationProtected) = try await pending.value else {
			Issue.record("Captured result escaped quarantine")
			await host.stop()
			return
		}
		envelope.payload = .request(UUID(), .inventory(cursor: nil, limit: 10))
		let newReadReply = try await LocalAutomationSocket.exchange(path: socket, envelope: envelope)
		guard case .failure(.authenticationProtected) = newReadReply else {
			Issue.record("A new read escaped quarantine")
			await host.stop()
			return
		}
		await host.stop()
	}

	@MainActor
	private final class State {
		internal var preferences: AutomationPreferences

		internal init(preferences: AutomationPreferences) {
			self.preferences = preferences
		}
	}
}
