import AppKit
import BrowserCore
import SwiftUI

/// A progressive blur behind a bar (DEV-808): content under the bar is blurred at full strength
/// near the top and the blur eases out across the bar, ending at its lower edge, as iOS's
/// soft scroll edge. ``ArxProgressiveEdge`` lays a veil of the surface's
/// background over it that eases out the same way, so content melts into the background rather
/// than turning into a blurred slab. AppKit's own soft edge on macOS 26 is mostly a uniform blur that stops at the bar's
/// lower edge, so this is an opt-in alternative (`ARX_SCROLL_EDGE=progressive`).
///
/// It's a backdrop layer with Core Animation's `variableBlur` filter and a gradient mask, both
/// private. Where either is missing, as on a future macOS, it draws nothing.
internal struct ArxVariableBlur: NSViewRepresentable {
	/// How far the content scrolls under the bar before the edge is at full strength.
	internal static let revealDistance: CGFloat = 24

	/// The share of the height, from the top, at full strength; below it both ease out.
	internal static let plateau: CGFloat = ArxProgressiveEdge.Style.standard.plateau

	/// The strongest blur, at the top.
	internal static let radius: CGFloat = ArxProgressiveEdge.Style.standard.radius

	internal var radius: CGFloat
	internal var plateau: CGFloat

	/// The edge it's strongest at: the top under a bar, the bottom over a footer (DEV-826).
	internal var edge: VerticalEdge

	internal init(
		radius: CGFloat = Self.radius,
		plateau: CGFloat = Self.plateau,
		edge: VerticalEdge = .top
	) {
		self.radius = radius
		self.plateau = plateau
		self.edge = edge
	}

	internal func makeNSView(context: Context) -> BlurView {
		BlurView(radius: radius, plateau: plateau, edge: edge)
	}

	internal func updateNSView(
		_ view: BlurView,
		context: Context
	) {
		view.update(radius: radius, plateau: plateau)
	}

	internal final class BlurView: NSView {
		private var radius: CGFloat
		private var plateau: CGFloat
		private let edge: VerticalEdge
		private var filter: NSObject?
		private var maskHeight: CGFloat = 0

		internal init(
			radius: CGFloat,
			plateau: CGFloat,
			edge: VerticalEdge = .top
		) {
			self.radius = radius
			self.plateau = plateau
			self.edge = edge
			super.init(frame: .zero)
			wantsLayer = true
		}

		/// Takes new values live, as from ``ArxProgressiveEdgeTuner``.
		internal func update(
			radius: CGFloat,
			plateau: CGFloat
		) {
			guard radius != self.radius || plateau != self.plateau else { return }
			self.radius = radius
			self.plateau = plateau
			filter?.setValue(radius, forKey: "inputRadius")
			maskHeight = 0
			needsLayout = true
		}

		@available(*, unavailable)
		internal required init?(coder: NSCoder) {
			fatalError("init(coder:) is not supported")
		}

		internal override func makeBackingLayer() -> CALayer {
			guard
				let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
				let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
				filterClass.responds(to: NSSelectorFromString("filterWithType:")),
				let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
					.takeUnretainedValue() as? NSObject
			else { return CALayer() }

			let layer = backdropClass.init()

			// A group of its own, so it captures the content under it (see ArxScrollPocketSeparator).
			layer.setValue("ArxVariableBlur-\(UInt(bitPattern: ObjectIdentifier(self).hashValue))", forKey: "groupName")
			filter.setValue(radius, forKey: "inputRadius")
			filter.setValue(true, forKey: "inputNormalizeEdges")
			layer.filters = [filter]
			self.filter = filter
			return layer
		}


		internal override func hitTest(_ point: NSPoint) -> NSView? { nil }

		internal override func isAccessibilityElement() -> Bool { false }

		internal override func layout() {
			super.layout()
			guard let filter, bounds.height > 0, bounds.height != maskHeight else { return }
			maskHeight = bounds.height
			let ramp = bounds.height * (1 - plateau)
			filter.setValue(Self.mask(height: bounds.height, ramp: ramp, edge: edge), forKey: "inputMaskImage")
			layer?.filters = [filter]
		}

