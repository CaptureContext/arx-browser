import AppKit
import Foundation
import Testing
import WebKit

@testable import WebKitBrowserEngine

/// Arx's swipe on WebKit pages (DEV-1203): scrolls drive it, the page's answers admit it, and the
/// router's answers decide where it goes.
@Suite(.serialized)
@MainActor
internal struct WebKitHistorySwipeTests {
	private final class FocusableView: NSView {
		override var acceptsFirstResponder: Bool { true }
	}

	@MainActor
	private final class Fixture {
		let window: NSWindow
		let view: NSView
		let swipe = WebKitHistorySwipe()
		var performed: [WebKitHistorySwipe.Navigation] = []
		var canGoBack = true
		var canGoForward = false
		var identity: [ObjectIdentifier] = []
		var list: [WebKitHistorySwipe.Entry] = []
		var swipesBetweenPages = true

		init() {
			window = NSWindow(
				contentRect: .init(x: -10_000, y: -10_000, width: 800, height: 600),
				styleMask: [.borderless],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			view = FocusableView(frame: .init(x: 0, y: 0, width: 800, height: 600))
			window.contentView = view
			window.orderFrontRegardless()
			swipe.availability = { [unowned self] in (canGoBack, canGoForward) }
			swipe.historyIdentity = { [unowned self] in identity }
			swipe.entries = { [unowned self] _ in list }
			swipe.perform = { [unowned self] in performed.append($0) }
			swipe.isEnabled = { [unowned self] in swipesBetweenPages }
		}

		@discardableResult
		func scroll(
			_ phase: WebKitHistorySwipe.Phase,
			x: Double = 0,
			y: Double = 0
		) -> Bool {
			swipe.handle(
				.init(phase: phase, deltaX: x, deltaY: y, pointer: .init(x: 400, y: 300)),
				in: view
			)
		}

		func answer(
			consumed: Bool = false,
			propagatesX: Bool? = true,
			time: Double = Date().timeIntervalSince1970 * 1000
		) {
			swipe.acknowledge(.init(consumed: consumed, propagatesX: propagatesX, time: time))
		}

		isolated deinit {
			swipe.invalidate()
			window.orderOut(nil)
			window.close()
		}
	}

	@Test
	internal func aSwipeBackGoesBackThroughTheRouter() {
		let fixture = Fixture()

		// Natural scrolling: fingers moving right scroll right, which goes back.
		#expect(!fixture.scroll(.began, x: 1))
		fixture.answer()
		for _ in 0 ..< 4 { fixture.scroll(.changed, x: 40) }
		#expect(fixture.scroll(.changed, x: 1))
		#expect(fixture.swipe.panel?.isFilled == true)
		fixture.scroll(.ended)
		#expect(fixture.performed == [.back])
		#expect(fixture.swipe.panel == nil)
	}

	@Test
	internal func aShortSwipeGoesNowhere() {
		let fixture = Fixture()
		fixture.scroll(.began, x: 1)
		fixture.answer()
		fixture.scroll(.changed, x: 60)
		#expect(fixture.swipe.panel?.isVisible == true)
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
	}

