@testable import AppUI
import Foundation
import Testing

/// DEV-1310: a swipe moves the sidebar's track by measured numbers,
/// measured frame by frame: half as far as the fingers, one
/// stop a swipe, a give that never stops dead, a landing chosen by which way the fingers were
/// still going, and one spring that starts at the track's speed.
@MainActor
@Suite
internal struct SidebarTrackSwipeTests {
	private static let pageWidth: CGFloat = 240

	private static func track(
		at space: Int = 0,
		pageCount: Int = 4
	) -> SidebarTrack {
		.init(
			spaceIndex: space,
			pageCount: pageCount,
			pageWidth: pageWidth,
			libraryWidth: 400
		)
	}

	/// A swipe of `points` toward later spaces, in `steps` moves 8 ms apart from `time`.
	private static func swipe(
		_ track: inout SidebarTrack,
		by points: CGFloat,
		steps: Int = 1,
		from time: TimeInterval = 1
	) {
		_ = track.begin(deltaX: points > 0 ? -4 : 4, deltaY: 0)
		for step in 0..<steps {
			track.move(by: -points / CGFloat(steps), at: time + Double(step) * 0.008)
		}
	}

	/// Reference: 40, 80, 120, 160 and 300 points of scrolling moved the row 19.5, 39.5, 59.5, 79.5
	/// and 149.
	@Test(arguments: [40, 80, 120, 160, 300] as [CGFloat])
	internal func theTrackGoesHalfAsFarAsTheFingers(_ points: CGFloat) {
		var track = Self.track()
		Self.swipe(&track, by: points)
		#expect(abs(track.position * Self.pageWidth - points / 2) < 0.001)
	}

	/// Where the track stands depends on how far the fingers have gone and on nothing else: not
	/// on how the trackpad cut the swipe into moves, and not on the way they got there. Its give
	/// used to be added move by move, at full speed on the way back.
	@Test
	internal func whereTheTrackStandsDependsOnlyOnHowFarTheFingersWent() {
		var whole = Self.track(at: 3)
		Self.swipe(&whole, by: 600)
		var pieces = Self.track(at: 3)
		Self.swipe(&pieces, by: 600, steps: 24)
		#expect(abs(whole.position - pieces.position) < 0.000_001)

		// Pushed far into the give and brought back by as much, it is where it began.
		var returned = Self.track(at: 3)
		Self.swipe(&returned, by: 900, steps: 9)
		for step in 0..<9 { returned.move(by: 100, at: 2 + Double(step) * 0.008) }
		#expect(abs(returned.position - 3) < 0.000_001)

		// And halfway back it stands where half the push alone would have left it.
		var half = Self.track(at: 3)
		Self.swipe(&half, by: 900)
		half.move(by: 450, at: 2)
		var direct = Self.track(at: 3)
		Self.swipe(&direct, by: 450)
		#expect(abs(half.position - direct.position) < 0.000_001)
	}

	/// Reference: 200 points of fingers toward a next space that isn't there moved the row 14, and
	/// the row never comes to a wall. It used to move at three tenths and stop dead a quarter
	/// of a page out.
	@Test
	internal func pastItsEndTheTrackGivesLessAndLessAndNeverStopsDead() {
		var track = Self.track(at: 3)
		Self.swipe(&track, by: 200)
		#expect(abs((track.position - 3) * Self.pageWidth - 14) < 0.5)

		var previous: CGFloat = track.position
		var gains: [CGFloat] = []
		for step in 1...40 {
			track.move(by: -200, at: 1 + Double(step) * 0.008)
			gains.append(track.position - previous)
			previous = track.position
		}

		// Every further push still moves it, each less than the one before, never a whole page.
		#expect(gains.allSatisfy { $0 > 0 })
		#expect(zip(gains, gains.dropFirst()).allSatisfy { $0 > $1 })
		#expect(track.position < 4)
	}

	/// The same give past the one stop a swipe may go, either way.
	@Test
	internal func pastTheNextSpaceTheTrackGivesTheSameWay() {
		var forward = Self.track(at: 1)
		Self.swipe(&forward, by: 2 * Self.pageWidth + 200)
		#expect(abs((forward.position - 2) * Self.pageWidth - 14) < 0.5)

		var back = Self.track(at: 2)
		Self.swipe(&back, by: -(2 * Self.pageWidth + 200))
		#expect(abs((1 - back.position) * Self.pageWidth - 14) < 0.5)

		// Each lands on the stop it reached, not on one beyond.
		#expect(forward.release(at: 2) == .space(2))
		#expect(back.release(at: 2) == .space(1))
	}

