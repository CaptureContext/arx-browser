import AppKit
import SwiftUI

/// The command bar's panel (DEV-1277): the window's content blurred through a tinted glass, in a
/// physical bezel. A 1-point outer edge, a lighter band, a darker line where the band meets the
/// glass, and the raised controls' rim along the top.
internal struct CommandBarRaisedPanel: View {
	internal let cornerRadius: CGFloat

	private typealias Metrics = BrowserMetrics.CommandBar.Raised

	internal var body: some View {
		let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
		shape
			.fill(.regularMaterial)
			.overlay { shape.fill(CommandBarGlassPalette.tint) }
			.browserShadow(BrowserMetrics.CommandBar.shadow)
			.overlay { shape.strokeBorder(CommandBarGlassPalette.bezelBand, lineWidth: Metrics.bezelWidth) }
			.overlay {
				// Outside the glass: the line lies on the band's inner side.
				shape
					.inset(by: Metrics.bezelWidth - 1)
					.strokeBorder(CommandBarGlassPalette.bezelInner, lineWidth: 1)
			}
			.overlay {
				// The raised glass's rim, as on the Runway's tiles, fading out by the middle.
				shape
					.inset(by: 1)
					.strokeBorder(
						LinearGradient(
							colors: [ArxRaisedPalette.rim, ArxRaisedPalette.rim.opacity(0)],
							startPoint: .top,
							endPoint: .center
						),
						lineWidth: 1
					)
			}
			.overlay { shape.strokeBorder(CommandBarGlassPalette.bezelEdge, lineWidth: 1) }
			.allowsHitTesting(false)
	}
}

internal enum CommandBarGlassPalette {
	/// Over the material: dark enough on dark that a busy page reads as texture, not content;
	/// on light, a milky white.
	internal static let tint: Color = dynamic(
		dark: .black.withAlphaComponent(0.32),
		light: .white.withAlphaComponent(0.42)
	)

	/// The bezel's outer edge.
	internal static let bezelEdge: Color = dynamic(
		dark: .black.withAlphaComponent(0.6),
		light: .black.withAlphaComponent(0.16)
	)

	/// The bezel's band, lighter than the glass it frames.
	internal static let bezelBand: Color = dynamic(
		dark: .white.withAlphaComponent(0.15),
		light: .white.withAlphaComponent(0.78)
	)

	/// Where the band meets the glass.
	internal static let bezelInner: Color = dynamic(
		dark: .black.withAlphaComponent(0.5),
		light: .black.withAlphaComponent(0.07)
	)

	/// The highlighted result and action: the raised group's selected squircle.
	internal static var selectedFill: Color { ArxRaisedPalette.selectedFill }
	internal static var selectedEdge: Color { ArxRaisedPalette.selectedEdge }

	private static func dynamic(
		dark: NSColor,
		light: NSColor
	) -> Color {
		.init(nsColor: NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
		})
	}
}

/// The glass the command bar's floating controls float on: the chrome behind a thinned raised
/// tile, as the destination picker's controls sit on it, so it reads the same over any result.
internal struct CommandBarRaisedGlass<S: Shape>: View {
	internal let shape: S
	internal let cornerRadius: CGFloat

	/// Off for glass in a group that casts one shadow for all of it.
	internal var castsShadow: Bool = true

	internal var body: some View {
		BrowserChromeBackground(textured: false)
			.clipShape(shape)
			.overlay {
				ArxGlassTile(
					cornerRadius: cornerRadius,
					fillOpacity: BrowserMetrics.CommandBar.Raised.glassFillOpacity,
					castsShadow: castsShadow
				)
			}
			.browserShadow(castsShadow ? BrowserMetrics.CommandBar.Raised.floatingShadow : .none)
			.allowsHitTesting(false)
	}
}

/// What replaces the footer (DEV-1277): Actions ⌘K floating over the panel's bottom-right
/// corner on raised glass. It's the key's pointer path; the key works without it, so it never
/// takes keyboard focus.
internal struct CommandBarActionsButton: View {
	internal let actionsKey: String?
	internal let onShowActions: () -> Void

