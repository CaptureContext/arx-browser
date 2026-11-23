import BrowserCore
import SwiftUI

/// The rail and panel that replace the sidebar's spaces, reached by swiping past the first space
/// or from the space switcher's first button.
public struct SidebarLibrary {
	public var isOpen: Bool

	/// 0 shows the spaces and 1 the Library. A swipe drives it directly, so it can rest between them.
	public var progress: Binding<CGFloat>
	public var sections: [LibrarySection]
	public var selection: LibrarySection?
	public var setOpen: (Bool) -> Void
	public var select: (LibrarySection) -> Void

	public init(
		isOpen: Bool,
		progress: Binding<CGFloat>,
		sections: [LibrarySection],
		selection: LibrarySection?,
		setOpen: @escaping (Bool) -> Void,
		select: @escaping (LibrarySection) -> Void
	) {
		self.isOpen = isOpen
		self.progress = progress
		self.sections = sections
		self.selection = selection
		self.setOpen = setOpen
		self.select = select
	}
}

extension LibrarySection {
	internal var symbol: String {
		switch self {
		case .media: BrowserCommand.media.symbol
		case .downloads: BrowserCommand.downloads.symbol
		case .history: BrowserCommand.showHistory.symbol
		case .spaces: "square.on.square"
		case .archive: BrowserCommand.openArchive.symbol
		}
	}

	internal var title: String {
		switch self {
		case .media: BrowserCommand.media.title
		case .downloads: BrowserCommand.downloads.title
		case .history: String.localized(.appUI.library.history)
		case .spaces: String.localized(.appUI.library.spaces)
		case .archive: BrowserCommand.openArchive.title
		}
	}
}

/// The sidebar's width with the spaces showing and with the Library showing.
internal struct SidebarWidths: Equatable {
	internal var base: CGFloat?
	internal var expanded: CGFloat?

	internal init(
		base: CGFloat? = nil,
		expanded: CGFloat? = nil
	) {
		self.base = base
		self.expanded = expanded
	}
}

extension EnvironmentValues {
	@Entry
	internal var sidebarWidths: SidebarWidths = .init()
}

/// Fades the spaces out early in the transition, so they are gone before the Library's rail arrives.
///
/// The outgoing spaces also shrink toward their leading edge, a slight parallax against the Library sliding in.
/// Reduce Motion keeps only the fade.
internal struct SidebarLibraryTransition: ViewModifier, Animatable {
	internal var progress: CGFloat
	private let range: ClosedRange<CGFloat>
	private let travel: CGFloat
	private let hiddenScale: CGFloat
	private let isOutgoing: Bool
	private let reducesMotion: Bool

	internal nonisolated var animatableData: CGFloat {
		get { progress }
		set { progress = newValue }
	}

	internal init(
		progress: CGFloat,
		range: ClosedRange<CGFloat>,
		travel: CGFloat,
		hiddenScale: CGFloat = 1,
		isOutgoing: Bool = false,
		reducesMotion: Bool = false
	) {
		self.progress = progress
		self.range = range
		self.travel = travel
		self.hiddenScale = hiddenScale
		self.isOutgoing = isOutgoing
		self.reducesMotion = reducesMotion
	}

	internal func body(content: Content) -> some View {
		let visible = Self.visibility(progress: progress, range: range, isOutgoing: isOutgoing)
		content
			.opacity(visible)
			.scaleEffect(reducesMotion ? 1 : Self.scale(visibility: visible, hidden: hiddenScale), anchor: .leading)
			.offset(x: reducesMotion ? 0 : (1 - visible) * travel)
	}

	/// How much of the content shows at `progress`: 1 fully shown, 0 gone.
	internal static func visibility(
		progress: CGFloat,
		range: ClosedRange<CGFloat>,
		isOutgoing: Bool
	) -> CGFloat {
		let fraction = (progress - range.lowerBound) / (range.upperBound - range.lowerBound)
		let elapsed = min(max(fraction, 0), 1)
		return isOutgoing ? 1 - elapsed : elapsed
	}

