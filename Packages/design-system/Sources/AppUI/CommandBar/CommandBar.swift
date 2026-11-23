import BrowserCore
import SwiftUI

public struct CommandBarResult: Identifiable, Equatable, Sendable {
	public let id: String
	public var title: String
	public var subtitle: String
	public var actionTitle: String
	public var symbol: String
	public var tint: SidebarTint

	/// Replaces the action title as the trailing hint on rows that have a binding.
	public var shortcut: String?

	/// A command's alias, which finds it when typed. Shown as a small tag after the title.
	public var alias: String?

	/// A setting's current value, such as On, shown as a small tag after the title (DEV-1015).
	public var state: String?
	public var siteIcon: SidebarItem.SiteIcon?

	/// When `siteIcon` may be fetched from its site if this Mac has no copy (DEV-1311).
	public var siteIconFetch: SiteIconFetch

	/// A disabled row is listed dimmed and does nothing when chosen (DEV-1262).
	public var isEnabled: Bool

	public init(
		id: String,
		title: String,
		subtitle: String = "",
		actionTitle: String,
		symbol: String,
		tint: SidebarTint = .white,
		shortcut: String? = nil,
		alias: String? = nil,
		state: String? = nil,
		siteIcon: SidebarItem.SiteIcon? = nil,
		siteIconFetch: SiteIconFetch = .onScreen,
		isEnabled: Bool = true
	) {
		self.id = id
		self.title = title
		self.subtitle = subtitle
		self.actionTitle = actionTitle
		self.symbol = symbol
		self.tint = tint
		self.shortcut = shortcut
		self.alias = alias
		self.state = state
		self.siteIcon = siteIcon
		self.siteIconFetch = siteIconFetch
		self.isEnabled = isEnabled
	}
}

extension CommandBarResult {
	/// Whether a result's site icon may be fetched from its site when this Mac has no copy of it.
	public enum SiteIconFetch: Equatable, Sendable {
		/// Whenever the row is on screen, as for a tab or a page the person has visited.
		case onScreen

		/// Never: only what's stored for the profile shows, as for a bang's site, which the
		/// person may never have visited. Listing or highlighting bangs asks no site for
		/// anything; the field fetches a bang's icon once its scoped search starts (DEV-1311).
		case storedOnly
	}
}

/// The icon at the leading edge of the command bar's field (DEV-1311): a scoped search's site,
/// else the highlighted result's, read from the same request as its row's, else the bar's own
/// while nothing is highlighted.
public struct CommandBarFieldIcon: Equatable, Sendable {
	public var siteIcon: SidebarItem.SiteIcon?
	public var symbol: String
	public var siteIconFetch: CommandBarResult.SiteIconFetch

	public init(
		siteIcon: SidebarItem.SiteIcon?,
		symbol: String,
		siteIconFetch: CommandBarResult.SiteIconFetch = .onScreen
	) {
		self.siteIcon = siteIcon
		self.symbol = symbol
		self.siteIconFetch = siteIconFetch
	}

	/// The site a scoped search searches, whatever is highlighted; it may be fetched if this Mac
	/// has none. Otherwise the highlighted result's icon, or `fallbackIcon` and `fallbackSymbol`
	/// with nothing highlighted. A result without a symbol shows the magnifying glass.
	public init(
		selected: CommandBarResult?,
		scope: SidebarItem.SiteIcon? = nil,
		fallbackIcon: SidebarItem.SiteIcon? = nil,
		fallbackSymbol: String = Self.searchSymbol
	) {
		if let scope {
			self.init(siteIcon: scope, symbol: Self.searchSymbol)
			return
		}
		guard let selected else {
			self.init(siteIcon: fallbackIcon, symbol: fallbackSymbol)
			return
		}

		self.init(
			siteIcon: selected.siteIcon,
			symbol: selected.symbol.isEmpty ? Self.searchSymbol : selected.symbol,
			siteIconFetch: selected.siteIconFetch
		)
	}

	public static let searchSymbol: String = "magnifyingglass"
}

