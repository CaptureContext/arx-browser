import AppKit
import SwiftUI

/// Hands a command bar row its bar's current actions (DEV-997).
///
/// The bar builds new closures on every pass, and closures never compare equal, so a row holding
/// them directly would look changed every time and draw again. Rows hold this relay instead, which
/// keeps its identity while the bar refreshes what it calls.
@MainActor
internal final class CommandBarRowActions {
	private var select: (String) -> Void = { _ in }
	private var commandSelect: ((String) -> Void)?
	private var hover: (String) -> Void = { _ in }

	internal init() {}

	internal func update(
		select: @escaping (String) -> Void,
		commandSelect: ((String) -> Void)? = nil,
		hover: @escaping (String) -> Void
	) {
		self.select = select
		self.commandSelect = commandSelect
		self.hover = hover
	}

	/// A click on the row; with ⌘ held, the host's ⌘-click when it has one (DEV-1319).
	internal func selected(
		_ id: String,
		withCommand: Bool = false
	) {
		if withCommand, let commandSelect {
			commandSelect(id)
		} else {
			select(id)
		}
	}

	internal func hovered(_ id: String) {
		hover(id)
	}
}

/// One result in the command bar's list. It compares its result, whether it's selected and the
/// bar's style, so moving the selection draws only the row it leaves and the one it reaches, and
/// the others keep their icons as they are (DEV-997).
internal struct CommandBarResultRow: View, Equatable {
	private let result: CommandBarResult
	private let isSelected: Bool
	private let style: CommandBarStyle
	private let actions: CommandBarRowActions

	@Environment(\.colorSchemeContrast)
	private var contrast

	internal init(
		result: CommandBarResult,
		isSelected: Bool,
		style: CommandBarStyle,
		actions: CommandBarRowActions
	) {
		self.result = result
		self.isSelected = isSelected
		self.style = style
		self.actions = actions
	}

	internal nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.result == rhs.result
		&& lhs.isSelected == rhs.isSelected
		&& lhs.style == rhs.style
		&& lhs.actions === rhs.actions
	}

	internal var body: some View {
		let _ = RenderTrace.body("CommandBar.resultRow")
		Button {
			actions.selected(result.id, withCommand: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
		} label: {
			HStack(spacing: 10) {
				icon
					.frame(width: 23, height: 23)
				VStack(alignment: .leading, spacing: 2) {
					HStack(spacing: 6) {
						Text(result.title)
							.font(.system(size: BrowserMetrics.CommandBar.rowFontSize, weight: .medium))
							.lineLimit(1)
						ForEach([result.alias, result.state].compactMap(\.self), id: \.self) { tag in
							Text(tag)
								.font(.system(size: 11, weight: .medium))
								.opacity(isSelected ? 0.8 : 0.6)
								.padding(.horizontal, 5)
								.padding(.vertical, 1)
								.background(BrowserTheme.surface.opacity(0.06), in: ArxControlShape())
								.accessibilityHidden(true)
						}
					}
					if !result.subtitle.isEmpty {
						Text(result.subtitle)
							.font(.system(size: 11))
							.opacity(BrowserMetrics.State.opacity(0.5, contrast: contrast))
							.lineLimit(1)
							.truncationMode(.middle)
					}
				}
				Spacer(minLength: 10)
				hint
			}

			// The highlight is the raised group's selected squircle, so the row keeps its own
			// colours on it (DEV-1277).
			.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.State.opacity(0.76, contrast: contrast)))

			// A disabled row stays findable, dimmed (DEV-1262).
			.opacity(
				result.isEnabled
				? 1
				: BrowserMetrics.State.opacity(BrowserMetrics.State.disabledOpacity, contrast: contrast)
			)
			.padding(.horizontal, style.rowHorizontalPadding)
			.frame(height: style.rowHeight)
			.background { highlight }

			// Rows touch; the gap to the next highlight is the row's own (DEV-1289).
			.arxListRow(gap: style.rowSpacing)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.onContinuousHover { phase in
			if case .active = phase { actions.hovered(result.id) }
		}
		.accessibilityLabel(result.accessibilityLabel)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}

	/// The raised group's selected squircle (DEV-1277), concentric with the panel's corners.
	@ViewBuilder
	private var highlight: some View {
		if isSelected {
			let shape = RoundedRectangle(cornerRadius: style.rowCornerRadius, style: .continuous)
			shape
				.fill(CommandBarGlassPalette.selectedFill)
				.overlay { shape.strokeBorder(CommandBarGlassPalette.selectedEdge, lineWidth: 0.5) }
		}
	}

	@ViewBuilder
	private var icon: some View {
		// The tour's sample sites draw their favicons without a site icon to load (DEV-791).
		if result.siteIcon != nil || TourSiteGlyph(symbol: result.symbol) != nil {
			FavoriteSiteIcon(
				key: result.siteIcon,
				fallback: result.symbol,
				tint: result.tint,
				// A bang without a stored icon keeps the plain search glyph the other rows draw.
				fallbackSize: result.siteIconFetch == .storedOnly ? 15 : 17,
				fallbackWeight: result.siteIconFetch == .storedOnly ? .medium : .semibold
			)
			.siteIconsShown(result.siteIconFetch == .onScreen)
		} else {
			let symbol = Image(systemName: result.symbol)
				.font(.system(size: 15, weight: .medium))
				.foregroundStyle(result.tint.color)
			if style.usesIconTiles {
				let metrics = BrowserMetrics.CommandBar.URLField.self
				symbol
					.frame(width: metrics.iconTileSize, height: metrics.iconTileSize)
					.background(BrowserTheme.surface.opacity(0.05), in: ArxControlShape())
			} else {
				symbol
			}
		}
	}

	@ViewBuilder
	private var hint: some View {
		if style.usesIconTiles, let shortcut = result.shortcut {
			Text(shortcut)
				.font(.system(size: 11, weight: .medium))
				.opacity(isSelected ? 0.8 : 0.6)
				.padding(.horizontal, 7)
				.frame(height: BrowserMetrics.CommandBar.URLField.keycapHeight)
				.background(BrowserTheme.surface.opacity(0.05), in: ArxControlShape())
		} else if style.showsRowHints {
			Text(result.shortcut ?? result.actionTitle)
				.font(.system(size: 11, weight: .medium))
				.opacity(0.45)
			Image(systemName: "arrow.right")
				.font(.system(size: 14, weight: .medium))
				.foregroundStyle(BrowserTheme.text.opacity(0.5))
				.frame(width: 23, height: 23)
				.background(BrowserTheme.surface.opacity(0.05), in: ArxControlShape())
		} else if isSelected {
			Image(systemName: "return")
				.font(.system(size: 12, weight: .medium))
				.accessibilityHidden(true)
		}
	}
}
