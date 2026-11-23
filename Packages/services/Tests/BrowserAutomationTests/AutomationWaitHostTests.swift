import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct AutomationWaitHostTests {
	@Test(arguments: ["allowed", "grant", "document", "cancel", "disconnect"])
	internal func queuedObservationMustStillPassFinalIPCRelease(change: String) async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-wait-ipc-" + UUID().uuidString.prefix(10))
		defer {
			do { try FileManager.default.removeItem(at: directory) }
			catch { Issue.record("Wait IPC fixture cleanup failed") }
		}
		let state = HostState()
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { state.preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in state.failure }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: state.preferences.clients[0].id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			await host.stop()
			throw AutomationFailure.staleSession
		}

		let result = AutomationWaitTests.result()
		let requestID = UUID()
		envelope.epoch = epoch
		envelope.payload = .request(requestID, .wait(result.request))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		for await event in events {
			if case .request = event { break }
		}

		switch change {
		case "grant":
			state.preferences.clients[0].allowsRead = false

		case "document":
			state.failure = .staleTarget

		case "cancel", "disconnect":
			envelope.payload = change == "cancel" ? .cancel(requestID) : .disconnect
			_ = try await LocalAutomationSocket.exchange(path: path, envelope: envelope)

		default:
			break
		}
		host.respond(requestID, result: .wait(result))
		let response = try await request.value
		let expected: AutomationResult = switch change {
		case "grant": .failure(.denied)
		case "document": .failure(.staleTarget)
		case "cancel": .failure(.cancelled)
		case "disconnect": .failure(.disconnected)
		default: .wait(result)
		}
		switch response {
		case let .result(value): expectNoDifference(value, expected)
		case let .failure(failure): expectNoDifference(AutomationResult.failure(failure), expected)
		default: Issue.record("Wait returned an unexpected IPC envelope")
		}
		await host.stop()
	}
}

@MainActor
private final class HostState {
	fileprivate var preferences: AutomationPreferences
	fileprivate var failure: AutomationFailure?

	fileprivate init() {
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		self.preferences = .init(isEnabled: true, clients: [client])
		self.failure = nil
	}
}