/// The geometry that separates the in-window palette from the Little Arx launcher.
public struct CommandBarStyle: Equatable, Sendable {
	public static let palette: Self = {
		let metrics = BrowserMetrics.CommandBar.self
		var style = Self(
			cornerRadius: metrics.cornerRadius,
			inputHeight: metrics.inputHeight,
			rowHeight: metrics.rowHeight,
			rowSpacing: metrics.rowSpacing,
			rowHorizontalPadding: metrics.rowHorizontalPadding,
			resultsPadding: metrics.resultsPadding,
			maximumResultsHeight: metrics.maximumResultsHeight,
			borderWidth: metrics.borderWidth,
			showsRowHints: true
		)

		// Inside the bezel, rows concentric with the panel's corners (DEV-1277).
		style.rowCornerRadius = metrics.paletteRowCornerRadius
		style.contentInset = metrics.contentInset
		style.resultsTopPadding = metrics.resultsTopPadding
		return style
	}()

	public static let urlField: Self = {
		let metrics = BrowserMetrics.CommandBar.URLField.self
		var style = Self.palette
		style.cornerRadius = metrics.cornerRadius
		style.inputHeight = metrics.inputHeight
		style.inputFontSize = metrics.inputFontSize
		style.inputHorizontalPadding = metrics.inputHorizontalPadding
		style.rowHeight = metrics.rowHeight
		style.rowSpacing = metrics.rowSpacing
		style.rowHorizontalPadding = metrics.rowHorizontalPadding
		style.resultsPadding = metrics.resultsPadding
		style.showsDivider = false
		style.usesIconTiles = true
		style.rowCornerRadius = BrowserMetrics.CommandBar.rowCornerRadius
		style.contentInset = 0
		style.resultsTopPadding = metrics.resultsPadding
		return style
	}()

	public static let launcher: Self = {
		let metrics = BrowserMetrics.LittleArx.Launcher.self
		let rows = metrics.visibleRows * metrics.rowHeight + (metrics.visibleRows - 1) * metrics.rowSpacing
		return .init(
			cornerRadius: BrowserMetrics.LittleArx.cornerRadius,
			inputHeight: metrics.inputHeight,
			rowHeight: metrics.rowHeight,
			rowSpacing: metrics.rowSpacing,
			rowHorizontalPadding: metrics.rowHorizontalPadding,
			resultsPadding: metrics.resultsPadding,
			maximumResultsHeight: rows + 2 * metrics.resultsPadding,
			borderWidth: metrics.borderWidth,
			showsRowHints: false
		)
	}()

	public var cornerRadius: CGFloat
	public var inputHeight: CGFloat
	public var rowHeight: CGFloat
	public var rowSpacing: CGFloat
	public var rowHorizontalPadding: CGFloat
	public var resultsPadding: CGFloat
	public var maximumResultsHeight: CGFloat
	public var borderWidth: CGFloat
	public var showsRowHints: Bool
	public var inputFontSize: CGFloat
	public var inputHorizontalPadding: CGFloat
	public var showsDivider: Bool
	public var usesIconTiles: Bool
	public var rowCornerRadius: CGFloat

	/// How far the input and the results sit in from the panel's edge: the palette's bezel band.
	public var contentInset: CGFloat

	/// Between the divider and the first result.
	public var resultsTopPadding: CGFloat

	public init(
		cornerRadius: CGFloat,
		inputHeight: CGFloat,
		rowHeight: CGFloat,
		rowSpacing: CGFloat,
		rowHorizontalPadding: CGFloat,
		resultsPadding: CGFloat,
		maximumResultsHeight: CGFloat,
		borderWidth: CGFloat,
		showsRowHints: Bool
	) {
		self.cornerRadius = cornerRadius
		self.inputHeight = inputHeight
		self.rowHeight = rowHeight
		self.rowSpacing = rowSpacing
		self.rowHorizontalPadding = rowHorizontalPadding
		self.resultsPadding = resultsPadding
		self.maximumResultsHeight = maximumResultsHeight
		self.borderWidth = borderWidth
		self.showsRowHints = showsRowHints
		self.inputFontSize = BrowserMetrics.CommandBar.inputFontSize
		self.inputHorizontalPadding = 20
		self.showsDivider = true
		self.usesIconTiles = false
		self.rowCornerRadius = BrowserMetrics.CommandBar.rowCornerRadius
		self.contentInset = 0
		self.resultsTopPadding = resultsPadding
	}
}

public struct CommandBar: View {
	private var style: CommandBarStyle
	private var onClose: (() -> Void)?
	private var placeholder: String?
	private var chip: String?
	private var inputIcon: SidebarItem.SiteIcon?
	private var inputSymbol: String

