import SwiftUI

/// The favicons of the tour's sample sites, drawn in code (DEV-791).
///
/// The demo's sites are made up (`mail.example.com`, `docs.example.com`, …), so each gets a
/// brand-free mark on a colored tile, in the style of a real favicon, rather than a third-party
/// logo or an illustrative SF Symbol. They draw synchronously, so `ImageRenderer` captures them
/// in snapshots and the website's tour videos.
///
/// A sample item names its glyph through its `symbol` (``symbol``), which the sidebar's and the
/// command bar's site icons draw in place of an SF Symbol.
internal enum TourSiteGlyph: String, CaseIterable, Sendable {
	case mail
	case calendar
	case notes
	case tracker
	case docs
	case code

	private static let prefix: String = "arx.sample."

	/// The `symbol` a sample item carries to show this glyph.
	internal var symbol: String {
		Self.prefix + rawValue
	}

	internal init?(symbol: String) {
		guard symbol.hasPrefix(Self.prefix) else { return nil }

		self.init(rawValue: String(symbol.dropFirst(Self.prefix.count)))
	}
}

/// A sample site's favicon at `size` points.
internal struct TourSiteGlyphView: View {
	internal let glyph: TourSiteGlyph
	internal let size: CGFloat

	internal var body: some View {
		Canvas { context, canvasSize in
			draw(in: context, side: min(canvasSize.width, canvasSize.height))
		}
		.frame(width: size, height: size)
		.accessibilityHidden(true)
	}

	/// A copy of a context draws into the same canvas, so the clip for the calendar's band stays local.
	private func draw(
		in context: GraphicsContext,
		side: CGFloat
	) {
		let tile: Path = .init(
			roundedRect: .init(x: 0, y: 0, width: side, height: side),
			cornerRadius: side * 0.24,
			style: .continuous
		)
		let lineWidth: CGFloat = max(side * 0.085, 1)
		let mark: GraphicsContext.Shading = .color(.white)

		func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
			.init(x: x * side, y: y * side)
		}

		func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
			.init(x: x * side, y: y * side, width: width * side, height: height * side)
		}

		func stroke(
			_ points: [CGPoint],
			shading: GraphicsContext.Shading
		) {
			var path: Path = .init()
			path.addLines(points)
			context.stroke(path, with: shading, style: .init(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
		}

		switch glyph {
		case .mail:
			context.fill(tile, with: .color(Color(red: 0.92, green: 0.29, blue: 0.24)))
			let envelope: CGRect = rect(0.2, 0.29, 0.6, 0.42)
			context.stroke(
				Path(roundedRect: envelope, cornerRadius: side * 0.06, style: .continuous),
				with: mark,
				style: .init(lineWidth: lineWidth, lineJoin: .round)
			)
			stroke([point(0.23, 0.33), point(0.5, 0.53), point(0.77, 0.33)], shading: mark)

		case .calendar:
			context.fill(tile, with: .color(.white))
			var band: GraphicsContext = context
			band.clip(to: tile)
			band.fill(Path(rect(0, 0, 1, 0.3)), with: .color(Color(red: 0.95, green: 0.27, blue: 0.23)))
			context.stroke(tile, with: .color(.black.opacity(0.12)), lineWidth: max(side * 0.03, 0.5))
			let day: Text = Text(verbatim: "12")
				.font(.system(size: side * 0.46, weight: .bold, design: .rounded))
				.foregroundStyle(Color(white: 0.15))
			context.draw(day, at: point(0.5, 0.64), anchor: .center)

		case .notes:
			context.fill(tile, with: .color(Color(red: 1, green: 0.8, blue: 0.22)))
			let ink: GraphicsContext.Shading = .color(Color(red: 0.42, green: 0.3, blue: 0.04).opacity(0.75))
			stroke([point(0.25, 0.36), point(0.75, 0.36)], shading: ink)
			stroke([point(0.25, 0.52), point(0.75, 0.52)], shading: ink)
			stroke([point(0.25, 0.68), point(0.58, 0.68)], shading: ink)

		case .tracker:
			context.fill(tile, with: .color(Color(red: 0.43, green: 0.36, blue: 0.93)))
			for (x, height) in [(0.22, 0.5), (0.43, 0.34), (0.64, 0.42)] {
				context.fill(
					Path(roundedRect: rect(x, 0.25, 0.14, height), cornerRadius: side * 0.05, style: .continuous),
					with: mark
				)
			}

		case .docs:
			context.fill(tile, with: .color(Color(red: 0.16, green: 0.47, blue: 0.96)))
			var page: Path = .init()
			page.addLines([
				point(0.3, 0.2),
				point(0.58, 0.2),
				point(0.72, 0.34),
				point(0.72, 0.8),
				point(0.3, 0.8),
			])
			page.closeSubpath()
			context.fill(page, with: mark)
			let lines: GraphicsContext.Shading = .color(Color(red: 0.16, green: 0.47, blue: 0.96).opacity(0.85))
			for y in [0.46, 0.58, 0.7] {
				context.fill(Path(rect(0.38, y - 0.025, y == 0.7 ? 0.2 : 0.26, 0.05)), with: lines)
			}

		case .code:
			context.fill(tile, with: .color(Color(white: 0.14)))
			context.stroke(tile, with: .color(.white.opacity(0.14)), lineWidth: max(side * 0.03, 0.5))
			stroke([point(0.36, 0.33), point(0.2, 0.5), point(0.36, 0.67)], shading: mark)
			stroke([point(0.64, 0.33), point(0.8, 0.5), point(0.64, 0.67)], shading: mark)
			stroke([point(0.56, 0.28), point(0.44, 0.72)], shading: .color(.white.opacity(0.7)))
		}
	}
}
