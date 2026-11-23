import BrowserCore
import BrowserPageInteractionClient
import ChromiumEngine
import CustomDump
import Foundation
import Testing

@testable import ChromiumBrowserEngine

@MainActor
internal struct ChromiumFormAdapterTests {
	@Test(arguments: ["unavailable", "foreignTab", "foreignSnapshot", "foreignReference", "staleSource"])
	internal func rejectedIdentityNeverReachesNative(change: String) async throws {
		let fixture = FormAdapterFixture()
		let client = fixture.client
		var request = fixture.request
		switch change {
		case "unavailable": fixture.available = false
		case "foreignTab": request.target.targetID = UUID()
		case "foreignSnapshot": request.target.snapshotID = "foreign"
		case "foreignReference": request.target.reference = "foreign"
		default: fixture.current = false
		}
		let result = await client.formAuthorized(request, fixture.inspection) {
			Issue.record("Rejected identity reached submission authority")
			return true
		}
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(fixture.nativeCalls, 0)
	}

	@Test(arguments: [false, true])
	internal func keypressCapabilityIsRecheckedBeforeNativeAuthority(revokeAtSubmission: Bool) async throws {
		let fixture = FormAdapterFixture()
		var request = fixture.request
		request.kind = .keyPress
		request.value = "x"
		fixture.keypressAvailable = revokeAtSubmission
		if revokeAtSubmission { fixture.beforeAuthorize = { fixture.keypressAvailable = false } }
		defer { fixture.beforeAuthorize = nil }
		let result = await fixture.client.formAuthorized(request, fixture.inspection) {
			Issue.record("Unavailable keypress reached live authority")
			return true
		}
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(fixture.nativeCalls, revokeAtSubmission ? 1 : 0)
	}

