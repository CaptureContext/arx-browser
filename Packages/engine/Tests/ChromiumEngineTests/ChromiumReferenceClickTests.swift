import AppKit
import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumReferenceClickTests {
	@Test
	internal func trustedHandoffReadinessRequiresNormalSuccessAndNeverGuessesCancellationDrain() async throws {
		let normal = ReferenceClickFixture()
		#expect(normal.bridge.submissionsAreSettled(page: 1, documentRevision: 1))
		let normalTask = Task { await normal.click() }
		let normalCall = try await normal.nextCall()
		#expect(!normal.bridge.submissionsAreSettled(page: 1, documentRevision: 1))
		normal.complete(normalCall.id)
		_ = await normalTask.value
		#expect(normal.bridge.submissionsAreSettled(page: 1, documentRevision: 1))

		let cancelled = ReferenceClickFixture()
		let task = Task { await cancelled.click() }
		let call = try await cancelled.nextCall()
		task.cancel()
		_ = await task.value

		// The real native CancelClick reply is early; DeliverClick subsequently
		// suppresses its callback. A synthetic late success must not clear it.
		cancelled.complete(call.id, disposition: ARX_CLICK_POSSIBLY_DISPATCHED, status: ARX_CLICK_CANCELLED)
		#expect(!cancelled.bridge.submissionsAreSettled(page: 1, documentRevision: 1))
		cancelled.complete(call.id)
		#expect(!cancelled.bridge.submissionsAreSettled(page: 1, documentRevision: 1))
		cancelled.bridge.stop() // native runtime teardown
		#expect(cancelled.bridge.submissionsAreSettled(page: 1, documentRevision: 1))
	}

	@Test
	internal func uncertainSubmissionBlocksOnlyItsOwnPageDocumentUntilReplacedOrClosed() async throws {
		let fixture = ReferenceClickFixture()
		fixture.documentRevision = 5
		let task = Task { await fixture.click() }
		let call = try await fixture.nextCall()
		fixture.complete(call.id, disposition: ARX_CLICK_POSSIBLY_DISPATCHED, status: ARX_CLICK_TIMEOUT)
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)

		// Another tab's page and the same page's later document are unaffected.
		#expect(fixture.bridge.submissionsAreSettled(page: 2, documentRevision: 5))
		#expect(!fixture.bridge.submissionsAreSettled(page: 1, documentRevision: 5))
		#expect(fixture.bridge.submissionsAreSettled(page: 1, documentRevision: 6))

		// The runtime releases entries for replaced documents; the entry is gone
		// even if the epoch is later compared with the original value.
		fixture.bridge.releaseSubmissions { page, revision in page == 1 && revision != 6 }
		#expect(fixture.bridge.submissionsAreSettled(page: 1, documentRevision: 5))

		// Page closure releases its entries; other pages keep theirs.
		let other = Task { await fixture.click(request: fixture.requestWithNewOperation(), page: 2) }
		_ = try await fixture.nextCall()
		other.cancel()
		_ = await other.value
		let closing = Task { await fixture.click(request: fixture.requestWithNewOperation(), page: 3) }
		_ = try await fixture.nextCall()
		closing.cancel()
		_ = await closing.value
		fixture.bridge.remove(page: 3)
		#expect(fixture.bridge.submissionsAreSettled(page: 3, documentRevision: 5))
		#expect(!fixture.bridge.submissionsAreSettled(page: 2, documentRevision: 5))
	}

	@Test
	internal func submissionWithoutKnownDocumentEpochBlocksEveryDocumentOfItsPage() async throws {
		let fixture = ReferenceClickFixture()
		fixture.documentRevision = 0
		let task = Task { await fixture.click() }
		_ = try await fixture.nextCall()
		task.cancel()
		_ = await task.value
		#expect(!fixture.bridge.submissionsAreSettled(page: 1, documentRevision: 9))
		#expect(fixture.bridge.submissionsAreSettled(page: 2, documentRevision: 9))
	}

	@Test
	internal func authorizesImmediatelyBeforeSubmissionAndDoesNotRequireCurrentSourceAfterDispatch() async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.click() }
		let call = try await fixture.nextCall()
		expectNoDifference(fixture.order, ["source", "source", "authorize", "source", "native"])
		expectNoDifference(call.operation, fixture.request.operationID.uuidString.lowercased())
		expectNoDifference(call.scope, fixture.scope.uuidString.lowercased())
		fixture.sourceFailure = .staleReference
		fixture.complete(call.id)
		let result = await task.value
		expectNoDifference(result.disposition, .dispatched)
		#expect(result.failure == nil)
	}

	@Test
	internal func authorityRevocationDuringFinalCallbackCannotSubmit() async {
		let fixture = ReferenceClickFixture()
		fixture.onAuthorize = { fixture.sourceFailure = .staleReference }
		let result = await fixture.click()
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, .staleReference)
		#expect(fixture.calls.isEmpty)
	}

	@Test
	internal func preCancelledCallerNeverAuthorizesOrSubmits() async {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.click() }
		task.cancel()
		let result = await task.value
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, .cancelled)
		#expect(fixture.calls.isEmpty)
		#expect(fixture.order.isEmpty)
		let duplicate = await fixture.click()
		expectNoDifference(duplicate.disposition, .notDispatched)
		expectNoDifference(duplicate.failure, .duplicateOperation)
	}

	@Test
	internal func cancellationPreservesUncertaintyAndLateReceiptWithoutReplaying() async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.click() }
		let call = try await fixture.nextCall()
		task.cancel()
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)
		expectNoDifference(result.failure, .cancelled)
		expectNoDifference(fixture.cancelled, [call.id])

		let duplicateWhilePending = await fixture.click()
		expectNoDifference(duplicateWhilePending.disposition, .possiblyDispatched)
		expectNoDifference(duplicateWhilePending.failure, .duplicateOperation)
		fixture.complete(call.id)
		fixture.bridge.remove(page: 1)
		fixture.sourceFailure = .staleReference
		let duplicateAfterClose = await fixture.click()
		expectNoDifference(duplicateAfterClose.disposition, .dispatched)
		expectNoDifference(duplicateAfterClose.failure, .duplicateOperation)
		#expect(fixture.calls.isEmpty)
	}

	@Test(arguments: ["scope", "page", "stop"])
	internal func disposalKeepsPossibleEffectAndNeverCompletesTwice(_ operation: String) async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.click() }
		let call = try await fixture.nextCall()
		switch operation {
		case "scope": fixture.bridge.revoke(scope: fixture.scope)
		case "page": fixture.bridge.remove(page: 1)
		default: fixture.bridge.stop()
		}
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)
		#expect(result.failure != nil)
		fixture.complete(call.id)
		let duplicate = await fixture.click()
		expectNoDifference(duplicate.failure, .duplicateOperation)
		#expect(duplicate.disposition != .notDispatched)
	}

	@Test
	internal func differentBindingNeverReceivesEarlierReceiptAndDuplicateIgnoresExpiredInput() async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.click() }
		fixture.complete(try await fixture.nextCall().id)
		_ = await task.value

		let changedScope = await fixture.click(scope: UUID())
		expectNoDifference(changedScope.disposition, .possiblyDispatched)
		expectNoDifference(changedScope.failure, .duplicateOperation)
		let invalidRetry: ChromiumReferenceClickRequest = .init(
			operationID: fixture.request.operationID,
			snapshot: fixture.request.snapshot,
			reference: fixture.request.reference,
			timeoutMilliseconds: 0
		)
		let duplicate = await fixture.click(request: invalidRetry)
		expectNoDifference(duplicate.disposition, .dispatched)
		expectNoDifference(duplicate.failure, .duplicateOperation)
		#expect(fixture.calls.isEmpty)
	}

	@Test
	internal func samePageRemainsBusyAfterCancellationUntilNativeReply() async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.click() }
		let first = try await fixture.nextCall()
		task.cancel()
		_ = await task.value
		let busy = await fixture.click(request: fixture.requestWithNewOperation())
		expectNoDifference(busy.disposition, .notDispatched)
		expectNoDifference(busy.failure, .busy)
		fixture.complete(first.id, disposition: ARX_CLICK_NOT_DISPATCHED, status: ARX_CLICK_STALE)
		let next = Task { await fixture.click(request: fixture.requestWithNewOperation()) }
		let second = try await fixture.nextCall()
		#expect(second.id > first.id)
		fixture.complete(second.id)
		let nextResult = await next.value
		expectNoDifference(nextResult.disposition, .dispatched)
	}

	@Test(arguments: [0, 2_001, Int.max])
	internal func invalidTimeoutCannotAuthorize(_ timeout: Int) async {
		let fixture = ReferenceClickFixture()
		let request: ChromiumReferenceClickRequest = .init(
			operationID: UUID(),
			snapshot: fixture.request.snapshot,
			reference: fixture.request.reference,
			timeoutMilliseconds: timeout
		)
		let result = await fixture.click(request: request)
		expectNoDifference(result.failure, .invalidResponse)
		expectNoDifference(result.disposition, .notDispatched)
		#expect(fixture.order.isEmpty)
	}

	@Test(arguments: ["wrong-page", "unknown-disposition", "inconsistent-success"])
	internal func malformedCallbackCannotErasePossibleEffects(_ kind: String) async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.click() }
		let call = try await fixture.nextCall()
		fixture.bridge.complete(
			call.id,
			page: kind == "wrong-page" ? 2 : 1,
			disposition: kind == "unknown-disposition"
			? ArxClickDisposition(rawValue: 100)
			: ARX_CLICK_NOT_DISPATCHED,
			status: ARX_CLICK_OK
		)
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)
		expectNoDifference(result.failure, .invalidResponse)
	}

	@Test
	internal func privateForeignAndStoppedRuntimeCannotReachAuthorityOrNativeAction() async {
		let fixture = ReferenceClickFixture()
		var api = ArxEngineAPI()
		api.reference_keypress_available = { false }
		api.inspect_page = { _, _, _, _ in }
		api.validate_inspection_reference = { _, _, _, _, _ in }
		api.cancel_inspection = { _ in }
		api.revoke_inspection_scope = { _ in }
		api.inspection_document_is_current = { _, _, _ in true }
		api.click_inspection_reference = { _, _, _, _, _, _, _ in
			Issue.record("Unowned page reached native click")
		}
		api.cancel_reference_click = { _ in }
		api.perform_inspection_form_action = { _, _, _, _, _, _, _, _, _, _ in
			Issue.record("Unowned page reached native form action")
		}
		api.cancel_reference_form_action = { _ in }
		api.scroll_inspection_reference = { _, _, _, _, _, _, _, _, _ in
			Issue.record("Unowned page reached native scroll")
		}
		let runtime = ChromiumRuntime(api: api)
		#expect(runtime.supportsReferenceFormActions)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		let privatePage = ChromiumPage(id: 1, view: NSView(), runtime: runtime, isPrivate: true)
		let foreignPage = ChromiumPage(id: 2, view: NSView(), runtime: runtime)
		for page in [privatePage, foreignPage] {
			let result = await runtime.clickInspectionReference(
				fixture.requestWithNewOperation(),
				on: page,
				scope: UUID(),
				authorize: {
					Issue.record("Unowned page reached authorization")
					return true
				}
			)
			expectNoDifference(result.disposition, .notDispatched)
			#expect(result.failure != nil)

			let form = await runtime.performInspectionFormAction(
				fixture.formRequest(action: .replaceText("new")),
				on: page,
				scope: UUID(),
				authorize: {
					Issue.record("Unowned page reached form authorization")
					return true
				}
			)
			expectNoDifference(form.disposition, .notDispatched)
			#expect(form.failure != nil)

			let scroll = await runtime.scrollInspectionReference(
				fixture.scrollRequest(),
				on: page,
				scope: UUID(),
				authorize: {
					Issue.record("Unowned page reached scroll authorization")
					return true
				}
			)
			expectNoDifference(scroll.disposition, .notDispatched)
			#expect(scroll.failure != nil)
		}
		runtime.finish()
		let stopped = await runtime.clickInspectionReference(
			fixture.requestWithNewOperation(),
			on: foreignPage,
			scope: UUID(),
			authorize: { true }
		)
		expectNoDifference(stopped.failure, .unavailable)
		let stoppedForm = await runtime.performInspectionFormAction(
			fixture.formRequest(action: .selectValue("option")),
			on: foreignPage,
			scope: UUID(),
			authorize: { true }
		)
		expectNoDifference(stoppedForm.failure, .unavailable)
		let stoppedScroll = await runtime.scrollInspectionReference(
			fixture.scrollRequest(),
			on: foreignPage,
			scope: UUID(),
			authorize: { true }
		)
		expectNoDifference(stoppedScroll.failure, .unavailable)
	}

	@Test
	internal func scopeReceiptExhaustionNeverEvictsEarlierOperation() async {
		let fixture = ReferenceClickFixture()
		fixture.sourceFailure = .staleReference
		for _ in 0..<256 {
			let result = await fixture.click(request: fixture.requestWithNewOperation())
			expectNoDifference(result.failure, .staleReference)
		}
		let exhausted = await fixture.click()
		expectNoDifference(exhausted.failure, .limitExceeded)
		#expect(fixture.calls.isEmpty)
	}
}

