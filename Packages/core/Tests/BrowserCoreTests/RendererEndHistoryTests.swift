import BrowserCore
import Foundation
import Testing

/// DEV-1016: renderer ends that share a cause, and pages that keep ending.
internal struct RendererEndHistoryTests {
	private let first = Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
	private let second = Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

	@Test
	internal func endsWithinATenthOfASecondShareTheirCause() {
		var history = RendererEndHistory()
		history.record(tab: first, number: 1, at: 10, counts: true)
		history.record(tab: second, number: 1, at: 10.05, counts: true)
		#expect(history.isShared(tab: first, number: 1))
		#expect(history.isShared(tab: second, number: 1))

		history.record(tab: first, number: 2, at: 20, counts: true)
		#expect(!history.isShared(tab: first, number: 2))
	}

	@Test
	internal func threeSoloEndsInAMinuteKeepEnding() {
		var history = RendererEndHistory()
		history.record(tab: first, number: 1, at: 0, counts: true)
		history.record(tab: first, number: 2, at: 20, counts: true)
		#expect(!history.isRepeated(tab: first, at: 20))
		history.record(tab: first, number: 3, at: 40, counts: true)
		#expect(history.isRepeated(tab: first, at: 40))
		// The same end reported again counts once.
		history.record(tab: first, number: 3, at: 41, counts: true)
		#expect(history.isRepeated(tab: first, at: 41))
		// A minute after the first, it's two again.
		#expect(!history.isRepeated(tab: first, at: 61))
	}

	@Test
	internal func sharedEndsAndEndsArxAskedForDontCount() {
		var history = RendererEndHistory()
		history.record(tab: first, number: 1, at: 0, counts: true)
		history.record(tab: second, number: 1, at: 0.02, counts: true)
		history.record(tab: first, number: 2, at: 10, counts: false)
		history.record(tab: first, number: 3, at: 20, counts: true)
		history.record(tab: first, number: 4, at: 30, counts: true)
		#expect(!history.isRepeated(tab: first, at: 30))
		history.record(tab: first, number: 5, at: 40, counts: true)
		#expect(history.isRepeated(tab: first, at: 40))

	}

	@Test
	internal func aTabWhosePageIsMadeAgainKeepsItsStreak() {
		var history = RendererEndHistory()
		history.record(tab: first, page: 1, number: 1, at: 0, counts: true)
		history.record(tab: first, page: 1, number: 2, at: 10, counts: true)

		// Retry: the page closes and a new one numbers its ends from one again.
		history.forget(first)
		history.record(tab: first, page: 2, number: 1, at: 20, counts: true)
		#expect(history.isRepeated(tab: first, at: 20))
		#expect(!history.isShared(tab: first, page: 2, number: 1))
	}

	@Test
	internal func aLaterEndTellsWhichEarlierPagesItMadeShared() {
		var history = RendererEndHistory()
		#expect(history.record(tab: first, number: 1, at: 10, counts: true).isEmpty)
		#expect(history.record(tab: second, number: 1, at: 10.05, counts: true) == [first])
		// Reading an end again tells nothing new.
		#expect(history.record(tab: second, number: 1, at: 10.06, counts: true).isEmpty)
	}

	@Test
	internal func rereadingAnExpiredEndDoesntRecordItAgain() {
		var history = RendererEndHistory()
		history.record(tab: first, number: 1, at: 0, counts: true)
		history.record(tab: first, number: 1, at: 61, counts: true)
		history.record(tab: first, number: 2, at: 65, counts: true)
		history.record(tab: first, number: 3, at: 70, counts: true)
		#expect(!history.isRepeated(tab: first, at: 70))
		#expect(history.lastNumber(of: first) == 3)
	}

	@Test
	internal func closingAnotherPageKeepsAnEndShared() {
		var history = RendererEndHistory()
		history.record(tab: first, number: 1, at: 0, counts: true)
		history.record(tab: second, number: 1, at: 0.02, counts: true)
		history.record(tab: first, number: 2, at: 10, counts: true)
		history.record(tab: first, number: 3, at: 20, counts: true)
		history.forget(second)
		#expect(history.isShared(tab: first, number: 1))
		#expect(!history.isRepeated(tab: first, at: 20))
	}

	@Test
	internal func anEndStaysSharedPastTheWindow() {
		var history = RendererEndHistory()
		history.record(tab: first, number: 1, at: 0, counts: true)
		history.record(tab: second, number: 1, at: 0.02, counts: true)
		history.record(tab: first, number: 1, at: 120, counts: true)
		#expect(history.isShared(tab: first, number: 1))
		#expect(history.isShared(tab: second, number: 1))
	}
}
