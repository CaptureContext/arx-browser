import AppKit
@testable import AppUI
import Foundation
import Testing

/// DEV-1310: what the sidebar's track does when one switch of space follows another before the
/// first has landed, and how its landing spring is timed.
@MainActor
@Suite
internal struct SidebarTrackQuickJumpTests {
	private static let pageWidth: CGFloat = 240

	private static func track(at space: Int = 0) -> SidebarTrack {
		.init(
			spaceIndex: space,
			pageCount: 4,
			pageWidth: pageWidth,
			libraryWidth: 400
		)
	}

	/// How long after `start` the track comes to rest, a frame of 120 Hz at a time.
	private static func landingTime(
		of track: inout SidebarTrack,
		from start: TimeInterval
	) -> TimeInterval {
		var time: TimeInterval = start
		while track.advance(to: time) { time += 1.0 / 120 }
		return time - start
	}

	/// The spring, as measured: critically damped with a response of 0.2 s, half the way
	/// in 50 ms and nine tenths in 120, never past the stop.
	@Test
	internal func aSlideBetweenSpacesFollowsArcsSpring() {
		var track = Self.track()
		track.present(spaceIndex: 1, isLibraryOpen: false, at: 10)

		_ = track.advance(to: 10.05)
		#expect(abs(track.position - 0.5) < 0.06)
		_ = track.advance(to: 10.12)
		#expect(abs(track.position - 0.9) < 0.03)
		var time: TimeInterval = 10
		while track.advance(to: time) {
			#expect(track.position <= 1)
			time += 1.0 / 120
		}
		#expect(track.position == 1)
	}

	/// The spring has landed within half a point of its stop, not a thousandth of a page: the
	/// selection the landing commits used to wait about 350 ms for a tail nobody could see.
	@Test
	internal func aSlideLandsWithinAHalfPointOfItsStop() {
		var track = Self.track()
		track.present(spaceIndex: 1, isLibraryOpen: false, at: 10)
		let landing = Self.landingTime(of: &track, from: 10)
		#expect(landing < 0.29, "landed after \(landing) s")
		#expect(landing > 0.2, "landed after \(landing) s")
	}

	/// Opening the Library keeps its own, slower spring.
	@Test
	internal func openingTheLibraryKeepsItsOwnSpring() {
		var library = Self.track()
		library.present(spaceIndex: 0, isLibraryOpen: true, at: 10)
		var space = Self.track()
		space.present(spaceIndex: 1, isLibraryOpen: false, at: 10)
		_ = library.advance(to: 10.05)
		_ = space.advance(to: 10.05)
		#expect(library.libraryProgress < space.position)
	}

	/// A slide to a selection made elsewhere is timed from the first frame it draws: the update
	/// that selects the space holds the main thread, and timed from before it the first frame
	/// was most of the way along.
	@Test
	internal func aSlideTimedFromItsFirstFrameStartsWhereTheTrackStood() {
		var track = Self.track()
		track.present(spaceIndex: 1, isLibraryOpen: false, at: 10)

		// The selection's update took 100 ms; without the restart this frame is 90% of the way.
		track.restartSettling(at: 10.1)
		_ = track.advance(to: 10.1 + 1.0 / 120)
		#expect(track.position < 0.05, "\(track.position)")

		// A time before the spring began changes nothing.
		var early = Self.track()
		early.present(spaceIndex: 1, isLibraryOpen: false, at: 10)
		let untouched = early
		early.restartSettling(at: 9)
		#expect(early == untouched)
	}