extension ChromiumReferenceClickTests {
	@Test
	internal func unchangedFormReceiptCannotReplayOrCrossActionBinding() async throws {
		let fixture = ReferenceClickFixture()
		let request = fixture.formRequest(action: .replaceText("same"))
		let task = Task { await fixture.form(request) }
		let call = try await fixture.nextCall()
		expectNoDifference(call.kind, 1)
		expectNoDifference(call.payload, Data("same".utf8))
		expectNoDifference(fixture.order, ["source", "source", "authorize", "source", "native"])

		fixture.completeForm(call.id, disposition: ARX_FORM_UNCHANGED)
		let result = await task.value
		expectNoDifference(result.disposition, .unchanged)
		#expect(result.failure == nil)

		let duplicate = await fixture.form(request)
		expectNoDifference(duplicate.disposition, .unchanged)
		expectNoDifference(duplicate.failure, .duplicateOperation)
		for changed in [
			fixture.formRequest(action: .replaceText("changed"), operation: request.operationID),
			fixture.formRequest(action: .selectValue("same"), operation: request.operationID)
		] {
			let mismatch = await fixture.form(changed)
			expectNoDifference(mismatch.disposition, .possiblyDispatched)
			expectNoDifference(mismatch.failure, .duplicateOperation)
		}

		let click = await fixture.click(request: .init(
			operationID: request.operationID,
			snapshot: request.snapshot,
			reference: request.reference
		))
		expectNoDifference(click.disposition, .possiblyDispatched)
		expectNoDifference(click.failure, .duplicateOperation)
		#expect(fixture.calls.isEmpty)
	}

