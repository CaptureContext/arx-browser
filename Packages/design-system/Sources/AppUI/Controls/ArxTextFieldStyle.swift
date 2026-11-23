import SwiftUI

/// Arx's inline text field: plain text on a filled rounded background, with no border, like the
/// Settings sidebar's search. For a field inside a row, such as a rule's URL.
///
/// It draws the accent ring while focused, fades while disabled and takes an optional leading
/// symbol. The size follows `controlSize` unless the style is given one. A field that takes a
/// whole row, with its title as a caption, is `SettingsTextField` instead.
///
/// ```swift
/// TextField("Address", text: $address, prompt: Text("example.com"))
///     .textFieldStyle(.arx)
/// ```
public struct ArxTextFieldStyle: TextFieldStyle {
	private let size: ArxControlSize?
	private let systemImage: String?

	/// `size` nil follows the environment's `controlSize`.
	public init(
		size: ArxControlSize? = nil,
		systemImage: String? = nil
	) {
		self.size = size
		self.systemImage = systemImage
	}

	// swiftlint:disable:next identifier_name
	public func _body(configuration: TextField<Self._Label>) -> some View {
		// A modifier, not a view holding the field: `_body` isn't isolated to the main actor.
		configuration.modifier(ArxTextFieldChrome(size: size, systemImage: systemImage))
	}
}

extension TextFieldStyle where Self == ArxTextFieldStyle {
	/// An inline Arx field that follows `controlSize`.
	public static var arx: Self {
		.init()
	}

	public static func arx(
		size: ArxControlSize? = nil,
		systemImage: String? = nil
	) -> Self {
		.init(size: size, systemImage: systemImage)
	}
}

private struct ArxTextFieldChrome: ViewModifier {
	internal nonisolated let size: ArxControlSize?
	internal nonisolated let systemImage: String?

	internal nonisolated init(
		size: ArxControlSize?,
		systemImage: String?
	) {
		self.size = size
		self.systemImage = systemImage
	}

	@Environment(\.isEnabled)
	private var isEnabled: Bool

	@Environment(\.controlSize)
	private var controlSize: ControlSize

	@Environment(\.arxControlStateOverride)
	private var stateOverride: ArxControlStateOverride

	@FocusState
	private var isFocused: Bool

	@SwiftUI.State
	private var isHovered: Bool = false

	internal func body(content field: Content) -> some View {
		let size = self.size ?? ArxControlSize(controlSize)
		let focused = isEnabled && (stateOverride.isFocused ?? isFocused)
		let hovered = isEnabled && !focused && (stateOverride.isHovered ?? isHovered)
		HStack(spacing: size == .small ? 5 : 7) {
			if let systemImage {
				Image(systemName: systemImage)
					.font(.system(size: size.symbolSize, weight: .medium))
					.foregroundStyle(.secondary)
					.accessibilityHidden(true)
			}
			field
				.textFieldStyle(.plain)
				.font(.system(size: size.fontSize))
				.focused($isFocused)
		}
		.padding(.horizontal, size.horizontalPadding - 3)
		.frame(minHeight: size.height)
		.background(ArxControlPalette.subtleFill(hovered: hovered, pressed: false), in: ArxControlShape())
		.overlay {
			if focused {
				ArxControlShape()
					.inset(by: -ArxControlPalette.focusRingWidth / 2 - 1)
					.stroke(ArxControlPalette.focusRing, lineWidth: ArxControlPalette.focusRingWidth)
					.allowsHitTesting(false)
			}
		}
		.contentShape(ArxControlShape())

		// A click anywhere on the background, not just on the text, starts editing.
		.onTapGesture { isFocused = true }
		.opacity(isEnabled ? 1 : ArxControlPalette.disabledOpacity)
		.onHover { isHovered = $0 }
		.animation(.easeOut(duration: 0.12), value: focused)
	}
}
