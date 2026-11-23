import SwiftUI

/// A Library panel's Filter button, beside its search field. It's quiet at rest, a symbol and
/// title with no fill, and takes the field's fill while hovered or while its pane is open. While
/// filters are on, it turns accent and shows how many.
///
/// Where the header is narrow, pass `showsTitle: false` to keep only the symbol, so the search
/// field keeps its room.
public struct SidebarLibraryFilterButton: View {
	private let title: String
	private let symbol: String
	private let count: Int
	private let isOpen: Bool
	private let showsTitle: Bool
	private let action: () -> Void

	public init(
		title: String,
		symbol: String = "line.3.horizontal.decrease.circle",
		count: Int,
		isOpen: Bool,
		showsTitle: Bool = true,
		action: @escaping () -> Void
	) {
		self.title = title
		self.symbol = symbol
		self.count = count
		self.isOpen = isOpen
		self.showsTitle = showsTitle
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			HStack(spacing: BrowserMetrics.Library.menuIconSpacing) {
				Image(systemName: count > 0 ? symbol + ".fill" : symbol)
					.frame(width: BrowserMetrics.Library.menuSymbolWidth)
				if showsTitle { Text(title) }
				if count > 0 {
					Text(verbatim: "\(count)")
						.font(.system(size: 11, weight: .semibold).monospacedDigit())
						.foregroundStyle(BrowserTheme.onAccent)
						.padding(.horizontal, 5)
						.frame(minWidth: 18, minHeight: 18)
						.background(BrowserTheme.accent, in: Capsule())
				}
			}
			.padding(.leading, BrowserMetrics.Library.menuLeadingPadding)
			.padding(.trailing, BrowserMetrics.Library.menuTrailingPadding - (count > 0 ? 4 : 0))
		}
		.buttonStyle(SidebarLibraryFilterButtonStyle(isActive: count > 0, isOpen: isOpen))
		.fixedSize()
		.help(title)
		.accessibilityLabel(title)
		.accessibilityValue(count > 0 ? String.localized(.appUI.library.filtersOn(count)) : "")
		.accessibilityAddTraits(isOpen ? .isSelected : [])
	}
}

/// A choice in a Library filter pane, such as a profile. A selected one is filled with the
/// accent.
public struct SidebarLibraryChoiceChip: View {
	private let title: String
	private let isSelected: Bool
	private let action: () -> Void

	public init(
		_ title: String,
		isSelected: Bool,
		action: @escaping () -> Void
	) {
		self.title = title
		self.isSelected = isSelected
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			Text(title).lineLimit(1)
		}
		.buttonStyle(SidebarLibraryChipStyle(isSelected: isSelected))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

/// A filter that's on, shown under a Library panel's search field. Clicking it removes the
/// filter.
public struct SidebarLibraryFilterChip: View {
	private let title: String
	private let onRemove: () -> Void

	public init(
		_ title: String,
		onRemove: @escaping () -> Void
	) {
		self.title = title
		self.onRemove = onRemove
	}

	public var body: some View {
		Button(action: onRemove) {
			HStack(spacing: 4) {
				Text(title).lineLimit(1)
				Image(systemName: "xmark")
					.font(.system(size: 8, weight: .bold))
					.opacity(0.75)
			}
		}
		.buttonStyle(SidebarLibraryChipStyle(isSelected: true, isCompact: true))
		.help(String.localized(.appUI.library.removeFilter(title)))
		.accessibilityLabel(String.localized(.appUI.library.removeFilter(title)))
	}
}

/// The pane a Library panel's Filter button opens under its header: a title, Done, and sections
/// of choices.
public struct SidebarLibraryFilterPane<Content: View>: View {
	private let title: String
	private let onDone: () -> Void
	private let content: Content

	public init(
		title: String,
		onDone: @escaping () -> Void,
		@ViewBuilder content: () -> Content
	) {
		self.title = title
		self.onDone = onDone
		self.content = content()
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Text(title)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
				Spacer(minLength: 8)
				Button(String.localized(.appUI.library.filterDone), action: onDone)
					.buttonStyle(.arx(size: .small))
					.keyboardShortcut(.cancelAction)
			}
			content
		}
		.padding(12)
		.background(
			BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.fieldOpacity),
			in: .rect(cornerRadius: BrowserMetrics.Library.filterPaneCornerRadius, style: .continuous)
		)
	}
}

/// A titled group of chips in a ``SidebarLibraryFilterPane``. The chips wrap.
public struct SidebarLibraryFilterSection<Content: View>: View {
	private let title: String
	private let content: Content

	public init(
		_ title: String,
		@ViewBuilder content: () -> Content
	) {
		self.title = title
		self.content = content()
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity))
				.accessibilityAddTraits(.isHeader)
			ArxFlowLayout(spacing: 5) { content }
		}
	}
}

private enum SidebarLibraryFilterPalette {
	/// Accent text over the chrome or a soft accent tint: lifted in dark, where the plain accent
	/// is too dim to read.
	internal static func accentText(_ colorScheme: ColorScheme) -> AnyShapeStyle {
		colorScheme == .dark
		? AnyShapeStyle(BrowserTheme.accent.mixed(with: .white, by: 0.45))
		: AnyShapeStyle(BrowserTheme.accent)
	}
}

private struct SidebarLibraryFilterButtonStyle: ButtonStyle {
	internal let isActive: Bool
	internal let isOpen: Bool

