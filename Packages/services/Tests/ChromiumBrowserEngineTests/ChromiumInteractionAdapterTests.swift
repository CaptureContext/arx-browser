import BrowserCore
import BrowserPageInteractionClient
import ChromiumEngine
import CustomDump
import Foundation
import Testing

@testable import ChromiumBrowserEngine

@MainActor
internal struct ChromiumInteractionAdapterTests {
	@Test(arguments: ["unavailable", "foreignTab", "foreignSnapshot", "foreignReference", "staleSource"])
	internal func rejectedIdentityNeverReachesNative(change: String) async throws {
		let fixture = InteractionFixture()
		let client = fixture.client
		var request = fixture.request
		switch change {
		case "unavailable": fixture.available = false
		case "foreignTab": request.targetID = UUID()
		case "foreignSnapshot": request.snapshotID = "foreign"
		case "foreignReference": request.reference = "foreign"
		default: fixture.current = false
		}
		let result = await client.clickAuthorized(request, fixture.inspection) {
			Issue.record("Rejected identity reached submission authority")
			return true
		}
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(fixture.nativeCalls, 0)
	}

	@Test
	internal func finalCallbackRechecksScopeImmediatelyBeforeSubmission() async throws {
		let fixture = InteractionFixture()
		fixture.beforeAuthorize = { fixture.current = false }
		defer { fixture.beforeAuthorize = nil }
		let result = await fixture.client.clickAuthorized(fixture.request, fixture.inspection) {
			Issue.record("Stale source reached app submission callback")
			return true
		}
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, .denied)
		expectNoDifference(fixture.nativeCalls, 1)
	}

	@Test(arguments: [false, true])
	internal func completionPreservesOutcomeAfterSourceNavigates(uncertain: Bool) async throws {
		let fixture = InteractionFixture()
		fixture.uncertain = uncertain
		fixture.afterAuthorize = {
			fixture.current = false
			fixture.available = false
		}
		defer { fixture.afterAuthorize = nil }
		let result = await fixture.client.clickAuthorized(fixture.request, fixture.inspection) { true }
		expectNoDifference(result.operationID, fixture.request.operationID)
		expectNoDifference(result.disposition, uncertain ? .possiblyDispatched : .dispatched)
		expectNoDifference(result.failure, uncertain ? .timedOut : nil)
	}
}

@MainActor
private final class InteractionFixture {
	internal var available: Bool = true
	internal var current: Bool = true
	internal var uncertain: Bool = false
	internal var nativeCalls: Int = 0
	internal var beforeAuthorize: (@MainActor () -> Void)?
	internal var afterAuthorize: (@MainActor () -> Void)?
	internal let request: AutomationClickRequest
	internal let inspection: AutomationInspectionResult

	internal init() {
		let targetID = UUID()
		self.request = .init(
			operationID: UUID(),
			targetID: targetID,
			expectedRevision: String(repeating: "a", count: 64),
			snapshotID: "snapshot",
			reference: "opaque"
		)
		self.inspection = .init(
			request: .init(targetID: targetID, expectedRevision: String(repeating: "a", count: 64)),
			source: .init(
				tabID: .init(rawValue: targetID),
				profileID: .init(rawValue: UUID()),
				sessionRevision: 3,
				documentRevision: 8,
				scopeID: UUID()
			),
			snapshot: .init(
				snapshotID: "snapshot",
				documentID: "document",
				frameID: "frame",
				domVersion: "4",
				nodes: [.init(index: 0, role: "button", reference: "opaque")],
				omissions: PageInspectionOmission.allCases
			)
		)
	}

	internal var client: BrowserPageInteractionClient {
		ChromiumInteractionAdapter.client(
			isAvailable: { [self] in available },
			sourceIsCurrent: { [self] in current && $0 == inspection.source },
			click: { [self] request, _, authorize in
				nativeCalls += 1
				beforeAuthorize?()
				guard authorize() else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .notAuthorized)
				}
				afterAuthorize?()
				return .init(
					operationID: request.operationID,
					disposition: uncertain ? .possiblyDispatched : .dispatched,
					failure: uncertain ? .timedOut : nil
				)
			}
		)
	}
}