	@Test(arguments: ["x", "🙂", "Enter", "Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"])
	internal func keypressUsesDistinctKindAndExactReceipt(key: String) async throws {
		let fixture = ReferenceClickFixture()
		let request = fixture.formRequest(action: .keyPress(key))
		let task = Task { await fixture.form(request) }
		let call = try await fixture.nextCall()
		expectNoDifference(call.kind, 4)
		expectNoDifference(call.payload, Data(key.utf8))
		fixture.completeForm(call.id)
		let result = await task.value
		expectNoDifference(result.disposition, .dispatched)
		fixture.keypressAvailable = false
		let duplicate = await fixture.form(request)
		expectNoDifference(duplicate.disposition, .dispatched)
		let differentKind = await fixture.form(fixture.formRequest(action: .replaceText(key), operation: request.operationID))
		expectNoDifference(differentKind.disposition, .possiblyDispatched)
		expectNoDifference(differentKind.failure, .duplicateOperation)
	}

	@Test
	internal func pointerActionsSendCanonicalPayloadsWithTheirOwnKinds() async throws {
		let fixture = ReferenceClickFixture()
		let snapshot = fixture.request.snapshot
		let destination = fixture.request.reference
		let cases: [(ChromiumPointerAction, String, UInt32, String)] = [
			(.hover(at: nil), fixture.request.reference, 8, ""),
			(.hover(at: .init(x: 12.5, y: 40)), snapshot.snapshotID, 8, "x=12.5;y=40;"),
			(
				.click(at: nil, count: 2, modifiers: [.shift, .command]),
				fixture.request.reference,
				16,
				"clicks=2;modifiers=9;"
			),
			(
				.drag(from: nil, to: .reference(destination), steps: 8, modifiers: []),
				fixture.request.reference,
				32,
				"to=\(destination);modifiers=0;steps=8;"
			),
			(
				.drag(from: .init(x: 1, y: 2), to: .point(.init(x: 3, y: 4)), steps: 1, modifiers: [.option]),
				snapshot.snapshotID,
				32,
				"x=1;y=2;tx=3;ty=4;modifiers=4;steps=1;"
			),
		]
		for (action, reference, kind, payload) in cases {
			let request = ChromiumReferenceFormRequest(
				operationID: UUID(),
				snapshot: snapshot,
				reference: reference,
				action: .pointer(action)
			)
			let task = Task { await fixture.form(request) }
			let call = try await fixture.nextCall()
			expectNoDifference(call.kind, kind)
			expectNoDifference(String(decoding: call.payload, as: UTF8.self), payload)
			fixture.completeForm(call.id)
			let result = await task.value
			expectNoDifference(result.disposition, .dispatched)
		}
		#expect(ChromiumPointerAction.hover(at: nil).consumesSnapshot == false)
		#expect(ChromiumPointerAction.click(at: nil, count: 1, modifiers: []).consumesSnapshot)
	}

