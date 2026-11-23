import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _Dependencies
import _MCP

@testable import BrowserMCPServer

internal struct AutomationClickTests {
	@Test
	internal func restoredClientsNeverGainInteractionPermission() async throws {
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(client)) as? [String: Any])
		object.removeValue(forKey: "allowsPageInteraction")
		let restored = try JSONDecoder().decode(AutomationClient.self, from: JSONSerialization.data(withJSONObject: object))
		expectNoDifference(restored, client)
		expectNoDifference(restored.allowsPageInteraction, false)
	}

	@Test
	internal func clickRequiresAllExplicitIdentitiesAndOffersNoOtherAction() async throws {
		let request = Self.request()
		let arguments: [String: Value] = [
			"operationID": .string(request.operationID.uuidString),
			"targetID": .string(request.targetID.uuidString),
			"expectedRevision": .string(request.expectedRevision),
			"snapshotID": .string(request.snapshotID),
			"reference": .string(request.reference),
		]
		expectNoDifference(try AutomationTools.operation(name: "browser_click", arguments: arguments), .click(request))
		for key in arguments.keys {
			var invalid = arguments
			invalid[key] = nil
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_click", arguments: invalid)
			}
		}
		for (key, value): (String, Value) in [
			("targetID", .string("focused")),
			("reference", .string("")),
			("snapshotID", .string(String(repeating: "x", count: 129))),
			("scopeID", .string(UUID().uuidString)),
			("frameID", .string("foreign")),
			("text", .string("type this")),
			("focus", .bool(true)),
		] {
			var invalid = arguments
			invalid[key] = value
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_click", arguments: invalid)
			}
		}
	}

	@Test
	internal func uncertainOutcomeIsAnErrorWithNoPageContentOrNavigationSuccess() async throws {
		let result = AutomationClickResult(operationID: UUID(), disposition: .possiblyDispatched, failure: .timedOut)
		let response = try BrowserMCPServer.toolResult(.click(result))
		expectNoDifference(response.isError, true)
		let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
		#expect(encoded.contains("possiblyDispatched"))
		#expect(encoded.contains("navigationCompleted"))
		#expect(!encoded.contains("nodes"))
		#expect(!encoded.contains("documentID"))
		#expect(!encoded.contains("url"))
	}

	@Test(.timeLimit(.minutes(1)))
	internal func unexpectedReplyAfterExchangePreservesUncertainty() async throws {
		let socket = LocalAutomationSocket()
		let directory = URL(fileURLWithPath: "/tmp/arx-click-gateway-" + UUID().uuidString.prefix(8))
		defer {
			do { try FileManager.default.removeItem(at: directory) }
			catch { Issue.record("Gateway fixture cleanup failed") }
		}
		let path = try await socket.start(directory: directory) { envelope in
			if case .hello = envelope.payload { return .hello(UUID()) }
			return .acknowledged
		}
		let gateway = AutomationGateway(path: path, clientID: UUID(), credential: String(repeating: "0", count: 64))
		try await gateway.initialize()
		let request = Self.request()
		let result = await gateway.perform(.click(request))
		expectNoDifference(result, .click(.init(
			operationID: request.operationID,
			disposition: .possiblyDispatched,
			failure: .invalidRequest
		)))
		await gateway.disconnect()
		await socket.stop()
	}

	internal static func request() -> AutomationClickRequest {
		.init(
			operationID: UUID(),
			targetID: UUID(),
			expectedRevision: String(repeating: "a", count: 64),
			snapshotID: "snapshot",
			reference: "opaque"
		)
	}
}

@MainActor
internal struct AutomationClickHostTests {
	@Test(
		.timeLimit(.minutes(1)),
		arguments: ["cancelBefore", "cancelAfter", "timeout", "revoke", "grant", "responseDenied", "nativeRejected"]
	)
	internal func interruptionPreservesSubmittedUncertainty(change: String) async throws {
		let fixture = HostFixture()
		let directory = URL(fileURLWithPath: "/tmp/arx-click-" + UUID().uuidString.prefix(12))
		defer {
			do { try FileManager.default.removeItem(at: directory) }
			catch { Issue.record("Click IPC fixture cleanup failed") }
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
		let click = AutomationClickTests.request()
		envelope.payload = .request(requestID, .click(click))
		let requestEnvelope = envelope
		let task = Task { try await LocalAutomationSocket.exchange(path: path, envelope: requestEnvelope) }
		for await event in events {
			if case .request = event { break }
		}
		if change != "cancelBefore" {
			expectNoDifference(host.beginClick(requestID), true)
			expectNoDifference(host.beginClick(requestID), false)
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
			host.respond(requestID, result: .click(.init(
				operationID: click.operationID,
				disposition: change == "nativeRejected" ? .notDispatched : .dispatched,
				failure: change == "nativeRejected" ? .staleReference : nil
			)))
		}
		let reply = try await task.value
		guard case let .result(.click(result)) = reply else {
			await host.stop()
			Issue.record("Click outcome was collapsed into an ordinary failure")
			return
		}
		let expected: AutomationClickDisposition = switch change {
		case "cancelBefore", "nativeRejected": .notDispatched
		case "grant", "responseDenied": .dispatched
		default: .possiblyDispatched
		}
		expectNoDifference(result.operationID, click.operationID)
		expectNoDifference(result.disposition, expected)
		#expect(result.failure != nil)
		expectNoDifference(host.beginClick(requestID), false)
		await host.stop()
	}
}

@MainActor
private final class HostFixture {
	internal var preferences: AutomationPreferences
	internal var failure: AutomationFailure?

	internal init() {
		var client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		client.allowsPageInteraction = true
		self.preferences = .init(isEnabled: true, clients: [client])
		self.failure = nil
	}
}