	/// Chaining swipes: fingers catch the sidebar on its way to the next space and go on to the
	/// one after. Catching used to call the landing off, so the window put the selected space's
	/// page back for the length of the second swipe.
	@Test
	internal func catchingTheSlideKeepsTheLandingUntilTheFingersChooseAgain() {
		var landings: [SidebarTrack.Stop?] = []
		var tracked: Int = 0
		var commits: [Int] = []

		// In a window that is never shown, so the spring starts and no frame of it ever runs.
		let window = NSWindow(
			contentRect: .init(x: -10_000, y: -10_000, width: 240, height: 400),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		defer { window.close() }
		let view = NSView(frame: .init(x: 0, y: 0, width: 240, height: 400))
		window.contentView = view

		let driver = SidebarTrackDriver(track: Self.track())
		driver.view = view
		driver.handlers = .init(
			isEnabled: true,
			reduceMotion: false,
			progressChanged: { _ in },
			committed: { _, index in commits.append(index) },
			tracked: { _ in tracked += 1 },
			landing: { landings.append($0) }
		)

		#expect(driver.begin(deltaX: -4, deltaY: 0))
		driver.move(by: -100, at: 1)
		driver.move(by: -100, at: 1.01)
		driver.release(at: 1.02)
		#expect(landings == [.space(1)])
		#expect(!driver.isAtRest)
		let trackedByTheFirstSwipe = tracked

		// Caught on its way: the landing isn't called off, and no other space is revealed.
		#expect(driver.begin(deltaX: -4, deltaY: 0))
		driver.move(by: -100, at: 1.1)
		driver.move(by: -100, at: 1.11)
		#expect(landings == [.space(1)])
		#expect(tracked == trackedByTheFirstSwipe)

		driver.release(at: 1.12)
		#expect(landings == [.space(1), .space(2)])
		// Nothing was selected on the way.
		#expect(commits.isEmpty)

		// The sidebar going away while fingers hold a caught slide's landing calls it off.
		landings = []
		#expect(driver.begin(deltaX: -4, deltaY: 0))
		driver.viewLeftWindow()
		#expect(landings == [nil])
	}

	/// One swipe goes one stop: however far the fingers travel, the track gives a
	/// little past the next space and lands on it. It used to follow them past space after space.
	@Test
	internal func oneSwipeGoesOneSpace() {
		var track = Self.track()
		_ = track.begin(deltaX: -4, deltaY: 0)
		for step in 1...20 { track.move(by: -60, at: 1 + Double(step) * 0.008) }
		#expect(track.position > 1)
		#expect(track.position < 1.2)
		let landed1 = track.release(at: 1.165)
		#expect(landed1 == .space(1))

		// And one back, from a space in the middle, with the same give.
		var middle = Self.track(at: 2)
		_ = middle.begin(deltaX: 4, deltaY: 0)
		for step in 1...20 { middle.move(by: 60, at: 1 + Double(step) * 0.008) }
		#expect(middle.position < 1)
		#expect(middle.position > 0.8)
		let landed2 = middle.release(at: 1.165)
		#expect(landed2 == .space(1))
	}

	/// Fingers that catch the track on its way to a space set out from that space: one more
	/// stop on, or back to where the first swipe began.
	@Test
	internal func aCaughtSlideGoesOneSpaceFromWhereItWasLanding() {
		var track = Self.track()
		_ = track.begin(deltaX: -4, deltaY: 0)
		track.move(by: -100, at: 1)
		track.move(by: -100, at: 1.008)
		let landed3 = track.release(at: 1.01)
		#expect(landed3 == .space(1))

		_ = track.begin(deltaX: -4, deltaY: 0)
		for step in 1...20 { track.move(by: -60, at: 1.05 + Double(step) * 0.008) }
		#expect(track.position < 2.2)
		let landed4 = track.release(at: 1.215)
		#expect(landed4 == .space(2))
	}

	/// The Create a Space page opens from the last space only: a swipe that set out a space
	/// before it stops at the last space.
	@Test
	internal func aSwipeFromTheSpaceBeforeTheLastDoesntReachCreateASpace() {
		var track = SidebarTrack(
			spaceIndex: 2,
			pageCount: 4,
			pageWidth: Self.pageWidth,
			libraryWidth: 400,
			offersCreation: true
		)
		_ = track.begin(deltaX: -4, deltaY: 0)
		for step in 1...20 { track.move(by: -60, at: 1 + Double(step) * 0.008) }
		#expect(track.creationPull == 0)
		let landed5 = track.release(at: 1.165)
		#expect(landed5 == .space(3))
		#expect(!track.isCreationOpen)
	}

	/// A window that is never shown, so a spring started in it never runs a frame.
	private static func unshownWindow() -> (window: NSWindow, view: NSView) {
		let window = NSWindow(
			contentRect: .init(x: -10_000, y: -10_000, width: 240, height: 400),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let view = NSView(frame: .init(x: 0, y: 0, width: 240, height: 400))
		window.contentView = view
		return (window, view)
	}

	/// Next Space pressed three times quickly: the sidebar turns toward each space in turn,
	/// shows its page, and selects nothing until the slide lands. Selecting on each press ran
	/// the whole selection three times before anything moved.
	@Test
	internal func keysSlideFirstAndSelectNothingUntilTheSlideLands() {
		var landings: [SidebarTrack.Stop?] = []
		var built: [Int] = []
		var commits: [Int] = []
		let hosted = Self.unshownWindow()
		defer { hosted.window.close() }

		let driver = SidebarTrackDriver(track: Self.track(at: 2))
		driver.view = hosted.view
		driver.selectedIndex = 2
		driver.handlers = .init(
			isEnabled: true,
			reduceMotion: false,
			progressChanged: { _ in },
			committed: { _, index in commits.append(index) },
			landing: { landings.append($0) },
			willSlide: { built.append($0) }
		)

		#expect(driver.stepSpace(by: 1))
		// Past the last space it goes round to the first, counting from where it's landing.
		#expect(driver.stepSpace(by: 1))
		#expect(driver.stepSpace(by: 1))
		#expect(landings == [.space(3), .space(0), .space(1)])
		#expect(built == [3, 0, 1])
		#expect(commits.isEmpty)
		#expect(!driver.isAtRest)

		// Back to the space still selected is a slide too, while one is under way.
		#expect(driver.slide(toSpace: 2))
		#expect(landings.last == .some(.space(2)))

		// Leaving the window lands the track where it was going and selects that once.
		driver.viewLeftWindow()
		#expect(commits == [2])
	}

	/// Where the selection has to come first, the sidebar changes nothing and says so.
	@Test
	internal func theSidebarLeavesTheChoiceToTheWindowWhereItCantSlide() {
		var landings: [SidebarTrack.Stop?] = []
		let hosted = Self.unshownWindow()
		defer { hosted.window.close() }

		func driver(
			reduceMotion: Bool = false,
			inWindow: Bool = true
		) -> SidebarTrackDriver {
			let driver = SidebarTrackDriver(track: Self.track(at: 1))
			if inWindow { driver.view = hosted.view }
			driver.selectedIndex = 1
			driver.handlers = .init(
				isEnabled: true,
				reduceMotion: reduceMotion,
				progressChanged: { _ in },
				committed: { _, _ in },
				landing: { landings.append($0) }
			)
			return driver
		}

		// The space already shown, a space that isn't there, Reduce Motion, and no window.
		#expect(!driver().slide(toSpace: 1))
		#expect(!driver().slide(toSpace: 4))
		#expect(!driver(reduceMotion: true).stepSpace(by: 1))
		#expect(!driver(inWindow: false).stepSpace(by: 1))
		#expect(landings.isEmpty)

		// Fingers on the track keep it.
		let held = driver()
		#expect(held.begin(deltaX: -4, deltaY: 0))
		#expect(!held.stepSpace(by: 1))
		#expect(landings.isEmpty)
	}

	/// A layer that only notes what the track asks of it.
	private final class NotedSurface: SidebarTrackSurface {
		var shown: [CGFloat] = []
		var plays: [[CGFloat]] = []
		var rests: [CGFloat] = []

		func show(position: CGFloat) { shown.append(position) }

		func play(
			positions: [CGFloat],
			every interval: TimeInterval
		) {
			plays.append(positions)
		}

		func rest(at position: CGFloat) { rests.append(position) }
	}

	/// A landing is handed to the render server once, whole, from where the track stands to its
	/// stop without ever going back; the server taking it replays nothing. A switch from a key
	/// used to start the landing's clock over a few frames in, which played its first frames
	/// twice: in a recording the sidebar ran four frames, jumped back a third of a page for
	/// one, and went on.
	@Test
	internal func aLandingIsHandedToTheRenderServerOnceAndNeverReplayed() {
		let hosted = Self.unshownWindow()
		defer { hosted.window.close() }
		let surface = NotedSurface()

		let driver = SidebarTrackDriver(track: Self.track(at: 2))
		driver.view = hosted.view
		driver.selectedIndex = 2
		driver.handlers = .init(
			isEnabled: true,
			reduceMotion: false,
			progressChanged: { _ in },
			committed: { _, _ in }
		)
		driver.attach(surface)
		#expect(surface.rests == [2])

		#expect(driver.slide(toSpace: 1))
		#expect(surface.plays.count == 1)
		let landing: [CGFloat] = surface.plays[0]
		#expect(landing.first == 2)
		#expect(landing.last == 1)
		#expect(zip(landing, landing.dropFirst()).allSatisfy { $0 >= $1 })

		driver.landingBegan()
		driver.landingBegan()
		#expect(surface.plays.count == 1)

		// Fingers that catch it take the layer where the track stands, and move it themselves.
		#expect(driver.begin(deltaX: -4, deltaY: 0))
		#expect(surface.shown.count == 1)
		driver.move(by: -40, at: 5)
		#expect(surface.shown.count == 2)
		#expect(surface.plays.count == 1)
	}
}
