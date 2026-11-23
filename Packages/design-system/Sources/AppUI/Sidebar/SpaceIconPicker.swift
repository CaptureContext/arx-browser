import BrowserCore
import SwiftUI

/// Draws a space's icon, whichever kind it is. The surrounding font sets its size, except for
/// ``BrowserCore/SpaceIcon/dot``, which is always the collapsed space switcher's dot (DEV-1251).
public struct SpaceIconImage: View {
	private let icon: SpaceIcon

	public init(_ icon: SpaceIcon) {
		self.icon = icon
	}

	public init(rawValue: String) {
		self.icon = SpaceIcon(rawValue: rawValue) ?? .stack
	}

	public var body: some View {
		if icon == .dot {
			Circle()
				.frame(width: BrowserMetrics.SpaceSwitcher.dotSize, height: BrowserMetrics.SpaceSwitcher.dotSize)
		} else if icon.isEmoji {
			Text(icon.rawValue)
		} else {
			Image(systemName: icon.rawValue)
		}
	}
}

/// Emoji and symbols in a searchable grid. With `onReset`, a trash button beside the search field
/// puts back the default icon: a tab's site icon, or a space's dot (DEV-1251).
public struct SpaceIconPicker: View {
	private enum Kind: Hashable {
		case emoji
		case symbol
	}

	/// Nil while the default icon shows.
	private let selection: SpaceIcon?
	private let onReset: (() -> Void)?
	private let onSelect: (SpaceIcon) -> Void

	@SwiftUI.State
	private var kind: Kind

	@SwiftUI.State
	private var query: String

	public init(
		selection: SpaceIcon?,
		onReset: (() -> Void)? = nil,
		onSelect: @escaping (SpaceIcon) -> Void
	) {
		self.selection = selection
		self.onReset = onReset
		self.onSelect = onSelect
		self._kind = .init(initialValue: selection?.isEmoji == true ? .emoji : .symbol)
		self._query = .init(initialValue: "")
	}

	public var body: some View {
		VStack(spacing: BrowserMetrics.IconPicker.spacing) {
			kindControl
			grid
			HStack(spacing: BrowserMetrics.IconPicker.spacing) {
				BrowserSearchField(placeholder: String.localized(.appUI.spaceIcon.search), query: $query)
					.onSubmit {
						if let first = results.first { onSelect(first) }
					}
				if let onReset {
					resetButton(onReset)
				}
			}
		}
		.padding(BrowserMetrics.IconPicker.padding)
		.frame(width: BrowserMetrics.IconPicker.width)
	}

