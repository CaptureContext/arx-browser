import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP

@testable import BrowserMCPServer

@MainActor
internal struct AutomationInspectionHostTests {
	@Test(.timeLimit(.minutes(1)), arguments: ["allowed", "grant", "document", "encodedSize", "mcpSize"])
	internal func finalIPCReleaseChecksScopeDocumentAndExactEncodedBytes(change: String) async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-inspection-ipc-" + UUID().uuidString.prefix(10))
		defer {
			do { try FileManager.default.removeItem(at: directory) }
			catch { Issue.record("Inspection IPC fixture cleanup failed") }
		}
		let state = HostState()
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { state.preferences },
			receive: { event in
				if case .inspectionReleased = event { state.releases += 1 }
				continuation.yield(event)
			},
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

		var result = AutomationInspectionTests.result()
		let requestID = UUID()
		envelope.epoch = epoch
		envelope.payload = .request(requestID, .inspect(result.request))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		for await event in events {
			if case .request = event { break }
		}

		switch change {
		case "grant": state.preferences.clients[0].allowsPageContent = false

		case "document": state.failure = .staleTarget

		case "mcpSize":
			result.request.maximumTextBytes = 65_536
			result.snapshot.nodes = (0..<14).map {
				.init(index: $0, role: "staticText", text: String(repeating: "\"", count: 4096))
			}
			result.snapshot.totalNodes = result.snapshot.nodes.count
			try result.validate()
			#expect(try JSONEncoder().encode(AutomationIPC.Reply.result(.inspection(result))).count < AutomationIPC.maximumResponseBytes)
			let value: Value = .object(["untrustedData": .bool(true), "result": try BrowserMCPServer.payload(.inspection(result))])
			let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
			let unbounded = CallTool.Result(
				content: [.text(text: text, annotations: nil, _meta: nil)],
				structuredContent: Optional(value),
				isError: false
			)
			#expect(try JSONEncoder().encode(unbounded).count > AutomationIPC.maximumResponseBytes)
			// The whole snapshot can't be one MCP result, but the helper pages it; the host releases it.
			let response = try BrowserMCPServer.toolResult(.inspection(result))
			expectNoDifference(response.isError, true)

		case "encodedSize":
			result.request.maximumTextBytes = 65_536
			result.snapshot.nodes = (0..<16).map {
				.init(index: $0, role: "staticText", text: String(repeating: "\u{01}", count: 4096))
			}
			result.snapshot.totalNodes = result.snapshot.nodes.count
			try result.validate()
			let encodedReply = try JSONEncoder().encode(AutomationIPC.Reply.result(.inspection(result)))
			#expect(encodedReply.count > AutomationIPC.maximumResponseBytes)

		default: break
		}
		host.respond(requestID, result: .inspection(result))
		let reply = try await request.value
		switch (change, reply) {
		case let ("allowed", .result(.inspection(value))), let ("mcpSize", .result(.inspection(value))):
			expectNoDifference(value, result)
		case ("grant", .failure(.denied)), ("document", .failure(.staleTarget)): break
		case ("encodedSize", .failure(.limitExceeded)): break
		default: Issue.record("Inspection escaped its final IPC release boundary")
		}
		expectNoDifference(state.releases, ["allowed", "mcpSize"].contains(change) ? 1 : 0)
		await host.stop()
	}
}

@MainActor
private final class HostState {
	internal var preferences: AutomationPreferences
	internal var failure: AutomationFailure?
	internal var releases: Int = 0

	internal init() {
		var client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		client.allowsPageContent = true
		self.preferences = .init(isEnabled: true, clients: [client])
		self.failure = nil
	}
}
