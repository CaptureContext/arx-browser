import AppUI
import Clocks
import CustomDump
import Foundation
import Testing
import _TestSupport

/// DEV-725: only the first hint waits; a showing hint follows the pointer at once.
@Suite(.dependencies)
@MainActor
internal struct SpaceHintTimerTests {
	private let a = UUID(1)
	private let b = UUID(2)
	private let c = UUID(3)

	private func settle() async {
		await Task.settle()
	}

	@Test
	internal func theFirstHintWaitsASecondOfRest() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)

		timer.pointerMoved(over: a)
		await settle()
		await clock.advance(by: .milliseconds(999))
		expectNoDifference(timer.hinted, nil)
		await clock.advance(by: .milliseconds(1))
		await settle()
		expectNoDifference(timer.hinted, a)
	}

	@Test
	internal func movingBeforeTheHintShowsStartsTheRestOver() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)

		timer.pointerMoved(over: a)
		await settle()
		await clock.advance(by: .milliseconds(600))

		// Moving within the same space still counts as moving.
		timer.pointerMoved(over: a)
		await settle()
		await clock.advance(by: .milliseconds(600))
		expectNoDifference(timer.hinted, nil)

		// Moving to another space, too.
		timer.pointerMoved(over: b)
		await settle()
		await clock.advance(by: .milliseconds(999))
		expectNoDifference(timer.hinted, nil)
		await clock.advance(by: .milliseconds(1))
		await settle()
		expectNoDifference(timer.hinted, b)
	}

	@Test
	internal func aShowingHintFollowsThePointerAtOnce() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)

		timer.pointerMoved(over: a)
		await settle()
		await clock.advance(by: .seconds(1))
		await settle()
		expectNoDifference(timer.hinted, a)

		timer.pointerMoved(over: b)
		expectNoDifference(timer.hinted, b)
		timer.pointerMoved(over: c)
		expectNoDifference(timer.hinted, c)

		// Moving within the shown space keeps it, with nothing pending.
		timer.pointerMoved(over: c)
		await settle()
		await clock.advance(by: .seconds(5))
		await settle()
		expectNoDifference(timer.hinted, c)
	}

	@Test
	internal func leavingEverySpaceHidesTheHintAndTheNextOneWaitsAgain() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)

		timer.pointerMoved(over: a)
		await settle()
		await clock.advance(by: .seconds(1))
		await settle()
		expectNoDifference(timer.hinted, a)

		timer.pointerMoved(over: nil)
		expectNoDifference(timer.hinted, nil)

		timer.pointerMoved(over: b)
		await settle()
		await clock.advance(by: .milliseconds(999))
		expectNoDifference(timer.hinted, nil)
		await clock.advance(by: .milliseconds(1))
		await settle()
		expectNoDifference(timer.hinted, b)
	}

	@Test
	internal func leavingBeforeTheHintShowsCancelsIt() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)

		timer.pointerMoved(over: a)
		await settle()
		await clock.advance(by: .milliseconds(500))
		timer.pointerMoved(over: nil)
		await settle()
		await clock.advance(by: .seconds(5))
		await settle()
		expectNoDifference(timer.hinted, nil)
	}

	@Test
	internal func aDragHidesTheHintAndCancelsAWait() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)

		timer.pointerMoved(over: a)
		await settle()
		await clock.advance(by: .seconds(1))
		await settle()
		timer.hide()
		expectNoDifference(timer.hinted, nil)

		timer.pointerMoved(over: b)
		await settle()
		timer.hide()
		await clock.advance(by: .seconds(5))
		await settle()
		expectNoDifference(timer.hinted, nil)
	}

	/// DEV-753: a showing hint survives the gap between the Library button and the spaces.
	@Test
	internal func aShowingHintCrossesTheGapToANeighbour() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)
		let library = SidebarSpaceHintTimer.libraryHintID

		timer.pointerMoved(over: library)
		await settle()
		await clock.advance(by: .seconds(1))
		await settle()
		expectNoDifference(timer.hinted, library)

		timer.pointerLeft(library)
		await settle()
		await clock.advance(by: .milliseconds(100))
		timer.pointerMoved(over: a)
		await settle()

		// No new wait: the hint is on the space straight away.
		expectNoDifference(timer.hinted, a)
		await clock.advance(by: .seconds(1))
		await settle()
		expectNoDifference(timer.hinted, a)
	}

	@Test
	internal func leavingForGoodHidesTheHintAfterTheGrace() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)
		let library = SidebarSpaceHintTimer.libraryHintID

		timer.pointerMoved(over: library)
		await settle()
		await clock.advance(by: .seconds(1))
		await settle()
		timer.pointerLeft(library)
		await settle()
		await clock.advance(by: SidebarSpaceHintTimer.leaveGrace - .milliseconds(1))
		await settle()
		expectNoDifference(timer.hinted, library)
		await clock.advance(by: .milliseconds(1))
		await settle()
		expectNoDifference(timer.hinted, nil)

		// Back on it, the first hint waits the full second again.
		timer.pointerMoved(over: library)
		await settle()
		await clock.advance(by: .milliseconds(999))
		await settle()
		expectNoDifference(timer.hinted, nil)
	}

	@Test
	internal func leavingBeforeAnyHintCancelsTheWait() async {
		let clock = TestClock()
		let timer = SidebarSpaceHintTimer(clock: clock)
		let library = SidebarSpaceHintTimer.libraryHintID

		timer.pointerMoved(over: library)
		await settle()
		await clock.advance(by: .milliseconds(500))
		timer.pointerLeft(library)
		await settle()
		await clock.advance(by: .seconds(5))
		await settle()
		expectNoDifference(timer.hinted, nil)
	}
}
