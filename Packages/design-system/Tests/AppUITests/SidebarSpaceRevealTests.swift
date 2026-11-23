import AppKit
@testable import AppUI
import Foundation
import Testing

/// DEV-1310: the window's background turns from one space's appearance to the next as far as
/// the sidebar has slid, so it needs to know which two spaces the sidebar stands between.
@MainActor
@Suite
internal struct SidebarSpaceRevealTests {
	private static let spaces: [UUID] = (0..<4).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", $0))! }

	@Test
	internal func atRestOnlyTheSpaceShownIsRevealed() {
		let shown = SidebarSpaceReveal.spaces(at: 2, among: Self.spaces)
		#expect(shown.lower == Self.spaces[2])
		#expect(shown.upper == nil)
		#expect(shown.fraction == 0)
	}

	@Test
	internal func betweenTwoSpacesTheLaterOneShowsAsFarAsTheSidebarHasGone() {
		let shown = SidebarSpaceReveal.spaces(at: 1.25, among: Self.spaces)
		#expect(shown.lower == Self.spaces[1])
		#expect(shown.upper == Self.spaces[2])
		#expect(shown.fraction == 0.25)
	}

	/// The give past the last space, and anything before the first, shows the end space alone.
	@Test
	internal func pastEitherEndTheEndSpaceShowsAlone() {
		let past = SidebarSpaceReveal.spaces(at: 3.1, among: Self.spaces)
		#expect(past.lower == Self.spaces[3])
		#expect(past.upper == nil)
		let before = SidebarSpaceReveal.spaces(at: -0.5, among: Self.spaces)
		#expect(before.lower == Self.spaces[0])
		#expect(before.upper == nil)
		#expect(SidebarSpaceReveal.spaces(at: 1, among: []).lower == nil)
	}

	/// It follows the track itself, not the selection: a swipe moves it with every move of the
	/// fingers, and a slide across several spaces passes through each of them.
	@Test
	internal func itFollowsTheTrackAsFingersMoveIt() {
		let reveal = SidebarSpaceReveal()
		let driver = SidebarTrackDriver(track: .init(
			spaceIndex: 1,
			pageCount: 4,
			pageWidth: 240,
			libraryWidth: 400
		))
		driver.spaceIDs = Self.spaces
		driver.reveal = reveal
		driver.handlers = .init(
			isEnabled: true,
			reduceMotion: false,
			progressChanged: { _ in },
			committed: { _, _ in }
		)
		#expect(reveal.lower == Self.spaces[1])
		#expect(reveal.upper == nil)

		_ = driver.begin(deltaX: -4, deltaY: 0)
		driver.move(by: -240, at: 1)
		#expect(reveal.lower == Self.spaces[1])
		#expect(reveal.upper == Self.spaces[2])
		#expect(abs(reveal.fraction - 0.5) < 0.000_001)

		// Back past where it began, toward the space before.
		driver.move(by: 360, at: 1.01)
		#expect(reveal.lower == Self.spaces[0])
		#expect(reveal.upper == Self.spaces[1])
		#expect(abs(reveal.fraction - 0.75) < 0.000_001)
	}
}

/// DEV-1310: a homepage that paints no ground of its own lets the window's background through
/// its page card; one that paints its own keeps the card solid.
@Suite
internal struct EmptyPageSeeThroughTests {
	@Test
	internal func onlyAHomepageWithNoGroundOfItsOwnIsClear() {
		#expect(EmptyPageStyle.captureContext.background.isClear)
		#expect(EmptyPageStyle.Background.dust.isClear)
		#expect(EmptyPageStyle.Background.none.isClear)
		#expect(!EmptyPageStyle.Background.sky.isClear)
		#expect(!EmptyPageStyle.Background.warp.isClear)
		#expect(BrowserMetrics.PageCard.seeThroughOpacity < 1)
	}
}

/// DEV-1310: a row's spring runs on a clock that a held frame doesn't run ahead of.
@Suite
internal struct SteadyClockTests {
	@Test
	internal func aHeldFrameCountsForOneStepAndOrdinaryFramesForThemselves() {
		var clock = SteadyClock()
		#expect(clock.advance(to: 0) == 0)
		// The update that opened the tab held the first frame for 150 ms.
		#expect(abs(clock.advance(to: 0.15) - SteadyClock.longestStep) < 0.000_001)
		// From there on, frames at 120 a second count in full.
		let afterOne: TimeInterval = clock.advance(to: 0.15 + 1.0 / 120)
		#expect(abs(afterOne - (SteadyClock.longestStep + 1.0 / 120)) < 0.000_001)
		// Time never runs backward.
		#expect(clock.advance(to: 0.1) == afterOne)
	}
}
