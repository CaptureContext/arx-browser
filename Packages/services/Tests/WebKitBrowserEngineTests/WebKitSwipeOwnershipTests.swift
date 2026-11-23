import Testing

@testable import WebKitBrowserEngine

/// The WebKit swipe's ownership keeps the Chromium gesture's rules (DEV-1203).
internal struct WebKitSwipeOwnershipTests {
	private func admitted(
		inverted: Bool = true,
		canGoBack: Bool = true,
		canGoForward: Bool = true
	) -> WebKitSwipeOwnership {
		var ownership = WebKitSwipeOwnership()
		ownership.begin(inverted: inverted, canGoBack: canGoBack, canGoForward: canGoForward)
		ownership.acknowledge(consumed: false, propagatesX: true)
		return ownership
	}

	@Test
	internal func aSwipeBackCommitsAtTheChromiumThreshold() {
		var ownership = admitted()

		// Natural scrolling: fingers moving right go back.
		ownership.update(horizontal: 0.001, totalVertical: 0)
		ownership.update(horizontal: 0.08, totalVertical: 0)
		#expect(ownership.direction == .back)
		#expect(ownership.owner == .history)
		#expect(ownership.progress > 0.4 && ownership.progress < 0.6)
		#expect(ownership.consumesWheel)

		ownership.update(horizontal: 0.2, totalVertical: 0)
		#expect(ownership.progress == 1)
		let releaseResult1 = ownership.release()
		#expect(releaseResult1 == .back)
		#expect(!ownership.isCurrent)
	}

	@Test
	internal func aShortSwipeGoesNowhere() {
		var ownership = admitted()
		ownership.update(horizontal: 0.001, totalVertical: 0)
		ownership.update(horizontal: 0.1, totalVertical: 0)
		let releaseResult2 = ownership.release()
		#expect(releaseResult2 == nil)
	}

	@Test
	internal func traditionalScrollingSwapsTheDirections() {
		var ownership = admitted(inverted: false)
		ownership.update(horizontal: 0.001, totalVertical: 0)
		ownership.update(horizontal: 0.2, totalVertical: 0)
		#expect(ownership.direction == .forward)
		let releaseResult3 = ownership.release()
		#expect(releaseResult3 == .forward)
	}

	@Test
	internal func scrollDeltasStandInForFingerTravel() {
		// Natural scrolling: content follows the fingers, so the deltas do too horizontally.
		let natural = WebKitSwipeOwnership.travel(deltaX: 80, deltaY: 8, inverted: true)
		#expect(natural.x == 0.1)
		#expect(natural.y == -0.01)
		let traditional = WebKitSwipeOwnership.travel(deltaX: 80, deltaY: 8, inverted: false)
		#expect(traditional.x == -0.1)
	}

	@Test
	internal func thePageKeepsAWheelItConsumes() {
		var ownership = WebKitSwipeOwnership()
		ownership.begin(inverted: true, canGoBack: true, canGoForward: true)
		ownership.acknowledge(consumed: true, propagatesX: nil)
		ownership.update(horizontal: 0.3, totalVertical: 0)
		#expect(ownership.owner == .content)
		#expect(!ownership.consumesWheel)
		let releaseResult4 = ownership.release()
		#expect(releaseResult4 == nil)
	}

	@Test
	internal func aLaterConsumedWheelTakesTheGestureBack() {
		var ownership = admitted()
		ownership.update(horizontal: 0.05, totalVertical: 0)
		#expect(ownership.owner == .history)
		ownership.acknowledge(consumed: true, propagatesX: false)
		#expect(ownership.owner == .content)
		let releaseResult5 = ownership.release()
		#expect(releaseResult5 == nil)
	}

	@Test
	internal func containedOverscrollNeverAdmits() {
		var ownership = WebKitSwipeOwnership()
		ownership.begin(inverted: true, canGoBack: true, canGoForward: true)
		ownership.acknowledge(consumed: false, propagatesX: false)
		ownership.update(horizontal: 0.3, totalVertical: 0)
		#expect(!ownership.admitted)
		let releaseResult6 = ownership.release()
		#expect(releaseResult6 == nil)
	}

	@Test
	internal func anUnknownAnswerIsNotPermission() {
		var ownership = WebKitSwipeOwnership()
		ownership.begin(inverted: true, canGoBack: true, canGoForward: true)
		ownership.acknowledge(consumed: false, propagatesX: nil)
		ownership.update(horizontal: 0.3, totalVertical: 0)
		#expect(!ownership.admitted)
		#expect(ownership.progress == 0)
	}

	@Test
	internal func travelBeforeAdmissionDoesNotPrefillTheRing() {
		var ownership = WebKitSwipeOwnership()
		ownership.begin(inverted: true, canGoBack: true, canGoForward: true)
		ownership.update(horizontal: 0.1, totalVertical: 0)
		ownership.acknowledge(consumed: false, propagatesX: true)
		#expect(ownership.progress == 0)
		ownership.update(horizontal: 0.18, totalVertical: 0)
		#expect(abs(ownership.progress - 0.5) < 1e-9)
	}

	@Test
	internal func noBackMeansThePageKeepsTheGesture() {
		var ownership = admitted(canGoBack: false)
		ownership.update(horizontal: 0.2, totalVertical: 0)
		#expect(ownership.owner == .content)
		let releaseResult7 = ownership.release()
		#expect(releaseResult7 == nil)
	}

	@Test
	internal func verticalTravelGivesTheGestureBack() {
		var ownership = admitted()
		ownership.update(horizontal: 0.02, totalVertical: 0.05)
		#expect(ownership.owner == .cancelled)
		let releaseResult8 = ownership.release()
		#expect(releaseResult8 == nil)
	}

	@Test
	internal func theListOpensPastHalfAgainTheThreshold() {
		var ownership = admitted()
		ownership.update(horizontal: 0.001, totalVertical: 0)
		ownership.update(horizontal: 0.2, totalVertical: 0)
		let revealScrubberResult9 = ownership.revealScrubber()
		#expect(!revealScrubberResult9)
		ownership.update(horizontal: 0.25, totalVertical: 0)
		let revealScrubberResult10 = ownership.revealScrubber()
		#expect(revealScrubberResult10)
		#expect(ownership.owner == .scrubber)
		// Selecting moves vertically without giving the gesture back.
		ownership.update(horizontal: 0.25, totalVertical: 0.3)
		#expect(ownership.owner == .scrubber)
		let releaseScrubberResult11 = ownership.releaseScrubber()
		#expect(releaseScrubberResult11)
	}

	@Test
	internal func retreatingFoldsTheListBack() {
		var ownership = admitted()
		ownership.update(horizontal: 0.001, totalVertical: 0)
		ownership.update(horizontal: 0.25, totalVertical: 0)
		let revealScrubberResult12 = ownership.revealScrubber()
		#expect(revealScrubberResult12)
		ownership.update(horizontal: 0.05, totalVertical: 0)
		#expect(ownership.owner == .history)
		let releaseResult13 = ownership.release()
		#expect(releaseResult13 == nil)
	}

	@Test
	internal func aCancelledGestureCommitsNothing() {
		var ownership = admitted()
		ownership.update(horizontal: 0.3, totalVertical: 0)
		ownership.cancel()
		let releaseResult14 = ownership.release()
		#expect(releaseResult14 == nil)
	}
}