	internal var body: some View {
		CommandBarFloatingButton(
			title: String.localized(.appUI.command.actions),
			key: actionsKey,
			action: onShowActions
		)
	}

	/// The caps a key's symbols take; see `CommandBarFloatingButton.keycaps(_:)`.
	internal static func keycaps(_ key: String) -> [String] {
		CommandBarFloatingButton.keycaps(key)
	}
}

/// A control floating over one of the command bar's bottom corners on raised glass: Actions ⌘K
/// at the right, and Little Arx's profile picker at the left (DEV-1331), its twin. A title and the
/// key that does the same, which works without the button, so it never takes keyboard focus.
internal struct CommandBarFloatingButton: View {
	internal let title: String

	/// A glyph before the title, as the profile picker's person.
	internal var symbol: String? = nil
	internal let key: String?

	/// What VoiceOver reads before the title, such as "Profile".
	internal var accessibilityPrefix: String? = nil
	internal let action: () -> Void

	private typealias Metrics = BrowserMetrics.CommandBar.Raised

	internal var body: some View {
		ArxRaisedGroup {
			Button(action: action) {
				HStack(spacing: Metrics.labelSpacing) {
					if let symbol {
						Image(systemName: symbol)
							.font(.system(size: 13, weight: .medium))
							.foregroundStyle(BrowserTheme.text.opacity(0.62))
							.accessibilityHidden(true)
					}
					Text(verbatim: Self.shortened(title))
						.font(.system(size: 13, weight: .medium))
						.foregroundStyle(BrowserTheme.text.opacity(0.62))
						.fixedSize()
					if let key {
						HStack(spacing: Metrics.keycapSpacing) {
							ForEach(Array(Self.keycaps(key).enumerated()), id: \.offset) { _, cap in
								CommandBarKeycap(cap)
							}
						}
						.accessibilityHidden(true)
					}
				}
			}
			.buttonStyle(.arxRaised(.item))
			.focusable(false)
			.accessibilityLabel(Text(verbatim: accessibilityLabel))
		}
		.background {
			CommandBarRaisedGlass(
				shape: ArxRaisedShape(),
				cornerRadius: ArxRaisedShape.cornerRadius(forSide: Metrics.floatingHeight)
			)
		}
		.arxRaisedControlHeight(Metrics.floatingHeight)
		.controlSize(.regular)
	}

	/// The longest title the button shows whole; a longer one, such as a long profile name, is cut
	/// short so the button never reaches across the bar to its twin.
	internal static let titleLimit: Int = 24

	internal static func shortened(_ title: String) -> String {
		guard title.count > titleLimit else { return title }
		return String(title.prefix(titleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
	}

	private var accessibilityLabel: String {
		let label = accessibilityPrefix.map { $0 + ", " + title } ?? title
		return key.map { label + ", " + $0 } ?? label
	}

	/// The caps a key's symbols take, one per modifier and one for the key: ⌘K is ⌘ and K, as
	/// the reference draws it.
	internal static func keycaps(_ key: String) -> [String] {
		let modifiers: Set<Character> = ["⌘", "⌥", "⌃", "⇧"]
		var caps: [String] = []
		var rest = Substring(key)
		while let first = rest.first, modifiers.contains(first), rest.count > 1 {
			caps.append(String(first))
			rest = rest.dropFirst()
		}
		if !rest.isEmpty { caps.append(String(rest)) }
		return caps
	}
}

/// A key cap as the floating Actions button draws it: the symbol in a rounded outline.
private struct CommandBarKeycap: View {
	private let symbol: String

	@Environment(\.colorSchemeContrast)
	private var contrast

	internal init(_ symbol: String) {
		self.symbol = symbol
	}

	internal var body: some View {
		let size = BrowserMetrics.CommandBar.Raised.keycapSize
		Text(verbatim: symbol)
			.font(.system(size: 10, weight: .semibold))
			.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.State.opacity(0.62, contrast: contrast)))
			.padding(.horizontal, symbol.count > 1 ? 4 : 0)
			.frame(minWidth: size, minHeight: size, maxHeight: size)
			.overlay {
				ArxControlShape()
					.strokeBorder(BrowserTheme.text.opacity(0.24), lineWidth: 1)
			}
	}
}
