import SwiftUI

/// Arx's button: a filled rounded rectangle with continuous corners and no stroke, like the
/// buttons in dialogs.
///
/// The primary button is filled with the accent, or red when its role is destructive; the others
/// with a subtle tint of the text color, or nothing at rest for a plain one. Hovering lightens a
/// button and pressing darkens it. A disabled button fades, except a primary one, which drops its
/// accent for the subtle fill and secondary text, so it reads as disabled without washing out. A
/// focused button draws the accent ring. The size follows `controlSize` unless the style is given
/// one.
///
/// ```swift
/// Button("Add") { add() }
///     .buttonStyle(.arx)
///
/// Button { quit() } label: {
///     ArxButtonLabel("Quit", keyHint: .return)
/// }
/// .buttonStyle(.arx(.primary, size: .large))
/// .keyboardShortcut(.defaultAction)
/// ```
public struct ArxButtonStyle: ButtonStyle {
	public enum Prominence: Hashable, Sendable {
		/// The accent fill, for the action a dialog or row is about.
		case primary

		/// A subtle tinted fill, for every other action.
		case secondary

		/// A subtle fill with red text, for an action that removes something.
		case destructive

		/// No fill at rest, the subtle one while hovered or pressed, and secondary text: for icon
		/// buttons inside a row, such as Remove.
		case plain
	}

	private let prominence: Prominence
	private let size: ArxControlSize?

	/// `size` nil follows the environment's `controlSize`.
	public init(
		_ prominence: Prominence = .secondary,
		size: ArxControlSize? = nil
	) {
		self.prominence = prominence
		self.size = size
	}

	public func makeBody(configuration: Configuration) -> some View {
		ArxButtonBody(
			label: configuration.label,
			role: configuration.role,
			isPressed: configuration.isPressed,
			prominence: prominence,
			size: size
		)
	}
}

extension ButtonStyle where Self == ArxButtonStyle {
	/// A secondary Arx button that follows `controlSize`.
	public static var arx: Self {
		.init()
	}

	public static func arx(
		_ prominence: ArxButtonStyle.Prominence = .secondary,
		size: ArxControlSize? = nil
	) -> Self {
		.init(prominence, size: size)
	}

	/// A modal sheet's button: an Arx button in the modal's larger frame. See ``ArxModalButton``.
	public static func arxModal(_ prominence: ArxButtonStyle.Prominence = .secondary) -> Self {
		.init(prominence, size: ArxModalMetrics.buttonSize)
	}
}

private struct ArxButtonBody<Label: View>: View {
	internal let label: Label
	internal let role: ButtonRole?
	internal let isPressed: Bool
	internal let prominence: ArxButtonStyle.Prominence
	internal let size: ArxControlSize?

	@Environment(\.isEnabled)
	private var isEnabled: Bool

	@Environment(\.isFocused)
	private var isFocused: Bool

	@Environment(\.controlSize)
	private var controlSize: ControlSize

	@Environment(\.arxControlStateOverride)
	private var stateOverride: ArxControlStateOverride

	@SwiftUI.State
	private var isHovered: Bool = false

	@SwiftUI.State
	private var showsFocusRing: Bool = false

	internal var body: some View {
		let size = self.size ?? ArxControlSize(controlSize)
		let hovered = isEnabled && (stateOverride.isHovered ?? isHovered)
		let pressed = isEnabled && (stateOverride.isPressed ?? isPressed)

		// Only focus moved by the keyboard shows the ring, not a sheet's first button (DEV-797).
		let focused = isEnabled && (stateOverride.isFocused ?? (isFocused && showsFocusRing))
		let prominence = role == .destructive && self.prominence == .secondary ? .destructive : self.prominence

		// A disabled primary button is drawn as a secondary one with secondary text, key hint
		// included, rather than as a faded accent.
		let isDisabledPrimary = prominence == .primary && !isEnabled
		label
			.font(.system(size: size.fontSize, weight: .medium))
			.lineLimit(1)
			.foregroundStyle(isDisabledPrimary ? AnyShapeStyle(.secondary) : foreground(prominence))
			.padding(.horizontal, size.horizontalPadding)
			.frame(minWidth: size.height, minHeight: size.height)
			.background(
				isDisabledPrimary
				? AnyShapeStyle(ArxControlPalette.subtleFill(hovered: false, pressed: false))
				: fill(prominence, hovered: hovered, pressed: pressed),
				in: ArxControlShape()
			)
			.overlay {
				if focused {
					ArxControlShape()
						.inset(by: -ArxControlPalette.focusRingWidth / 2 - 1)
						.stroke(ArxControlPalette.focusRing, lineWidth: ArxControlPalette.focusRingWidth)
				}
			}
			.contentShape(.focusEffect, ArxControlShape())
			.contentShape(ArxControlShape())
			.opacity(isEnabled || isDisabledPrimary ? 1 : ArxControlPalette.disabledOpacity)
			.environment(\.arxButtonContext, .init(prominence: isDisabledPrimary ? .secondary : prominence, size: size))
			.onHover { isHovered = $0 }
			.arxKeyboardFocusRing(isFocused: isFocused, showsRing: $showsFocusRing)
			.animation(.easeOut(duration: 0.12), value: hovered)
			.animation(.easeOut(duration: 0.08), value: pressed)
	}