		/// Opaque (full blur) at `edge`, fading to clear (no blur) over the `ramp` points farthest
		/// from it, with an ease so the blur melts out rather than stopping at a line. Rows run
		/// from the top.
		internal static func mask(
			height: CGFloat,
			ramp: CGFloat,
			edge: VerticalEdge = .top
		) -> CGImage? {
			let rows = max(Int(height.rounded(.up)), 2)
			let rampStart = Double(rows) - Double(ramp)

			// Black, with the blur's strength in alpha, premultiplied: gray 0, alpha `eased`.
			var pixels = [UInt8](repeating: 0, count: rows * 2)
			for row in 0..<rows {
				// How far from the strong edge, counted in rows.
				let distance = edge == .top ? row : rows - 1 - row
				let t = max(0, min(1, (Double(distance) - rampStart) / Double(ramp)))

				// Smoothstep from 1 to 0 across the ramp.
				let eased = 1 - t * t * (3 - 2 * t)
				pixels[row * 2 + 1] = UInt8((eased * 255).rounded())
			}
			guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
			return CGImage(
				width: 1,
				height: rows,
				bitsPerComponent: 8,
				bitsPerPixel: 16,
				bytesPerRow: 2,
				space: CGColorSpaceCreateDeviceGray(),
				bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
				provider: provider,
				decode: nil,
				shouldInterpolate: true,
				intent: .defaultIntent
			)
		}
	}
}

/// The progressive edge behind a bar: ``ArxVariableBlur`` with a veil over it, both strongest at
/// the bar's edge and easing out together. Over a footer it runs from the bottom (DEV-826).
internal struct ArxProgressiveEdge: View {
	/// What content melts into under the blur.
	internal enum Veil {
		/// An opaque surface's background, as Settings'.
		case color(Color)

		/// A soft dark, over a translucent surface with no background of its own, as the chat
		/// panel or the Library.
		case translucent

		/// The browser chrome's own tint, as the sidebar's, so content melts into the chrome
		/// rather than into a gray (DEV-826).
		case chrome
	}

	/// How strong the blur and the veil are along the edge.
	internal struct Style: Equatable, Sendable {
		/// The strongest blur, at `edge`, in points.
		internal var radius: CGFloat

		/// The share of the height, from `edge`, at full strength, unless a ramp sets it.
		internal var plateau: CGFloat

		/// The veil's opacity at `edge`.
		internal var veilTop: CGFloat

		/// The veil's opacity where the plateau ends.
		internal var veilPlateau: CGFloat

		/// The veil's opacity three quarters of the way across.
		internal var veilLate: CGFloat

		/// The veil's darkness over a translucent surface, which has no background to veil with.
		internal var translucentVeil: CGFloat

		/// Every bar's: Settings, the Library, the chat panel and onboarding (DEV-808). The tuner
		/// adjusts it live.
		internal static let standard: Self = .init(
			radius: 2,
			plateau: 0.55,
			veilTop: 0.7,
			veilPlateau: 0.3,
			veilLate: 0.15,
			translucentVeil: 0.1
		)

		/// The sidebar's, under its header and over its footer: a denser veil, which fades rows
		/// scrolling under the window's toolbar row enough that their clipping doesn't show
		/// (Max's values, 17 Nov).
		internal static let sidebar: Self = .init(
			radius: 2,
			plateau: 0.55,
			veilTop: 0.95,
			veilPlateau: 0.6,
			veilLate: 0.6,
			translucentVeil: 0.1
		)
	}

	internal var veil: Veil
	internal var edge: VerticalEdge

	/// How many points it eases out over, at the end away from `edge`, or nil for the style's
	/// share of its height. A tall header, as the sidebar's, stays at full strength under its
	/// controls and eases out under its last row.
	internal var ramp: CGFloat?

	/// ``Style/standard`` follows ``ArxProgressiveEdgeTuner``; any other style is fixed.
	internal var style: Style

	@Environment(\.browserChromeTint)
	private var chromeTint: ChromeTint

	/// The page's color while the space matches the site (DEV-1101).
	@Environment(\.browserChromeSiteColor)
	private var siteColor: ChromePalette.RGB?

	@Environment(\.colorSchemeContrast)
	private var contrast: ColorSchemeContrast

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion: Bool