	/// Interpolates from full size when shown to `hidden` when gone.
	internal static func scale(
		visibility: CGFloat,
		hidden: CGFloat
	) -> CGFloat {
		hidden + (1 - hidden) * visibility
	}
}

/// One solid page: it enters from the left, so its rail is the last thing to arrive.
internal struct SidebarLibraryPage<Panel: View>: View {
	private let library: SidebarLibrary
	private let panel: Panel

	internal init(
		library: SidebarLibrary,
		panel: Panel
	) {
		self.library = library
		self.panel = panel
	}

	internal var body: some View {
		HStack(spacing: 0) {
			rail
			panelColumn
		}
	}

	private var rail: some View {
		VStack(spacing: 0) {
			Spacer(minLength: BrowserMetrics.Toolbar.height)
			VStack(spacing: BrowserMetrics.Library.tileSpacing) {
				ForEach(library.sections, id: \.self) { section in
					SidebarLibraryTile(
						section: section,
						isSelected: section == library.selection,
						select: { library.select(section) }
					)
				}
			}
			Spacer(minLength: BrowserMetrics.Library.tileSpacing)
			HStack {
				Button { library.setOpen(false) } label: {
					Image(systemName: "arrow.left")
						.font(.system(size: BrowserMetrics.SpaceSwitcher.symbolSize, weight: .medium))
						.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.placeholderOpacity))
				}
				.buttonStyle(BrowserToolbarButtonStyle())
				.help(String.localized(.appUI.library.exit))
				.accessibilityLabel(String.localized(.appUI.library.exit))
				Spacer(minLength: 0)
			}
			.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
			.frame(height: BrowserMetrics.Library.footerHeight)
		}
		.frame(width: BrowserMetrics.Library.railWidth)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.sidebar.library))
	}

	private var panelColumn: some View {
		panel
			.padding(.top, BrowserMetrics.Library.headerInset)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.background(alignment: .leading) {
				// A soft shadow from the rail does most of the work; the line only sharpens its edge.
				LinearGradient(
					colors: [Color.black.opacity(BrowserMetrics.Library.railShadowOpacity), .clear],
					startPoint: .leading,
					endPoint: .trailing
				)
				.frame(width: BrowserMetrics.Library.railShadowWidth)
				.overlay(alignment: .leading) {
					BrowserTheme.libraryTint
						.opacity(BrowserMetrics.Library.railLineOpacity)
						.frame(width: 1)
				}
				.allowsHitTesting(false)
			}
	}
}

private struct SidebarLibraryTile: View {
	private let section: LibrarySection
	private let isSelected: Bool
	private let select: () -> Void

	@SwiftUI.State
	private var isHovered: Bool

	internal init(
		section: LibrarySection,
		isSelected: Bool,
		select: @escaping () -> Void
	) {
		self.section = section
		self.isSelected = isSelected
		self.select = select
		self._isHovered = .init(initialValue: false)
	}

	internal var body: some View {
		Button(action: select) {
			VStack(spacing: BrowserMetrics.Library.labelSpacing) {
				Image(systemName: section.symbol)
					.font(.system(size: BrowserMetrics.Library.symbolSize, weight: .regular))
					.foregroundStyle(BrowserTheme.accent)
					.frame(height: BrowserMetrics.Library.symbolSize)
				Text(section.title)
					.font(.system(
						size: BrowserMetrics.Library.tileFontSize,
						weight: isSelected ? .bold : .semibold
					))
					.foregroundStyle(
						isSelected ? BrowserTheme.text : BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity)
					)
					.lineLimit(1)
					.minimumScaleFactor(0.8)
			}
			.frame(
				width: BrowserMetrics.Library.tileWidth,
				height: BrowserMetrics.Library.tileHeight
			)
			.background(
				BrowserTheme.libraryTint.opacity(fillOpacity),
				in: .rect(cornerRadius: BrowserMetrics.Library.tileCornerRadius, style: .continuous)
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.onHover { isHovered = $0 }
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}

	private var fillOpacity: Double {
		if isSelected { return BrowserMetrics.Library.selectionOpacity }
		return isHovered ? BrowserMetrics.Library.fieldOpacity : 0
	}
}

// MARK: - Panel parts

/// The plain search field shared by the Library and the icon picker.
public struct BrowserSearchField: View {
	private let placeholder: String
	private let query: Binding<String>

