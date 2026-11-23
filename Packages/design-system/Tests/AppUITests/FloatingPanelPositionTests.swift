import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Where the movable theme panel opens and how it keeps its place (DEV-1286).
internal struct FloatingPanelPositionTests {
	private static let visible: CGRect = .init(x: 0, y: 0, width: 1_440, height: 875)
	private static let size: CGSize = .init(width: 328, height: 420)
	private static let gap: CGFloat = 8

	@Test
	internal func trailingOpensBesideTheAnchorCenteredOnIt() {
		let anchor = CGRect(x: 20, y: 400, width: 220, height: 36)
		let origin = FloatingPanelPosition.origin(of: Self.size, beside: anchor, in: Self.visible, placement: .trailing, gap: Self.gap)
		#expect(origin.x == anchor.maxX + Self.gap)
		#expect(origin.y == anchor.midY - Self.size.height / 2)
	}

	@Test
	internal func trailingFlipsToTheLeadingSideAtTheScreensEdge() {
		let anchor = CGRect(x: 1_200, y: 400, width: 220, height: 36)
		let origin = FloatingPanelPosition.origin(of: Self.size, beside: anchor, in: Self.visible, placement: .trailing, gap: Self.gap)
		#expect(origin.x == anchor.minX - Self.gap - Self.size.width)
	}

	@Test
	internal func rightToLeftOpensOnTheLeftWhereItFits() {
		let anchor = CGRect(x: 1_000, y: 400, width: 220, height: 36)
		let origin = FloatingPanelPosition.origin(
			of: Self.size,
			beside: anchor,
			in: Self.visible,
			placement: .trailing,
			layoutDirection: .rightToLeft,
			gap: Self.gap
		)
		#expect(origin.x == anchor.minX - Self.gap - Self.size.width)
	}

	@Test
	internal func trailingStaysInsideTheVisibleFrame() {
		// Near the bottom of the screen: the panel is pushed up rather than off screen.
		let low = CGRect(x: 20, y: 30, width: 220, height: 36)
		let lowOrigin = FloatingPanelPosition.origin(of: Self.size, beside: low, in: Self.visible, placement: .trailing, gap: Self.gap)
		#expect(lowOrigin.y == Self.visible.minY + Self.gap)

		// Near the top: pushed down below the menu bar's visible frame.
		let high = CGRect(x: 20, y: 840, width: 220, height: 30)
		let highOrigin = FloatingPanelPosition.origin(of: Self.size, beside: high, in: Self.visible, placement: .trailing, gap: Self.gap)
		#expect(highOrigin.y + Self.size.height == Self.visible.maxY - Self.gap)

		// On a second screen to the left, in its own coordinates.
		let second = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_050)
		let anchor = CGRect(x: -1_900, y: 500, width: 220, height: 36)
		let origin = FloatingPanelPosition.origin(of: Self.size, beside: anchor, in: second, placement: .trailing, gap: Self.gap)
		#expect(second.contains(CGRect(origin: origin, size: Self.size)))
	}

	@Test
	internal func verticalKeepsTheFloatingPanelsPlacement() {
		let anchor = CGRect(x: 100, y: 40, width: 28, height: 28)
		let above = FloatingPanelPosition.origin(of: Self.size, beside: anchor, in: Self.visible, placement: .vertical(.top), gap: Self.gap)
		#expect(above.y == anchor.maxY + Self.gap)
		#expect(above.x == Self.visible.minX + Self.gap)

		let tooHigh = CGRect(x: 600, y: 700, width: 28, height: 28)
		let below = FloatingPanelPosition.origin(of: Self.size, beside: tooHigh, in: Self.visible, placement: .vertical(.top), gap: Self.gap)
		#expect(below.y == tooHigh.minY - Self.gap - Self.size.height)
		#expect(below.x == tooHigh.midX - Self.size.width / 2)
	}

	@Test
	internal func aPanelGrowingPastTheScreensBottomRisesToStayInside() {
		var position = FloatingPanelPosition()
		let anchor = CGRect(x: 20, y: 30, width: 220, height: 36)
		_ = position.open(size: Self.size, anchor: anchor, visible: Self.visible, placement: .trailing, gap: Self.gap)

		// Dragged down to the bottom of the screen, then a row is added.
		position.moved(to: .init(origin: .init(x: 600, y: Self.gap), size: Self.size))
		let taller = CGSize(width: Self.size.width, height: Self.size.height + 60)
		let origin = position.resized(to: taller, in: Self.visible, gap: Self.gap)
		#expect(origin?.y == Self.visible.minY + Self.gap)
		#expect(origin?.x == 600)

		// Without a screen (offscreen), the top edge is kept.
		var unplaced = FloatingPanelPosition(frame: .init(origin: .init(x: 0, y: 0), size: Self.size))
		#expect(unplaced.resized(to: taller, in: nil)?.y == -60)
	}

	@Test
	internal func aDraggedPanelKeepsItsPlaceUntilItCloses() {
		let anchor = CGRect(x: 20, y: 400, width: 220, height: 36)
		var position = FloatingPanelPosition()
		let opened = position.open(size: Self.size, anchor: anchor, visible: Self.visible, placement: .trailing, gap: Self.gap)
		#expect(position.frame == CGRect(origin: opened, size: Self.size))

		let dragged = CGRect(origin: .init(x: 900, y: 300), size: Self.size)
		position.moved(to: dragged)
		#expect(position.frame == dragged)

		// The content grows (a section opens): the top edge stays where the drag left it.
		let taller = CGSize(width: Self.size.width, height: Self.size.height + 60)
		let resized = position.resized(to: taller, in: Self.visible, gap: Self.gap)
		#expect(resized == CGPoint(x: dragged.minX, y: dragged.maxY - taller.height))
		#expect(position.frame?.maxY == dragged.maxY)

		// Closing forgets the drag; the next opening starts beside the anchor again.
		position.close()
		#expect(position.frame == nil)
		#expect(position.resized(to: Self.size, in: Self.visible, gap: Self.gap) == nil)
		position.moved(to: dragged)
		#expect(position.frame == nil)
		let reopened = position.open(size: Self.size, anchor: anchor, visible: Self.visible, placement: .trailing, gap: Self.gap)
		#expect(reopened == opened)
	}
}

/// Writes offscreen PNGs of the movable theme panel with its handle (DEV-1286), light and dark,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct MovableFloatingPanelSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func thePanelWithItsHandle(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			HStack(alignment: .top, spacing: 24) {
				FloatingPanelChrome(
					isMovable: true,
					content: AnyView(
						SpaceThemeEditor(
							choices: AppearanceOverride().settingThemeColors([.init(hue: 205, intensity: 0.35)], over: .default),
							inherited: .default,
							onCommit: { _ in },
							onClear: {}
						)
						.frame(width: SpaceThemeEditor.width)
						.padding([.horizontal, .bottom], 14)
						.padding(.top, 4)
					)
				)
				FloatingPanelChrome(
					isMovable: true,
					content: AnyView(
						Text(verbatim: "Panel content")
							.frame(width: 200, height: 80)
					)
				)
			}
			.padding(24)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
			size: .init(width: 680, height: 600),
			appearance: appearance,
			name: "movable-floating-panel"
		)
	}
}
