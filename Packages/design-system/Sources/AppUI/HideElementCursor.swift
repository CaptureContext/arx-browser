import AppKit

/// Where Hide Element's pointer sits (DEV-1298), in points with a top-left origin: Figma's
/// `scope` glyph in black with a white halo, as macOS draws its own pointers, so it reads on
/// light and dark pages, centered on the pixel it acts on.
public enum HideElementCursorLayout {
	public static let size: CGSize = .init(width: 24, height: 24)

	/// The glyph's 20-point square, as Figma draws it.
	public static let glyph: CGRect = .init(x: 2, y: 2, width: 20, height: 20)

	/// The ring's center, the pixel the pointer acts on.
	public static let hotSpot: CGPoint = .init(x: 12, y: 12)

	/// How far the halo reaches past the glyph's strokes.
	public static let haloWidth: CGFloat = 1
	public static let haloOpacity: CGFloat = 0.95
}

extension NSCursor {
	/// Hide Element's pointer over the page while the mode is on (DEV-1298): the scope. The image
	/// redraws from the vector glyph at each backing scale, so it stays sharp on Retina displays.
	@MainActor
	public static let hideElement: NSCursor = {
		typealias Layout = HideElementCursorLayout

		guard let glyph = Bundle.module.image(forResource: "glyph.scope") else { return .crosshair }

		let image = NSImage(size: Layout.size, flipped: true) { _ in
			let halo = Layout.haloWidth

			// One halo image, so the offsets don't darken twice where they overlap.
			let shadow = NSImage(size: Layout.size, flipped: true) { _ in
				let light = glyph.tinted(.white, size: Layout.glyph.size)
				for dx in [-halo, 0, halo] {
					for dy in [-halo, 0, halo] where dx != 0 || dy != 0 {
						light.draw(in: Layout.glyph.offsetBy(dx: dx, dy: dy))
					}
				}
				return true
			}
			shadow.draw(
				in: CGRect(origin: .zero, size: Layout.size),
				from: .zero,
				operation: .sourceOver,
				fraction: Layout.haloOpacity
			)
			glyph.tinted(.black, size: Layout.glyph.size).draw(in: Layout.glyph)
			return true
		}
		return NSCursor(image: image, hotSpot: Layout.hotSpot)
	}()
}

extension NSImage {
	/// The image's shape filled with `color`, at `size`.
	fileprivate func tinted(
		_ color: NSColor,
		size: CGSize
	) -> NSImage {
		NSImage(size: size, flipped: false) { rect in
			self.draw(in: rect)
			color.set()
			rect.fill(using: .sourceAtop)
			return true
		}
	}
}
