import SwiftUI

/// The sidebar folder (`SidebarRowPolish`): one rounded outline per state, stroked once at one
/// width, over a pale back strip and a light front.
///
/// It's drawn on an 18-point square, placed on whole points. Every straight edge's center runs on a
/// quarter point, a 1.5-point stroke's center at 2x, so the stroke covers whole pixels at 2x and
/// the same pixel and a half on every side at 1x. The open folder reaches 3 points past the square
/// on the trailing side.
internal struct PolishedFolderIcon: View {
	internal enum State: Hashable {
		case closed
		case open

		/// Closed, with its selected tab showing beneath it: "•••" on the front (DEV-1110).
		case collapsedWithSelection
	}

	internal static let side: CGFloat = 18
	internal static let lineWidth: CGFloat = 1.5
	internal static let openOverhang: CGFloat = 3

	private let state: State
	private let paper: AnyShapeStyle
	private let back: AnyShapeStyle
	private let outline: AnyShapeStyle

	internal init(
		state: State,
		paper: AnyShapeStyle,
		back: AnyShapeStyle,
		outline: AnyShapeStyle
	) {
		self.state = state
		self.paper = paper
		self.back = back
		self.outline = outline
	}

	internal var body: some View {
		Canvas(rendersAsynchronously: false) { context, _ in
			switch state {
			case .closed: drawClosed(in: &context, dots: false)
			case .collapsedWithSelection: drawClosed(in: &context, dots: true)
			case .open: drawOpen(in: &context)
			}
		}
		.frame(width: Self.side + Self.openOverhang, height: Self.side)

		// The square sits on the leading edge; the open flap may overhang it.
		.frame(width: Self.side, height: Self.side, alignment: .leading)
	}

