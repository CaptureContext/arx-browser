import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
internal struct AutomationScrollSmokeTests {
	@Test(arguments: [AutomationScrollDisposition.notDispatched, .dispatched, .possiblyDispatched, .unchanged])
	internal func publicReceiptPreservesUncertaintyWithoutPageContent(disposition: AutomationScrollDisposition) async throws {
		let failure: AutomationFailure? = disposition == .possiblyDispatched ? .timedOut : nil
		let result = try AutomationScrollSmoke.decode(
			Self.response(disposition: disposition, failure: failure),
			operationID: UUID(1)
		)
		expectNoDifference(result, .init(operationID: UUID(1), disposition: disposition, failure: failure))
	}

	@Test(arguments: ["operation", "navigation", "pageContent", "errorFlag", "untrusted", "textMismatch", "failure", "disposition"])
	internal func malformedOrOverclaimedReceiptsAreRejected(change: String) async throws {
		#expect(throws: AutomationSmokeFailure.invalidResponse) {
			try AutomationScrollSmoke.decode(Self.response(change: change), operationID: UUID(1))
		}
	}

	@Test
	internal func boundedOwnedEvidencePreservesOnlyGeometryAndCounters() async throws {
		let result = try AutomationScrollSmoke.decodeEvidence(Self.evidence())
		expectNoDifference(result.sample, 1)
		expectNoDifference(result.events, 0)
		expectNoDifference(result.innerAtEnd, false)
		#expect(result.matches())
		#expect(!result.matches(["innerY": 120.5]))
		#expect(!result.matches(["unknown": 0]))
	}

	@Test(arguments: [
		"missing", "secret", "focused", "activation", "untrusted",
		"badOffset", "hugeOffset", "sample", "events", "boolean",
	])
	internal func unsafeOrUnboundedOwnedEvidenceCannotPass(change: String) async throws {
		#expect(throws: AutomationSmokeFailure.invalidResponse) {
			try AutomationScrollSmoke.decodeEvidence(Self.evidence(change: change))
		}
	}

	private static func evidence(change: String? = nil) throws -> Data {
		var fields: [String: Value] = [
			"innerX": .double(0), "innerY": .double(0),
			"outerX": .double(0), "outerY": .double(0),
			"pageX": .double(0), "pageY": .double(0),
			"sample": .int(1), "events": .int(0),
			"focused": .bool(false), "activation": .bool(false),
			"trusted": .bool(true), "innerAtEnd": .bool(false),
		]
		switch change {
		case "missing": fields["innerY"] = nil
		case "secret": fields["value"] = .string("Unexpected private value")
		case "focused": fields["focused"] = .bool(true)
		case "activation": fields["activation"] = .bool(true)
		case "untrusted": fields["trusted"] = .bool(false)
		case "badOffset": fields["innerY"] = .string("120")
		case "hugeOffset": fields["outerY"] = .double(100_001)
		case "sample": fields["sample"] = .int(0)
		case "events": fields["events"] = .int(10_001)
		case "boolean": fields["trusted"] = .int(1)
		default: break
		}
		return try JSONEncoder().encode(Value.object(fields))
	}

	private static func response(
		disposition: AutomationScrollDisposition = .dispatched,
		failure: AutomationFailure? = nil,
		change: String? = nil
	) throws -> CallTool.Result {
		var payload: [String: Value] = [
			"kind": .string("scroll"),
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
