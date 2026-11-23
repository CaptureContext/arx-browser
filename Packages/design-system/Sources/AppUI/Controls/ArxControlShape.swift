import SwiftUI

/// The shape of every Arx control: a rounded rectangle with continuous corners whose radius is
/// `cornerRatio` × the smaller side, so a control keeps its proportions at any size.
///
/// ```swift
/// content.background(.tint, in: ArxControlShape())
/// ```
///
/// Every rounded shape in Arx uses continuous corners. Buttons, text fields, chips, key caps,
/// icon tiles, segmented controls, sidebar rows and Favorites take this shape, or
/// `cornerRadius(forSide:)` where a radius has to be a number (uneven corners, glass, metrics).
///
/// Deliberate exceptions keep their own radius, because they're containers rather than controls
/// or have a shape of their own:
/// - the window and the page card, split drop zones and Peek;
/// - large panels and cards: floating panels, the floating sidebar, the command bar and the Little
///   Arx window, Settings groups, Library tiles, the identity card, sheets, dialogs and toasts,
///   theme and chat-style previews, onboarding and tour illustrations;
/// - the chat panel, with its composer, bubbles and message cards;
/// - rows inside a rounded panel, which stay concentric with it: command bar results, menus,
///   suggestion lists and hover previews;
/// - content blocks rather than controls: code and command blocks, list cells, search highlights;
/// - app icon marks, which follow the macOS icon shape;
/// - the sidebar's URL bar, which rounds like the Favorites under it (DEV-1252).
public struct ArxControlShape: InsettableShape {
	/// The app's corner rule for controls: 0.28 × the smaller side.
	public static let cornerRatio: CGFloat = 0.28

	private var inset: CGFloat

	public init() {
		self.inset = 0
	}

	/// The corner radius the rule gives a control of `size`.
	public static func cornerRadius(for size: CGSize) -> CGFloat {
		cornerRadius(forSide: min(size.width, size.height))
	}

	/// The corner radius the rule gives a control whose smaller side is `side`, usually its height.
	public static func cornerRadius(forSide side: CGFloat) -> CGFloat {
		max(side, 0) * cornerRatio
	}

	public func path(in rect: CGRect) -> Path {
		let insetRect = rect.insetBy(dx: inset, dy: inset)
		return RoundedRectangle(
			cornerRadius: Self.cornerRadius(for: insetRect.size),
			style: .continuous
		)
		.path(in: insetRect)
	}

	public func inset(by amount: CGFloat) -> Self {
		var shape = self
		shape.inset += amount
		return shape
	}
}

/// The three sizes Arx's controls come in. They follow SwiftUI's `controlSize` unless a style is
/// given one: mini and small are `.small`, extra large is `.large`.
public enum ArxControlSize: Hashable, Sendable, CaseIterable {
	case small
	case regular
	case large

	public init(_ controlSize: ControlSize) {
		switch controlSize {
		case .mini, .small: self = .small
		case .large, .extraLarge: self = .large
		default: self = .regular
		}
	}

	/// The control's height. Its corner radius follows from it.
	public var height: CGFloat {
		switch self {
		case .small: 22
		case .regular: 28
		case .large: 34
		}
	}

	public var fontSize: CGFloat {
		switch self {
		case .small: 11
		case .regular: 13
		case .large: 14
		}
	}

	/// Between the content and the control's leading and trailing edges.
	public var horizontalPadding: CGFloat {
		switch self {
		case .small: 8
		case .regular: 12
		case .large: 16
		}
	}

	/// A key hint chip's height inside a button of this size.
	internal var keyHintHeight: CGFloat {
		switch self {
		case .small: 14
		case .regular: 18
		case .large: 20
		}
	}

	internal var keyHintFontSize: CGFloat {
		switch self {
		case .small: 8
		case .regular: 10
		case .large: 10
		}
	}

	internal var symbolSize: CGFloat {
		fontSize - 1
	}
}

/// Colors Arx's controls share, in light and dark.
internal enum ArxControlPalette {
	/// A secondary button's or a field's fill at rest, hovered and pressed.
	internal static func subtleFill(
		hovered: Bool,
		pressed: Bool
	) -> Color {
		.primary.opacity(pressed ? 0.15 : hovered ? 0.1 : 0.065)
	}

	/// The ring a focused control draws: the accent, as macOS draws keyboard focus.
	internal static var focusRing: ArxFocusRing { .init() }
	internal static let focusRingWidth: CGFloat = 2.5

	/// How much a disabled control fades.
	internal static let disabledOpacity: Double = 0.45
}

/// What a control shows besides its configuration: for snapshots and previews, which can't
/// hover or focus a control by hand. Live controls track these themselves.
internal struct ArxControlStateOverride: Equatable, Sendable {
	internal var isHovered: Bool?
	internal var isPressed: Bool?
	internal var isFocused: Bool?

	internal init(
		isHovered: Bool? = nil,
		isPressed: Bool? = nil,
		isFocused: Bool? = nil
	) {
		self.isHovered = isHovered
		self.isPressed = isPressed
		self.isFocused = isFocused
	}
}

extension EnvironmentValues {
	@Entry
	internal var arxControlStateOverride: ArxControlStateOverride = .init()
}

extension View {
	/// Draws Arx controls inside as hovered, pressed or focused. For snapshots and previews only.
	internal func arxControlState(_ state: ArxControlStateOverride) -> some View {
		environment(\.arxControlStateOverride, state)
	}
}

/// A focused control's ring: the appearance's accent where the accent follows the cascade
/// (DEV-1117), macOS's accent otherwise.
internal struct ArxFocusRing: ShapeStyle {
	internal func resolve(in environment: EnvironmentValues) -> Color.Resolved {
		var color: Color.Resolved = environment.browserAccentIsEnabled
		? BrowserAccent().resolve(in: environment)
		: Color.accentColor.resolve(in: environment)
		color.opacity *= 0.75
		return color
	}
}