	@Test(arguments: ["point-with-reference", "reference-without-point", "foreign-destination", "count", "steps", "range"])
	internal func invalidPointerRequestsNeverReachNative(_ kind: String) async throws {
		let fixture = ReferenceClickFixture()
		let snapshot = fixture.request.snapshot
		let reference = fixture.request.reference
		let (action, target): (ChromiumPointerAction, String) = switch kind {
		case "point-with-reference": (.hover(at: .init(x: 1, y: 1)), reference)
		case "reference-without-point": (.hover(at: nil), snapshot.snapshotID)
		case "foreign-destination":
			(.drag(from: nil, to: .reference(String(repeating: "e", count: 32)), steps: 1, modifiers: []), reference)
		case "count": (.click(at: nil, count: 4, modifiers: []), reference)
		case "steps": (.drag(from: nil, to: .point(.init(x: 1, y: 1)), steps: 33, modifiers: []), reference)
		default: (.hover(at: .init(x: -1, y: .infinity)), snapshot.snapshotID)
		}
		let result = await fixture.form(.init(
			operationID: UUID(),
			snapshot: snapshot,
			reference: target,
			action: .pointer(action)
		))
		expectNoDifference(result.disposition, .notDispatched)
		#expect(result.failure == .invalidValue || result.failure == .invalidResponse)
		#expect(fixture.calls.isEmpty)
	}

	@Test
	internal func keyboardActionsSendTheirOwnKindsAndPayloads() async throws {
		let fixture = ReferenceClickFixture()
		let cases: [(ChromiumReferenceFormAction, UInt32, String)] = [
			(.typeText("ab🙂\nc"), 64, "ab🙂\nc"),
			(.keyChord("k", modifiers: [.control, .shift]), 128, "3:k"),
			(.keyChord("Tab", modifiers: []), 128, "0:Tab"),
			(.keyChord("F12", modifiers: [.command, .option]), 128, "12:F12"),
			(.selectValues(["a", "b \"c\""]), 256, #"["a","b \"c\""]"#),
			(.selectValues([]), 256, "[]"),
			(.setChecked(true), 512, "1"),
			(.setChecked(false), 512, "0"),
		]
		for (action, kind, payload) in cases {
			let task = Task { await fixture.form(fixture.formRequest(action: action)) }
			let call = try await fixture.nextCall()
			expectNoDifference(call.kind, kind)
			expectNoDifference(String(decoding: call.payload, as: UTF8.self), payload)
			fixture.completeForm(call.id)
			let result = await task.value
			expectNoDifference(result.disposition, .dispatched)
		}
	}

	@Test(arguments: [
		ChromiumReferenceFormAction.typeText(""),
		.typeText("tab\there"),
		.typeText(String(repeating: "a", count: 1_025)),
		.keyChord("F13", modifiers: []),
		.keyChord("ab", modifiers: []),
		.keyChord("\u{7F}", modifiers: []),
		.selectValues(["same", "same"]),
		.selectValues(Array(repeating: "", count: 65).enumerated().map { "\($0.offset)" }),
	])
	internal func invalidKeyboardActionsNeverReachNative(_ action: ChromiumReferenceFormAction) async throws {
		let fixture = ReferenceClickFixture()
		let result = await fixture.form(fixture.formRequest(action: action))
		expectNoDifference(result.disposition, .notDispatched)
		#expect(result.failure == .invalidValue || result.failure == .limitExceeded)
		#expect(fixture.calls.isEmpty)
	}

	@Test
	internal func obscuredPointerStatusStaysTyped() async throws {
		let fixture = ReferenceClickFixture()
		let task = Task {
			await fixture.form(fixture.formRequest(action: .pointer(.click(at: nil, count: 1, modifiers: []))))
		}
		let call = try await fixture.nextCall()
		fixture.completeForm(call.id, disposition: ARX_FORM_NOT_DISPATCHED, status: ARX_FORM_OBSCURED)
		let result = await task.value
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, .obscured)
	}

	@Test(arguments: ["", "Tab", "Escape", "Control+a", "ab", "e\u{0301}", "\n", "\u{2028}", "\u{FFFF}"])
	internal func unsupportedKeysNeverReachNative(key: String) async throws {
		let fixture = ReferenceClickFixture()
		let result = await fixture.form(fixture.formRequest(action: .keyPress(key)))
		expectNoDifference(result.failure, .invalidValue)
		expectNoDifference(result.disposition, .notDispatched)
		#expect(fixture.calls.isEmpty)
	}