	@Test
	internal func finalCallbackRechecksScopeImmediatelyBeforeSubmission() async throws {
		let fixture = FormAdapterFixture()
		fixture.beforeAuthorize = { fixture.current = false }
		defer { fixture.beforeAuthorize = nil }
		let result = await fixture.client.formAuthorized(fixture.request, fixture.inspection) {
			Issue.record("Stale source reached app submission callback")
			return true
		}
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, .denied)
		expectNoDifference(fixture.nativeCalls, 1)
	}

	@Test(arguments: [ChromiumReferenceFormDisposition.dispatched, .possiblyDispatched, .unchanged])
	internal func completionPreservesOutcomeAfterSourceNavigates(disposition: ChromiumReferenceFormDisposition) async throws {
		let fixture = FormAdapterFixture()
		fixture.disposition = disposition
		fixture.afterAuthorize = {
			fixture.current = false
			fixture.available = false
		}
		defer { fixture.afterAuthorize = nil }
		let result = await fixture.client.formAuthorized(fixture.request, fixture.inspection) { true }
		expectNoDifference(result.operationID, fixture.request.operationID)
		let expected: AutomationFormDisposition = switch disposition {
		case .notDispatched: .notDispatched
		case .dispatched: .dispatched
		case .possiblyDispatched: .possiblyDispatched
		case .unchanged: .unchanged
		}
		expectNoDifference(result.disposition, expected)
		expectNoDifference(result.failure, disposition == .possiblyDispatched ? .timedOut : nil)
	}

	@Test(arguments: [ChromiumReferenceFormFailure.cancelled, .staleReference, .timedOut, .notAuthorized])
	internal func knownUnchangedReceiptSurvivesLateLifecycleFailure(failure: ChromiumReferenceFormFailure) async throws {
		let fixture = FormAdapterFixture()
		fixture.disposition = .unchanged
		fixture.failure = failure
		fixture.afterAuthorize = { fixture.current = false }
		defer { fixture.afterAuthorize = nil }

		let result = await fixture.client.formAuthorized(fixture.request, fixture.inspection) { true }
		let expected: AutomationFailure = switch failure {
		case .cancelled: .cancelled
		case .staleReference: .staleReference
		case .notAuthorized: .denied
		default: .timedOut
		}
		expectNoDifference(result.disposition, .unchanged)
		expectNoDifference(result.failure, expected)
	}

	@Test
	internal func pointerRequestsMapToNativePointerActions() async throws {
		let fixture = FormAdapterFixture()
		let target = fixture.request.target
		var viewport = target
		viewport.reference = target.snapshotID
		let cases: [(AutomationFormRequest, String, ChromiumPointerAction)] = [
			(.init(target: target, kind: .hover, value: "", pointer: .init()), "opaque", .hover(at: nil)),
			(
				.init(
					target: viewport,
					kind: .pointerClick,
					value: "",
					pointer: .init(point: .init(x: 3, y: 4), clickCount: 3, modifiers: [.option])
				),
				"snapshot",
				.click(at: .init(x: 3, y: 4), count: 3, modifiers: [.option])
			),
			(
				.init(
					target: target,
					kind: .drag,
					value: "",
					pointer: .init(destinationReference: "opaque", modifiers: [.shift], steps: 5)
				),
				"opaque",
				.drag(from: nil, to: .reference("opaque"), steps: 5, modifiers: [.shift])
			),
		]
		for (request, reference, action) in cases {
			let result = await fixture.client.formAuthorized(request, fixture.inspection) { true }
			expectNoDifference(result.disposition, .dispatched)
			expectNoDifference(fixture.submitted?.reference, reference)
			expectNoDifference(fixture.submitted?.action, .pointer(action))
		}
	}

	@Test
	internal func keyboardRequestsMapToNativeKeyboardActions() async throws {
		let fixture = FormAdapterFixture()
		let target = fixture.request.target
		let cases: [(AutomationFormRequest, ChromiumReferenceFormAction)] = [
			(.init(target: target, kind: .typeText, value: "typed"), .typeText("typed")),
			(
				.init(target: target, kind: .keyChord, value: "k", keyModifiers: [.command, .option]),
				.keyChord("k", modifiers: [.command, .option])
			),
			(.init(target: target, kind: .selectValues, value: "", values: ["a", "b"]), .selectValues(["a", "b"])),
			(.init(target: target, kind: .setChecked, value: "", checked: true), .setChecked(true)),
		]
		for (request, action) in cases {
			let result = await fixture.client.formAuthorized(request, fixture.inspection) { true }
			expectNoDifference(result.disposition, .dispatched)
			expectNoDifference(fixture.submitted?.action, action)
		}
	}

	@Test
	internal func pointerDestinationsComeFromTheSameSnapshot() async throws {
		let fixture = FormAdapterFixture()
		let request = AutomationFormRequest(
			target: fixture.request.target,
			kind: .drag,
			value: "",
			pointer: .init(destinationReference: "foreign")
		)
		let result = await fixture.client.formAuthorized(request, fixture.inspection) { true }
		expectNoDifference(result.failure, .staleReference)
		expectNoDifference(fixture.nativeCalls, 0)
	}
}

@MainActor
private final class FormAdapterFixture {
	internal var available: Bool = true
	internal var keypressAvailable: Bool = true
	internal var current: Bool = true
	internal var disposition: ChromiumReferenceFormDisposition = .dispatched
	internal var nativeCalls: Int = 0
	internal var submitted: ChromiumReferenceFormRequest?
	internal var failure: ChromiumReferenceFormFailure?
	internal var beforeAuthorize: (@MainActor () -> Void)?
	internal var afterAuthorize: (@MainActor () -> Void)?
	internal let request: AutomationFormRequest
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
			kind: .replaceText,
			value: "Fixture replacement"
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
		let action = ChromiumFormAdapter.action(
			isAvailable: { [self] in available },
			keypressIsAvailable: { [self] in keypressAvailable },
			sourceIsCurrent: { [self] in current && $0 == inspection.source },
			perform: { [self] request, _, authorize in
				nativeCalls += 1
				submitted = request
				beforeAuthorize?()
				guard authorize() else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .notAuthorized)
				}
				afterAuthorize?()
				return .init(
					operationID: request.operationID,
					disposition: disposition,
					failure: failure ?? (disposition == .possiblyDispatched ? .timedOut : nil)
				)
			}
		)
		return .init(formIsAvailable: { [self] in available }, formAuthorized: action)
	}
}
