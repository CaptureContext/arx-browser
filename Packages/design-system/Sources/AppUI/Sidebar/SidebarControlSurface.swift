import SwiftUI

/// The background of a sidebar control such as the URL bar or a favorite tile: a flat fill
/// with a hairline, like Arx's other controls, with no glass, rim or inner highlight (DEV-788).
internal struct SidebarControlSurface<SurfaceShape: InsettableShape>: ViewModifier {
	internal let fill: AnyShapeStyle
	internal let shape: SurfaceShape

	@Environment(\.colorSchemeContrast)
	private var contrast

	internal init(
		fill: some ShapeStyle,
		shape: SurfaceShape
	) {
		self.fill = AnyShapeStyle(fill)
		self.shape = shape
	}

	internal func body(content: Content) -> some View {
		content
			.background { shape.fill(fill) }
			.overlay {
				shape
					.strokeBorder(
						BrowserTheme.text.opacity(
							contrast == .increased
							? BrowserMetrics.ControlSurface.increasedContrastHairlineOpacity
							: BrowserMetrics.ControlSurface.hairlineOpacity
						),
						lineWidth: BrowserMetrics.ControlSurface.hairlineWidth
					)
					.allowsHitTesting(false)
			}
	}
}

/// A sidebar control's fill: the chrome's text color, a little stronger hovered and pressed.
internal enum SidebarControlFill {
	internal static func tint(
		hovered: Bool,
		pressed: Bool = false
	) -> Color {
		let opacity = pressed
		? BrowserMetrics.ControlSurface.pressedFillOpacity
		: hovered
		? BrowserMetrics.ControlSurface.hoveredFillOpacity
		: BrowserMetrics.ControlSurface.restingFillOpacity
		return BrowserTheme.text.opacity(opacity)
	}
}

extension EnvironmentValues {
	/// Draws favorite tiles, the URL bar and toasts without live effects, for demos and offscreen
	/// renders, which can't draw them.
	@Entry
	public var sidebarIsStatic: Bool = false
}