	@Test
	internal func keypressRequiresCapabilityAndCancellationHoldsSharedLane() async throws {
		let fixture = ReferenceClickFixture()
		fixture.keypressAvailable = false
		let unavailable = await fixture.form(fixture.formRequest(action: .keyPress("x")))
		expectNoDifference(unavailable.failure, .unavailable)
		#expect(fixture.calls.isEmpty)
		fixture.keypressAvailable = true
		let request = fixture.formRequest(action: .keyPress("x"))
		let task = Task { await fixture.form(request) }
		let call = try await fixture.nextCall()
		task.cancel()
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)
		expectNoDifference(fixture.formCancelled, [call.id])
		let click = await fixture.click()
		expectNoDifference(click.failure, .busy)
		fixture.completeForm(call.id)
		let duplicate = await fixture.form(request)
		expectNoDifference(duplicate.disposition, .dispatched)
	}

	@Test
	internal func clickAndFormSharePhysicalSlotAfterCancellation() async throws {
		let fixture = ReferenceClickFixture()
		let request = fixture.formRequest(action: .selectValue("option"))
		let task = Task { await fixture.form(request) }
		let call = try await fixture.nextCall()
		task.cancel()
		let cancelled = await task.value
		expectNoDifference(cancelled.disposition, .possiblyDispatched)
		expectNoDifference(cancelled.failure, .cancelled)
		expectNoDifference(fixture.formCancelled, [call.id])

		let blockedClick = await fixture.click()
		expectNoDifference(blockedClick.failure, .busy)
		let blockedForm = await fixture.form(fixture.formRequest(action: .replaceText("new")))
		expectNoDifference(blockedForm.failure, .busy)

		fixture.completeForm(call.id, disposition: ARX_FORM_UNCHANGED)
		let duplicate = await fixture.form(request)
		expectNoDifference(duplicate.disposition, .unchanged)
		expectNoDifference(duplicate.failure, .duplicateOperation)

		let clickTask = Task { await fixture.click(request: fixture.requestWithNewOperation()) }
		let clickCall = try await fixture.nextCall()
		#expect(clickCall.id > call.id)
		let formDuringClick = await fixture.form(fixture.formRequest(action: .replaceText("later")))
		expectNoDifference(formDuringClick.failure, .busy)
		fixture.complete(clickCall.id)
		let clickResult = await clickTask.value
		expectNoDifference(clickResult.disposition, .dispatched)
	}

	@Test(arguments: ["oversized-text", "oversized-option", "text-nul", "option-nul"])
	internal func invalidFormPayloadCannotReachAuthority(_ kind: String) async throws {
		let fixture = ReferenceClickFixture()
		let action: ChromiumReferenceFormAction = switch kind {
		case "oversized-text": .replaceText(String(repeating: "é", count: 16_385))
		case "oversized-option": .selectValue(String(repeating: "é", count: 2_049))
		case "text-nul": .replaceText("before\0after")
		default: .selectValue("before\0after")
		}
		let result = await fixture.form(fixture.formRequest(action: action))
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, kind.hasPrefix("oversized") ? .limitExceeded : .invalidValue)
		#expect(fixture.calls.isEmpty)
		#expect(fixture.order.isEmpty)
	}

	@Test(arguments: ["empty-text", "empty-option", "maximum-text", "maximum-option"])
	internal func exactPayloadBoundariesAreCopiedWithoutNormalization(_ kind: String) async throws {
		let fixture = ReferenceClickFixture()
		let value = kind.hasPrefix("empty") ? "" : String(
			repeating: "é",
			count: kind == "maximum-text" ? 16_384 : 2_048
		)
		let action: ChromiumReferenceFormAction = kind.hasSuffix("text")
		? .replaceText(value)
		: .selectValue(value)
		let task = Task { await fixture.form(fixture.formRequest(action: action)) }
		let call = try await fixture.nextCall()
		expectNoDifference(call.payload, Data(value.utf8))
		fixture.completeForm(call.id)
		let result = await task.value
		expectNoDifference(result.disposition, .dispatched)
	}

	@Test
	internal func formAuthorityRevocationAndPreCancellationNeverSubmit() async throws {
		let fixture = ReferenceClickFixture()
		fixture.onAuthorize = { fixture.sourceFailure = .staleReference }
		let denied = await fixture.form(fixture.formRequest(action: .replaceText("new")))
		expectNoDifference(denied.disposition, .notDispatched)
		expectNoDifference(denied.failure, .staleReference)
		#expect(fixture.calls.isEmpty)

		fixture.order.removeAll()
		let task = Task { await fixture.form(fixture.formRequest(action: .replaceText("new"))) }
		task.cancel()
		let cancelled = await task.value
		expectNoDifference(cancelled.disposition, .notDispatched)
		expectNoDifference(cancelled.failure, .cancelled)
		#expect(fixture.calls.isEmpty)
		#expect(fixture.order.isEmpty)
	}

	@Test(arguments: [
		"wrong-kind", "wrong-page", "unknown-disposition", "unknown-status",
		"inconsistent-success"
	])
	internal func malformedFormReplyCannotErasePossibleEffect(_ kind: String) async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.form(fixture.formRequest(action: .replaceText("new"))) }
		let call = try await fixture.nextCall()
		if kind == "wrong-kind" {
			fixture.complete(call.id)

		} else {
			let disposition: ArxFormDisposition = switch kind {
			case "unknown-disposition": .init(rawValue: 100)
			default: ARX_FORM_NOT_DISPATCHED
			}
			let status: ArxFormStatus = switch kind {
			case "unknown-status": .init(rawValue: 100)
			default: ARX_FORM_OK
			}
			fixture.bridge.completeFormAction(
				call.id,
				page: kind == "wrong-page" ? 2 : 1,
				disposition: disposition,
				status: status
			)
		}
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)
		expectNoDifference(result.failure, .invalidResponse)
	}

	@Test(arguments: ["scope", "page", "stop"])
	internal func formDisposalRetainsUncertaintyAndLateReceipt(_ kind: String) async throws {
		let fixture = ReferenceClickFixture()
		let request = fixture.formRequest(action: .replaceText("new"))
		let task = Task { await fixture.form(request) }
		let call = try await fixture.nextCall()
		switch kind {
		case "scope": fixture.bridge.revoke(scope: fixture.scope)
		case "page": fixture.bridge.remove(page: 1)
		default: fixture.bridge.stop()
		}
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)
		#expect(result.failure != nil)

		fixture.completeForm(call.id)
		let duplicate = await fixture.form(request)
		expectNoDifference(duplicate.failure, .duplicateOperation)
		#expect(duplicate.disposition != .notDispatched)
	}

	@Test(arguments: [
		ARX_FORM_UNSUPPORTED_CONTROL,
		ARX_FORM_INVALID_VALUE,
		ARX_FORM_OPTION_NOT_FOUND,
		ARX_FORM_AMBIGUOUS_OPTION
	])
	internal func nativeControlFailuresRemainTyped(_ status: ArxFormStatus) async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.form(fixture.formRequest(action: .selectValue("option"))) }
		let call = try await fixture.nextCall()
		fixture.completeForm(call.id, disposition: ARX_FORM_NOT_DISPATCHED, status: status)
		let result = await task.value
		let expected: ChromiumReferenceFormFailure = switch status {
		case ARX_FORM_UNSUPPORTED_CONTROL: .unsupportedControl
		case ARX_FORM_INVALID_VALUE: .invalidValue
		case ARX_FORM_OPTION_NOT_FOUND: .optionNotFound
		default: .ambiguousOption
		}
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, expected)
	}

	@Test(arguments: [ARX_FORM_STALE, ARX_FORM_CANCELLED, ARX_FORM_TIMEOUT, ARX_FORM_NOT_AUTHORIZED])
	internal func knownUnchangedSurvivesLifecycleFailureBeforePostedDelivery(_ status: ArxFormStatus) async throws {
		let fixture = ReferenceClickFixture()
		let request = fixture.formRequest(action: .replaceText("same"))
		let task = Task { await fixture.form(request) }
		let call = try await fixture.nextCall()

		// Native has already recorded the renderer's unchanged outcome. A page
		// lifecycle event wins before its separately posted Swift delivery.
		fixture.completeForm(call.id, disposition: ARX_FORM_UNCHANGED, status: status)
		let result = await task.value
		expectNoDifference(result.disposition, .unchanged)
		let expected: ChromiumReferenceFormFailure = switch status {
		case ARX_FORM_STALE: .staleReference
		case ARX_FORM_CANCELLED: .cancelled
		case ARX_FORM_TIMEOUT: .timedOut
		default: .notAuthorized
		}
		expectNoDifference(result.failure, expected)

		let duplicate = await fixture.form(request)
		expectNoDifference(duplicate.disposition, .unchanged)
		expectNoDifference(duplicate.failure, .duplicateOperation)
		#expect(fixture.calls.isEmpty)
	}

	@Test
	internal func scopeCapacityIsSharedAcrossActionKinds() async throws {
		let fixture = ReferenceClickFixture()
		fixture.sourceFailure = .staleReference
		for _ in 0..<128 {
			_ = await fixture.click(request: fixture.requestWithNewOperation())
			_ = await fixture.form(fixture.formRequest(action: .replaceText("new")))
		}
		let exhausted = await fixture.form(fixture.formRequest(action: .selectValue("option")))
		expectNoDifference(exhausted.failure, .limitExceeded)
		#expect(fixture.calls.isEmpty)
	}

	@Test(arguments: [Double.nan, .infinity, -.infinity, 8_192.01, -8_192.01])
	internal func invalidScrollDeltaNeverSerializesOrAuthorizes(_ delta: Double) async throws {
		let fixture = ReferenceClickFixture()
		let result = await fixture.scroll(fixture.scrollRequest(delta: delta))
		expectNoDifference(result.disposition, .notDispatched)
		expectNoDifference(result.failure, .invalidDelta)
		#expect(fixture.calls.isEmpty)
		#expect(fixture.order.isEmpty)
	}

	@Test
	internal func scrollZeroCanonicalizationAndActionBindingNeverReplay() async throws {
		let fixture = ReferenceClickFixture()
		let request = fixture.scrollRequest(delta: -0.0)
		let task = Task { await fixture.scroll(request) }
		let call = try await fixture.nextCall()
		expectNoDifference(fixture.order, ["source", "source", "authorize", "source", "native"])
		expectNoDifference(call.axis, 1)
		expectNoDifference(call.delta.bitPattern, Double(0).bitPattern)
		fixture.completeScroll(call.id, disposition: ARX_SCROLL_UNCHANGED)
		let result = await task.value
		expectNoDifference(result.disposition, .unchanged)
		#expect(result.failure == nil)

		let duplicate = await fixture.scroll(fixture.scrollRequest(delta: 0, operation: request.operationID))
		expectNoDifference(duplicate.disposition, .unchanged)
		expectNoDifference(duplicate.failure, .duplicateOperation)
		for changed in [
			fixture.scrollRequest(delta: 1, operation: request.operationID),
			fixture.scrollRequest(delta: 0, axis: .horizontal, operation: request.operationID),
		] {
			let different = await fixture.scroll(changed)
			expectNoDifference(different.disposition, .possiblyDispatched)
			expectNoDifference(different.failure, .duplicateOperation)
		}
		let form = await fixture.form(fixture.formRequest(action: .selectValue("0"), operation: request.operationID))
		expectNoDifference(form.disposition, .possiblyDispatched)
		expectNoDifference(form.failure, .duplicateOperation)
		#expect(fixture.calls.isEmpty)
	}

	@Test
	internal func scrollCancellationHoldsSharedFormLaneUntilLateReply() async throws {
		let fixture = ReferenceClickFixture()
		let request = fixture.scrollRequest()
		let task = Task { await fixture.scroll(request) }
		let call = try await fixture.nextCall()
		task.cancel()
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)
		expectNoDifference(result.failure, .cancelled)
		expectNoDifference(fixture.cancelled, [call.id])

		let busy = await fixture.form(fixture.formRequest(action: .replaceText("new")))
		expectNoDifference(busy.failure, .busy)
		fixture.completeScroll(call.id, disposition: ARX_SCROLL_UNCHANGED)
		let duplicate = await fixture.scroll(request)
		expectNoDifference(duplicate.disposition, .unchanged)
		expectNoDifference(duplicate.failure, .duplicateOperation)
		let next = Task { await fixture.form(fixture.formRequest(action: .replaceText("new"))) }
		fixture.completeForm(try await fixture.nextCall().id)
		let nextResult = await next.value
		expectNoDifference(nextResult.disposition, .dispatched)
	}

	@Test(arguments: [
		ARX_SCROLL_STALE.rawValue,
		ARX_SCROLL_CANCELLED.rawValue,
		ARX_SCROLL_TIMEOUT.rawValue,
		ARX_SCROLL_NOT_AUTHORIZED.rawValue,
	])
	internal func scrollPreservesKnownUnchangedDuringPostedDeliveryRace(_ status: UInt32) async throws {
		let fixture = ReferenceClickFixture()
		let request = fixture.scrollRequest()
		let task = Task { await fixture.scroll(request) }
		fixture.completeScroll(
			try await fixture.nextCall().id,
			disposition: ARX_SCROLL_UNCHANGED,
			status: .init(rawValue: status)
		)
		let result = await task.value
		expectNoDifference(result.disposition, .unchanged)
		#expect(result.failure != nil)
		let duplicate = await fixture.scroll(request)
		expectNoDifference(duplicate.disposition, .unchanged)
	}

	@Test
	internal func wrongCallbackFamilyCannotConfirmScroll() async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.scroll(fixture.scrollRequest()) }
		fixture.completeForm(try await fixture.nextCall().id)
		let result = await task.value
		expectNoDifference(result.disposition, .possiblyDispatched)
		expectNoDifference(result.failure, .invalidResponse)
	}

	@Test
	internal func scrollFinalAuthorityAndPreCancellationCannotSubmit() async throws {
		let fixture = ReferenceClickFixture()
		let task = Task { await fixture.scroll(fixture.scrollRequest()) }
		task.cancel()
		let cancelled = await task.value
		expectNoDifference(cancelled.failure, .cancelled)
		#expect(fixture.order.isEmpty)

		fixture.onAuthorize = { fixture.sourceFailure = .staleReference }
		let stale = await fixture.scroll(fixture.scrollRequest())
		expectNoDifference(stale.failure, .staleReference)
		#expect(fixture.calls.isEmpty)
	}

}

