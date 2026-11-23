import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _TestSupport

/// A client the user stopped from the page's indicator gets `paused`, not a bare denial (DEV-899).
@MainActor
internal struct AutomationPausedHostTests {
	@Test(.timeLimit(.minutes(1)))
	internal func pausedClientsAreRefusedBeforeAndAfterTheAppAnswers() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-paused-" + UUID().uuidString.prefix(10))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let authority = PausedAuthority(preferences: AutomationPreferences(isEnabled: true, clients: [client]))
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { authority.preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		envelope.epoch = epoch

		// Stopped while a request was in the app: its answer is replaced with `paused`.
		let requestID = UUID()
		envelope.payload = .request(requestID, .inventory(cursor: nil, limit: 1))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		for await event in events {
			if case .request = event { break }
		}
		authority.preferences.clients[0].isPaused = true
		host.respond(requestID, result: .failure(.cancelled))
		guard case .failure(.paused) = try await request.value else {
			Issue.record("A stopped client's answer was released")
			await host.stop()
			return
		}

		// Later requests never reach the app.
		envelope.payload = .request(UUID(), .inventory(cursor: nil, limit: 1))
		guard case .failure(.paused) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("A paused client's request was accepted")
			await host.stop()
			return
		}
		envelope.payload = .changes
		guard case .failure(.paused) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("A paused client still received changes")
			await host.stop()
			return
		}
		await host.stop()
	}
}

private final class PausedAuthority {
	internal var preferences: AutomationPreferences

	internal init(preferences: AutomationPreferences) {
		self.preferences = preferences
	}
}
