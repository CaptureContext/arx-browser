import AppKit
import CoreGraphics
import Foundation
import PageCaptureFeature
import Testing

internal struct PageCaptureCursorTests {
	private typealias Layout = PageCaptureCursorLayout

	@Test
	internal func hotSpotIsTheCrosshairCenter() {
		#expect(Layout.horizontalBar.midX == Layout.hotSpot.x + 0.5)
		#expect(Layout.verticalBar.midY == Layout.hotSpot.y + 0.5)
		#expect(Layout.horizontalBar.contains(.init(x: Layout.hotSpot.x + 0.5, y: Layout.hotSpot.y + 0.5)))
		#expect(Layout.verticalBar.contains(.init(x: Layout.hotSpot.x + 0.5, y: Layout.hotSpot.y + 0.5)))
	}

	@Test
	internal func crosshairSitsOnWholePoints() {
		for bar in [Layout.horizontalBar, Layout.verticalBar] {
			for edge in [bar.minX, bar.minY, bar.maxX, bar.maxY] {
				#expect(edge == edge.rounded())
			}
		}
	}

	@Test
	internal func everythingFitsAndTheBadgeClearsTheCrosshair() {
		let canvas = CGRect(origin: .zero, size: Layout.size)
		let halo = Layout.haloWidth
		for bar in [Layout.horizontalBar, Layout.verticalBar] {
			#expect(canvas.contains(bar.insetBy(dx: -halo, dy: -halo)))
			#expect(!Layout.badge.intersects(bar.insetBy(dx: -halo, dy: -halo)))
		}
		#expect(canvas.contains(Layout.badge))
		#expect(Layout.badge.contains(Layout.cameraBody))
		#expect(Layout.badge.contains(Layout.cameraBump))
		// Top right of the crosshair.
		#expect(Layout.badge.minX > Layout.hotSpot.x)
		#expect(Layout.badge.maxY < Layout.hotSpot.y)
	}

	/// Draws the pointer at 1× and 2×: the crossing is white, the badge dark, and the
	/// corner away from both clear. Writes the PNGs when `ARX_DESIGN_SNAPSHOTS` names a directory.
	@MainActor
	@Test(arguments: [1, 2])
	internal func pointerDrawsCrispAtEachScale(_ scale: Int) throws {
		let cursor = NSCursor.pageCapture
		#expect(cursor.hotSpot == Layout.hotSpot)

		let width = Int(Layout.size.width) * scale
		let height = Int(Layout.size.height) * scale
		let representation = try #require(NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: width,
			pixelsHigh: height,
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		))
		representation.size = Layout.size
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
		cursor.image.draw(in: CGRect(origin: .zero, size: Layout.size))
		NSGraphicsContext.restoreGraphicsState()

		if let directory = ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] {
			let data = try #require(representation.representation(using: .png, properties: [:]))
			try data.write(to: URL(fileURLWithPath: directory).appending(path: "capture-cursor-\(scale)x.png"))
		}

		func color(_ point: CGPoint) -> NSColor? {
			representation.colorAt(x: Int(point.x) * scale, y: Int(point.y) * scale)?.usingColorSpace(.deviceRGB)
		}
		let center = try #require(color(Layout.hotSpot))
		#expect(center.brightnessComponent > 0.95 && center.alphaComponent > 0.95)
		let badge = try #require(color(.init(x: Layout.badge.minX + 1.5, y: Layout.badge.maxY - 1.5)))
		#expect(badge.brightnessComponent < 0.3 && badge.alphaComponent > 0.8)
		// The halo is as dark where the arms cross as along them.
		let crossingHalo = try #require(color(.init(x: Layout.hotSpot.x - 1, y: Layout.hotSpot.y - 1)))
		let armHalo = try #require(color(.init(x: Layout.hotSpot.x - 1, y: Layout.hotSpot.y - 5)))
		#expect(abs(crossingHalo.alphaComponent - armHalo.alphaComponent) < 0.02)
		let corner = try #require(color(.init(x: 1, y: 1)))
		#expect(corner.alphaComponent < 0.05)
	}
}