	private func foreground(_ prominence: ArxButtonStyle.Prominence) -> AnyShapeStyle {
		switch prominence {
		case .primary: AnyShapeStyle(.white)
		case .secondary: AnyShapeStyle(.primary)
		case .destructive: AnyShapeStyle(.red)
		case .plain: AnyShapeStyle(.secondary)
		}
	}

	private func fill(
		_ prominence: ArxButtonStyle.Prominence,
		hovered: Bool,
		pressed: Bool
	) -> AnyShapeStyle {
		switch prominence {
		case .primary:
			let tint: Color = role == .destructive ? .red : .accentColor
			if pressed { return AnyShapeStyle(tint.mix(with: .black, by: 0.18)) }
			if hovered { return AnyShapeStyle(tint.mix(with: .white, by: 0.1)) }
			return AnyShapeStyle(tint)

		case .secondary, .destructive:
			return AnyShapeStyle(ArxControlPalette.subtleFill(hovered: hovered, pressed: pressed))

		case .plain:
			guard hovered || pressed else { return AnyShapeStyle(.clear) }
			return AnyShapeStyle(ArxControlPalette.subtleFill(hovered: hovered, pressed: pressed))
		}
	}
}

/// The prominence and size of the Arx button a view sits in, so a key hint can match it.
internal struct ArxButtonContext: Hashable, Sendable {
	internal var prominence: ArxButtonStyle.Prominence
	internal var size: ArxControlSize
}

extension EnvironmentValues {
	@Entry
	internal var arxButtonContext: ArxButtonContext = .init(prominence: .secondary, size: .regular)
}

/// A key a button answers to, drawn as a small chip inside it.
///
/// It only shows the key: give the button the matching `keyboardShortcut` as well. VoiceOver
/// skips it, since the shortcut is announced from the button's own shortcut.
public struct ArxKeyHint: View {
	private let key: Text

	public init(_ key: String) {
		self.key = Text(verbatim: key)
	}

	public init(_ key: Text) {
		self.key = key
	}

	/// Return, for a button with `.keyboardShortcut(.defaultAction)`.
	public static let `return`: ArxKeyHint = .init("↩")

	/// Escape, for a button with `.keyboardShortcut(.cancelAction)`.
	public static let escape: ArxKeyHint = .init("esc")

	@Environment(\.arxButtonContext)
	private var context: ArxButtonContext

	public var body: some View {
		let shape = ArxControlShape()
		key
			.font(.system(size: context.size.keyHintFontSize, weight: .semibold))
			.textCase(.uppercase)
			.padding(.horizontal, 5)
			.frame(minWidth: context.size.keyHintHeight + 4, minHeight: context.size.keyHintHeight)
			.foregroundStyle(
				context.prominence == .primary
				? AnyShapeStyle(.white.opacity(0.9))
				: AnyShapeStyle(.secondary)
			)
			.background(
				context.prominence == .primary
				? AnyShapeStyle(.white.opacity(0.2))
				: AnyShapeStyle(.primary.opacity(0.08)),
				in: shape
			)
			.accessibilityHidden(true)
	}
}

/// A button's title with an optional leading symbol and a trailing key hint.
///
/// ```swift
/// Button { cancel() } label: {
///     ArxButtonLabel("Cancel", keyHint: .escape)
/// }
/// .buttonStyle(.arx)
/// .keyboardShortcut(.cancelAction)
/// ```
public struct ArxButtonLabel: View {
	private let title: Text
	private let systemImage: String?
	private let keyHint: ArxKeyHint?

	public init(
		_ title: String,
		systemImage: String? = nil,
		keyHint: ArxKeyHint? = nil
	) {
		self.title = Text(title)
		self.systemImage = systemImage
		self.keyHint = keyHint
	}

	public init(
		_ title: Text,
		systemImage: String? = nil,
		keyHint: ArxKeyHint? = nil
	) {
		self.title = title
		self.systemImage = systemImage
		self.keyHint = keyHint
	}

	@Environment(\.arxButtonContext)
	private var context: ArxButtonContext

	public var body: some View {
		HStack(spacing: context.size == .small ? 5 : 8) {
			if let systemImage {
				Image(systemName: systemImage)
					.font(.system(size: context.size.symbolSize, weight: .semibold))
					.accessibilityHidden(true)
			}
			title
			if let keyHint {
				keyHint
			}
		}
	}
}

extension View {
	/// Lights an Arx-styled `Menu` while the pointer is over it. A menu drawn with `.menuStyle(.button)`
	/// tracks the mouse itself, so the button style inside never sees the hover; this tracks it
	/// outside and hands it in.
	public func arxMenuHover() -> some View {
		modifier(ArxMenuHover())
	}
}

private struct ArxMenuHover: ViewModifier {
	@SwiftUI.State
	private var isHovered: Bool = false

	@Environment(\.arxControlStateOverride)
	private var stateOverride: ArxControlStateOverride

	internal func body(content: Content) -> some View {
		var state = stateOverride
		state.isHovered = stateOverride.isHovered ?? isHovered
		return content
			.environment(\.arxControlStateOverride, state)
			.onHover { isHovered = $0 }
	}
}
