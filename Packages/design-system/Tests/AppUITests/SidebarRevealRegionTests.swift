@testable import AppUI
import CoreGraphics
import Testing

/// The area that reveals a collapsed sidebar and keeps it revealed, and the side menu's parallax.
internal struct SidebarRevealRegionTests {
	private let inset: CGFloat = BrowserMetrics.FloatingSidebar.inset

	@Test
	internal func onlyTheEdgeStripRevealsAHiddenSidebar() {
		let region = SidebarRevealRegion(visibleWidth: 286, inset: inset)
		#expect(region.contains(x: 0, isRevealed: false))
		#expect(region.contains(x: SidebarRevealRegion.edgeWidth, isRevealed: false))
		#expect(!region.contains(x: SidebarRevealRegion.edgeWidth + 1, isRevealed: false))
		#expect(!region.contains(x: 200, isRevealed: false))
	}

	@Test
	internal func aRevealedSidebarStaysWhileThePointerIsOverItOrJustPastIt() {
		let region = SidebarRevealRegion(visibleWidth: 286, inset: inset)
		#expect(region.keepWidth == inset + 286 + SidebarRevealRegion.margin)
		#expect(region.contains(x: 200, isRevealed: true))
		#expect(region.contains(x: inset + 286 + SidebarRevealRegion.margin, isRevealed: true))
		#expect(!region.contains(x: inset + 286 + SidebarRevealRegion.margin + 1, isRevealed: true))
	}

	/// The bug in DEV-754: the region used the sidebar's own width, so reaching for the
	/// Library's page closed it. It follows the width as drawn now.
	@Test
	internal func anOpenSideMenuKeepsItsWholePageInTheRegion() {
		let base: CGFloat = 286
		let menu = SidebarRevealRegion(visibleWidth: BrowserMetrics.Library.minimumWidth, inset: inset)
		#expect(menu.contains(x: base + 60, isRevealed: true))
		#expect(menu.contains(x: BrowserMetrics.Library.minimumWidth, isRevealed: true))

		// The Spaces page fills the window, so every column counts, up to the far edge.
		let window: CGFloat = 1440
		let spaces = SidebarRevealRegion(visibleWidth: window, inset: inset)
		#expect(spaces.contains(x: base + 12 + 1, isRevealed: true))
		#expect(spaces.contains(x: window - 1, isRevealed: true))
		#expect(spaces.contains(x: window, isRevealed: true))
	}

	@Test
	internal func theRegionGrowsWithTheMenuMidSwipe() {
		let base: CGFloat = 286
		let expanded: CGFloat = 1440
		let halfway = SidebarRevealRegion(visibleWidth: base + (expanded - base) * 0.5, inset: inset)
		#expect(halfway.contains(x: 800, isRevealed: true))
		#expect(!halfway.contains(x: 1300, isRevealed: true))
	}

	@Test
	@MainActor
	internal func theSpacesShrinkTowardTheirLeadingEdgeAsTheyFade() {
		let hidden = BrowserMetrics.Library.spacesHiddenScale
		#expect((0.94...0.96).contains(hidden))
		let shown = SidebarLibraryTransition.visibility(progress: 0, range: 0...0.5, isOutgoing: true)
		let half = SidebarLibraryTransition.visibility(progress: 0.25, range: 0...0.5, isOutgoing: true)
		let gone = SidebarLibraryTransition.visibility(progress: 0.5, range: 0...0.5, isOutgoing: true)
		#expect(shown == 1)
		#expect(gone == 0)
		#expect(SidebarLibraryTransition.scale(visibility: shown, hidden: hidden) == 1)
		#expect(SidebarLibraryTransition.scale(visibility: gone, hidden: hidden) == hidden)
		let midway = SidebarLibraryTransition.scale(visibility: half, hidden: hidden)
		#expect(midway < 1 && midway > hidden)
	}
}
