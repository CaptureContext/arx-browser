import BrowserCore
import BrowserPageInteractionClient
import ChromiumEngine
import CustomDump
import Foundation
import Testing

@testable import ChromiumBrowserEngine

@MainActor
internal struct ChromiumScrollAdapterTests {
	@Test(arguments: ["unavailable", "foreignTab", "foreignSnapshot", "foreignReference", "staleSource", "nan", "infinite", "tooLarge"])
	internal func rejectedIdentityNeverReachesNative(change: String) async throws {
		let fixture = ScrollAdapterFixture()
		let client = fixture.client
		var request = fixture.request
		switch change {
		case "unavailable": fixture.available = false
		case "foreignTab": request.target.targetID = UUID()
		case "foreignSnapshot": request.target.snapshotID = "foreign"
		case "foreignReference": request.target.reference = "foreign"
		case "nan": request.deltaCSSPixels = .nan
		case "infinite": request.deltaCSSPixels = .infinity
		case "tooLarge": request.deltaCSSPixels = 8193
		default: fixture.current = false
		}
		let result = await client.scrollAuthorized(request, fixture.inspection) {
			Issue.record("Rejected identity reached submission authority")
			return true
		}
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(fixture.nativeCalls, 0)
	}

	@Test(arguments: AutomationScrollRequest.Axis.allCases, [-8192.0, -0.0, 120.5, 8192])
	internal func forwardsOnlyTheExplicitBoundedNativeRequest(
		axis: AutomationScrollRequest.Axis,
		delta: Double
	) async throws {
		let fixture = ScrollAdapterFixture()
		var request = fixture.request
		request.axis = axis
		request.deltaCSSPixels = delta
		let result = await fixture.client.scrollAuthorized(request, fixture.inspection) { true }

		let native = try #require(fixture.nativeRequest)
		expectNoDifference(native.operationID, request.operationID)
		expectNoDifference(native.reference, request.target.reference)
		expectNoDifference(native.snapshot.snapshotID, request.target.snapshotID)
		expectNoDifference(native.axis, axis == .horizontal ? .horizontal : .vertical)
		expectNoDifference(native.deltaCSSPixels.bitPattern, request.canonicalDelta.bitPattern)
		expectNoDifference(result.disposition, .dispatched)
	}

	@Test
	internal func foreignNativeReceiptPreservesUncertaintyWithoutBorrowingItsIdentity() async throws {
		let fixture = ScrollAdapterFixture()
		fixture.returnForeignOperation = true
		let result = await fixture.client.scrollAuthorized(fixture.request, fixture.inspection) { true }
		expectNoDifference(result.operationID, fixture.request.operationID)
		expectNoDifference(result.disposition, .possiblyDispatched)
		expectNoDifference(result.failure, .engineFailed)
	}

	@Test(arguments: [ChromiumReferenceScrollFailure.noScrollableContainer, .invalidDelta])
	internal func nativeScrollRejectionsRemainExplicit(failure: ChromiumReferenceScrollFailure) async throws {
		let fixture = ScrollAdapterFixture()
		fixture.disposition = .notDispatched
		fixture.failure = failure
		let result = await fixture.client.scrollAuthorized(fixture.request, fixture.inspection) { true }
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, failure == .noScrollableContainer ? .noScrollableContainer : .invalidDelta)
	}

	@Test
	internal func finalCallbackRechecksScopeImmediatelyBeforeSubmission() async throws {
		let fixture = ScrollAdapterFixture()
		fixture.beforeAuthorize = { fixture.current = false }
		defer { fixture.beforeAuthorize = nil }
		let result = await fixture.client.scrollAuthorized(fixture.request, fixture.inspection) {
			Issue.record("Stale source reached app submission callback")
			return true
		}
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, .denied)
		expectNoDifference(fixture.nativeCalls, 1)
	}

	@Test(arguments: [ChromiumReferenceScrollDisposition.dispatched, .possiblyDispatched, .unchanged])
	internal func completionPreservesOutcomeAfterSourceNavigates(disposition: ChromiumReferenceScrollDisposition) async throws {
		let fixture = ScrollAdapterFixture()
		fixture.disposition = disposition
		fixture.afterAuthorize = {
			fixture.current = false
			fixture.available = false
		}
		defer { fixture.afterAuthorize = nil }
		let result = await fixture.client.scrollAuthorized(fixture.request, fixture.inspection) { true }
		expectNoDifference(result.operationID, fixture.request.operationID)
		let expected: AutomationScrollDisposition = switch disposition {
		case .notDispatched: .notDispatched
		case .dispatched: .dispatched
		case .possiblyDispatched: .possiblyDispatched
		case .unchanged: .unchanged
		}
		expectNoDifference(result.disposition, expected)
		expectNoDifference(result.failure, disposition == .possiblyDispatched ? .timedOut : nil)
	}

	@Test(arguments: [ChromiumReferenceScrollFailure.cancelled, .staleReference, .timedOut, .notAuthorized])
	internal func knownUnchangedReceiptSurvivesLateLifecycleFailure(failure: ChromiumReferenceScrollFailure) async throws {
		let fixture = ScrollAdapterFixture()
		fixture.disposition = .unchanged
		fixture.failure = failure
		fixture.afterAuthorize = { fixture.current = false }
		defer { fixture.afterAuthorize = nil }

		let result = await fixture.client.scrollAuthorized(fixture.request, fixture.inspection) { true }
		let expected: AutomationFailure = switch failure {
		case .cancelled: .cancelled
		case .staleReference: .staleReference
		case .notAuthorized: .denied
		default: .timedOut
		}
		expectNoDifference(result.disposition, .unchanged)
		expectNoDifference(result.failure, expected)
	}
}

@MainActor
private final class ScrollAdapterFixture {
	internal var available: Bool = true
	internal var current: Bool = true
	internal var disposition: ChromiumReferenceScrollDisposition = .dispatched
	internal var nativeCalls: Int = 0
	internal var nativeRequest: ChromiumReferenceScrollRequest?
	internal var returnForeignOperation: Bool = false
	internal var failure: ChromiumReferenceScrollFailure?
	internal var beforeAuthorize: (@MainActor () -> Void)?
	internal var afterAuthorize: (@MainActor () -> Void)?
	internal let request: AutomationScrollRequest
	internal let inspection: AutomationInspectionResult

	internal init() {
		let targetID = UUID()
		self.request = .init(
			target: .init(
				operationID: UUID(),
				targetID: targetID,
				expectedRevision: String(repeating: "a", count: 64),
				snapshotID: "snapshot",
				reference: "opaque"
			),
			axis: .vertical,
			deltaCSSPixels: 120.5
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
		let action = ChromiumScrollAdapter.action(
			isAvailable: { [self] in available },
			sourceIsCurrent: { [self] in current && $0 == inspection.source },
			perform: { [self] request, _, authorize in
				nativeCalls += 1
				nativeRequest = request
				beforeAuthorize?()
				guard authorize() else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .notAuthorized)
				}
				afterAuthorize?()
				return .init(
					operationID: returnForeignOperation ? UUID() : request.operationID,
					disposition: disposition,
					failure: failure ?? (disposition == .possiblyDispatched ? .timedOut : nil)
				)
			}
		)
		return .init(scrollIsAvailable: { [self] in available }, scrollAuthorized: action)
	}
}
