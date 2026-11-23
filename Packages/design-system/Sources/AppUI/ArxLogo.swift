import SwiftUI

/// The Arx mark: three curved blades turning about a centre.
///
/// The geometry is the mark's vector from the Arx Browser Figma file (AppIcon page, node
/// 291:48594), in its own 700 × 674 space and scaled to the frame it is drawn in. The app
/// icon's `02-Vector.svg` is the same vector. Fill it with any style, so every surface can tint
/// the same mark.
public struct ArxLogo: Shape {
	/// The mark's nominal size in points; keep frames at this aspect ratio. The width is the
	/// previous mark's, so layouts that place the mark at its design size keep their measure.
	public static let designSize: CGSize = .init(width: 52, height: 52 * 674 / 700)

	/// The space the Figma vector's coordinates are in.
	private static let vectorSize: CGSize = .init(width: 700, height: 674)

	public init() {}

	public func path(in rect: CGRect) -> Path {
		var path = Path()

		// Lower blade.
		path.move(to: .init(x: 2.14561, y: 457.026))
		path.addCurve(to: .init(x: 215.188, y: 526.049), control1: .init(x: 14.8507, y: 424.478), control2: .init(x: 44.9696, y: 515.158))
		path.addCurve(to: .init(x: 531.94, y: 528.968), control1: .init(x: 385.406, y: 536.94), control2: .init(x: 489.548, y: 448.56))
		path.addCurve(to: .init(x: 484.128, y: 642.715), control1: .init(x: 561.466, y: 584.972), control2: .init(x: 529.836, y: 621.231))
		path.addCurve(to: .init(x: 204.017, y: 659.201), control1: .init(x: 418.169, y: 673.717), control2: .init(x: 326.878, y: 687.28))
		path.addCurve(to: .init(x: 2.14561, y: 457.026), control1: .init(x: 81.1555, y: 631.122), control2: .init(x: -13.2362, y: 496.475))
		path.closeSubpath()

		// Right blade.
		path.move(to: .init(x: 615.727, y: 638.6))
		path.addCurve(to: .init(x: 569.006, y: 419.663), control1: .init(x: 581.177, y: 643.875), control2: .init(x: 644.68, y: 572.462))
		path.addCurve(to: .init(x: 413.159, y: 144), control1: .init(x: 493.333, y: 266.864), control2: .init(x: 364.692, y: 220.901))
		path.addCurve(to: .init(x: 535.614, y: 128.516), control1: .init(x: 446.917, y: 90.438), control2: .init(x: 494.147, y: 99.6899))
		path.addCurve(to: .init(x: 689.952, y: 362.758), control1: .init(x: 595.452, y: 170.114), control2: .init(x: 652.849, y: 242.36))
		path.addCurve(to: .init(x: 615.727, y: 638.6), control1: .init(x: 727.055, y: 483.155), control2: .init(x: 657.596, y: 632.191))
		path.closeSubpath()

		// Upper blade.
		path.move(to: .init(x: 466.248, y: 16.6514))
		path.addCurve(to: .init(x: 299.927, y: 166.565), control1: .init(x: 488.094, y: 43.9236), control2: .init(x: 394.472, y: 24.657))
		path.addCurve(to: .init(x: 139.022, y: 439.309), control1: .init(x: 205.382, y: 308.473), control2: .init(x: 229.881, y: 442.816))
		path.addCurve(to: .init(x: 64.3802, y: 341.046), control1: .init(x: 75.7384, y: 436.867), control2: .init(x: 60.1391, y: 391.356))
		path.addCurve(to: .init(x: 190.152, y: 90.3182), control1: .init(x: 70.5002, y: 268.447), control2: .init(x: 104.394, y: 182.636))
		path.addCurve(to: .init(x: 466.248, y: 16.6514), control1: .init(x: 275.91, y: -1.9998), control2: .init(x: 439.761, y: -16.3887))
		path.closeSubpath()

		let scale: CGAffineTransform = .init(
			scaleX: rect.width / Self.vectorSize.width,
			y: rect.height / Self.vectorSize.height
		)
		return path.applying(scale.concatenating(.init(translationX: rect.minX, y: rect.minY)))
	}
}

/// The Arx mark at a given width, filled with the foreground style, so it tints like a template
/// image in light and dark (DEV-829). Use it wherever an icon stands for Arx itself; websites
/// keep the globe.
public struct ArxMark: View {
	private let width: CGFloat

	public init(width: CGFloat) {
		self.width = width
	}

	public var body: some View {
		ArxLogo()
			.fill(.foreground)
			.frame(
				width: width,
				height: width * ArxLogo.designSize.height / ArxLogo.designSize.width
			)
			.accessibilityHidden(true)
	}
}

/// An icon tile's glyph: an SF Symbol, or the Arx mark where the tile stands for Arx itself
/// (DEV-829).
public enum ArxGlyph: Hashable, Sendable {
	case symbol(String)
	case arxMark
}