@MainActor
private final class ReferenceClickFixture {
	private static var active: ReferenceClickFixture?
	internal let bridge: ChromiumReferenceClicks
	internal let scope: UUID = .init()
	internal let request: ChromiumReferenceClickRequest
	internal var calls: [Call] = []
	internal var cancelled: [UInt64] = []
	internal var formCancelled: [UInt64] = []
	internal var order: [String] = []
	internal var sourceFailure: ChromiumReferenceClickFailure?
	internal var documentRevision: UInt64 = 1
	internal var authorized: Bool = true
	internal var keypressAvailable: Bool = true
	internal var onAuthorize: (() -> Void)?

	internal init() {
		let reference = String(repeating: "a", count: 32)
		self.request = .init(
			operationID: UUID(),
			snapshot: .init(
				snapshotID: String(repeating: "b", count: 32),
				documentID: String(repeating: "c", count: 32),
				frameID: String(repeating: "d", count: 32),
				domVersion: "42",
				nodes: [.init(
					index: 0,
					parent: nil,
					role: "button",
					name: "Action",
					text: nil,
					reference: reference
				)],
				omissions: ChromiumInspectionOmission.allCases
			),
			reference: reference
		)
		var api = ArxEngineAPI()
		api.reference_keypress_available = {
			MainActor.assumeIsolated { ReferenceClickFixture.active?.keypressAvailable == true }
		}
		api.click_inspection_reference = { page, request, scope, _, _, operation, _ in
			MainActor.assumeIsolated {
				guard let fixture = ReferenceClickFixture.active
				else { return }
				fixture.order.append("native")
				fixture.calls.append(.init(
					id: request,
					page: page,
					scope: scope.map { String(cString: $0) } ?? "",
					operation: operation.map { String(cString: $0) } ?? ""
				))
			}
		}
		api.cancel_reference_click = { request in
			MainActor.assumeIsolated {
				ReferenceClickFixture.active?.cancelled.append(request)
			}
		}
		api.perform_inspection_form_action = { page, request, scope, _, _, operation, kind, bytes, count, _ in
			MainActor.assumeIsolated {
				guard let fixture = ReferenceClickFixture.active
				else { return }

				fixture.order.append("native")
				fixture.calls.append(.init(
					id: request,
					page: page,
					scope: scope.map { String(cString: $0) } ?? "",
					operation: operation.map { String(cString: $0) } ?? "",
					kind: kind.rawValue,
					payload: bytes.map { Data(bytes: $0, count: count) } ?? .init()
				))
			}
		}
		api.cancel_reference_form_action = { request in
			MainActor.assumeIsolated {
				ReferenceClickFixture.active?.formCancelled.append(request)
			}
		}
		api.scroll_inspection_reference = { page, request, scope, _, _, operation, axis, delta, _ in
			MainActor.assumeIsolated {
				guard let fixture = ReferenceClickFixture.active else { return }
				fixture.order.append("native")
				fixture.calls.append(.init(
					id: request,
					page: page,
					scope: scope.map { String(cString: $0) } ?? "",
					operation: operation.map { String(cString: $0) } ?? "",
					kind: 3,
					axis: axis.rawValue,
					delta: delta
				))
			}
		}
		self.bridge = .init(api: api)
		Self.active = self
	}

