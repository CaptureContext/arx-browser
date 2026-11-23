@testable import AppFeature
import Foundation
import Testing
import _TestSupport

/// DEV-1183: a full-screen toggle AppKit drops, with no transition and no notification, is asked
/// again, for a page entering full screen and for one leaving it, a few times at most; one AppKit
/// takes, or a transition under way, isn't. It looks again by itself, though nothing else changes.
@MainActor
@Suite
internal struct PageFullScreenWindowsTests {
	@Test
	internal func aTakenEntryIsAskedOnce() {
		let fixture = Fixture()
		fixture.update(target: fixture.id)
		#expect(fixture.window.toggles == 1)
		#expect(fixture.window.isInFullScreen)

		fixture.advance(.seconds(5))
		fixture.update(target: fixture.id)
		#expect(fixture.window.toggles == 1)
		#expect(fixture.windows.isFullScreenForPage(fixture.id))
	}

	@Test
	internal func aDroppedEntryIsAskedAgainAfterTheDelayAFewTimesAtMost() {
		let fixture = Fixture()
		fixture.window.drops = 10
		fixture.update(target: fixture.id)
		#expect(fixture.window.toggles == 1)

		// Not before the delay: AppKit may still be about to start.
		fixture.advance(.milliseconds(500))
		fixture.update(target: fixture.id)
		#expect(fixture.window.toggles == 1)

		for expected in [2, 3, 3, 3] {
			fixture.advance(.seconds(2))
			fixture.update(target: fixture.id)
			#expect(fixture.window.toggles == expected)
		}
		#expect(!fixture.window.isInFullScreen)
	}

	@Test
	internal func anEntryTakenOnTheSecondAskIsDone() {
		let fixture = Fixture()
		fixture.window.drops = 1
		fixture.update(target: fixture.id)
		fixture.advance(.seconds(2))
		fixture.update(target: fixture.id)
		#expect(fixture.window.toggles == 2)
		#expect(fixture.window.isInFullScreen)

		fixture.advance(.seconds(5))
		fixture.update(target: fixture.id)
		#expect(fixture.window.toggles == 2)
	}

	@Test
	internal func aTransitionUnderWayIsNotADroppedToggle() {
		let fixture = Fixture()
		fixture.window.drops = 1
		fixture.update(target: fixture.id)
		fixture.transitioning = true
		fixture.advance(.seconds(2))
		fixture.update(target: fixture.id)
		#expect(fixture.window.toggles == 1)
	}

	@Test
	internal func aDroppedExitIsAskedAgain() {
		let fixture = Fixture()
		fixture.update(target: fixture.id)
		#expect(fixture.window.isInFullScreen)

		fixture.window.drops = 1
		fixture.update(target: nil)
		#expect(fixture.window.toggles == 2)
		#expect(fixture.window.isInFullScreen)

		fixture.advance(.seconds(2))
		fixture.update(target: nil)
		#expect(fixture.window.toggles == 3)
		#expect(!fixture.window.isInFullScreen)
	}

	/// The page coming back before a dropped exit is asked again wants the window in full screen,
	/// where it still is.
	@Test
	internal func aDroppedExitTheyNoLongerWantIsForgotten() {
		let fixture = Fixture()
		fixture.update(target: fixture.id)
		fixture.window.drops = 1
		fixture.update(target: nil)
		fixture.advance(.seconds(2))
		fixture.update(target: fixture.id)
		#expect(fixture.window.toggles == 2)
		#expect(fixture.window.isInFullScreen)

		// It's still the page's full screen, so it leaves when the page does.
		fixture.update(target: nil)
		#expect(fixture.window.toggles == 3)
		#expect(!fixture.window.isInFullScreen)
	}

	/// A window the person put in full screen stays there, and nothing is retried for it.
	@Test
	internal func aWindowAlreadyInFullScreenIsLeftAlone() {
		let fixture = Fixture()
		fixture.window.isInFullScreen = true
		fixture.update(target: fixture.id)
		fixture.update(target: nil)
		fixture.advance(.seconds(5))
		fixture.update(target: nil)
		#expect(fixture.window.toggles == 0)
		#expect(fixture.window.isInFullScreen)
	}

	@Test
	internal func itLooksAgainByItself() async throws {
		let window = Window()
		window.drops = 1
		let windows = PageFullScreenWindows(retryDelay: .milliseconds(50))
		let id = UUID()
		windows.update(target: id, browserWindow: { $0 == id ? window : nil }, littleWindows: [:], isTransitioning: { _ in false })

		await waitWhile { window.toggles < 2 }
		#expect(window.toggles == 2)
		#expect(window.isInFullScreen)
	}

	// MARK: - Fixture

	/// A window whose next `drops` toggles AppKit drops, starting nothing.
	@MainActor
	private final class Window: PageFullScreenWindow {
		var isInFullScreen: Bool = false
		var drops: Int = 0
		var toggles: Int = 0

		func toggleFullScreen() {
			toggles += 1
			if drops > 0 {
				drops -= 1
			} else {
				isInFullScreen.toggle()
			}
		}
	}

	@MainActor
	private final class Fixture {
		let id = UUID()
		let window = Window()
		var transitioning = false
		private var now = ContinuousClock.now
		private(set) var windows: PageFullScreenWindows!

		init() {
			// A long delay for its own look, so only the test's updates count.
			windows = PageFullScreenWindows(retryDelay: .seconds(1)) { [unowned self] in self.now }
		}

		func advance(_ duration: Duration) {
			now = now.advanced(by: duration)
		}

		func update(target: UUID?) {
			windows.update(
				target: target,
				browserWindow: { [id, window] in $0 == id ? window : nil },
				littleWindows: [:],
				isTransitioning: { [unowned self] _ in self.transitioning }
			)
		}
	}
}
