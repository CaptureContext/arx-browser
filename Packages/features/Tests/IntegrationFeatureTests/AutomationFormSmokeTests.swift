import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
internal struct AutomationFormSmokeTests {
	@Test(arguments: [AutomationFormDisposition.notDispatched, .dispatched, .possiblyDispatched, .unchanged])
	internal func publicReceiptPreservesUncertaintyWithoutPageContent(disposition: AutomationFormDisposition) throws {
		let failure: AutomationFailure? = disposition == .possiblyDispatched ? .timedOut : nil
		let result = try AutomationFormSmoke.decode(
			Self.response(disposition: disposition, failure: failure),
			operationID: UUID(1)
		)
		expectNoDifference(result, .init(operationID: UUID(1), disposition: disposition, failure: failure))
	}

	@Test(arguments: ["operation", "navigation", "pageContent", "errorFlag", "untrusted", "textMismatch", "failure", "disposition"])
	internal func malformedOrOverclaimedReceiptsAreRejected(change: String) throws {
		#expect(throws: AutomationSmokeFailure.invalidResponse) {
			try AutomationFormSmoke.decode(Self.response(change: change), operationID: UUID(1))
		}
	}

	@Test
	internal func actualEvidenceRequiresOneTrustedUnfocusedPairPerControl() throws {
		try AutomationFormSmoke.verifyEvidence(Self.evidence(), targets: ["text", "select"])
	}

	@Test(arguments: ["missing", "duplicate", "untrusted", "activation", "focused", "wrongValue", "extraValue", "target"])
	internal func weakOrLeakingEventEvidenceCannotPass(change: String) throws {
		#expect(throws: AutomationSmokeFailure.invalidResponse) {
			try AutomationFormSmoke.verifyEvidence(Self.evidence(change: change), targets: ["text", "select"])
		}
	}

	private static func evidence(change: String? = nil) throws -> Data {
		var events: [[String: Value]] = ["text", "select"].flatMap { target in
			["input", "change"].map { event in
				[
					"target": .string(target),
					"event": .string(event),
					"trusted": .bool(true),
					"activation": .bool(false),
					"focused": .bool(false),
					"correct": .bool(true),
				]
			}
		}
		switch change {
		case "missing": events.removeLast()
		case "duplicate": events[1] = events[0]
		case "untrusted": events[0]["trusted"] = .bool(false)
		case "activation": events[0]["activation"] = .bool(true)
		case "focused": events[0]["focused"] = .bool(true)
		case "wrongValue": events[0]["correct"] = .bool(false)
		case "extraValue": events[0]["value"] = .string("Unexpected private value")
		case "target": events[0]["target"] = .string("password")
		default: break
		}
		return try JSONEncoder().encode(Value.object(["events": .array(events.map(Value.object))]))
	}

	private static func response(
		disposition: AutomationFormDisposition = .dispatched,
		failure: AutomationFailure? = nil,
		change: String? = nil
	) throws -> CallTool.Result {
		var payload: [String: Value] = [
			"kind": .string("form"),
			"operationID": .string(UUID(1).uuidString),
			"disposition": .string(disposition.rawValue),
			"failure": failure.map { .string($0.rawValue) } ?? .null,
			"navigationCompleted": .bool(false),
		]
		if change == "operation" { payload["operationID"] = .string(UUID(2).uuidString) }
		if change == "navigation" { payload["navigationCompleted"] = .bool(true) }
		if change == "pageContent" { payload["url"] = .string("https://fixture.invalid/private") }
		if change == "failure" { payload["failure"] = .string("unknown") }
		if change == "disposition" { payload["disposition"] = .string("completed") }
		let envelope: Value = .object([
			"untrustedData": .bool(change != "untrusted"),
			"result": .object(payload),
		])
		let text = change == "textMismatch"
		? "{}"
		: String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
		return .init(
			content: [.text(text: text, annotations: nil, _meta: nil)],
			structuredContent: Optional(envelope),
			isError: change == "errorFlag" || failure != nil
		)
	}
}
