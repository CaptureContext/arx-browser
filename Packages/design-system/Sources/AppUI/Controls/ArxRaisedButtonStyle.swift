import AppKit
import SwiftUI

/// A raised toolbar button (DEV-797): a glassy squircle, a continuous rounded
/// rectangle whose radius is ``ArxRaisedShape/cornerRatio`` of its height, with a translucent
/// fill, a faint lighter rim along its top edge and a soft shadow, and thin icons. Hovering
/// draws a lighter squircle inset ``ArxRaisedPalette/inset`` points from the tile's edges, with
/// corners concentric with the tile's, and pressing darkens that inset squircle
/// (DEV-806): the tile itself never changes.
///
/// Related actions share one tile in ``ArxRaisedGroup``, where each one uses
/// ``ArxRaisedButtonStyle/item`` and only draws the same inset fill: lighter when hovered, a
/// darker inset squircle when selected. Like every
/// Arx control, it follows `controlSize` unless it's given a size and fades when disabled. It
/// draws the accent ring only when focus came to it from the keyboard. Give it a `help` for its
/// tooltip.
///
/// ```swift
/// Button { close() } label: { Image(systemName: "xmark") }
///     .buttonStyle(.arxRaised(.square))
///     .help("Close")
///
/// ArxRaisedGroup {
///     Button { more() } label: { Image(systemName: "ellipsis") }
///     Button { close() } label: { Image(systemName: "xmark") }
/// }
/// ```
public struct ArxRaisedButtonStyle: ButtonStyle {
	public enum Kind: Hashable, Sendable {
		/// Its own glassy squircle, padded for its label.
		case tile

		/// Inside an ``ArxRaisedGroup``'s tile: only the inset fill.
		case item

		/// A round tile (DEV-782). Raised controls are squircles since DEV-797, so this draws
		/// ``square``.
		@available(*, deprecated, renamed: "square", message: "Raised controls are squircles since DEV-797.")
		case round

		/// A header bar's compact text control, such as Refresh. A capsule until DEV-797; now a
		/// squircle-cornered ``tile`` padded for a bar's height.
		case capsule

		/// A squircle as wide as it's tall, for an icon: a header bar's Close or Back button (DEV-790, DEV-797).
		case square

		/// A key: a glassy squircle that fills the width it's given, with a denser fill, a darker
		/// lip along its bottom and a shadow under it, that sinks a point while pressed, as the site
		/// menu's buttons (DEV-1333). Selected is a switch that's on: an accent inset squircle and
		/// an accent glyph, rather than the darker selected fill.
		case key
	}

	private let kind: Kind
	private let size: ArxControlSize?
	private let isSelected: Bool
	private let isSquare: Bool

	/// `size` nil follows the environment's `controlSize`. A selected button keeps its darker
	/// inset fill, as the chosen view in a switcher does. A square button is as wide as it's
	/// tall, so icon buttons sharing a group get equal hit areas whatever their glyph's width.
	public init(
		_ kind: Kind = .tile,
		size: ArxControlSize? = nil,
		isSelected: Bool = false,
		isSquare: Bool = false
	) {
		self.kind = kind
		self.size = size
		self.isSelected = isSelected
		self.isSquare = isSquare
	}

	public func makeBody(configuration: Configuration) -> some View {
		ArxRaisedButtonBody(
			label: configuration.label,
			isPressed: configuration.isPressed,
			kind: kind,
			size: size,
			isSelected: isSelected,
			isSquare: isSquare
		)
	}
}

extension ButtonStyle where Self == ArxRaisedButtonStyle {
	/// A glassy squircle tile that follows `controlSize`.
	public static var arxRaised: Self {
		.init()
	}

	public static func arxRaised(
		_ kind: ArxRaisedButtonStyle.Kind = .tile,
		size: ArxControlSize? = nil,
		isSelected: Bool = false,
		isSquare: Bool = false
	) -> Self {
		.init(kind, size: size, isSelected: isSelected, isSquare: isSquare)
	}
}

