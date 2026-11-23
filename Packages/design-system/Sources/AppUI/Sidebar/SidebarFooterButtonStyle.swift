import SwiftUI

/// A footer icon button's quiet tile: no fill at rest, the sidebar controls' tint while hovered
/// or while what it opens is showing, and a little more pressed (DEV-788). The footer's spaces
/// and its + use it.
internal struct SidebarFooterButtonStyle: ButtonStyle {
	/// Drawn as hovered, such as while the button's panel is open.
	internal var isActive: Bool

	/// Replaces the tile, such as a space's accent while a tab is dragged over it.
	internal var highlight: AnyShapeStyle?

	internal init(
		isActive: Bool = false,
		highlight: AnyShapeStyle? = nil
	) {
		self.isActive = isActive
		self.highlight = highlight
	}

	internal func makeBody(configuration: Configuration) -> some View {
		SidebarFooterButtonBody(
			label: configuration.label,
			isPressed: configuration.isPressed,
			isActive: isActive,
			highlight: highlight
		)
	}
}

private struct SidebarFooterButtonBody<Label: View>: View {
	internal let label: Label
	internal let isPressed: Bool
	internal let isActive: Bool
	internal let highlight: AnyShapeStyle?

	@Environment(\.isEnabled)
	private var isEnabled

	@Environment(\.arxControlStateOverride)
	private var stateOverride

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		let hovered = isEnabled && (stateOverride.isHovered ?? isHovered)
		let pressed = isEnabled && (stateOverride.isPressed ?? isPressed)
		label
			.background(fill(hovered: hovered || isActive, pressed: pressed), in: ArxControlShape())
			.onHover { isHovered = $0 }
			.animation(.easeOut(duration: 0.12), value: hovered)
			.animation(.easeOut(duration: 0.08), value: pressed)
	}

	private func fill(
		hovered: Bool,
		pressed: Bool
	) -> AnyShapeStyle {
		if let highlight { return highlight }
		guard hovered || pressed else { return AnyShapeStyle(Color.clear) }
		return AnyShapeStyle(SidebarControlFill.tint(hovered: hovered, pressed: pressed))
	}
}
