@testable import AppUI
import CoreGraphics
import Testing

/// When the sidebar header's profile badge truncates, and when it hides.
internal struct SidebarToolbarFitTests {
	@Test
	internal func theNarrowestSidebarHasNoRoomForTheBadge() {
		#expect(SidebarToolbarFit.profileBadgeWidth(rowWidth: 216) == nil)
	}

	@Test
	internal func theBadgeTruncatesBeforeItHides() throws {
		let minimum = BrowserMetrics.Toolbar.profileBadgeMinimumWidth
		let threshold = try #require(
			(216...528).first { SidebarToolbarFit.profileBadgeWidth(rowWidth: CGFloat($0)) != nil }
		)
		#expect(SidebarToolbarFit.profileBadgeWidth(rowWidth: CGFloat(threshold)).map { $0 >= minimum } == true)
		#expect(SidebarToolbarFit.profileBadgeWidth(rowWidth: CGFloat(threshold - 1)) == nil)
		// The badge shows from just under 260 pt, so the toolbar's other buttons and a short name still fit there.
		#expect(threshold <= 260)
		#expect(threshold > 216)
	}

	@Test
	internal func theBadgeGrowsWithTheSidebarUpToItsMaximum() throws {
		let at260 = try #require(SidebarToolbarFit.profileBadgeWidth(rowWidth: 260))
		let at286 = try #require(SidebarToolbarFit.profileBadgeWidth(rowWidth: 286))
		#expect(at260 < at286)
		#expect(SidebarToolbarFit.profileBadgeWidth(rowWidth: 528) == BrowserMetrics.Toolbar.profileBadgeMaximumWidth)
	}

	/// The badge only ever takes the room the fixed controls leave, so nothing pushes the window controls.
	@Test(arguments: Array(stride(from: CGFloat(216), through: 528, by: 4)))
	internal func theRowNeverOverflows(rowWidth: CGFloat) {
		let badge = SidebarToolbarFit.profileBadgeWidth(rowWidth: rowWidth).map {
			$0 + BrowserMetrics.Toolbar.spacing + BrowserMetrics.Toolbar.profileBadgeGap
		} ?? 0
		#expect(SidebarToolbarFit.fixedWidth + badge <= rowWidth)
	}
}
