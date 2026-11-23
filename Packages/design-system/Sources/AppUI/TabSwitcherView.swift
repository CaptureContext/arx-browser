import SwiftUI

/// One tab in ⌃Tab's switcher (DEV-544).
public struct TabSwitcherRow: Equatable, Identifiable, Sendable {
	public let id: UUID
	public let title: String

	/// The space it's in, when that's not the space the window shows.
	public let spaceName: String?
	public let siteIcon: SidebarItem.SiteIcon?
	public let symbol: String

	/// Its page isn't loaded. The switcher shows it dimmed, as the sidebar does, and loads nothing.
	public let isUnloaded: Bool

	public init(
		id: UUID,
		title: String,
		spaceName: String? = nil,
		siteIcon: SidebarItem.SiteIcon?,
		symbol: String = SidebarItem.siteSymbol,
		isUnloaded: Bool = false
	) {
		self.id = id
		self.title = title
		self.spaceName = spaceName
		self.siteIcon = siteIcon
		self.symbol = symbol
		self.isUnloaded = isUnloaded
	}
}

/// ⌃Tab's recent-tab switcher (DEV-544): the window's tabs, most recently shown first, in a card
/// over the page. The keyboard walks it; the pointer picks a row only once it moves, so a pointer
/// resting where the card happened to open changes nothing.
public struct TabSwitcherView: View {
	private let rows: [TabSwitcherRow]
	private let selectedIndex: Int
	private let onHighlight: (Int) -> Void
	private let onChoose: (Int) -> Void

	@SwiftUI.State
	private var restingPointer: CGPoint?

	@Environment(\.colorSchemeContrast)
	private var contrast

	public init(
		rows: [TabSwitcherRow],
		selectedIndex: Int,
		onHighlight: @escaping (Int) -> Void = { _ in },
		onChoose: @escaping (Int) -> Void = { _ in }
	) {
		self.rows = rows
		self.selectedIndex = selectedIndex
		self.onHighlight = onHighlight
		self.onChoose = onChoose
	}

	public var body: some View {
		let metrics = BrowserMetrics.TabSwitcher.self
		let padding = Self.contentPadding
		ScrollViewReader { proxy in
			ScrollView(.vertical) {
				// DESIGN.md › Lists, as the folder card's search lays out its tabs (DEV-1318): rows
				// touch, each holding half the gap around its highlight, and the card's inset is
				// padding on the scrolled content, which scrolling to a row brings in with it, so
				// the last highlight never ends flush with the card's edge. Not lazy, so every row
				// has the anchor the arrows scroll to.
				VStack(spacing: 0) {
					ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
						rowView(row, index: index)
							.id(row.id)
							.arxListRowAnchor(row.id, top: padding, bottom: padding)
					}
				}
				.padding(.horizontal, metrics.padding)
				.padding(.vertical, padding)
			}
			.scrollIndicators(.never)
			.scrollBounceBehavior(.basedOnSize)
			.frame(height: height)
			.onAppear { scroll(proxy, animated: false) }
			.onChange(of: selectedIndex) { _, _ in scroll(proxy, animated: true) }
		}
		.frame(width: metrics.width)
		.background {
			RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
				.fill(BrowserTheme.commandBackground)
				.browserShadow(BrowserMetrics.CommandBar.shadow)
		}
		.overlay {
			RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.CommandBar.borderWidth)
		}
		.clipShape(.rect(cornerRadius: metrics.cornerRadius, style: .continuous))
		.onContinuousHover(coordinateSpace: .global) { phase in
			guard case let .active(location) = phase else { return }
			if restingPointer == nil { restingPointer = location }
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.tabSwitcher.accessibility))
	}

	/// Tall enough for every row up to `visibleRows`; more scroll, following the selection.
	private var height: CGFloat {
		let metrics = BrowserMetrics.TabSwitcher.self
		let count = CGFloat(min(rows.count, metrics.visibleRows))
		return count * (metrics.rowHeight + metrics.rowSpacing) + 2 * Self.contentPadding
	}

	/// Above the first row and below the last: the card's inset, less the row's own half gap.
	private static var contentPadding: CGFloat {
		let metrics = BrowserMetrics.TabSwitcher.self
		return ArxListLayout.contentPadding(inset: metrics.padding, gap: metrics.rowSpacing)
	}

	private func scroll(
		_ proxy: ScrollViewProxy,
		animated: Bool
	) {
		guard rows.indices.contains(selectedIndex) else { return }
		let id = rows[selectedIndex].id
		if animated {
			withAnimation(.easeOut(duration: 0.12)) { proxy.scrollToListRow(id) }
		} else {
			proxy.scrollTo(id, anchor: .center)
		}
	}

	private func rowView(
		_ row: TabSwitcherRow,
		index: Int
	) -> some View {
		let metrics = BrowserMetrics.TabSwitcher.self
		let isSelected = index == selectedIndex
		return Button { onChoose(index) } label: {
			HStack(spacing: 10) {
				// Selected, the icon sits on a tile of its own so it reads on the accent, as in the
				// URL field's results.
				FavoriteSiteIcon(key: row.siteIcon, fallback: row.symbol, tint: .lavender)
					.frame(width: metrics.iconTileSize, height: metrics.iconTileSize)
					.background(
						isSelected ? AnyShapeStyle(BrowserTheme.onAccent) : AnyShapeStyle(Color.clear),
						in: ArxControlShape()
					)
				VStack(alignment: .leading, spacing: 1) {
					Text(row.title)
						.font(.system(size: BrowserMetrics.CommandBar.rowFontSize, weight: .medium))
						.lineLimit(1)
					if let space = row.spaceName {
						Text(space)
							.font(.system(size: 11))
							.opacity(BrowserMetrics.State.opacity(isSelected ? 0.8 : 0.5, contrast: contrast))
							.lineLimit(1)
					}
				}
				Spacer(minLength: 0)
			}
			.opacity(row.isUnloaded && !isSelected ? BrowserMetrics.Row.unloadedOpacity : 1)
			.foregroundStyle(
				isSelected
				? AnyShapeStyle(BrowserTheme.onAccent)
				: AnyShapeStyle(BrowserTheme.text.opacity(BrowserMetrics.State.opacity(0.86, contrast: contrast)))
			)
			.padding(.horizontal, metrics.rowHorizontalPadding)
			.frame(height: metrics.rowHeight)
			.background(
				isSelected ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(Color.clear),
				in: .rect(cornerRadius: BrowserMetrics.CommandBar.rowCornerRadius, style: .continuous)
			)

			// The gap between highlights is the rows', so the pointer finds a row anywhere in it.
			.arxListRow(gap: metrics.rowSpacing)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.onContinuousHover(coordinateSpace: .global) { phase in
			guard
				case let .active(location) = phase,
				let resting = restingPointer,
				hypot(location.x - resting.x, location.y - resting.y) > 2,
				index != selectedIndex
			else { return }
			onHighlight(index)
		}
		.accessibilityLabel(row.spaceName.map { "\(row.title), \($0)" } ?? row.title)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}