/// The shape of Arx's raised toolbar controls (DEV-797): a squircle, a rounded rectangle with
/// continuous corners whose radius is ``cornerRatio`` × the smaller side. It's rounder than
/// ``ArxControlShape``.
public struct ArxRaisedShape: InsettableShape {
	/// A third of the side.
	public static let cornerRatio: CGFloat = 0.34

	private var inset: CGFloat

	public init() {
		self.inset = 0
	}

	/// The corner radius a raised control whose smaller side is `side` takes.
	public static func cornerRadius(forSide side: CGFloat) -> CGFloat {
		max(side, 0) * cornerRatio
	}

	public func path(in rect: CGRect) -> Path {
		let insetRect = rect.insetBy(dx: inset, dy: inset)
		return RoundedRectangle(
			cornerRadius: Self.cornerRadius(forSide: min(insetRect.width, insetRect.height)),
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

/// Related raised buttons sharing one glassy squircle, such as a ⋯ and × pair or a
/// switcher's segments. Give each button `.buttonStyle(.arxRaised(.item))`.
public struct ArxRaisedGroup<Content: View>: View {
	private let content: Content

	public init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}

	@Environment(\.controlSize)
	private var controlSize: ControlSize

	@Environment(\.arxRaisedControlHeight)
	private var raisedHeight: CGFloat?

	public var body: some View {
		let inset: CGFloat = ArxRaisedPalette.inset
		HStack(spacing: 0) {
			content
		}
		.padding(inset)
		.frame(minHeight: height)
		.background {
			ArxGlassTile(cornerRadius: ArxRaisedShape.cornerRadius(forSide: height))
		}
	}

	private var height: CGFloat {
		raisedHeight ?? ArxControlSize(controlSize).height
	}
}

/// The glassy squircle surface behind a raised toolbar control (DEV-797), for any toolbar-like
/// view that wants the same look, such as a search field: a translucent fill that's a touch
/// lighter at the top, a hairline edge with a lighter rim along the top, and a soft shadow.
public struct ArxGlassTile: View {
	private let cornerRadius: CGFloat
	private let isHovered: Bool
	private let isPressed: Bool
	private let fillOpacity: Double
	private let castsShadow: Bool
	private let isKey: Bool

	public init(cornerRadius: CGFloat) {
		self.init(cornerRadius: cornerRadius, isHovered: false, isPressed: false)
	}

	/// `fillOpacity` thins the glass over a backing that should show through it, as the
	/// command bar's floating controls do over the chrome (DEV-1277). Without `castsShadow`,
	/// a group of tiles casts one shadow of its own.
	internal init(
		cornerRadius: CGFloat,
		isHovered: Bool = false,
		isPressed: Bool = false,
		fillOpacity: Double = 1,
		castsShadow: Bool = true,
		isKey: Bool = false
	) {
		self.cornerRadius = cornerRadius
		self.isHovered = isHovered
		self.isPressed = isPressed
		self.fillOpacity = fillOpacity
		self.castsShadow = castsShadow
		self.isKey = isKey
	}

	public var body: some View {
		let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
		shape
			.fill(
				LinearGradient(
					colors: isKey
					? [ArxRaisedPalette.keyFillTop, ArxRaisedPalette.keyFillBottom]
					: [ArxRaisedPalette.fillTop, ArxRaisedPalette.fillBottom],
					startPoint: .top,
					endPoint: .bottom
				)
				.opacity(fillOpacity)
			)
			.overlay {
				// Hover and press light an inset squircle, not the whole tile (DEV-806).
				let inset: CGFloat = ArxRaisedPalette.inset
				let highlight = RoundedRectangle(
					cornerRadius: ArxRaisedPalette.insetRadius(tileRadius: cornerRadius),
					style: .continuous
				)
				if isPressed {
					highlight.fill(ArxRaisedPalette.itemPressedFill).padding(inset)
				} else if isHovered {
					highlight.fill(ArxRaisedPalette.itemHoverFill).padding(inset)
				}
			}
			.shadow(color: castsShadow ? ArxRaisedPalette.shadow : .clear, radius: isKey ? (isPressed ? 2 : 4) : 5, y: isKey ? (isPressed ? 0.5 : 2) : 2)
			.shadow(color: castsShadow && isKey ? ArxRaisedPalette.keyContactShadow : .clear, radius: isPressed ? 0.5 : 1, y: isPressed ? 0.5 : 1)
			.overlay { shape.strokeBorder(ArxRaisedPalette.hairline, lineWidth: 0.5) }
			.overlay {
				// A key's lip: a darker edge along its bottom, fading out by the middle.
				if isKey {
					shape.strokeBorder(
						LinearGradient(
							colors: [ArxRaisedPalette.keyLip.opacity(0), ArxRaisedPalette.keyLip],
							startPoint: .center,
							endPoint: .bottom
						),
						lineWidth: 1
					)
				}
			}
			.overlay {
				// The lighter rim along the top edge, fading out by the middle.
				shape.strokeBorder(
					LinearGradient(
						colors: [ArxRaisedPalette.rim, ArxRaisedPalette.rim.opacity(0)],
						startPoint: .top,
						endPoint: .center
					),
					lineWidth: 1
				)
			}
			.allowsHitTesting(false)
	}
}

/// The raised tile behind a card, such as a composer or a message: a light tile with a hairline
/// border and a faint soft shadow. Toolbar controls draw ``ArxGlassTile`` since DEV-797.
public struct ArxRaisedTile: View {
	private let cornerRadius: CGFloat
	private let style: RoundedCornerStyle
	private let isTranslucent: Bool

	/// How much of the tile's fill a translucent tile keeps over its material.
	internal static let translucentFillOpacity: Double = 0.55

	/// `style` `.circular` with a radius of half the height draws a true circle or capsule;
	/// continuous corners that large leave flat sides.
	///
	/// `isTranslucent` draws it over a material with its fill thinned, for a card that content
	/// scrolls under, such as a chat's composer (DEV-826): the content stays visible through it,
	/// blurred, rather than cut off at its edge.
	public init(
		cornerRadius: CGFloat,
		style: RoundedCornerStyle = .continuous,
		isTranslucent: Bool = false
	) {
		self.cornerRadius = cornerRadius
		self.style = style
		self.isTranslucent = isTranslucent
	}

	public var body: some View {
		let shape = RoundedRectangle(cornerRadius: cornerRadius, style: style)
		fill(shape)
			.shadow(color: .black.opacity(0.07), radius: 4, y: 1.5)
			.overlay { shape.strokeBorder(BrowserTheme.pageBorder, lineWidth: 0.5) }
	}

	@ViewBuilder
	private func fill(_ shape: RoundedRectangle) -> some View {
		if isTranslucent {
			shape
				.fill(.regularMaterial)
				.overlay { shape.fill(BrowserTheme.selection.opacity(Self.translucentFillOpacity)) }
		} else {
			shape.fill(BrowserTheme.selection)
		}
	}
}

internal enum ArxRaisedPalette {
	/// The gap between a tile's edge and its inset fill: a hovered, pressed or selected squircle
	/// inside a tile, or a group's items inside its tile. The inset is about 4 points (DEV-806).
	internal static let inset: CGFloat = 4

	/// The space an item leaves at each side of its label.
	internal static func itemPadding(_ size: ArxControlSize) -> CGFloat {
		size.horizontalPadding * 0.45
	}

	/// An inset squircle's corner radius inside a tile whose radius is `tileRadius`: smaller by
	/// the inset, so the two corners stay concentric.
	internal static func insetRadius(tileRadius: CGFloat) -> CGFloat {
		max(tileRadius - inset, 2)
	}

	/// The glass's fill at its top and bottom: white at about a tenth on dark, a near-opaque white
	/// on light.
	internal static let fillTop: Color = dynamic(dark: .white.withAlphaComponent(0.11), light: .white.withAlphaComponent(0.92))
	internal static let fillBottom: Color = dynamic(dark: .white.withAlphaComponent(0.075), light: .white.withAlphaComponent(0.72))

	/// The inset squircle inside a tile or a group's item: hovered, pressed, and the darker
	/// selected one.
	internal static let itemHoverFill: Color = dynamic(dark: .white.withAlphaComponent(0.07), light: .black.withAlphaComponent(0.045))
	internal static let itemPressedFill: Color = dynamic(dark: .black.withAlphaComponent(0.2), light: .black.withAlphaComponent(0.09))
	internal static let selectedFill: Color = dynamic(dark: .black.withAlphaComponent(0.3), light: .black.withAlphaComponent(0.08))
	internal static let selectedEdge: Color = dynamic(dark: .black.withAlphaComponent(0.25), light: .black.withAlphaComponent(0.06))

	/// A key's denser glass (DEV-1333), its darker bottom lip and the tight shadow where it meets
	/// the surface under it.
	internal static let keyFillTop: Color = dynamic(dark: .white.withAlphaComponent(0.17), light: .white)
	internal static let keyFillBottom: Color = dynamic(dark: .white.withAlphaComponent(0.11), light: NSColor(white: 0.955, alpha: 1))
	internal static let keyLip: Color = dynamic(dark: .black.withAlphaComponent(0.35), light: .black.withAlphaComponent(0.1))
	internal static let keyContactShadow: Color = dynamic(dark: .black.withAlphaComponent(0.45), light: .black.withAlphaComponent(0.12))

	/// A key that's on: the inset squircle in the accent color, over the key's glass.
	internal static let keyOnFill: Double = 0.2

	internal static let hairline: Color = dynamic(dark: .white.withAlphaComponent(0.06), light: .black.withAlphaComponent(0.08))
	internal static let rim: Color = dynamic(dark: .white.withAlphaComponent(0.16), light: .white)
	internal static let shadow: Color = dynamic(dark: .black.withAlphaComponent(0.3), light: .black.withAlphaComponent(0.08))

	/// A hovered segment's tooltip: opaque, so it reads over whatever lies under it.
	internal static let tooltipFill: Color = dynamic(
		dark: NSColor(white: 0.2, alpha: 1),
		light: .white
	)

	private static func dynamic(
		dark: NSColor,
		light: NSColor
	) -> Color {
		.init(nsColor: NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
		})
	}
}

private struct ArxRaisedButtonBody<Label: View>: View {
	internal let label: Label
	internal let isPressed: Bool
	internal let kind: ArxRaisedButtonStyle.Kind
	internal let size: ArxControlSize?
	internal let isSelected: Bool
	internal let isSquare: Bool