	/// Reference: let go while moving, even at 7 points a second and 2% of the way, the row goes on
	/// the way it was going. It used to take 500 points a second, or half a page.
	@Test
	internal func letGoWhileMovingTheTrackGoesOnTheWayItWasGoing() {
		var slow = Self.track()
		_ = slow.begin(deltaX: -4, deltaY: 0)
		slow.move(by: -9.3, at: 1)
		slow.move(by: -0.3, at: 1.04)
		#expect(slow.position < 0.03)
		#expect(slow.release(at: 1.05) == .space(1))

		// Past halfway and coming back: back where it set out.
		var back = Self.track()
		_ = back.begin(deltaX: -4, deltaY: 0)
		back.move(by: -300, at: 1)
		back.move(by: 4, at: 1.04)
		#expect(back.position > 0.5)
		#expect(back.release(at: 1.05) == .space(0))
	}

	/// Reference: let go held still, 44%, 48% and 50.4% of the way went back; 51.8%, 55% and 66% went
	/// on. Arx goes back up to and at half, and on past it.
	@Test(arguments: [(0.44, 0), (0.48, 0), (0.5, 0), (0.518, 1), (0.55, 1), (0.66, 1)] as [(CGFloat, Int)])
	internal func letGoHeldStillTheTrackGoesToWhicheverSpaceShowsMore(
		_ along: CGFloat,
		_ space: Int
	) {
		var track = Self.track()
		Self.swipe(&track, by: along * Self.pageWidth / SidebarTrack.follow, steps: 6)
		#expect(abs(track.position - along) < 0.000_001)
		// A tenth of a second after the last move: held.
		#expect(track.release(at: 1.15) == .space(space))
	}

	/// The speed is read from the last 60 ms alone: a fast swipe on, then a slow move back just
	/// before lifting, goes back. An average over every move still carried the swipe on.
	@Test
	internal func onlyTheLastMovesSayWhichWayTheFingersWereGoing() {
		var track = Self.track()
		Self.swipe(&track, by: 200, steps: 5)
		track.move(by: 2, at: 1.2)
		track.move(by: 2, at: 1.22)
		#expect(track.release(at: 1.23) == .space(0))
	}

	/// The landing starts at the speed the track had: the first frame after the fingers lift
	/// moves about as far as the last frame under them.
	@Test
	internal func theLandingStartsAtTheTracksSpeed() {
		var track = Self.track()

		// 480 points a second of fingers: one unit a second of track.
		_ = track.begin(deltaX: -4, deltaY: 0)
		for step in 0..<6 { track.move(by: -4, at: 1 + Double(step) / 120) }
		let lifted: CGFloat = track.position
		_ = track.release(at: 1 + 5.0 / 120)
		_ = track.advance(to: 1 + 6.0 / 120)
		let frame: CGFloat = track.position - lifted
		#expect(frame > 0.7 / 120, "\(frame * 120) units a second")
	}

	/// A landing that turns the track round does it without a jolt: fingers still pushing into
	/// the give as they lift carry the track a little further before it comes back. It used to
	/// start back from a standstill.
	@Test
	internal func aLandingThatTurnsTheTrackRoundKeepsItsSpeedToo() {
		var track = Self.track(at: 3)
		_ = track.begin(deltaX: -4, deltaY: 0)
		for step in 0..<6 { track.move(by: -40, at: 1 + Double(step) / 120) }
		let lifted: CGFloat = track.position
		#expect(track.release(at: 1 + 5.0 / 120) == .space(3))
		_ = track.advance(to: 1 + 6.0 / 120)
		#expect(track.position > lifted)

		var time: TimeInterval = 1 + 6.0 / 120
		while track.advance(to: time) { time += 1.0 / 120 }
		#expect(track.position == 3)
	}

	/// The row never passes its stop, to the pixel, however fast it was let go.
	@Test
	internal func theLandingNeverPassesItsStop() {
		var track = Self.track()
		_ = track.begin(deltaX: -4, deltaY: 0)

		// 0.9 of the way in 40 ms: about 22 units a second as the fingers lift.
		for step in 0..<6 { track.move(by: -72, at: 1 + Double(step) * 0.008) }
		#expect(track.release(at: 1.041) == .space(1))
		var time: TimeInterval = 1.041
		while track.advance(to: time) {
			#expect(track.position <= 1)
			time += 1.0 / 120
		}
		#expect(track.position == 1)
	}

	/// A point or two of sideways drift uncovers no space, so no page is woken for it.
	@Test
	internal func aDriftOfAPointOrTwoUncoversNoSpace() {
		var track = Self.track(at: 1)
		Self.swipe(&track, by: 6)
		#expect(track.revealedSpace(from: 1) == nil)
		track.move(by: -10, at: 1.01)
		#expect(track.revealedSpace(from: 1) == 2)
	}
}
