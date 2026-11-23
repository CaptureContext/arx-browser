import SwiftUI

/// A selectable row in a list Arx draws itself, such as the Extensions sheet's (DEV-1002): the
/// row spans the list's width and takes a click anywhere in it, not only on its text. It's filled
/// while selected, and more lightly on hover and while pressed.
///
/// The label lays out the row's content and padding; the style adds the width, the fill and the
/// hit area.
///
/// ```swift
/// Button { select(item) } label: {
///     Text(item.name).padding(10)
/// }
/// .buttonStyle(.arxListRow(isSelected: item.id == selectedID))
/// ```
public struct ArxListRowButtonStyle: ButtonStyle {
	private let isSelected: Bool

	public init(isSelected: Bool) {
		self.isSelected = isSelected
	}

	public func makeBody(configuration: Configuration) -> some View {
		ArxListRowButtonBody(
			label: configuration.label,
			isSelected: isSelected,
			isPressed: configuration.isPressed
		)
	}
}

extension ButtonStyle where Self == ArxListRowButtonStyle {
	/// A selectable list row that takes a click anywhere in it (DEV-1002).
	public static func arxListRow(isSelected: Bool) -> Self {
		.init(isSelected: isSelected)
	}
}

extension View {
	/// Makes the whole row the hit area (DEV-1002): it spans the available width and takes clicks
	/// in its empty space too, not only on its text. For rows that aren't buttons, such as a
	/// `List` row with a double-click.
	public func rowHitArea() -> some View {
		frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(.rect)
	}
}

internal enum ArxListRowMetrics {
	internal static let cornerRadius: CGFloat = 8

	internal static func fillOpacity(
		isSelected: Bool,
		isHovered: Bool,
		isPressed: Bool
	) -> Double {
		if isSelected { return isPressed ? 0.18 : 0.12 }
		if isPressed { return 0.08 }
		return isHovered ? 0.05 : 0
	}
}

private struct ArxListRowButtonBody<Label: View>: View {
	internal let label: Label
	internal let isSelected: Bool
	internal let isPressed: Bool

	@Environment(\.isEnabled)
	private var isEnabled: Bool

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		let shape: RoundedRectangle = .init(cornerRadius: ArxListRowMetrics.cornerRadius, style: .continuous)
		let opacity: Double = ArxListRowMetrics.fillOpacity(
			isSelected: isSelected,
			isHovered: isEnabled && isHovered,
			isPressed: isEnabled && isPressed
		)
		label
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(.tint.opacity(opacity), in: shape)
			.contentShape(shape)
			.onHover { isHovered = $0 }
			.animation(.easeOut(duration: 0.12), value: opacity)
	}
}