	private var stroke: StrokeStyle {
		.init(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
	}

	/// The outline and the line where the front meets the back strip, stroked together as one path.
	private func drawClosed(
		in context: inout GraphicsContext,
		dots: Bool
	) {
		let outer = Self.closedOutline
		context.fill(outer, with: .style(paper))
		var strip = context
		strip.clip(to: Path(CGRect(x: 0, y: 0, width: Self.side, height: Self.frontTop)))
		strip.fill(outer, with: .style(back))

		var lines = outer
		lines.move(to: .init(x: Self.left, y: Self.frontTop))
		lines.addLine(to: .init(x: Self.right, y: Self.frontTop))
		context.stroke(lines, with: .style(outline), style: stroke)

		guard dots else { return }

		let diameter: CGFloat = 2.5
		let centerY: CGFloat = (Self.frontTop + Self.bottom) / 2
		for centerX in [5, 9, 13] as [CGFloat] {
			let rect = CGRect(
				x: centerX - diameter / 2,
				y: centerY - diameter / 2,
				width: diameter,
				height: diameter
			)
			context.fill(Path(ellipseIn: rect), with: .style(outline))
		}
	}

	/// The back, its leading edge leaning in a little toward the bottom, behind a front flap that
	/// leans out to the trailing side. One stroke draws the whole silhouette and the flap's top and
	/// leading edges. Both leading edges meet at the folder's bottom-leading corner's,
	/// and the round join and cap there draw it at the same width as every other corner.
	private func drawOpen(in context: inout GraphicsContext) {
		context.fill(Self.openSilhouette, with: .style(back))
		context.fill(Self.openFlap, with: .style(paper))

		var lines = Self.openSilhouette
		lines.addPath(Self.openFlapEdges)
		context.stroke(lines, with: .style(outline), style: stroke)
	}

	// MARK: Geometry, in points on the 18-point square

	private static let left: CGFloat = 0.75
	private static let right: CGFloat = 17.25
	private static let tabTop: CGFloat = 1.75
	private static let bodyTop: CGFloat = 3.75

	/// The front's top edge, under the back strip.
	private static let frontTop: CGFloat = 6.75
	private static let bottom: CGFloat = 16.25

	/// Where the tab's top ends and its slope down to the body begins.
	private static let tabEnd: CGFloat = 6.75
	private static let slopeEnd: CGFloat = 8.75

	private static let closedOutline: Path = .rounded([
		.init(.init(x: left, y: tabTop), radius: 2.5),
		.init(.init(x: tabEnd, y: tabTop), radius: 1.5),
		.init(.init(x: slopeEnd, y: bodyTop), radius: 1.5),
		.init(.init(x: right, y: bodyTop), radius: 2.5),
		.init(.init(x: right, y: bottom), radius: 3),
		.init(.init(x: left, y: bottom), radius: 3),
	])

	/// The open folder's flap: its top edge sits just under the back's body.
	private static let flapTop: CGFloat = 5.75

	/// Where the back's trailing edge, above the flap, meets the flap's top edge.
	private static let backEdge: CGFloat = 14.25
	private static let flapTopLeading: Corner = .init(.init(x: 8.25, y: flapTop), radius: 2)
	private static let flapTopTrailing: Corner = .init(.init(x: right + openOverhang, y: flapTop), radius: 2)
	private static let flapBottomTrailing: Corner = .init(.init(x: right - 0.5, y: bottom), radius: 2.5)

	/// The folder's bottom-leading corner, where the back's leading edge and the flap's meet, as
	/// in the design: one point both edges run into, so the stroke turns there once, at one width.
	private static let bottomLeading: CGPoint = .init(x: 2.75, y: bottom)

	/// The back and the flap as one outline: the back's leading edge, tab and top, the flap's top
	/// and trailing edges, and the bottom they share.
	private static let openSilhouette: Path = .rounded([
		.init(.init(x: left, y: tabTop), radius: 2.5),
		.init(.init(x: tabEnd, y: tabTop), radius: 1.5),
		.init(.init(x: slopeEnd, y: bodyTop), radius: 1.5),
		.init(.init(x: backEdge, y: bodyTop), radius: 2),
		.init(.init(x: backEdge, y: flapTop), radius: 0),
		flapTopTrailing,
		flapBottomTrailing,
		.init(bottomLeading, radius: 0),
	])

	private static let openFlap: Path = .rounded([
		flapTopLeading,
		flapTopTrailing,
		flapBottomTrailing,
		.init(bottomLeading, radius: 0),
	])

	/// The flap's top and leading edges inside the silhouette: from the back's trailing edge, round
	/// the flap's top-leading corner, down to the bottom-leading corner the silhouette turns at.
	/// It ends on that point, so its round cap lies inside the silhouette's round join there.
	private static let openFlapEdges: Path = Path { path in
		path.move(to: .init(x: backEdge, y: flapTop))
		path.addArc(
			tangent1End: flapTopLeading.point,
			tangent2End: bottomLeading,
			radius: flapTopLeading.radius
		)
		path.addLine(to: bottomLeading)
	}
}

extension Path {
	/// A closed polygon through `corners`, each rounded by its own radius.
	fileprivate static func rounded(_ corners: [PolishedFolderIcon.Corner]) -> Path {
		Path { path in
			guard let first = corners.first, let last = corners.last else { return }

			// Start halfway along the closing edge, so every corner, the first too, is rounded.
			path.move(to: .init(
				x: (last.point.x + first.point.x) / 2,
				y: (last.point.y + first.point.y) / 2
			))
			for (index, corner) in corners.enumerated() {
				let next = corners[(index + 1) % corners.count]
				path.addArc(tangent1End: corner.point, tangent2End: next.point, radius: corner.radius)
			}
			path.closeSubpath()
		}
	}
}

extension PolishedFolderIcon {
	/// A polygon's corner and how round it is.
	fileprivate struct Corner {
		fileprivate let point: CGPoint
		fileprivate let radius: CGFloat

		fileprivate init(
			_ point: CGPoint,
			radius: CGFloat
		) {
			self.point = point
			self.radius = radius
		}
	}
}
