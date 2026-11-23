import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _Dependencies

@MainActor
internal struct AutomationFormHostTests {
	@Test(
		.timeLimit(.minutes(1)),
		arguments: [
			"cancelBefore", "cancelAfter", "timeout", "revoke", "grant", "responseDenied",
			"nativeRejected", "unchanged", "unchangedCancelled", "unchangedStale",
			"unchangedTimeout", "unchangedDenied",
		]
	)
	internal func interruptionPreservesSubmittedUncertainty(change: String) async throws {
		let fixture = FormHostFixture()
		let directory = URL(fileURLWithPath: "/tmp/arx-form-" + UUID().uuidString.prefix(12))
		defer {
			do { try FileManager.default.removeItem(at: directory) }
			catch { Issue.record("Form IPC fixture cleanup failed") }
		}
		let clock: TestClock<Duration> = .init()
		let host = BrowserAutomationHost(directory: directory, clock: AnyClock(clock))
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { fixture.preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in fixture.failure }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: fixture.preferences.clients[0].id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope)
		else { throw AutomationFailure.staleSession }
		envelope.epoch = epoch
		let requestID = UUID()
		let click = AutomationFormTests.request()
		envelope.payload = .request(requestID, .form(click))
		let requestEnvelope = envelope
		let task = Task { try await LocalAutomationSocket.exchange(path: path, envelope: requestEnvelope) }
		for await event in events {
			if case .request = event { break }
		}
		if change != "cancelBefore" {
			expectNoDifference(host.beginForm(requestID), true)
			expectNoDifference(host.beginForm(requestID), false)
		}

		switch change {
		case "cancelBefore", "cancelAfter":
			envelope.payload = .cancel(requestID)
			_ = try await LocalAutomationSocket.exchange(path: path, envelope: envelope)

		case "revoke": host.revoke(fixture.preferences.clients[0].id)

		case "timeout": await clock.advance(by: .seconds(30))

		default:
			if change == "grant" { fixture.preferences.clients[0].allowsPageInteraction = false }
			if change == "responseDenied" { fixture.failure = .denied }
			let disposition: AutomationFormDisposition = switch change {
			case "nativeRejected": .notDispatched
			case "unchanged", "unchangedCancelled", "unchangedStale", "unchangedTimeout", "unchangedDenied": .unchanged
			default: .dispatched
			}
			let failure: AutomationFailure? = switch change {
			case "nativeRejected", "unchangedStale": .staleReference
			case "unchangedCancelled": .cancelled
			case "unchangedTimeout": .timedOut
			case "unchangedDenied": .denied
			default: nil
			}
			host.respond(requestID, result: .form(.init(
				operationID: click.operationID,
				disposition: disposition,
				failure: failure
			)))
		}
		let reply = try await task.value
		guard case let .result(.form(result)) = reply else {
			await host.stop()
			Issue.record("Form outcome was collapsed into an ordinary failure")
			return
		}
		let expected: AutomationFormDisposition = switch change {
		case "cancelBefore", "nativeRejected": .notDispatched
		case "unchanged", "unchangedCancelled", "unchangedStale", "unchangedTimeout", "unchangedDenied": .unchanged
		case "grant", "responseDenied": .dispatched
		default: .possiblyDispatched
		}
		expectNoDifference(result.operationID, click.operationID)
		expectNoDifference(result.disposition, expected)
		#expect((result.failure == nil) == (change == "unchanged"))
		expectNoDifference(host.beginForm(requestID), false)
		await host.stop()
	}
}

@MainActor
private final class FormHostFixture {
	internal var preferences: AutomationPreferences
	internal var failure: AutomationFailure?

	internal init() {
		var client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		client.allowsPageInteraction = true
		self.preferences = .init(isEnabled: true, clients: [client])
		self.failure = nil
	}
}
