import AppKit
import ChromiumEngine
import CustomDump
import Testing

@testable import ChromiumHost

internal struct ReferenceClickSmokeTests {
	@Test
	internal func navigationAllowsOnlyConfirmedDispatchOrSourceInvalidationUncertainty() async throws {
		let allowed: [(ChromiumReferenceClickDisposition, ChromiumReferenceClickFailure?)] = [
			(.dispatched, nil),
			(.possiblyDispatched, .staleReference),
		]
		for (disposition, failure) in allowed {
			try ReferenceClickSmokeContract.requireNavigationReceipt(.init(
				operationID: UUID(),
				disposition: disposition,
				failure: failure
			))
		}

		let rejected: [(ChromiumReferenceClickDisposition, ChromiumReferenceClickFailure?)] = [
			(.notDispatched, .staleReference),
			(.possiblyDispatched, .timedOut),
			(.possiblyDispatched, .cancelled),
			(.possiblyDispatched, .duplicateOperation),
			(.possiblyDispatched, nil),
			(.dispatched, .duplicateOperation),
		]
		for (disposition, failure) in rejected {
			#expect(throws: ReferenceClickSmokeContract.Failure.unexpectedReceipt) {
				try ReferenceClickSmokeContract.requireNavigationReceipt(.init(
					operationID: UUID(),
					disposition: disposition,
					failure: failure
				))
			}
		}
	}

	@Test
	internal func receiptAssertionNeverTreatsUncertaintyAsSuccessOrCancellationAsUndo() {
		let uncertain: ChromiumReferenceClickResult = .init(
			operationID: UUID(),
			disposition: .possiblyDispatched,
			failure: .cancelled
		)
		#expect(throws: ReferenceClickSmokeContract.Failure.unexpectedReceipt) {
			try ReferenceClickSmokeContract.require(uncertain, disposition: .dispatched)
		}
		#expect(throws: ReferenceClickSmokeContract.Failure.unexpectedReceipt) {
			try ReferenceClickSmokeContract.require(
				uncertain,
				disposition: .notDispatched,
				failure: .cancelled
			)
		}
	}

	@Test
	internal func mutationInputRequiresExactOwnedPathAndPositiveGeometry() throws {
		let url = URL(string: "http://127.0.0.1:1234/reference-click/main")!
		let point = try ReferenceClickSmokeContract.inputPoint(
			currentURL: url,
			expectedURL: url,
			bounds: .init(x: 0, y: 0, width: 640, height: 480),
			isFlipped: false,
			reinsert: true
		)
		expectNoDifference(point, .init(x: 280, y: 446))
		let other = URL(string: "http://127.0.0.1:1234/other")!
		for expected in [other, URL(string: "https://capturecontext.dev/reference-click/main")!] {
			#expect(throws: ReferenceClickSmokeContract.Failure.invalidFixture) {
				try ReferenceClickSmokeContract.inputPoint(
					currentURL: expected,
					expectedURL: expected,
					bounds: .init(x: 0, y: 0, width: 640, height: 480),
					isFlipped: true,
					reinsert: false
				)
			}
		}

		#expect(throws: ReferenceClickSmokeContract.Failure.invalidFixture) {
			try ReferenceClickSmokeContract.inputPoint(
				currentURL: url,
				expectedURL: url,
				bounds: .zero,
				isFlipped: true,
				reinsert: false
			)
		}
	}
}