	@Test
	internal func aPageThatScrollsSidewaysKeepsItsSwipe() {
		let fixture = Fixture()
		fixture.scroll(.began, x: 1)
		fixture.answer(consumed: true, propagatesX: nil)
		for _ in 0 ..< 5 { #expect(!fixture.scroll(.changed, x: 40)) }
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
		#expect(fixture.swipe.panel == nil)
	}

	@Test
	internal func noAnswerFromThePageAdmitsNothing() {
		let fixture = Fixture()
		fixture.scroll(.began, x: 1)
		for _ in 0 ..< 5 { #expect(!fixture.scroll(.changed, x: 40)) }
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
	}

	@Test
	internal func anAnswerForAnEarlierWheelDoesNotCount() {
		let fixture = Fixture()
		fixture.scroll(.began, x: 1)
		fixture.answer(time: Date().timeIntervalSince1970 * 1000 - 1000)
		for _ in 0 ..< 5 { fixture.scroll(.changed, x: 40) }
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
	}

	@Test
	internal func withoutForwardTheSwipeIsThePages() {
		let fixture = Fixture()

		// Fingers moving left go forward, which the router says isn't there.
		fixture.scroll(.began, x: -1)
		fixture.answer()
		for _ in 0 ..< 5 { #expect(!fixture.scroll(.changed, x: -40)) }
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
	}

	@Test
	internal func aForwardSwipeGoesForward() {
		let fixture = Fixture()
		fixture.canGoForward = true
		fixture.scroll(.began, x: -1)
		fixture.answer()
		for _ in 0 ..< 5 { fixture.scroll(.changed, x: -40) }
		fixture.scroll(.ended)
		#expect(fixture.performed == [.forward])
	}

	@Test
	internal func aHistoryChangeDuringTheSwipeCancelsIt() {
		let fixture = Fixture()
		fixture.identity = [ObjectIdentifier(NSObject.self)]
		fixture.scroll(.began, x: 1)
		fixture.answer()
		for _ in 0 ..< 5 { fixture.scroll(.changed, x: 40) }
		fixture.identity = []
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
	}

	@Test
	internal func aCancelledScrollGoesNowhere() {
		let fixture = Fixture()
		fixture.scroll(.began, x: 1)
		fixture.answer()
		for _ in 0 ..< 5 { fixture.scroll(.changed, x: 40) }
		fixture.scroll(.cancelled)
		#expect(fixture.performed.isEmpty)
	}

	@Test
	internal func theHistoryListCanPickTheChromiumPage() async throws {
		let fixture = Fixture()
		fixture.list = [
			.init(title: "Two", navigation: .entry(-1)),
			.init(title: "One", navigation: .entry(-2)),
			.init(title: "Google", navigation: .returnToChromium),
		]
		fixture.scroll(.began, x: 1)
		fixture.answer()

		// Past half again the threshold, held, the list opens.
		for _ in 0 ..< 6 { fixture.scroll(.changed, x: 40) }
		try await Task.sleep(for: .milliseconds(450))
		fixture.scroll(.changed, x: 1)
		#expect(fixture.swipe.ownership.owner == .scrubber)
		#expect(fixture.swipe.panel?.isArmed == true)
		// Natural scrolling: fingers moving down scroll down and pick older entries.
		for _ in 0 ..< 4 { fixture.scroll(.changed, y: 40) }
		fixture.scroll(.ended)
		#expect(fixture.performed == [.returnToChromium])
	}

	/// DEV-1292: down goes back through history and up goes forward. Each list moves away from the
	/// current page in its own direction, one row per `rowPitch` of travel.
	@Test
	internal func downGoesBackAndUpGoesForward() {
		let pitch = WebKitHistorySwipe.rowPitch
		#expect(WebKitHistorySwipe.rowPitch == 0.07)
		// Fingers down: y falls.
		func rows(_ index: Int, _ y: Double, _ direction: WebKitSwipeDirection) -> Double {
			WebKitHistorySwipe.selection(anchorIndex: index, anchorY: 0.5, y: y, direction: direction).rounded()
		}
		#expect(rows(0, 0.5 - 2 * pitch, .back) == 2)
		#expect(rows(0, 0.5 - 2 * pitch, .forward) == -2)
		// Fingers up: y rises.
		#expect(rows(0, 0.5 + 2 * pitch, .back) == -2)
		#expect(rows(0, 0.5 + 2 * pitch, .forward) == 2)
		#expect(rows(3, 0.5 + pitch, .forward) == 4)
		// Under half a row moves nothing: the old 0.05 pitch would have moved one.
		#expect(rows(0, 0.5 + 0.034, .forward) == 0)
	}

	/// DEV-1292: on a forward swipe the list rises from the arrow, so fingers moving up pick
	/// entries further forward, and down from the nearest goes nowhere further.
	@Test
	internal func theForwardListGoesFurtherWithFingersUp() async throws {
		let fixture = Fixture()
		fixture.canGoBack = false
		fixture.canGoForward = true
		fixture.list = [
			.init(title: "Two", navigation: .entry(1)),
			.init(title: "Three", navigation: .entry(2)),
			.init(title: "Four", navigation: .entry(3)),
		]
		fixture.scroll(.began, x: -1)
		fixture.answer()
		for _ in 0 ..< 6 { fixture.scroll(.changed, x: -40) }
		try await Task.sleep(for: .milliseconds(450))
		fixture.scroll(.changed, x: -1)
		#expect(fixture.swipe.ownership.owner == .scrubber)
		#expect(fixture.swipe.panel?.isArmed == true)
		// Natural scrolling: fingers moving up give negative deltas. Two rows' travel is two rows.
		let row = WebKitHistorySwipe.rowPitch * WebKitSwipeOwnership.scrollPointsPerUnit
		fixture.scroll(.changed, y: -row)
		fixture.scroll(.changed, y: -row)
		fixture.scroll(.ended)
		#expect(fixture.performed == [.entry(3)])
	}

	/// DEV-1292: fingers down on a forward list stay on the nearest entry.
	@Test
	internal func fingersDownOnTheForwardListStayOnTheNearest() async throws {
		let fixture = Fixture()
		fixture.canGoBack = false
		fixture.canGoForward = true
		fixture.list = [
			.init(title: "Two", navigation: .entry(1)),
			.init(title: "Three", navigation: .entry(2)),
		]
		fixture.scroll(.began, x: -1)
		fixture.answer()
		for _ in 0 ..< 6 { fixture.scroll(.changed, x: -40) }
		try await Task.sleep(for: .milliseconds(450))
		fixture.scroll(.changed, x: -1)
		#expect(fixture.swipe.ownership.owner == .scrubber)
		for _ in 0 ..< 4 { fixture.scroll(.changed, y: 40) }
		fixture.scroll(.ended)
		#expect(fixture.performed == [.entry(1)])
	}

	@Test
	internal func losingTheFocusItBeganWithCancelsIt() {
		let fixture = Fixture()
		#expect(fixture.window.makeFirstResponder(fixture.view))
		fixture.scroll(.began, x: 1)
		fixture.answer()
		for _ in 0 ..< 5 { fixture.scroll(.changed, x: 40) }
		#expect(fixture.swipe.panel?.isFilled == true)
		fixture.window.makeFirstResponder(nil)
		#expect(!fixture.scroll(.changed, x: 1))
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
		#expect(fixture.swipe.panel == nil)
	}

	@Test
	internal func thePageLeavingItsWindowEndsTheSwipe() {
		let fixture = Fixture()
		let page = WebKitPageView(frame: fixture.view.bounds, configuration: .init())
		page.historySwipe = fixture.swipe
		fixture.view.addSubview(page)
		_ = fixture.swipe.handle(.init(phase: .began, deltaX: 1, pointer: .init(x: 400, y: 300)), in: page)
		fixture.answer()
		for _ in 0 ..< 5 {
			_ = fixture.swipe.handle(.init(phase: .changed, deltaX: 40, pointer: .init(x: 400, y: 300)), in: page)
		}
		#expect(fixture.swipe.panel?.isVisible == true)
		page.removeFromSuperview()
		#expect(fixture.swipe.panel == nil)
		#expect(!fixture.swipe.ownership.isCurrent)
		page.historySwipe = nil
	}

	@Test
	internal func macOSSwipeBetweenPagesOffLeavesScrollsToThePage() {
		let fixture = Fixture()
		fixture.swipesBetweenPages = false
		fixture.scroll(.began, x: 1)
		fixture.answer()
		for _ in 0 ..< 5 { #expect(!fixture.scroll(.changed, x: 40)) }
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
		#expect(fixture.swipe.panel == nil)
	}

	@Test
	internal func turningSwipeBetweenPagesOffMidSwipeCancelsIt() {
		let fixture = Fixture()
		fixture.scroll(.began, x: 1)
		fixture.answer()
		for _ in 0 ..< 5 { fixture.scroll(.changed, x: 40) }
		fixture.swipesBetweenPages = false
		fixture.scroll(.ended)
		#expect(fixture.performed.isEmpty)
	}
}
