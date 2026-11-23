import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
internal struct AutomationInspectionSmokeTests {
	@Test
	internal func publicEnvelopePreservesHistoricalContentWithoutPrivateScope() async throws {
		let request = Self.request
		let snapshot = try AutomationInspectionSmoke.verify(
			AutomationInspectionSmoke.decode(Self.response()),
			request: request,
			profileID: .init(rawValue: UUID(1))
		)
		expectNoDifference(snapshot.content.nodes.first?.text, "Untrusted website text")
		expectNoDifference(snapshot.content.domVersion, "4")
		expectNoDifference(snapshot.sessionRevision, 3)
		expectNoDifference(snapshot.documentRevision, 8)
		var stale = request
		stale.expectedRevision = String(repeating: "b", count: 64)
		#expect(throws: AutomationSmokeFailure.inspectionMismatch) {
			try AutomationInspectionSmoke.verify(.snapshot(snapshot), request: stale, profileID: .init(rawValue: UUID(1)))
		}
	}

	@Test(arguments: ["trusted", "current", "actionAuthority", "changedText", "missingOmissions"])
	internal func malformedOrOverstatedPublicEvidenceIsRejected(change: String) async throws {
		let response = try Self.response(change: change)
		#expect(throws: (any Error).self) {
			try AutomationInspectionSmoke.verify(
				AutomationInspectionSmoke.decode(response),
				request: Self.request,
				profileID: .init(rawValue: UUID(1))
			)
		}
	}

	@Test
	internal func fixtureEvidenceRequiresSafeTextExplicitReferenceAndAllOmissions() async throws {
		var snapshot = try AutomationInspectionSmoke.verify(
			AutomationInspectionSmoke.decode(Self.response()),
			request: Self.request,
			profileID: .init(rawValue: UUID(1))
		)
		snapshot.content.nodes = [
			.init(index: 0, role: "staticText", text: "ARX_INSPECTION_SAFE_TEXT ARX_INSPECTION_SAFE_SHADOW_TEXT"),
			.init(index: 1, role: "button", name: "Arx inspection button", reference: "opaque"),
		]
		try AutomationInspectionSmoke.verifyFixtureContent(snapshot)
		for secret in [
			"ARX_PASSWORD_SECRET", "ARX_FORM_VALUE_SECRET", "ARX_SHADOW_PASSWORD_SECRET", "ARX_FORMER_PASSWORD_SECRET",
			"ARX_FRAME_SECRET", "ARX_CROSS_ORIGIN_SECRET", "ARX_CANVAS_FALLBACK_SECRET",
			"ARX_EDITABLE_SECRET", "ARX_GENERATED_SECRET", "ARX_BUTTON_NESTED_SECRET",
		] {
			var leaked = snapshot
			leaked.content.nodes.append(.init(index: 2, role: "staticText", text: secret))
			#expect(throws: AutomationSmokeFailure.inspectionMismatch) {
				try AutomationInspectionSmoke.verifyFixtureContent(leaked)
			}
		}
		snapshot.content.nodes[1].reference = nil
		#expect(throws: AutomationSmokeFailure.inspectionMismatch) {
			try AutomationInspectionSmoke.verifyFixtureContent(snapshot)
		}
	}

	private static var request: AutomationInspectionRequest {
		.init(targetID: UUID(2), expectedRevision: String(repeating: "a", count: 64))
	}

	private static func response(change: String? = nil) throws -> CallTool.Result {
		var snapshot: [String: Value] = [
			"kind": .string("inspection"),
			"targetID": .string(request.targetID.uuidString),
			"expectedRevision": .string(request.expectedRevision),
			"profileID": .string(UUID(1).uuidString),
			"sessionRevision": .string("3"),
			"documentRevision": .string("8"),
			"snapshotID": .string("snapshot"),
			"documentID": .string("document"),
			"frameID": .string("frame"),
			"domVersion": .string("4"),
			"historical": .bool(true),
			"referencesAuthorizeActions": .bool(false),
			"nodes": try Value([PageInspectionNode(index: 0, role: "staticText", text: "Untrusted website text")]),
			"omissions": try Value(PageInspectionOmission.allCases),
		]
		if change == "current" { snapshot["historical"] = .bool(false) }
		if change == "actionAuthority" { snapshot["referencesAuthorizeActions"] = .bool(true) }
		if change == "missingOmissions" { snapshot["omissions"] = .array([]) }
		let envelope: Value = .object([
			"untrustedData": .bool(change != "trusted"),
			"result": .object(snapshot),
		])
		let text = change == "changedText"
		? "{}"
		: String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
		return .init(
			content: [.text(text: text, annotations: nil, _meta: nil)],
			structuredContent: Optional(envelope),
			isError: false
		)
	}
}
