import AppKit
import CoreGraphics

/// Where the capture pointer's parts sit, in points with a top-left origin. Every edge is
/// on a whole point, so the 1-point crosshair lands on whole pixels at 1× and 2×.
public enum PageCaptureCursorLayout {
	public static let size: CGSize = .init(width: 32, height: 32)

	/// The pixel the pointer acts on, the crosshair's center. A hot spot names the pixel
	/// whose top-left corner it is, which is the 1-point bars' crossing.
	public static let hotSpot: CGPoint = .init(x: 12, y: 20)

	/// How far each arm reaches past the center pixel.
	public static let armLength: CGFloat = 9

	/// The white bars, one point wide.
	public static let horizontalBar: CGRect = .init(
		x: hotSpot.x - armLength,
		y: hotSpot.y,
		width: armLength * 2 + 1,
		height: 1
	)
	public static let verticalBar: CGRect = .init(
		x: hotSpot.x,
		y: hotSpot.y - armLength,
		width: 1,
		height: armLength * 2 + 1
	)

	/// The dark halo around each bar, so the crosshair reads on light and dark pages.
	public static let haloWidth: CGFloat = 1

	/// The camera badge at the crosshair's top right.
	public static let badge: CGRect = .init(x: 17, y: 1, width: 14, height: 11)
	public static let badgeCornerRadius: CGFloat = 3

	/// The camera glyph inside the badge.
	public static let cameraBody: CGRect = .init(x: 19.5, y: 4.5, width: 9, height: 5.5)
	public static let cameraBump: CGRect = .init(x: 22, y: 3, width: 4, height: 2.5)
	public static let lensCenter: CGPoint = .init(x: 24, y: 7.25)
	public static let lensRadius: CGFloat = 1.6
}

extension NSCursor {
	/// A "+" crosshair with a camera badge at its top right. The image redraws from
	/// vectors at each backing scale, so it stays sharp on Retina displays.
	@MainActor
	public static let pageCapture: NSCursor = {
		typealias Layout = PageCaptureCursorLayout

		let image = NSImage(size: Layout.size, flipped: true) { _ in
			let halo = Layout.haloWidth

			// One path, so the translucent halo doesn't darken twice where the arms cross.
			let outline = NSBezierPath(rect: Layout.horizontalBar.insetBy(dx: -halo, dy: -halo))
			outline.append(NSBezierPath(rect: Layout.verticalBar.insetBy(dx: -halo, dy: -halo)))
			outline.windingRule = .nonZero
			NSColor.black.withAlphaComponent(0.6).setFill()
			outline.fill()
			NSColor.white.setFill()
			for bar in [Layout.horizontalBar, Layout.verticalBar] {
				NSBezierPath(rect: bar).fill()
			}

			let badge = NSBezierPath(
				roundedRect: Layout.badge,
				xRadius: Layout.badgeCornerRadius,
				yRadius: Layout.badgeCornerRadius
			)
			NSColor(white: 0.1, alpha: 0.9).setFill()
			badge.fill()
			NSColor.white.withAlphaComponent(0.35).setStroke()
			let edge = NSBezierPath(
				roundedRect: Layout.badge.insetBy(dx: 0.25, dy: 0.25),
				xRadius: Layout.badgeCornerRadius - 0.25,
				yRadius: Layout.badgeCornerRadius - 0.25
			)
			edge.lineWidth = 0.5
			edge.stroke()

			let camera = NSBezierPath(roundedRect: Layout.cameraBody, xRadius: 1.25, yRadius: 1.25)
			camera.append(NSBezierPath(roundedRect: Layout.cameraBump, xRadius: 0.75, yRadius: 0.75))
			NSColor.white.setFill()
			camera.fill()

			let lens = NSBezierPath(ovalIn: CGRect(
				x: Layout.lensCenter.x - Layout.lensRadius,
				y: Layout.lensCenter.y - Layout.lensRadius,
				width: Layout.lensRadius * 2,
				height: Layout.lensRadius * 2
			))
			NSColor(white: 0.1, alpha: 1).setFill()
			lens.fill()
			return true
		}
		return NSCursor(image: image, hotSpot: Layout.hotSpot)
	}()
}