	public init(
		placeholder: String,
		query: Binding<String>
	) {
		self.placeholder = placeholder
		self.query = query
	}

	public var body: some View {
		HStack(spacing: BrowserMetrics.Library.fieldIconSpacing) {
			Image(systemName: "magnifyingglass")
				.frame(width: BrowserMetrics.Library.fieldSymbolWidth)
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))

			// Drawn by hand, because a plain text field colors its prompt like its text.
			ZStack(alignment: .leading) {
				if query.wrappedValue.isEmpty {
					Text(placeholder)
						.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))
						.lineLimit(1)
						.allowsHitTesting(false)
						.accessibilityHidden(true)
				}
				TextField(placeholder, text: query, prompt: Text(verbatim: ""))
					.textFieldStyle(.plain)
					.foregroundStyle(BrowserTheme.text)
					.accessibilityLabel(placeholder)
			}
		}
		.font(.system(size: BrowserMetrics.Library.fieldFontSize, weight: .medium))
		.padding(.leading, BrowserMetrics.Library.fieldLeadingPadding)
		.padding(.trailing, BrowserMetrics.URLBar.horizontalPadding)
		.frame(height: BrowserMetrics.Library.fieldHeight)
		.background(
			BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.fieldOpacity),
			in: ArxControlShape()
		)
	}
}

/// The search field every Library panel starts with, beside the panel's own menu.
public struct SidebarLibraryHeader<Menu: View>: View {
	private let placeholder: String
	private let query: Binding<String>
	private let menu: Menu

	public init(
		placeholder: String,
		query: Binding<String>,
		@ViewBuilder menu: () -> Menu
	) {
		self.placeholder = placeholder
		self.query = query
		self.menu = menu()
	}

	public var body: some View {
		HStack(spacing: BrowserMetrics.Library.headerSpacing) {
			BrowserSearchField(placeholder: placeholder, query: query)
			menu
		}
		.padding(.horizontal, BrowserMetrics.Library.headerInset)
		.padding(.bottom, BrowserMetrics.Library.headerBottomPadding)
	}
}

/// A page's icon in a Library row, falling back to a symbol until one loads.
public struct SidebarLibrarySiteIcon: View {
	private let key: SidebarItem.SiteIcon?

	public init(key: SidebarItem.SiteIcon?) {
		self.key = key
	}

	public var body: some View {
		FavoriteSiteIcon(key: key, fallback: "globe", tint: .white)
	}
}

/// The pill beside a Library panel's search field.
public struct SidebarLibraryMenu<Items: View>: View {
	private let title: String
	private let symbol: String
	private let items: Items

	public init(
		title: String,
		symbol: String,
		@ViewBuilder items: () -> Items
	) {
		self.title = title
		self.symbol = symbol
		self.items = items()
	}

	public var body: some View {
		Menu {
			items
		} label: {
			HStack(spacing: BrowserMetrics.Library.menuIconSpacing) {
				Image(systemName: symbol)
					.frame(width: BrowserMetrics.Library.menuSymbolWidth)
				Text(title)
			}
			.font(.system(size: BrowserMetrics.Library.fieldFontSize, weight: .medium))
			.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
			.padding(.leading, BrowserMetrics.Library.menuLeadingPadding)
			.padding(.trailing, BrowserMetrics.Library.menuTrailingPadding)
			.frame(height: BrowserMetrics.Library.fieldHeight)
			.background(
				BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.fieldOpacity),
				in: ArxControlShape()
			)
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
	}
}

public struct SidebarLibraryGroupHeader: View {
	private let title: String

	public init(title: String) {
		self.title = title
	}