	/// The site a scoped search searches, shown in the field while the search is scoped (DEV-1311).
	private var scopeIcon: SidebarItem.SiteIcon?
	private var onTab: () -> Bool
	private var onDeleteWhenEmpty: (() -> Void)?
	private var onAskAgent: (() -> Void)?
	private var focusRequest: Int
	private var inputRefocusRequest: Int
	private var onShowActions: (() -> Void)?
	private var actionsKey: String?
	private var actionsPanel: CommandBarActionsContent?

	/// Little Arx's profile picker at the bottom-left corner (DEV-1331); nil everywhere else.
	private var profilePicker: CommandBarProfilePickerContent?
	private var onShortcut: ((String) -> Bool)?
	private var maximumResultsHeight: CGFloat
	private var onFocusChanged: (Bool) -> Void
	private let results: [CommandBarResult]
	private let onQuery: (String) -> Void
	private let onSelect: (String) -> Void
	private var onCommandSelect: ((String) -> Void)?
	private let onDismiss: () -> Void
	private var queryBinding: Binding<String>?
	private var selectionBinding: Binding<String?>?

	private var query: String {
		get { queryBinding?.wrappedValue ?? localQuery }
		nonmutating set {
			if let queryBinding {
				queryBinding.wrappedValue = newValue
			} else {
				localQuery = newValue
			}
		}
	}

	private var selectedID: String? {
		get {
			selectionBinding.map { $0.wrappedValue } ?? localSelectedID
		}
		nonmutating set {
			if let selectionBinding {
				selectionBinding.wrappedValue = newValue
			} else {
				localSelectedID = newValue
			}
		}
	}

	@SwiftUI.State
	private var localQuery: String

	@Environment(\.commandBarIsStatic)
	private var isStatic

	@Environment(\.colorSchemeContrast)
	private var contrast

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var localSelectedID: String?

	/// The rows' actions, which keep their identity while the bar hands them new closures, so a
	/// row is drawn again only when its result or selection changes (DEV-997).
	@SwiftUI.State
	private var rowActions: CommandBarRowActions = .init()

	/// What may scroll the results besides the person (DEV-1265).
	@SwiftUI.State
	private var scrolling: CommandBarListScrolling = .init()

	/// The bar's height, so ⌘K's panel never reaches past its top edge.
	@SwiftUI.State
	private var height: CGFloat = 0

	public init(
		initialQuery: String = "",
		results: [CommandBarResult],
		onQuery: @escaping (String) -> Void,
		onSelect: @escaping (String) -> Void,
		onDismiss: @escaping () -> Void
	) {
		self.style = .palette
		self.onClose = nil
		self.placeholder = nil
		self.chip = nil
		self.inputIcon = nil
		self.inputSymbol = "magnifyingglass"
		self.scopeIcon = nil
		self.onTab = { false }
		self.onDeleteWhenEmpty = nil
		self.onAskAgent = nil
		self.focusRequest = 0
		self.inputRefocusRequest = 0
		self.onShowActions = nil
		self.actionsKey = "⌘K"
		self.actionsPanel = nil
		self.profilePicker = nil
		self.onShortcut = nil
		self.maximumResultsHeight = CommandBarStyle.palette.maximumResultsHeight
		self.onFocusChanged = { _ in }
		self.queryBinding = nil
		self.selectionBinding = nil
		self.results = results
		self.onQuery = onQuery
		self.onSelect = onSelect
		self.onDismiss = onDismiss
		self._localQuery = .init(initialValue: initialQuery)
		self._localSelectedID = .init(initialValue: results.first?.id)
	}

