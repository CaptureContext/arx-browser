import ChromiumEngine
import Foundation
import Testing

@testable import ChromiumHost

internal struct ReferenceScrollSmokeTests {
	@Test
	internal func evidenceRequiresBoundedFiniteOffsetsAndTrustedUnfocusedEffect() throws {
		let valid = #"""
		{
		  "innerX":0,"innerY":80,"outerX":0,"outerY":0,"pageX":0,"pageY":0,
		  "sample":2,"events":1,"focused":false,"activation":false,
		  "trusted":true,"innerAtEnd":false
		}
		"""#
		let evidence = try ReferenceScrollSmokeContract.evidence(Data(valid.utf8))
		#expect(evidence.offsets == [0, 80, 0, 0, 0, 0])
		try ReferenceScrollSmokeContract.requireSafe(evidence)

		for (old, replacement) in [
			("\"focused\":false", "\"focused\":true"),
			("\"activation\":false", "\"activation\":true"),
			("\"trusted\":true", "\"trusted\":false")
		] {
			let data = Data(valid.replacingOccurrences(of: old, with: replacement).utf8)
			let changed = try ReferenceScrollSmokeContract.evidence(data)
			#expect(throws: ReferenceScrollSmokeContract.Failure.unexpectedEffect) {
				try ReferenceScrollSmokeContract.requireSafe(changed)
			}
		}

		for (old, replacement) in [
			("\"sample\":2", "\"sample\":0"),
			("\"events\":1", "\"events\":10001"),
			("\"innerY\":80", "\"innerY\":100001")
		] {
			let data = Data(valid.replacingOccurrences(of: old, with: replacement).utf8)
			#expect(throws: ReferenceScrollSmokeContract.Failure.invalidFixture) {
				try ReferenceScrollSmokeContract.evidence(data)
			}
		}
		#expect(throws: ReferenceScrollSmokeContract.Failure.invalidFixture) {
			try ReferenceScrollSmokeContract.evidence(Data(repeating: 32, count: 4_097))
		}
	}

	@Test
	internal func navigationAllowsOnlyKnownDispatchOrDocumentInvalidationUncertainty() throws {
		let dispositions: [ChromiumReferenceScrollDisposition] = [
			.notDispatched, .dispatched, .possiblyDispatched, .unchanged
		]
		for disposition in dispositions {
			for failure: ChromiumReferenceScrollFailure? in [nil, .staleReference, .timedOut, .cancelled] {
				let result = ChromiumReferenceScrollResult(
					operationID: UUID(),
					disposition: disposition,
					failure: failure
				)
				let expected = disposition == .dispatched && failure == nil
				|| disposition == .possiblyDispatched && failure == .staleReference
				if expected {
					try ReferenceScrollSmokeContract.requireNavigation(result)
				} else {
					#expect(throws: ReferenceScrollSmokeContract.Failure.unexpectedReceipt) {
						try ReferenceScrollSmokeContract.requireNavigation(result)
					}
				}
			}
		}
	}

	@Test
	internal func unchangedCannotHideFailureOrReplaceDispatchEvidence() throws {
		let result = ChromiumReferenceScrollResult(operationID: UUID(), disposition: .unchanged)
		try ReferenceScrollSmokeContract.require(result, disposition: .unchanged)
		#expect(throws: ReferenceScrollSmokeContract.Failure.unexpectedReceipt) {
			try ReferenceScrollSmokeContract.require(result, disposition: .dispatched)
		}
		let cancelled = ChromiumReferenceScrollResult(
			operationID: UUID(),
			disposition: .unchanged,
			failure: .cancelled
		)
		#expect(throws: ReferenceScrollSmokeContract.Failure.unexpectedReceipt) {
			try ReferenceScrollSmokeContract.require(cancelled, disposition: .unchanged)
		}
	}
}