	@Environment(\.isEnabled)
	private var isEnabled: Bool

	@Environment(\.isFocused)
	private var isFocused: Bool

	@Environment(\.controlSize)
	private var controlSize: ControlSize

	@Environment(\.arxControlStateOverride)
	private var stateOverride: ArxControlStateOverride

	@Environment(\.arxRaisedControlHeight)
	private var raisedHeight: CGFloat?

	@SwiftUI.State
	private var isHovered: Bool = false

	@SwiftUI.State
	private var showsFocusRing: Bool = false

	internal var body: some View {
		let size = self.size ?? ArxControlSize(controlSize)

		// A bar's own height for its raised controls applies to those that follow the
		// environment; a button given a size keeps it.
		let tileHeight: CGFloat = self.size == nil ? raisedHeight ?? size.height : size.height
		let hovered = isEnabled && (stateOverride.isHovered ?? isHovered)
		let pressed = isEnabled && (stateOverride.isPressed ?? isPressed)
		let focused = isEnabled && (stateOverride.isFocused ?? (isFocused && showsFocusRing))
		let inset: CGFloat = ArxRaisedPalette.inset
		let isItem = kind == .item
		let isKey = kind == .key

		// The legacy round kind draws a square, like ``ArxRaisedButtonStyle/Kind/square``.
		let isIcon = !isItem && !isKey && kind != .tile && kind != .capsule

		// An item sits inside its group's tile, so it's the tile's height less the inset.
		let height: CGFloat = isItem ? tileHeight - inset * 2 : tileHeight
		let tileRadius: CGFloat = ArxRaisedShape.cornerRadius(forSide: tileHeight)
		let fillRadius: CGFloat = ArxRaisedPalette.insetRadius(tileRadius: tileRadius)
		let horizontalPadding: CGFloat = if isIcon || isKey {
			0
		} else if isItem {
			ArxRaisedPalette.itemPadding(size)
		} else if kind == .capsule {
			// A bar's text control pads for its height.
			max(size.horizontalPadding * 0.85, tileHeight * 0.36)
		} else {
			size.horizontalPadding * 0.6
		}
		label
			.font(.system(size: size.fontSize, weight: .regular))
			.imageScale(.medium)
			.lineLimit(1)
			.foregroundStyle(isKey && isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(BrowserTheme.text.opacity(0.85)))
			.padding(.horizontal, isSquare ? 0 : horizontalPadding)
			.frame(minWidth: height, maxWidth: isSquare ? height : (isKey ? .infinity : nil), minHeight: height)
			.frame(width: isIcon ? height : nil)
			.offset(y: isKey && pressed ? 1 : 0)
			.background {
				if isItem {
					itemFill(radius: fillRadius, hovered: hovered, pressed: pressed)
				} else if isKey, isSelected {
					RoundedRectangle(cornerRadius: fillRadius, style: .continuous)
						.fill(Color.accentColor.opacity(ArxRaisedPalette.keyOnFill))
						.overlay {
							RoundedRectangle(cornerRadius: fillRadius, style: .continuous)
								.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
						}
						.padding(inset)
						.offset(y: pressed ? 1 : 0)
				} else if isSelected {
					itemFill(radius: fillRadius, hovered: false, pressed: false)
						.padding(inset)
				}
			}
			.background {
				if !isItem {
					ArxGlassTile(cornerRadius: tileRadius, isHovered: hovered, isPressed: pressed, isKey: isKey)
						.offset(y: isKey && pressed ? 1 : 0)
				}
			}
			.overlay {
				if focused {
					RoundedRectangle(cornerRadius: isItem ? fillRadius : tileRadius, style: .continuous)
						.inset(by: -ArxControlPalette.focusRingWidth / 2 - 1)
						.stroke(ArxControlPalette.focusRing, lineWidth: ArxControlPalette.focusRingWidth)
				}
			}
			.contentShape(.focusEffect, RoundedRectangle(cornerRadius: isItem ? fillRadius : tileRadius, style: .continuous))
			.contentShape(RoundedRectangle(cornerRadius: isItem ? fillRadius : tileRadius, style: .continuous))
			.opacity(isEnabled ? 1 : ArxControlPalette.disabledOpacity)
			.onHover { isHovered = $0 }
			.arxKeyboardFocusRing(isFocused: isFocused, showsRing: $showsFocusRing)
			.animation(.easeOut(duration: 0.12), value: hovered)
			.animation(.easeOut(duration: 0.08), value: pressed)
	}

	/// An item's inset squircle: the darker selected one, or a lighter one while hovered.
	@ViewBuilder
	private func itemFill(
		radius: CGFloat,
		hovered: Bool,
		pressed: Bool
	) -> some View {
		let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
		if pressed {
			shape.fill(ArxRaisedPalette.itemPressedFill)
		} else if isSelected {
			shape
				.fill(ArxRaisedPalette.selectedFill)
				.overlay { shape.strokeBorder(ArxRaisedPalette.selectedEdge, lineWidth: 0.5) }
		} else if hovered {
			shape.fill(ArxRaisedPalette.itemHoverFill)
		}
	}
}

extension EnvironmentValues {
	/// The height raised controls inside take when they follow the environment, such as a header
	/// bar's: nil follows `controlSize`.
	@Entry
	internal var arxRaisedControlHeight: CGFloat? = nil
}

extension View {
	/// Sizes the raised controls inside to `height`, unless one is given a size of its own: a
	/// header bar's leading tile, text controls and search all match this way (DEV-790).
	public func arxRaisedControlHeight(_ height: CGFloat?) -> some View {
		environment(\.arxRaisedControlHeight, height)
	}
}
