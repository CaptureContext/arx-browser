@testable import AppUI
import BrowserCore
import CoreGraphics
import Testing

/// Hover previews: a panel beside the row, and a longer wait before the first one.
internal struct SidebarHoverPanelTests {
	private static let screen: CGRect = .init(x: 0, y: 0, width: 1440, height: 900)
	private static let card: CGSize = .init(width: 300, height: 220)

	@Test
	internal func theCardSitsAfterTheRowCenteredOnIt() {
		let row = CGRect(x: 10, y: 500, width: 260, height: 34)
		let origin = SidebarHoverPanelPlacement.origin(of: Self.card, beside: row, within: Self.screen, gap: 8)
		#expect(origin.x == row.maxX + 8)
		#expect(origin.y + Self.card.height / 2 == row.midY)
	}

	@Test
	internal func itGoesBeforeTheRowWhenAfterDoesntFit() {
		let row = CGRect(x: 1200, y: 500, width: 220, height: 34)
		let origin = SidebarHoverPanelPlacement.origin(of: Self.card, beside: row, within: Self.screen, gap: 8)
		#expect(origin.x + Self.card.width == row.minX - 8)
	}

	@Test
	internal func itStaysOnScreenNearTheTopAndBottom() {
		let top = CGRect(x: 10, y: 880, width: 260, height: 34)
		#expect(
			SidebarHoverPanelPlacement.origin(of: Self.card, beside: top, within: Self.screen, gap: 8).y
			== CGFloat(900 - 8 - 220)
		)
		let bottom = CGRect(x: 10, y: 0, width: 260, height: 34)
		#expect(
			SidebarHoverPanelPlacement.origin(of: Self.card, beside: bottom, within: Self.screen, gap: 8).y
			== CGFloat(8)
		)
	}

	@Test
	internal func theFirstPreviewWaitsASecond() {
		#expect(SidebarInteractionConfiguration().hoverPreviewDelay == .seconds(1))
	}

	/// DEV-1029: Shift opens a preview at once, as a preview that just closed does.
	@Test
	internal func shiftOpensAPreviewAtOnce() {
		let interaction = SidebarInteractionConfiguration(shiftOpensPreviews: true)
		#expect(SidebarHoverPreviewDelay.delay(isShiftDown: false, isWarm: false, interaction: interaction) == .seconds(1))
		#expect(SidebarHoverPreviewDelay.delay(isShiftDown: true, isWarm: false, interaction: interaction) == .zero)
		#expect(SidebarHoverPreviewDelay.delay(isShiftDown: false, isWarm: true, interaction: interaction) == .zero)
		#expect(SidebarHoverPreviewDelay.delay(isShiftDown: true, isWarm: true, interaction: interaction) == .zero)
	}

	/// With `ARX_SHIFT_HOVER_PREVIEW` off, Shift waits the hover delay like any other hover.
	@Test
	internal func shiftWaitsWithItsFeatureFlagOff() {
		let interaction = SidebarInteractionConfiguration(shiftOpensPreviews: false)
		#expect(SidebarHoverPreviewDelay.delay(isShiftDown: true, isWarm: false, interaction: interaction) == .seconds(1))
		#expect(SidebarHoverPreviewDelay.delay(isShiftDown: true, isWarm: true, interaction: interaction) == .zero)
	}

	@Test
	internal func shiftHoverPreviewsAreOnByDefault() {
		let flag = FeatureFlag.shiftHoverPreview
		#expect(flag.name == "ARX_SHIFT_HOVER_PREVIEW")
		#expect(flag.isOnByDefault)
		#expect(flag.needsRelaunch)
		#expect(!flag.isRisky)
		#expect(!flag.isReadByEngine)
	}
}