	@Environment(\.colorScheme)
	private var colorScheme: ColorScheme

	private var tuning: ArxProgressiveEdgeTuning { .shared }

	internal init(
		background: Color?,
		edge: VerticalEdge = .top,
		ramp: CGFloat? = nil,
		style: Style = .standard
	) {
		self.init(veil: background.map(Veil.color) ?? .translucent, edge: edge, ramp: ramp, style: style)
	}

	internal init(
		veil: Veil,
		edge: VerticalEdge = .top,
		ramp: CGFloat? = nil,
		style: Style = .standard
	) {
		self.veil = veil
		self.edge = edge
		self.ramp = ramp
		self.style = style
	}

	internal var body: some View {
		// Read once, so a fixed style never observes the tuner.
		let values: Style = values
		return Group {
			if let ramp {
				GeometryReader { geometry in
					edgeBody(values, plateau: Self.plateau(height: geometry.size.height, ramp: ramp))
				}
			} else {
				edgeBody(values, plateau: values.plateau)
			}
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	/// The tuner's values for the standard style, or the style's own.
	private var values: Style {
		style == .standard ? tuning.style : style
	}

	private func edgeBody(
		_ values: Style,
		plateau: CGFloat
	) -> some View {
		let color: Color = veilColor(values)
		return ZStack {
			ArxVariableBlur(radius: values.radius, plateau: plateau, edge: edge)
			LinearGradient(
				stops: [
					.init(color: color.opacity(values.veilTop), location: 0),
					.init(color: color.opacity(values.veilPlateau), location: plateau),
					.init(color: color.opacity(values.veilLate), location: max(plateau, 0.75)),
					.init(color: color.opacity(0), location: 1),
				],
				startPoint: edge == .top ? .top : .bottom,
				endPoint: edge == .top ? .bottom : .top
			)

			// Eases with the chrome behind it when the page's color changes (DEV-1101).
			.animation(reduceMotion ? nil : BrowserChromeTransition.animation, value: siteColor)
		}
	}

	/// The share of `height` at full strength when it eases out over its last `ramp` points.
	internal static func plateau(
		height: CGFloat,
		ramp: CGFloat
	) -> CGFloat {
		guard height > 0 else { return 0 }
		return min(max(1 - ramp / height, 0), 1)
	}

	/// How strong the edge is once content has scrolled `offset` points under the bar: 0 at rest,
	/// 1 once ``ArxVariableBlur/revealDistance`` has passed. Stepped by tenths, so scrolling past that doesn't
	/// update the bar on every tick.
	internal static func reveal(scrolledBy offset: CGFloat) -> CGFloat {
		let raw = min(max(offset / ArxVariableBlur.revealDistance, 0), 1)
		return (raw * 10).rounded() / 10
	}

	private func veilColor(_ values: Style) -> Color {
		switch veil {
		case let .color(color):
			color

		case .translucent:
			Color.black.opacity(values.translucentVeil)

		case .chrome:
			Self.chromeColor(palette: chromePalette, edge: edge)
		}
	}

	/// The sidebar's stops: the site's color while the chrome matches the site, the tint's otherwise.
	private var chromePalette: ChromePalette {
		guard let siteColor else {
			return ChromePalette(tint: chromeTint, surface: .sidebar, isDark: colorScheme == .dark)
		}
		return ChromePalette(
			site: siteColor,
			surface: .sidebar,
			isDark: colorScheme == .dark,
			increasedContrast: contrast == .increased
		)
	}

	/// The sidebar's gradient where the edge sits: near its top for a header, toward its middle
	/// for a footer, as the window's diagonal gradient reaches the sidebar's bottom only halfway.
	internal static func chromeColor(
		palette: ChromePalette,
		edge: VerticalEdge
	) -> Color {
		let share: Double = edge == .top ? 0.1 : 0.45
		func mix(_ top: Double, _ bottom: Double) -> Double { top + (bottom - top) * share }
		return Color(
			.sRGB,
			red: mix(palette.top.red, palette.bottom.red),
			green: mix(palette.top.green, palette.bottom.green),
			blue: mix(palette.top.blue, palette.bottom.blue)
		)
	}
}