	internal func makeBody(configuration: Configuration) -> some View {
		SidebarLibraryFilterButtonBody(
			label: configuration.label,
			isPressed: configuration.isPressed,
			isActive: isActive,
			isOpen: isOpen
		)
	}
}

private struct SidebarLibraryFilterButtonBody<Label: View>: View {
	internal let label: Label
	internal let isPressed: Bool
	internal let isActive: Bool
	internal let isOpen: Bool

	@Environment(\.arxControlStateOverride)
	private var stateOverride: ArxControlStateOverride

	@Environment(\.colorScheme)
	private var colorScheme: ColorScheme

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		let hovered: Bool = stateOverride.isHovered ?? isHovered
		let pressed: Bool = stateOverride.isPressed ?? isPressed
		label
			.font(.system(size: BrowserMetrics.Library.fieldFontSize, weight: .medium))
			.foregroundStyle(
				isActive
				? SidebarLibraryFilterPalette.accentText(colorScheme)
				: AnyShapeStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
			)
			.frame(height: BrowserMetrics.Library.fieldHeight)
			.background(
				BrowserTheme.libraryTint.opacity(fillOpacity(hovered: hovered, pressed: pressed)),
				in: ArxControlShape()
			)
			.contentShape(ArxControlShape())
			.onHover { isHovered = $0 }
			.animation(.easeOut(duration: 0.12), value: hovered)
			.animation(.easeOut(duration: 0.08), value: pressed)
	}

	private func fillOpacity(
		hovered: Bool,
		pressed: Bool
	) -> Double {
		if pressed { return BrowserMetrics.Library.chipPressedOpacity }
		if hovered { return BrowserMetrics.Library.chipHoverOpacity }
		return isOpen ? BrowserMetrics.Library.fieldOpacity : 0
	}
}

private struct SidebarLibraryChipStyle: ButtonStyle {
	internal let isSelected: Bool
	internal var isCompact: Bool

	internal init(
		isSelected: Bool,
		isCompact: Bool = false
	) {
		self.isSelected = isSelected
		self.isCompact = isCompact
	}

	internal func makeBody(configuration: Configuration) -> some View {
		SidebarLibraryChipBody(
			label: configuration.label,
			isPressed: configuration.isPressed,
			isSelected: isSelected,
			isCompact: isCompact
		)
	}
}

private struct SidebarLibraryChipBody<Label: View>: View {
	internal let label: Label
	internal let isPressed: Bool
	internal let isSelected: Bool
	internal let isCompact: Bool

	@Environment(\.isEnabled)
	private var isEnabled: Bool

	@Environment(\.isFocused)
	private var isFocused: Bool

	@Environment(\.colorScheme)
	private var colorScheme: ColorScheme

	@Environment(\.arxControlStateOverride)
	private var stateOverride: ArxControlStateOverride

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		let hovered: Bool = isEnabled && (stateOverride.isHovered ?? isHovered)
		let pressed: Bool = isEnabled && (stateOverride.isPressed ?? isPressed)
		let focused: Bool = isEnabled && (stateOverride.isFocused ?? isFocused)
		let height: CGFloat = isCompact ? BrowserMetrics.Library.filterChipHeight : BrowserMetrics.Library.choiceChipHeight
		label
			.font(.system(size: isCompact ? 12 : 13, weight: .medium))
			.foregroundStyle(foreground)
			.padding(.horizontal, isCompact ? 8 : 11)
			.frame(height: height)
			.background(fill(hovered: hovered, pressed: pressed), in: ArxControlShape())
			.overlay {
				if focused {
					ArxControlShape()
						.inset(by: -ArxControlPalette.focusRingWidth / 2 - 1)
						.stroke(ArxControlPalette.focusRing, lineWidth: ArxControlPalette.focusRingWidth)
				}
			}
			.contentShape(.focusEffect, ArxControlShape())
			.contentShape(ArxControlShape())
			.opacity(isEnabled ? 1 : ArxControlPalette.disabledOpacity)
			.onHover { isHovered = $0 }
			.animation(.easeOut(duration: 0.12), value: hovered)
			.animation(.easeOut(duration: 0.08), value: pressed)
	}

	/// A header chip is a soft accent tint with accent text; a selected choice is filled.
	private var foreground: AnyShapeStyle {
		if isCompact { return SidebarLibraryFilterPalette.accentText(colorScheme) }
		if isSelected { return AnyShapeStyle(BrowserTheme.onAccent) }
		return AnyShapeStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
	}

	private func fill(
		hovered: Bool,
		pressed: Bool
	) -> AnyShapeStyle {
		if isCompact {
			let opacity: Double = pressed ? 0.3 : hovered ? 0.22 : 0.14
			return AnyShapeStyle(BrowserTheme.accent.opacity(opacity))
		}
		if isSelected {
			let accent: BrowserAccent = BrowserTheme.accent
			if pressed { return AnyShapeStyle(accent.mixed(with: .black, by: 0.18)) }
			if hovered { return AnyShapeStyle(accent.mixed(with: .white, by: 0.12)) }
			return AnyShapeStyle(accent)
		}
		let opacity: Double = pressed
		? BrowserMetrics.Library.chipPressedOpacity
		: hovered ? BrowserMetrics.Library.chipHoverOpacity : BrowserMetrics.Library.chipOpacity
		return AnyShapeStyle(BrowserTheme.libraryTint.opacity(opacity))
	}
}