	public init(
		query: Binding<String>,
		selectedID: Binding<String?>,
		results: [CommandBarResult],
		style: CommandBarStyle = .palette,
		placeholder: String? = nil,
		chip: String? = nil,
		inputIcon: SidebarItem.SiteIcon? = nil,
		inputSymbol: String = "magnifyingglass",
		scopeIcon: SidebarItem.SiteIcon? = nil,
		onTab: @escaping () -> Bool = { false },
		onDeleteWhenEmpty: (() -> Void)? = nil,
		onAskAgent: (() -> Void)? = nil,
		focusRequest: Int = 0,
		inputRefocusRequest: Int = 0,
		onShowActions: (() -> Void)? = nil,
		actionsKey: String? = "⌘K",
		actionsPanel: CommandBarActionsContent? = nil,
		profilePicker: CommandBarProfilePickerContent? = nil,
		onShortcut: ((String) -> Bool)? = nil,
		maximumResultsHeight: CGFloat? = nil,
		onClose: (() -> Void)? = nil,
		onFocusChanged: @escaping (Bool) -> Void = { _ in },
		onSelect: @escaping (String) -> Void,
		onCommandSelect: ((String) -> Void)? = nil,
		onDismiss: @escaping () -> Void
	) {
		self.init(
			initialQuery: query.wrappedValue,
			results: results,
			onQuery: { _ in },
			onSelect: onSelect,
			onDismiss: onDismiss
		)
		self.style = style
		self.onClose = onClose
		self.placeholder = placeholder
		self.chip = chip
		self.inputIcon = inputIcon
		self.inputSymbol = inputSymbol
		self.scopeIcon = scopeIcon
		self.onTab = onTab
		self.onDeleteWhenEmpty = onDeleteWhenEmpty
		self.onAskAgent = onAskAgent
		self.focusRequest = focusRequest
		self.inputRefocusRequest = inputRefocusRequest
		self.onShowActions = onShowActions
		self.actionsKey = actionsKey
		self.actionsPanel = actionsPanel
		self.profilePicker = profilePicker
		self.onShortcut = onShortcut
		self.maximumResultsHeight = maximumResultsHeight ?? style.maximumResultsHeight
		self.onFocusChanged = onFocusChanged
		self.queryBinding = query
		self.selectionBinding = selectedID
		self.onCommandSelect = onCommandSelect
	}

