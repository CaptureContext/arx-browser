@testable import AppUI
import SwiftUI
import Testing

/// DEV-1310: the sidebar's rows take no hit-testing while fingers or their momentum scroll
/// them, and do while a scroll made for the keyboard runs.
@MainActor
@Suite
internal struct SidebarScrollLatchTests {
	@Test
	internal func onlyFingersAndTheirMomentumHoldTheRows() {
		#expect(SidebarScrollLatch.holdsRows(during: .tracking))
		#expect(SidebarScrollLatch.holdsRows(during: .interacting))
		#expect(SidebarScrollLatch.holdsRows(during: .decelerating))
		#expect(!SidebarScrollLatch.holdsRows(during: .idle))
		#expect(!SidebarScrollLatch.holdsRows(during: .animating))
	}

	@Test
	internal func theRowsAreHeldFromTheFirstMoveUntilTheScrollRests() {
		let latch = SidebarScrollLatch()
		#expect(!latch.isScrolling)
		latch.phaseChanged(.interacting)
		#expect(latch.isScrolling)
		latch.phaseChanged(.decelerating)
		#expect(latch.isScrolling)
		latch.phaseChanged(.idle)
		#expect(!latch.isScrolling)
	}
}
