import AppKit
import CustomDump
import _ComposableArchitecture
import Foundation
import Testing

@testable import AppFeature

/// DEV-865: a headless run needs a logged-in session, not a display.
@Suite(.dependencies)
@MainActor
internal struct HeadlessDisplayTests {
	@Test
	internal func withoutScreensTheHostGoesOffscreenAtTheFallbackScale() async throws {
		let display = withDependencies {
			$0.screens = .init(screens: { [] })
		} operation: {
			HeadlessDisplay.current()
		}

		expectNoDifference(display, HeadlessDisplay(
			origin: HeadlessDisplay.offscreenOrigin,
			deviceScale: 2,
			hasScreen: false
		))
		#expect(display.environmentValue == "2")
	}

	@Test
	internal func theOffscreenOriginKeepsTheLargestViewportOffEveryLikelyScreen() async throws {
		let largest = NSSize(
			width: HeadlessConfiguration.viewportWidths.upperBound,
			height: HeadlessConfiguration.viewportHeights.upperBound
		)
		let host = CGRect(origin: HeadlessDisplay.offscreenOrigin, size: largest)

		// Three 5K displays left of and below the main one still end before the host.
		let arrangement = CGRect(x: -15_360, y: -8_640, width: 15_360 + 5_120, height: 8_640 + 2_880)
		#expect(!host.intersects(arrangement))
	}

	@Test
	internal func theMainScreenPlacesTheHostAndSetsTheScale() async throws {
		let display = withDependencies {
			$0.screens = .init(screens: {
				[
					.init(frame: .init(x: 0, y: 0, width: 3840, height: 2160), backingScale: 1),
					.init(frame: .init(x: 3840, y: 0, width: 1512, height: 982), backingScale: 2),
				]
			})
		} operation: {
			HeadlessDisplay.current()
		}

		expectNoDifference(display, HeadlessDisplay(origin: .zero, deviceScale: 1, hasScreen: true))
		#expect(display.environmentValue == "1")
	}

	@Test
	internal func aSecondaryMainScreenKeepsItsOwnOrigin() async throws {
		let display = HeadlessDisplay(screens: [
			.init(frame: .init(x: -1512, y: 120, width: 1512, height: 982), backingScale: 2),
		])

		expectNoDifference(display, HeadlessDisplay(
			origin: .init(x: -1512, y: 120),
			deviceScale: 2,
			hasScreen: true
		))
	}

	@Test
	internal func anUnusableScreenScaleFallsBack() async throws {
		let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
		for scale: CGFloat in [0, 0.5, 8, .nan, .infinity] {
			let display = HeadlessDisplay(screens: [.init(frame: frame, backingScale: scale)])
			#expect(display.deviceScale == HeadlessDisplay.fallbackScale)
			#expect(display.hasScreen)
		}
	}

	@Test
	internal func fractionalScalesRoundTripThroughTheEnvironment() async throws {
		let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
		let display = HeadlessDisplay(screens: [.init(frame: frame, backingScale: 1.5)])
		#expect(display.environmentValue == "1.5")
		#expect(Double(display.environmentValue) == 1.5)
	}
}