	public var body: some View {
		let _ = RenderTrace.body("CommandBar.body")

		// Only the selection's binding, never the whole bar: the relay lives in the bar's state, and
		// a closure holding the bar would keep both alive after it closes.
		let selection: Binding<String?> = selectionBinding ?? $localSelectedID
		let scrolling = scrolling
		let _ = rowActions.update(
			select: onSelect,
			commandSelect: onCommandSelect,
			hover: { id in
				guard scrolling.pointerMoved(over: id), selection.wrappedValue != id else { return }
				selection.wrappedValue = id
			}
		)
		panel
			.animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12), value: actionsPanel != nil)
			.animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12), value: profilePicker?.panel != nil)
			.onChange(of: query) { _, value in onQuery(value) }
			.onChange(of: results) { _, results in
				if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
			}
			.accessibilityElement(children: .contain)
			.accessibilityLabel(String.localized(.appUI.command.accessibility))
	}

	/// The input and the results, inside the bezel.
	private var content: some View {
		VStack(spacing: 0) {
			HStack(spacing: BrowserMetrics.CommandBar.inputSpacing) {
				if let chip {
					chipView(chip)
				} else {
					fieldIconView
				}
				if isStatic {
					CommandBarStaticInput(
						text: query,
						placeholder: placeholder ?? String.localized(.appUI.url.search),
						fontSize: style.inputFontSize
					)
					.frame(height: 28)
				} else {
					input
				}
				if let onAskAgent {
					CommandBarKeyHintButton(
						CommandBarKeyHintButton.agentTitle,
						key: CommandBarKeyHintButton.agentKey,
						keyName: String.localized(.appUI.command.tabKey),
						action: onAskAgent
					)
					.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
				}
				if let onClose { closeButton(onClose) }
			}
			.animation(.easeOut(duration: 0.14), value: onAskAgent != nil)
			.foregroundStyle(BrowserTheme.text.opacity(0.86))
			.padding(.horizontal, style.inputHorizontalPadding)
			.frame(height: style.inputHeight)
			if showsResults {
				resultsList
			} else if profilePicker != nil {
				// Nothing to list, and still the picker's room under the field.
				pickerRoom
			}
		}
		.padding(style.contentInset)
	}

	/// The highlighted result's icon (DEV-1311), from the same request as its row's, in a slot of
	/// fixed size (DEV-1334) so the text never moves as the highlight does, nor while an icon loads.
	private var fieldIconView: some View {
		let slot = BrowserMetrics.CommandBar.fieldIconSlot

		// Centred over the rows' icon column, which sits `resultsPadding + rowHorizontalPadding` in,
		// while the text keeps its place after the slot.
		let column = style.resultsPadding + style.rowHorizontalPadding - style.inputHorizontalPadding
		return fieldIcon(fieldIcon)
			.frame(width: slot, height: slot)
			.offset(x: column)
	}

	@ViewBuilder
	private func fieldIcon(_ icon: CommandBarFieldIcon) -> some View {
		if icon.siteIcon != nil || TourSiteGlyph(symbol: icon.symbol) != nil {
			FavoriteSiteIcon(
				key: icon.siteIcon,
				fallback: icon.symbol,
				tint: .white,
				size: 16,
				fallbackSize: 15,
				fallbackWeight: .medium
			)
			.siteIconsShown(icon.siteIconFetch == .onScreen)
		} else {
			Image(systemName: icon.symbol)
				.font(.system(size: style.inputFontSize < 20 ? 15 : 17, weight: .medium))
		}
	}

	private var fieldIcon: CommandBarFieldIcon {
		.init(
			selected: results.first { $0.id == selectedID },
			scope: scopeIcon,
			fallbackIcon: inputIcon,
			fallbackSymbol: inputSymbol
		)
	}

	/// The Raised look (DEV-1277): a glass panel in a physical bezel, with Actions ⌘K floating
	/// over its bottom-right corner, where ⌘K's search field and list open.
	private var panel: some View {
		content
			.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
			.background { CommandBarRaisedPanel(cornerRadius: style.cornerRadius) }
			.clipShape(.rect(cornerRadius: style.cornerRadius, style: .continuous))
			.overlay(alignment: .bottomTrailing) {
				floatingActions
					.padding(BrowserMetrics.CommandBar.Raised.floatingInset)
			}
			.overlay(alignment: .bottomLeading) {
				floatingProfilePicker
					.padding(BrowserMetrics.CommandBar.Raised.floatingInset)
			}
			.animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsActionsButton)
	}

	private var input: some View {
		CommandInput(
			text: Binding(get: { query }, set: { query = $0 }),
			focusRequest: focusRequest,
			refocusRequest: inputRefocusRequest,
			onFocusChanged: onFocusChanged,
			placeholder: placeholder,
			fontSize: style.inputFontSize,
			onTab: onTab,
			onDeleteWhenEmpty: onDeleteWhenEmpty,
			onMove: moveSelection,
			onShortcut: onShortcut,
			onSubmit: acceptSelection,
			onDismiss: onDismiss
		)
		.frame(height: 28)
	}

	/// An empty query with nothing to suggest is not a failed search.
	private var showsResults: Bool { !results.isEmpty || !query.isEmpty }

	/// The Actions button shows while there's a result to act on (DEV-810), and gives way while the
	/// profile list is open over the bar (DEV-1331).
	private var showsActionsButton: Bool {
		onShowActions != nil && !results.isEmpty && profilePicker?.panel == nil
	}

	/// Whether something floats over the bar's bottom edge, so the last row stops above it.
	private var reservesFloatingRoom: Bool { showsActionsButton || profilePicker != nil }

	/// The profile picker, or its list while open; hidden while ⌘K's actions are open, which take
	/// the bar's bottom edge (DEV-1331).
	@ViewBuilder
	private var floatingProfilePicker: some View {
		if let profilePicker, actionsPanel == nil {
			if let panel = profilePicker.panel {
				let metrics = BrowserMetrics.CommandBar.self
				let room = height - 2 * metrics.Raised.floatingInset
				let minimumHeight = metrics.Actions.searchHeight + metrics.Actions.spacing
					+ metrics.Actions.rowHeight + 2 * metrics.Actions.listInset
				CommandBarActionsPanel(
					panel,
					maximumHeight: max(minimumHeight, min(metrics.Actions.maximumHeight, room)),
					edge: .leading
				)
				.transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
			} else {
				CommandBarFloatingButton(
					title: profilePicker.title,
					symbol: "person.crop.circle",
					key: profilePicker.key,
					accessibilityPrefix: String.localized(.appUI.littleArx.profile),
					action: profilePicker.onToggle
				)
				.transition(.opacity)
			}
		}
	}

	/// Under the field when there are no results: the picker's height and its inset, so it sits
	/// below the field as it does below the results.
	private var pickerRoom: some View {
		let raised = BrowserMetrics.CommandBar.Raised.self
		return VStack(spacing: 0) {
			if style.showsDivider { divider }
			Color.clear
				.frame(height: max(0, raised.floatingHeight + 2 * raised.floatingInset - style.contentInset))
		}
		.accessibilityHidden(true)
	}

	private var divider: some View {
		Rectangle()
			.fill(BrowserTheme.divider.opacity(BrowserMetrics.Section.dividerOpacity))
			.frame(height: BrowserMetrics.Section.dividerThickness)

			// Clear of the bezel's band where the content isn't inset from it.
			.padding(.horizontal, max(0, BrowserMetrics.CommandBar.Raised.bezelWidth - style.contentInset))
	}

	/// Actions ⌘K, or ⌘K's search field with the actions over it while they're open.
	@ViewBuilder
	private var floatingActions: some View {
		if let actionsPanel {
			let metrics = BrowserMetrics.CommandBar.self

			// Never past the bar's top edge.
			let room = height - 2 * metrics.Raised.floatingInset
			let minimumHeight = metrics.Actions.searchHeight + metrics.Actions.spacing
				+ metrics.Actions.rowHeight + 2 * metrics.Actions.listInset
			CommandBarActionsPanel(
				actionsPanel,
				maximumHeight: max(minimumHeight, min(metrics.Actions.maximumHeight, room))
			)
			.transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
		} else if showsActionsButton, let onShowActions {
			CommandBarActionsButton(actionsKey: actionsKey, onShowActions: onShowActions)
				.transition(.opacity)
		}
	}

	private var resultsList: some View {
		VStack(spacing: 0) {
			if style.showsDivider { divider }
			if isStatic {
				resultRows
					.frame(height: min(maximumResultsHeight, resultsHeight), alignment: .top)
					.clipped()
			} else {
				ScrollViewReader { proxy in
					ScrollView {
						resultRows
					}

					// Never, not hidden: hidden still shows them when the Mac is set to always
					// show scroll bars, or while a mouse is connected.
					.scrollIndicators(.never)
					.frame(height: max(0, min(maximumResultsHeight, resultsHeight)))
					.onScrollPhaseChange { _, phase in scrolling.isScrolling = phase.isScrolling }
					.onChange(of: selectedID) { _, id in
						if let id, scrolling.scrolls(to: id) { proxy.scrollToListRow(id) }
					}
				}
			}
		}
	}

	/// The results as DESIGN.md › Lists lays a list out (DEV-1289): rows touch, each holding half
	/// the gap above and below its highlight, and the list's inset is padding on the scrolled
	/// content, with Actions ⌘K's room at the end.
	private var resultRows: some View {
		let top = topContentPadding
		let bottom = bottomContentPadding
		return VStack(spacing: 0) {
			// Each row compares its own result and selection, so moving the selection draws the
			// two rows it leaves and reaches, not every row (DEV-997).
			ForEach(results) { result in
				CommandBarResultRow(
					result: result,
					isSelected: selectedID == result.id,
					style: style,
					actions: rowActions
				)
				.equatable()
				.arxListRowAnchor(result.id, top: top, bottom: bottom)
			}
			if results.isEmpty {
				Text(localized: .appUI.command.noResults)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
					.padding(24)
			}
		}
		.padding(.horizontal, style.resultsPadding)
		.padding(.top, top)
		.padding(.bottom, bottom)
	}

	/// Between the divider and the first row: the first highlight sits `resultsTopPadding` below
	/// the divider, less the row's own half gap.
	private var topContentPadding: CGFloat {
		results.isEmpty
		? style.resultsTopPadding
		: ArxListLayout.contentPadding(inset: style.resultsTopPadding, gap: style.rowSpacing)
	}

	/// Below the last row: the list's inset, or, while Actions ⌘K floats over the results' corner,
	/// the room it takes, so the last highlight stops above it by the button's own offset from the
	/// glass (DEV-1289, DEV-1318). The row anchors reach this padding too, so a row the arrows
	/// move to in the middle stops there as well. In the palette that's 51 points, 56 from the
	/// panel's bottom edge.
	private var bottomContentPadding: CGFloat {
		let raised = BrowserMetrics.CommandBar.Raised.self

		// "No results" keeps clear of Little Arx's profile picker too (DEV-1331).
		guard !results.isEmpty else {
			guard profilePicker != nil else { return style.resultsPadding }
			return max(style.resultsPadding, raised.floatingHeight + raised.floatingInset - style.contentInset)
		}

		let inset = ArxListLayout.contentPadding(inset: style.resultsPadding, gap: style.rowSpacing)
		guard reservesFloatingRoom else { return inset }

		let reserve = ArxListLayout.floatingReserve(
			height: raised.floatingHeight,
			floatingInset: raised.floatingInset,
			contentInset: style.contentInset,
			rowGap: style.rowSpacing
		)
		return max(inset, reserve)
	}

	private func chipView(_ title: String) -> some View {
		let metrics = BrowserMetrics.CommandBar.URLField.self
		return Text(title)
			.font(.system(size: BrowserMetrics.CommandBar.rowFontSize, weight: .medium))
			.foregroundStyle(BrowserTheme.onAccent)
			.lineLimit(1)
			.fixedSize()
			.padding(.horizontal, metrics.chipHorizontalPadding)
			.frame(height: metrics.chipHeight)
			.background(BrowserTheme.accent, in: .capsule)
	}

	private func closeButton(_ action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: "xmark")
				.font(.system(size: 11, weight: .semibold))
				.frame(
					width: BrowserMetrics.LittleArx.Launcher.closeButtonSize,
					height: BrowserMetrics.LittleArx.Launcher.closeButtonSize
				)
				.background(BrowserTheme.fill, in: ArxControlShape())
				.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.help(String.localized(.appUI.common.close))
		.accessibilityLabel(String.localized(.appUI.common.close))
	}

	private var resultsHeight: CGFloat {
		let count = CGFloat(max(1, results.count))
		return count * (style.rowHeight + style.rowSpacing) + topContentPadding + bottomContentPadding
		- (results.isEmpty ? style.rowSpacing : 0)
	}

	private func moveSelection(_ offset: Int) {
		guard !results.isEmpty else { return }
		let current = results.firstIndex(where: { $0.id == selectedID }) ?? 0
		let next = results[min(max(0, current + offset), results.count - 1)]
		scrolling.keyboardMoved(to: next.id)
		selectedID = next.id

		// Focus stays in the input while arrows move the selection, so VoiceOver would
		// otherwise say nothing about the result Return now opens.
		AccessibilityNotification.Announcement(next.accessibilityLabel).post()
	}

	private func acceptSelection() {
		guard let selectedID else { return }
		onSelect(selectedID)
	}
}

