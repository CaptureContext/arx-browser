import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
internal struct AutomationClickSmokeTests {
	@Test(arguments: [AutomationClickDisposition.notDispatched, .dispatched, .possiblyDispatched])
	internal func publicReceiptPreservesUncertaintyWithoutPageContent(disposition: AutomationClickDisposition) throws {
		let failure: AutomationFailure? = disposition == .possiblyDispatched ? .timedOut : nil
		let result = try AutomationClickSmoke.decode(
			Self.response(disposition: disposition, failure: failure),
			operationID: UUID(1)
		)
		expectNoDifference(result, .init(operationID: UUID(1), disposition: disposition, failure: failure))
	}

	@Test(arguments: ["operation", "navigation", "pageContent", "errorFlag", "untrusted", "textMismatch", "failure", "disposition"])
	internal func malformedOrOverclaimedReceiptsAreRejected(change: String) throws {
		#expect(throws: AutomationSmokeFailure.invalidResponse) {
			try AutomationClickSmoke.decode(Self.response(change: change), operationID: UUID(1))
		}
	}

	@Test(arguments: [
		AutomationClickResult(operationID: UUID(1), disposition: .dispatched),
		.init(operationID: UUID(1), disposition: .possiblyDispatched, failure: .staleReference),
	])
	internal func navigationReceiptAllowsOnlyTheDocumentRetirementRace(result: AutomationClickResult) throws {
		try AutomationClickSmoke.verifyNavigationReceipt(result)
	}

	@Test(arguments: [
		AutomationClickResult(operationID: UUID(1), disposition: .notDispatched),
		.init(operationID: UUID(1), disposition: .notDispatched, failure: .staleReference),
		.init(operationID: UUID(1), disposition: .possiblyDispatched, failure: .denied),
		.init(operationID: UUID(1), disposition: .possiblyDispatched, failure: .timedOut),
		.init(operationID: UUID(1), disposition: .dispatched, failure: .busy),
	])
	internal func otherFailuresCannotPassTheNavigationFixture(result: AutomationClickResult) throws {
		#expect(throws: AutomationSmokeFailure.clickMismatch) {
			try AutomationClickSmoke.verifyNavigationReceipt(result)
		}
	}

	@Test
	internal func fixtureRequiresOneExplicitReferenceFromTheDeliveredSnapshot() throws {
		var snapshot = AutomationInspectionSmoke.Snapshot(
			targetID: UUID(2),
			expectedRevision: String(repeating: "a", count: 64),
			profileID: UUID(3),
			sessionRevision: 1,
			documentRevision: 4,
			content: .init(
				snapshotID: "snapshot",
				documentID: "document",
				frameID: "frame",
				domVersion: "1",
				nodes: [.init(index: 0, role: "button", name: "Arx reference click", reference: "opaque")],
				omissions: PageInspectionOmission.allCases
			)
		)
		let request = try AutomationClickSmoke.request(for: snapshot, name: "Arx reference click")
		expectNoDifference(request.targetID, snapshot.targetID)
		expectNoDifference(request.expectedRevision, snapshot.expectedRevision)
		expectNoDifference(request.snapshotID, snapshot.content.snapshotID)
		expectNoDifference(request.reference, "opaque")
		snapshot.content.nodes.append(snapshot.content.nodes[0])
		#expect(throws: AutomationSmokeFailure.clickMismatch) {
			try AutomationClickSmoke.request(for: snapshot, name: "Arx reference click")
		}
	}

	private static func response(
		disposition: AutomationClickDisposition = .dispatched,
		failure: AutomationFailure? = nil,
		change: String? = nil
	) throws -> CallTool.Result {
		var payload: [String: Value] = [
			"kind": .string("click"),
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
