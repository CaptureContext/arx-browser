@testable import AppFeature
import Testing

/// DEV-1073: ⌘Z's two seconds count from when focus arrives at a page, not from every move of
/// the first responder inside it.
@Suite
internal struct PageFocusArrivalsTests {
	private let page = SiteShortcutState.Page(1)
	private let other = SiteShortcutState.Page(2)

	@Test
	func focusMovingInsideThePageIsNoArrival() {
		var arrivals = PageFocusArrivals()
		#expect(arrivals.note(page, windowBecameKey: false) == page)
		#expect(arrivals.note(page, windowBecameKey: false) == nil)
		#expect(arrivals.note(page, windowBecameKey: false) == nil)
	}

	@Test
	func focusComingBackFromArxsOwnViewsArrivesAgain() {
		var arrivals = PageFocusArrivals(page: page)
		#expect(arrivals.note(nil, windowBecameKey: false) == nil)
		#expect(arrivals.page == nil)
		#expect(arrivals.note(page, windowBecameKey: false) == page)
	}

	@Test
	func anotherPageArrives() {
		var arrivals = PageFocusArrivals(page: page)
		#expect(arrivals.note(other, windowBecameKey: false) == other)
	}

	@Test
	func theWindowBecomingKeyIsAnArrival() {
		var arrivals = PageFocusArrivals(page: page)
		#expect(arrivals.note(page, windowBecameKey: true) == page)
	}
}