extension EnvironmentValues {
	/// Draws the query as text instead of an editable field, and the results without a
	/// scroll view, for demos and offscreen renders: the bar takes no keyboard focus from the
	/// window it sits in, and `ImageRenderer` can draw all of it.
	@Entry
	public var commandBarIsStatic: Bool = false
}

/// The query as plain text with a caret after it, or the placeholder while it's empty.
private struct CommandBarStaticInput: View {
	internal let text: String
	internal let placeholder: String
	internal let fontSize: CGFloat

	internal var body: some View {
		HStack(spacing: 1) {
			if !text.isEmpty {
				Text(verbatim: text)
					.lineLimit(1)
			}
			Rectangle()
				.fill(BrowserTheme.accent)
				.frame(width: 2, height: fontSize + 2)
			if text.isEmpty {
				Text(verbatim: placeholder)
					.lineLimit(1)
					.foregroundStyle(.tertiary)
			}
			Spacer(minLength: 0)
		}
		.font(.system(size: fontSize, weight: .medium))
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(verbatim: text.isEmpty ? placeholder : text))
	}
}

extension CommandBarResult {
	/// The title and what Return does with it, as VoiceOver reads the result.
	internal var accessibilityLabel: String {
		let title = [title, state].compactMap(\.self).joined(separator: ", ")
		return .localized(.appUI.command.resultAccessibility(title, actionTitle))
	}
}

extension CommandBar {
	/// The bar deciding its scrolling with this, so a test can stand in for the pointer, which
	/// can't reach a window off every screen.
	internal func listScrolling(_ scrolling: CommandBarListScrolling) -> Self {
		var bar = self
		bar._scrolling = .init(initialValue: scrolling)
		return bar
	}
}
