import SwiftUI

/// A split button in the chrome's style: the URL bar's flat surface and shape, with a main action and a
/// trailing ⌄ that opens a menu or list. Each part lights its own inset fill while hovered or
/// pressed, so the surface itself never moves.
///
/// Little Arx's "Open in Personal ⌘O ⌄" is one. Pass the main part's `shortcut` where its label
/// shows a key hint.
///
/// ```swift
/// ChromeSplitButton(
///     height: 30,
///     moreHelp: "Move to Space",
///     shortcut: .init("o", modifiers: .command),
///     action: open,
///     onMore: showSpaces
/// ) {
///     Text("Open in Personal")
///     ChromeKeyHint("⌘O")
/// }
/// ```
public struct ChromeSplitButton<Label: View>: View {
	public typealias Part = ChromeSplitButtonPart

	private let height: CGFloat
	private let moreHelp: String
	private let shortcut: KeyboardShortcut?
	private let action: (() -> Void)?
	private let onMore: () -> Void
	private let label: Label
	private let stateOverrides: [Part: ArxControlStateOverride]

	@SwiftUI.State
	private var isHovered: Bool = false

	/// A nil `action` draws only the ⌄ part.
	public init(
		height: CGFloat,
		moreHelp: String,
		shortcut: KeyboardShortcut? = nil,
		action: (() -> Void)?,
		onMore: @escaping () -> Void,
		@ViewBuilder label: () -> Label
	) {
		self.init(
			height: height,
			moreHelp: moreHelp,
			shortcut: shortcut,
			action: action,
			onMore: onMore,
			stateOverrides: [:],
			label: label
		)
	}

	internal init(
		height: CGFloat,
		moreHelp: String,
		shortcut: KeyboardShortcut?,
		action: (() -> Void)?,
		onMore: @escaping () -> Void,
		stateOverrides: [Part: ArxControlStateOverride],
		@ViewBuilder label: () -> Label
	) {
		self.height = height
		self.moreHelp = moreHelp
		self.shortcut = shortcut
		self.action = action
		self.onMore = onMore
		self.stateOverrides = stateOverrides
		self.label = label()
	}

	public var body: some View {
		let inset: CGFloat = ChromeSplitButtonMetrics.inset
		let shape: ArxControlShape = .init()
		HStack(spacing: 0) {
			if let action {
				Button(action: action) {
					HStack(spacing: 6) { label }
						.padding(.horizontal, ChromeSplitButtonMetrics.mainPadding)
				}
				.buttonStyle(ChromeSplitPartStyle(
					height: height - inset * 2,
					cornerRadius: ArxControlShape.cornerRadius(forSide: height) - inset
				))
				.keyboardShortcut(shortcut)
				.environment(\.arxControlStateOverride, stateOverrides[.main] ?? .init())

				Rectangle()
					.fill(BrowserTheme.text.opacity(ChromeSplitButtonMetrics.dividerOpacity))
					.frame(width: 1, height: height * 0.4)
					.padding(.horizontal, 1)
					.accessibilityHidden(true)
			}
			Button(action: onMore) {
				Image(systemName: "chevron.down")
					.font(.system(size: ChromeSplitButtonMetrics.chevronSize, weight: .semibold))
					.frame(width: ChromeSplitButtonMetrics.moreWidth)
			}
			.buttonStyle(ChromeSplitPartStyle(
				height: height - inset * 2,
				cornerRadius: ArxControlShape.cornerRadius(forSide: height) - inset
			))
			.environment(\.arxControlStateOverride, stateOverrides[.more] ?? .init())
			.help(moreHelp)
			.accessibilityLabel(moreHelp)
		}
		.font(.system(size: BrowserMetrics.URLBar.fontSize, weight: .medium))
		.foregroundStyle(BrowserTheme.text.opacity(0.85))
		.padding(inset)
		.frame(height: height)

		// The URL bar's surface, so the two read as one row of chrome.
		.modifier(SidebarControlSurface(
			fill: SidebarControlFill.tint(hovered: isHovered),
			shape: shape
		))
		.onHover { isHovered = $0 }
		.fixedSize()
	}
}

/// A ``ChromeSplitButton``'s two parts, for previews and snapshots that draw one of them hovered
/// or pressed.
public enum ChromeSplitButtonPart: Hashable, Sendable {
	case main
	case more
}

/// A key a chrome control answers to, such as ⌘O, drawn as a small chip after its title.
public struct ChromeKeyHint: View {
	private let key: String

	public init(_ key: String) {
		self.key = key
	}

	public var body: some View {
		Text(verbatim: key)
			.font(.system(size: 11, weight: .medium))
			.foregroundStyle(BrowserTheme.secondary)
			.padding(.horizontal, 5)
			.frame(minHeight: 18)
			.background(.primary.opacity(0.07), in: ArxControlShape())
			.accessibilityHidden(true)
	}
}

internal enum ChromeSplitButtonMetrics {
	/// Between the surface's edge and a part's fill.
	internal static let inset: CGFloat = 2
	internal static let mainPadding: CGFloat = 8
	internal static let moreWidth: CGFloat = 22
	internal static let chevronSize: CGFloat = 10
	internal static let dividerOpacity: Double = 0.14
}

private struct ChromeSplitPartStyle: ButtonStyle {
	internal let height: CGFloat
	internal let cornerRadius: CGFloat

	internal func makeBody(configuration: Configuration) -> some View {
		ChromeSplitPartBody(
			label: configuration.label,
			isPressed: configuration.isPressed,
			height: height,
			cornerRadius: cornerRadius
		)
	}
}

private struct ChromeSplitPartBody<Label: View>: View {
	internal let label: Label
	internal let isPressed: Bool
	internal let height: CGFloat
	internal let cornerRadius: CGFloat

	@Environment(\.isEnabled)
	private var isEnabled: Bool

	@Environment(\.arxControlStateOverride)
	private var stateOverride: ArxControlStateOverride

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		let hovered: Bool = isEnabled && (stateOverride.isHovered ?? isHovered)
		let pressed: Bool = isEnabled && (stateOverride.isPressed ?? isPressed)
		let shape: RoundedRectangle = .init(cornerRadius: max(cornerRadius, 2), style: .continuous)
		label
			.lineLimit(1)
			.frame(minHeight: height)
			.background {
				if hovered || pressed {
					shape.fill(ArxControlPalette.subtleFill(hovered: hovered, pressed: pressed))
				}
			}
			.contentShape(shape)
			.opacity(isEnabled ? (pressed ? BrowserMetrics.State.pressedOpacity : 1) : BrowserMetrics.State.disabledOpacity)
			.onHover { isHovered = $0 }
			.animation(.easeOut(duration: 0.12), value: hovered)
			.animation(.easeOut(duration: 0.08), value: pressed)
	}
}