	public var body: some View {
		Text(title)
			.font(.system(size: BrowserMetrics.Library.fontSize, weight: .semibold))
			.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity))
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, BrowserMetrics.Library.groupInset)
			.padding(.top, BrowserMetrics.Library.groupTopPadding)
			.padding(.bottom, 2)
			.accessibilityAddTraits(.isHeader)
	}
}

public struct SidebarLibraryRow<Icon: View, Accessory: View>: View {
	private let title: String
	private let subtitle: String
	private let action: () -> Void
	private let icon: Icon
	private let accessory: Accessory

	@SwiftUI.State
	private var isHovered: Bool

	public init(
		title: String,
		subtitle: String,
		action: @escaping () -> Void,
		@ViewBuilder icon: () -> Icon,
		@ViewBuilder accessory: () -> Accessory = { EmptyView() }
	) {
		self.title = title
		self.subtitle = subtitle
		self.action = action
		self.icon = icon()
		self.accessory = accessory()
		self._isHovered = .init(initialValue: false)
	}

	public var body: some View {
		Button(action: action) {
			HStack(spacing: BrowserMetrics.Library.rowIconSpacing) {
				icon
					.frame(
						width: BrowserMetrics.Library.rowIconSize,
						height: BrowserMetrics.Library.rowIconSize
					)
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(.system(size: BrowserMetrics.Library.rowFontSize))
						.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
						.lineLimit(1)
						.truncationMode(.tail)
					Text(subtitle)
						.font(.system(size: BrowserMetrics.Library.fontSize))
						.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))
						.lineLimit(1)
					accessory
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, BrowserMetrics.Row.horizontalPadding)
			.frame(minHeight: BrowserMetrics.Library.rowHeight)
			.background(
				isHovered ? BrowserTheme.hover : .clear,
				in: .rect(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.onHover { isHovered = $0 }
		.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
	}
}

/// Library entries that share a relative age, such as "3 days ago".
public struct SidebarLibraryGroup<Item> {
	public let title: String
	public let items: [Item]

	internal init(
		title: String,
		items: [Item]
	) {
		self.title = title
		self.items = items
	}
}

extension SidebarLibraryGroup {
	/// Groups entries in the order given, which callers keep newest first.
	public static func grouping(
		_ items: [Item],
		date: (Item) -> Date,
		now: Date = .init(),
		calendar: Calendar = .current,
		locale: Locale = .current
	) -> [SidebarLibraryGroup] {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .full
		formatter.locale = locale
		formatter.calendar = calendar

		// Runs in view bodies on every search keystroke: titles are formatted once per age,
		// and each group's items are collected in place.
		var titles: [DateComponents: String] = [:]
		var groups: [(title: String, items: [Item])] = []
		for item in items {
			let age = age(of: date(item), now: now, calendar: calendar)
			let title = titles[age] ?? {
				// "Today" and "yesterday" read well, but "1 week ago" reads better rather than "last week".
				formatter.dateTimeStyle = age.day.map { $0 > -2 } == true ? .named : .numeric
				let title = formatter.localizedString(from: age)
				titles[age] = title
				return title
			}()
			if groups.last?.title == title {
				groups[groups.count - 1].items.append(item)
			} else {
				groups.append((title, [item]))
			}
		}
		return groups.map { SidebarLibraryGroup(title: $0.title, items: $0.items) }
	}

	private static func age(
		of date: Date,
		now: Date,
		calendar: Calendar
	) -> DateComponents {
		let parts = calendar.dateComponents(
			[.year, .month, .weekOfYear, .day],
			from: calendar.startOfDay(for: date),
			to: calendar.startOfDay(for: now)
		)
		if let years = parts.year, years > 0 { return .init(year: -years) }
		if let months = parts.month, months > 0 { return .init(month: -months) }
		if let weeks = parts.weekOfYear, weeks > 0 { return .init(weekOfMonth: -weeks) }
		return .init(day: -max(parts.day ?? 0, 0))
	}
}