	private var kindControl: some View {
		HStack(spacing: 0) {
			kindButton(.emoji, title: String.localized(.appUI.spaceIcon.emoji))
			kindButton(.symbol, title: String.localized(.appUI.spaceIcon.icon))
		}
		.padding(BrowserMetrics.IconPicker.segmentInset)
		.background(
			BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.fieldOpacity),
			in: ArxControlShape()
		)
	}

	private func kindButton(
		_ value: Kind,
		title: String
	) -> some View {
		Button { kind = value } label: {
			Text(title)
				.font(.system(size: BrowserMetrics.Library.fieldFontSize, weight: .medium))
				.foregroundStyle(
					BrowserTheme.text.opacity(kind == value ? 1 : BrowserMetrics.Library.subtitleOpacity)
				)
				.frame(maxWidth: .infinity)
				.frame(height: BrowserMetrics.IconPicker.segmentHeight)
				.background(
					kind == value
					? BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.selectionOpacity)
					: .clear,
					in: ArxControlShape()
				)
				.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.accessibilityAddTraits(kind == value ? .isSelected : [])
	}

	private func resetButton(_ reset: @escaping () -> Void) -> some View {
		Button(action: reset) {
			Image(systemName: "trash")
				.font(.system(size: BrowserMetrics.Library.fieldFontSize, weight: .medium))
				.foregroundStyle(BrowserTheme.text.opacity(selection == nil ? BrowserMetrics.Library.subtitleOpacity : 1))
				.frame(width: BrowserMetrics.Library.fieldHeight, height: BrowserMetrics.Library.fieldHeight)
				.background(
					BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.fieldOpacity),
					in: ArxControlShape()
				)
				.contentShape(ArxControlShape())
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()

		// The default shows already: nothing to reset.
		.disabled(selection == nil)
		.help(String.localized(.appUI.spaceIcon.reset))
		.accessibilityLabel(String.localized(.appUI.spaceIcon.reset))
	}

	private var results: [SpaceIcon] {
		switch kind {
		case .emoji: SpaceIconCatalog.emoji(matching: query).map(SpaceIcon.init(emoji:))
		case .symbol: SpaceIconCatalog.symbols(matching: query).map(SpaceIcon.init(symbol:))
		}
	}

	private var grid: some View {
		ScrollView {
			LazyVGrid(
				columns: Array(
					repeating: .init(.fixed(BrowserMetrics.IconPicker.cellSize), spacing: 0),
					count: BrowserMetrics.IconPicker.columns
				),
				spacing: 0
			) {
				ForEach(results, id: \.self) { icon in
					SpaceIconPickerCell(icon: icon, isSelected: icon == selection) { onSelect(icon) }
				}
			}
		}
		.scrollIndicators(.hidden)
		.scrollEdgeEffectHidden(true)
		.frame(height: BrowserMetrics.IconPicker.gridHeight)
		.overlay {
			if results.isEmpty {
				Text(localized: .appUI.spaceIcon.noResults)
					.font(.system(size: BrowserMetrics.Library.fieldFontSize))
					.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))
			}
		}
	}
}

private struct SpaceIconPickerCell: View {
	private let icon: SpaceIcon
	private let isSelected: Bool
	private let select: () -> Void

	@SwiftUI.State
	private var isHovered: Bool

	internal init(
		icon: SpaceIcon,
		isSelected: Bool,
		select: @escaping () -> Void
	) {
		self.icon = icon
		self.isSelected = isSelected
		self.select = select
		self._isHovered = .init(initialValue: false)
	}

	internal var body: some View {
		Button(action: select) {
			SpaceIconImage(icon)
				.font(.system(size: BrowserMetrics.IconPicker.symbolSize, weight: .medium))
				.foregroundStyle(BrowserTheme.text)
				.frame(
					width: BrowserMetrics.IconPicker.cellSize,
					height: BrowserMetrics.IconPicker.cellSize
				)
				.background(
					background,
					in: ArxControlShape()
				)
				.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.onHover { isHovered = $0 }
		.accessibilityLabel(title)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}

	private var background: Color {
		let selectionOpacity = BrowserMetrics.Library.selectionOpacity
		if isSelected { return BrowserTheme.libraryTint.opacity(selectionOpacity * 2) }
		return isHovered ? BrowserTheme.libraryTint.opacity(selectionOpacity) : .clear
	}

	private var title: String {
		if icon.isEmoji, let emoji = icon.rawValue.first {
			return SpaceIconCatalog.title(ofEmoji: emoji)
		}
		return SpaceIconCatalog.title(ofSymbol: icon.rawValue)
	}
}

extension View {
	public func spaceIconPicker(
		isPresented: Binding<Bool>,
		selection: SpaceIcon?,
		edge: VerticalEdge = .top,
		onReset: (() -> Void)? = nil,
		onSelect: @escaping (SpaceIcon) -> Void
	) -> some View {
		floatingPanel(isPresented: isPresented, edge: edge) {
			SpaceIconPicker(
				selection: selection,
				onReset: onReset.map { reset in
					{
						isPresented.wrappedValue = false
						reset()
					}
				}
			) { icon in
				isPresented.wrappedValue = false
				onSelect(icon)
			}
		}
	}
}
