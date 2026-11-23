import AppUI
import CoreGraphics
import SwiftUI
import Testing

/// DEV-793: a tab dropped outside every Arx window, where nothing took it, tears off.
internal struct SidebarTabTearOffTests {
	private static let windows: [CGRect] = [
		.init(x: 100, y: 100, width: 800, height: 600),
		.init(x: 1200, y: 200, width: 400, height: 300),
	]

	@Test
	internal func anUntakenDropOutsideEveryWindowTearsOff() {
		#expect(SidebarTabTearOff.isOutside(point: .init(x: 1000, y: 400), operation: .cancel, windowFrames: Self.windows))
		#expect(SidebarTabTearOff.isOutside(point: .init(x: 50, y: 50), operation: .forbidden, windowFrames: Self.windows))
		#expect(SidebarTabTearOff.isOutside(point: .init(x: 50, y: 50), operation: .cancel, windowFrames: []))
	}

	@Test
	internal func aDropOverAnArxWindowStays() {
		#expect(!SidebarTabTearOff.isOutside(point: .init(x: 500, y: 400), operation: .cancel, windowFrames: Self.windows))
		// A second window, such as Little Arx, counts too.
		#expect(!SidebarTabTearOff.isOutside(point: .init(x: 1300, y: 300), operation: .cancel, windowFrames: Self.windows))
	}

	@Test
	internal func aTakenDropNeverTearsOff() {
		#expect(!SidebarTabTearOff.isOutside(point: .init(x: 1000, y: 400), operation: .move, windowFrames: Self.windows))
		#expect(!SidebarTabTearOff.isOutside(point: .init(x: 1000, y: 400), operation: .copy, windowFrames: Self.windows))
	}

	@Test
	internal func aDragCancelledWithEscapeStays() {
		#expect(!SidebarTabTearOff.isOutside(
			point: .init(x: 1000, y: 400),
			operation: .cancel,
			cancelledByKey: true,
			windowFrames: Self.windows
		))
	}
}