	internal func requestWithNewOperation() -> ChromiumReferenceClickRequest {
		.init(operationID: UUID(), snapshot: request.snapshot, reference: request.reference)
	}

	internal func click(
		request: ChromiumReferenceClickRequest? = nil,
		page: UInt64 = 1,
		scope: UUID? = nil
	) async -> ChromiumReferenceClickResult {
		await bridge.click(
			request ?? self.request,
			page: page,
			scope: scope ?? self.scope,
			documentRevision: { self.documentRevision },
			validateSource: {
				self.order.append("source")
				return self.sourceFailure
			},
			authorize: {
				self.order.append("authorize")
				self.onAuthorize?()
				return self.authorized
			}
		)
	}

	internal func formRequest(
		action: ChromiumReferenceFormAction,
		operation: UUID = UUID()
	) -> ChromiumReferenceFormRequest {
		.init(
			operationID: operation,
			snapshot: request.snapshot,
			reference: request.reference,
			action: action
		)
	}

	internal func form(_ request: ChromiumReferenceFormRequest) async -> ChromiumReferenceFormResult {
		await bridge.formAction(
			request,
			page: 1,
			scope: scope,
			documentRevision: { self.documentRevision },
			validateSource: {
				self.order.append("source")
				return self.sourceFailure == nil ? nil : .staleReference
			},
			authorize: {
				self.order.append("authorize")
				self.onAuthorize?()
				return self.authorized
			}
		)
	}

