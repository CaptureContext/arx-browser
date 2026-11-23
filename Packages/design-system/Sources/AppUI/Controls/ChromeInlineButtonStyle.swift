import BrowserCore
import SwiftUI

/// A button that sits inside another control or a row, such as the URL bar's Copy Link and Site
/// Settings, or a tab row's close button: no fill at rest, and hovered or pressed a shape about
/// its icon's size in black at low opacity, so it's a darker shade of the field or row under it
/// rather than a fixed pale fill: it reads over the URL bar's fill, a light selected row's
/// near-white and the dark chrome's lifted fills alike, in light and dark.
///
/// Behind ``ChromeInlineButtons/featureFlag``; with it off, it draws as `ChromeButtonStyle`.
public struct ChromeInlineButtonStyle: ButtonStyle {
	private let shapeInset: CGFloat

	/// - Parameters:
	///   - shapeInset: How far the shape sits inside the label's frame; 0 fills it.
	public init(shapeInset: CGFloat = BrowserMetrics.InlineButton.shapeInset) {
		self.shapeInset = shapeInset
	}

	public func makeBody(configuration: Configuration) -> some View {
		ChromeInlineButtonBody(label: configuration.label, isPressed: configuration.isPressed, shapeInset: shapeInset)
	}
}

/// The feature flag for ``ChromeInlineButtonStyle`` and the URL bar's buttons around it.
public enum ChromeInlineButtons {
	public static let featureFlag: String = FeatureFlag.inlineButtons.name

	/// Whether the inline style draws. Read once, through the `FeatureFlag` registry: the
	/// environment, then Arx's defaults under the flag's name; on unless it says `0`, `false`,
	/// `no` or `off`. Tests set it.
	@MainActor
	public static var isEnabled: Bool = FeatureFlag.inlineButtons.isOn()

	/// What one value turns it to.
	public static func isOn(read: (String) -> String?) -> Bool {
		read(featureFlag).flatMap(FeatureFlag.parse) ?? FeatureFlag.inlineButtons.isOnByDefault
	}

	/// The shape's black: none at rest; hovered, more in dark, where the chrome's fills are
	/// lifted; more again pressed and under Increase Contrast.
	internal static func fillOpacity(
		hovered: Bool,
		pressed: Bool,
		colorScheme: ColorScheme,
		contrast: ColorSchemeContrast
	) -> Double {
		guard hovered || pressed else { return 0 }

		let base: Double = colorScheme == .dark
		? BrowserMetrics.InlineButton.darkFillOpacity
		: BrowserMetrics.InlineButton.lightFillOpacity
		let pressedShare: Double = pressed ? BrowserMetrics.InlineButton.pressedIncrease : 0
		let contrastShare: Double = contrast == .increased ? BrowserMetrics.InlineButton.increasedContrastIncrease : 0
		return base * (1 + pressedShare + contrastShare)
	}
}

private struct ChromeInlineButtonBody<Label: View>: View {
	internal let label: Label
	internal let isPressed: Bool
	internal let shapeInset: CGFloat

	@Environment(\.isEnabled)
	private var isEnabled

	@Environment(\.colorScheme)
	private var colorScheme

	@Environment(\.colorSchemeContrast)
	private var contrast

	@Environment(\.arxControlStateOverride)
	private var stateOverride

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		let hovered = isEnabled && (stateOverride.isHovered ?? isHovered)
		let pressed = isEnabled && (stateOverride.isPressed ?? isPressed)
		if ChromeInlineButtons.isEnabled {
			label
				.background {
					ArxControlShape()
						.fill(Color.black.opacity(ChromeInlineButtons.fillOpacity(
							hovered: hovered,
							pressed: pressed,
							colorScheme: colorScheme,
							contrast: contrast
						)))
						.padding(shapeInset)
				}
				.contentShape(.rect)
				.onHover { isHovered = $0 }
				.animation(.easeOut(duration: 0.12), value: hovered)
				.animation(.easeOut(duration: 0.08), value: pressed)
		} else {
			// ChromeButtonStyle's look.
			label
				.background(hovered || pressed ? BrowserTheme.hover : .clear, in: ArxControlShape())
				.opacity(pressed ? BrowserMetrics.State.pressedOpacity : 1)
				.onHover { isHovered = $0 }
		}
	}
}
