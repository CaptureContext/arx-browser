import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

internal struct AutomationWaitTests {
	@Test
	internal func parserRequiresExplicitScopeAndBoundsTheDeadline() async throws {
		let expected = Self.result().request
		let arguments: [String: Value] = [
			"targetID": .string(expected.targetID.uuidString),
			"expectedRevision": .string(expected.expectedRevision),
			"condition": .string("loadingStopped"),
		]
		expectNoDifference(try AutomationTools.operation(name: "browser_wait", arguments: arguments), .wait(expected))
		for (key, value): (String, Value) in [
			("targetID", .string("current")),
			("expectedRevision", .string("")),
			("condition", .string("navigationCompleted")),
			("timeoutMilliseconds", .int(0)),
			("timeoutMilliseconds", .int(10_001)),
			("timeoutMilliseconds", .double(2.5)),
			("text", .string("Logged in")),
			("reference", .string("opaque")),
			("url", .string("https://example.test")),
			("focus", .bool(true)),
			("script", .string("document.readyState")),
		] {
			var invalid = arguments
			invalid[key] = value
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_wait", arguments: invalid)
			}
		}
		for required in ["targetID", "expectedRevision", "condition"] {
			var invalid = arguments
			invalid[required] = nil
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_wait", arguments: invalid)
			}
		}
	}

	@Test(arguments: [nil, -105, -3] as [Int?])
	internal func outputDistinguishesLoadingObservationFromPageSuccess(error: Int?) async throws {
		var result = Self.result()
		result.errorCode = error
		let response = try BrowserMCPServer.toolResult(.wait(result))
		guard
			case let .object(envelope) = response.structuredContent,
			case let .object(payload) = envelope["result"]
		else { throw AutomationFailure.invalidRequest }
		expectNoDifference(payload["status"], .string(error == nil ? "stopped" : "stoppedWithError"))
		expectNoDifference(payload["errorCode"], error.map(Value.int) ?? .null)
		expectNoDifference(payload["historical"], .bool(true))
		expectNoDifference(payload["navigationCompleted"], .bool(false))
		expectNoDifference(payload["sessionRevision"], .string(String(UInt64.max)))
		expectNoDifference(payload["documentRevision"], .string(String(UInt64.max)))
		expectNoDifference(payload["pageID"], nil)
		#expect(try JSONEncoder().encode(response).count < 4096)
	}

	@Test
	internal func invalidRequestsCannotBypassParserThroughIPC() async throws {
		for timeout in [0, 10_001, Int.max] {
			var request = Self.result().request
			request.timeoutMilliseconds = timeout
			let decoded = try JSONDecoder().decode(AutomationWaitRequest.self, from: JSONEncoder().encode(request))
			#expect(throws: AutomationFailure.invalidRequest) { try decoded.validate() }
		}
	}

	internal static func result() -> AutomationWaitResult {
		.init(
			request: .init(targetID: UUID(3), expectedRevision: String(repeating: "a", count: 64)),
			source: .init(
				target: .init(
					tabID: .init(rawValue: UUID(3)),
					profileID: .init(rawValue: UUID(0)),
					sessionRevision: 3,
					documentRevision: UInt64.max
				),
				pageID: 42
			),
			observedRevision: String(repeating: "b", count: 64),
			sessionRevision: UInt64.max,
			errorCode: nil
		)
	}
}