	internal func scrollRequest(
		delta: Double = 80,
		axis: ChromiumReferenceScrollAxis = .vertical,
		operation: UUID = UUID()
	) -> ChromiumReferenceScrollRequest {
		.init(
			operationID: operation,
			snapshot: request.snapshot,
			reference: request.reference,
			axis: axis,
			deltaCSSPixels: delta
		)
	}

	internal func scroll(_ request: ChromiumReferenceScrollRequest) async -> ChromiumReferenceScrollResult {
		await bridge.scroll(
			request,
			page: 1,
			scope: scope,
			documentRevision: { self.documentRevision },
			validateSource: {
				self.order.append("source")
				return self.sourceFailure == nil ? nil : .staleReference
			},
			authorize: {
				self.order.append("authorize")
				self.onAuthorize?()
				return self.authorized
			}
		)
	}

	internal func completeScroll(
		_ id: UInt64,
		disposition: ArxScrollDisposition = ARX_SCROLL_DISPATCHED,
		status: ArxScrollStatus = ARX_SCROLL_OK
	) {
		bridge.completeScroll(id, page: 1, disposition: disposition, status: status)
	}

	internal func completeForm(
		_ id: UInt64,
		disposition: ArxFormDisposition = ARX_FORM_DISPATCHED,
		status: ArxFormStatus = ARX_FORM_OK
	) {
		bridge.completeFormAction(id, page: 1, disposition: disposition, status: status)
	}

	internal func nextCall() async throws -> Call {
		for _ in 0..<1_000 {
			if !calls.isEmpty { return calls.removeFirst() }
			await Task.yield()
		}
		throw FixtureFailure.missingCall
	}

	internal func complete(
		_ id: UInt64,
		page: UInt64 = 1,
		disposition: ArxClickDisposition = ARX_CLICK_DISPATCHED,
		status: ArxClickStatus = ARX_CLICK_OK
	) {
		bridge.complete(id, page: page, disposition: disposition, status: status)
	}

	internal struct Call {
		internal let id: UInt64
		internal let page: UInt64
		internal let scope: String
		internal let operation: String
		internal let kind: UInt32
		internal let payload: Data
		internal let axis: UInt32
		internal let delta: Double

		internal init(
			id: UInt64,
			page: UInt64,
			scope: String,
			operation: String,
			kind: UInt32 = 0,
			payload: Data = .init(),
			axis: UInt32 = 0,
			delta: Double = 0
		) {
			self.id = id
			self.page = page
			self.scope = scope
			self.operation = operation
			self.kind = kind
			self.payload = payload
			self.axis = axis
			self.delta = delta
		}
	}

	internal enum FixtureFailure: Error {
		case missingCall
	}
}
