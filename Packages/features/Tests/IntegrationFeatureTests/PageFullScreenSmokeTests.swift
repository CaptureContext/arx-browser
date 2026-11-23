#if DEBUG
import AppKit
@testable import AppFeature
import Testing

@MainActor
@Suite
struct PageFullScreenSmokeTests {
	@Test
	func aFullScreenWindowFillsADisplayWithoutAHousing() {
		let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
		let visible = NSRect(x: 0, y: 0, width: 2560, height: 1415)
		#expect(PageFullScreenSmoke.fullScreenFrame(screen: screen, visible: visible, housing: 0) == screen)
	}

	@Test
	func aFullScreenWindowStaysBelowTheMenuBarAroundACameraHousing() {
		// The built-in 14-inch display: a 38-point housing in a 39-point menu bar.
		let screen = NSRect(x: 0, y: 0, width: 1800, height: 1169)
		let visible = NSRect(x: 0, y: 0, width: 1800, height: 1130)
		#expect(
			PageFullScreenSmoke.fullScreenFrame(screen: screen, visible: visible, housing: 38)
			== NSRect(x: 0, y: 0, width: 1800, height: 1130)
		)
	}

	@Test
	func aSecondDisplayKeepsItsOrigin() {
		let screen = NSRect(x: 1800, y: -200, width: 1800, height: 1169)
		let visible = NSRect(x: 1800, y: -200, width: 1800, height: 1130)
		#expect(
			PageFullScreenSmoke.fullScreenFrame(screen: screen, visible: visible, housing: 38)
			== NSRect(x: 1800, y: -200, width: 1800, height: 1130)
		)
	}
}
#endif
