import AppKit
import ChromiumEngine
import CustomDump
import Testing

@testable import ChromiumHost

internal struct ReferenceFormSmokeTests {
	@Test
	internal func eventsRequireExactlyTrustedUnfocusedCorrectInputAndChange() async throws {
		let valid = Data(#"""
		{
		  "events": [
		    {"target":"text", "event":"input", "trusted":true,
		     "activation":false, "focused":false, "correct":true},
		    {"target":"text", "event":"change", "trusted":true,
		     "activation":false, "focused":false, "correct":true}
		  ]
		}
		"""#.utf8)
		let events = try ReferenceFormSmokeContract.events(valid)
		try ReferenceFormSmokeContract.requireEvents(events, target: "text")
		try ReferenceFormSmokeContract.requireEvents(events.reversed(), target: "text")
		for (old, new) in [
			("\"trusted\":true", "\"trusted\":false"),
			("\"activation\":false", "\"activation\":true"),
			("\"focused\":false", "\"focused\":true"),
			("\"correct\":true", "\"correct\":false")
		] {
			let changed = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
			let incorrect = try ReferenceFormSmokeContract.events(changed)
			#expect(throws: ReferenceFormSmokeContract.Failure.unexpectedEvents) {
				try ReferenceFormSmokeContract.requireEvents(incorrect, target: "text")
			}
		}
		#expect(throws: ReferenceFormSmokeContract.Failure.unexpectedEvents) {
			try ReferenceFormSmokeContract.requireEvents(events + events, target: "text")
		}
		#expect(throws: ReferenceFormSmokeContract.Failure.invalidFixture) {
			try ReferenceFormSmokeContract.events(Data(repeating: 32, count: 16_385))
		}
	}

	@Test
	internal func mutationInputRequiresExactOwnedRunOriginAndGeometry() async throws {
		let run = UUID().uuidString.lowercased()
		let url = URL(string: "http://127.0.0.1:1234/reference-form/value?run=\(run)")!
		let point = try ReferenceFormSmokeContract.inputPoint(
			currentURL: url,
			expectedURL: url,
			bounds: .init(x: 0, y: 0, width: 640, height: 700),
			isFlipped: false
		)
		expectNoDifference(point, .init(x: 96, y: 666))
		for wrong in [
			"http://127.0.0.1:1234/reference-form/value",
			"http://127.0.0.1:1234/reference-form/value?run=invalid",
			"http://127.0.0.1:1234/reference-form/main?run=\(run)",
			"http://127.0.0.1:1234/reference-form/value?run=\(run)&other=1",
			"https://capturecontext.dev/reference-form/value?run=\(run)"
		] {
			let wrongURL = URL(string: wrong)!
			#expect(throws: ReferenceFormSmokeContract.Failure.invalidFixture) {
				try ReferenceFormSmokeContract.inputPoint(
					currentURL: wrongURL,
					expectedURL: wrongURL,
					bounds: .init(x: 0, y: 0, width: 640, height: 700),
					isFlipped: true
				)
			}
		}
		#expect(throws: ReferenceFormSmokeContract.Failure.invalidFixture) {
			try ReferenceFormSmokeContract.inputPoint(currentURL: url, expectedURL: url, bounds: .zero, isFlipped: true)
		}
	}

	@Test
	internal func unchangedReceiptIsNotWebsiteEffectAndStillRequiresNoFailure() async throws {
		let unchanged: ChromiumReferenceFormResult = .init(operationID: UUID(), disposition: .unchanged)
		try ReferenceFormSmokeContract.require(unchanged, disposition: .unchanged)
		#expect(throws: ReferenceFormSmokeContract.Failure.unexpectedReceipt) {
			try ReferenceFormSmokeContract.require(unchanged, disposition: .dispatched)
		}
		let failed: ChromiumReferenceFormResult = .init(
			operationID: UUID(),
			disposition: .unchanged,
			failure: .cancelled
		)
		#expect(throws: ReferenceFormSmokeContract.Failure.unexpectedReceipt) {
			try ReferenceFormSmokeContract.require(failed, disposition: .unchanged)
		}
	}
}
