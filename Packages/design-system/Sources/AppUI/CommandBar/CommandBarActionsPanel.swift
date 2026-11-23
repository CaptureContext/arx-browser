import BrowserCore
import SwiftUI

/// One of a result's actions as ⌘K's panel lists it (DEV-810).
public struct CommandBarActionItem: Identifiable, Equatable, Sendable {
	public let id: String
	public var title: String
	public var symbol: String

	/// The key that runs it from the bar, such as ↩ for the result's own action.
	public var shortcut: String?
	public var isDestructive: Bool

	public init(
		id: String,
		title: String,
		symbol: String,
		shortcut: String? = nil,
		isDestructive: Bool = false
	) {
		self.id = id
		self.title = title
		self.symbol = symbol
		self.shortcut = shortcut
		self.isDestructive = isDestructive
	}
}

/// What the bar needs to show ⌘K's panel over its bottom-right corner.
public struct CommandBarActionsContent {
	/// The result the actions belong to, which VoiceOver names with them.
	public var title: String
	public var query: Binding<String>
	public var selectedID: Binding<String?>
	public var actions: [CommandBarActionItem]
	public var onSelect: (String) -> Void
	public var onDismiss: () -> Void

	/// An action's key pressed in the search field; returns whether it ran one.
	public var onShortcut: ((String) -> Bool)?

	/// The search field's prompt; "Search actions…" when nil.
	public var searchPlaceholder: String?

	/// What VoiceOver calls the panel; "Actions for the selected result" when nil.
	public var accessibilityLabel: String?

	public init(
		title: String,
		query: Binding<String>,
		selectedID: Binding<String?>,
		actions: [CommandBarActionItem],
		onSelect: @escaping (String) -> Void,
		onDismiss: @escaping () -> Void,
		onShortcut: ((String) -> Bool)? = nil,
		searchPlaceholder: String? = nil,
		accessibilityLabel: String? = nil
	) {
		self.title = title
		self.query = query
		self.selectedID = selectedID
		self.actions = actions
		self.onSelect = onSelect
		self.onDismiss = onDismiss
		self.onShortcut = onShortcut
		self.searchPlaceholder = searchPlaceholder
		self.accessibilityLabel = accessibilityLabel
	}
}

/// A result's actions, searched by typing and chosen with the arrow keys and Return. In the
/// Raised look (DEV-1277) Actions ⌘K opens into the actions' search field, and the list floats
/// above it as the destination picker draws its profiles: raised glass on the chrome, plain
/// glyphs, and the raised group's selected squircle for the highlight. The two are one surface
/// with one shadow. Esc closes it. Little Arx's profile picker (DEV-1331) is the same panel at
/// the bar's bottom-left corner, listing profiles.
public struct CommandBarActionsPanel: View {
	private let content: CommandBarActionsContent
	private let maximumHeight: CGFloat

	/// The corner it opens from, which its field and list line up with.
	private let edge: HorizontalEdge

	@Environment(\.commandBarIsStatic)
	private var isStatic

	@Environment(\.colorSchemeContrast)
	private var contrast

	/// What may scroll the actions besides the person (DEV-1265).
	@State
	private var scrolling: CommandBarListScrolling = .init()

	public init(
		_ content: CommandBarActionsContent,
		maximumHeight: CGFloat = BrowserMetrics.CommandBar.Actions.maximumHeight,
		edge: HorizontalEdge = .trailing
	) {
		self.content = content
		self.maximumHeight = maximumHeight
		self.edge = edge
	}

	private typealias Metrics = BrowserMetrics.CommandBar.Actions

	private var actions: [CommandBarActionItem] { content.actions }

	public var body: some View {
		VStack(alignment: edge == .leading ? .leading : .trailing, spacing: Metrics.spacing) {
			list
			searchField
		}
		.frame(width: Metrics.width)

		// One shadow for the list and the field, so neither falls on the other.
		.compositingGroup()
		.shadow(color: ArxRaisedPalette.shadow, radius: 5, y: 2)
		.browserShadow(BrowserMetrics.CommandBar.Raised.floatingShadow)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(content.accessibilityLabel ?? String.localized(.appUI.command.actionsAccessibility))
		.accessibilityValue(Text(verbatim: content.title))
	}

	private var list: some View {
		let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
		return Group {
			if isStatic {
				rows
			} else {
				ScrollViewReader { proxy in
					ScrollView { rows }
						.scrollIndicators(.never)
						.frame(maxHeight: max(0, maximumHeight - Metrics.searchHeight - Metrics.spacing))
						.fixedSize(horizontal: false, vertical: true)
						.onScrollPhaseChange { _, phase in scrolling.isScrolling = phase.isScrolling }
						.onChange(of: content.selectedID.wrappedValue) { _, id in
							if let id, scrolling.scrolls(to: id) { proxy.scrollToListRow(id) }
						}
				}
			}
		}
		.background {
			CommandBarRaisedGlass(shape: shape, cornerRadius: Metrics.cornerRadius, castsShadow: false)
		}
		.clipShape(shape)
	}

	private var placeholder: String {
		content.searchPlaceholder ?? String.localized(.appUI.command.actionsSearch)
	}

	private var searchField: some View {
		HStack(spacing: 7) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 13, weight: .medium))
				.foregroundStyle(BrowserTheme.secondary)
				.accessibilityHidden(true)
			if isStatic {
				Text(
					verbatim: content.query.wrappedValue.isEmpty
					? placeholder
					: content.query.wrappedValue
				)
				.foregroundStyle(content.query.wrappedValue.isEmpty ? AnyShapeStyle(BrowserTheme.secondary) : AnyShapeStyle(.primary))
				.lineLimit(1)
				Spacer(minLength: 0)
			} else {
				CommandInput(
					text: content.query,
					focusRequest: 0,
					onFocusChanged: { _ in },
					placeholder: placeholder,
					fontSize: 13,
					// Tab stays in the panel.
					onTab: { true },
					onMove: move,
					onShortcut: content.onShortcut,
					onSubmit: submit,
					onDismiss: content.onDismiss
				)
			}
		}
		.font(.system(size: 13))
		.padding(.leading, 13)
		.padding(.trailing, 10)
		.frame(height: Metrics.searchHeight)
		.background {
			CommandBarRaisedGlass(
				shape: ArxRaisedShape(),
				cornerRadius: ArxRaisedShape.cornerRadius(forSide: Metrics.searchHeight),
				castsShadow: false
			)
		}
	}

	/// DESIGN.md › Lists (DEV-1289): rows touch, each holding half the gap around its highlight,
	/// and the tile's inset is padding on the scrolled content, which scrolling to the first or
	/// last action brings in with it.
	private var rows: some View {
		let padding = actions.isEmpty
		? Metrics.listInset
		: ArxListLayout.contentPadding(inset: Metrics.listInset, gap: Metrics.rowSpacing)
		return VStack(spacing: 0) {
			ForEach(actions) { action in
				row(action).arxListRowAnchor(action.id, top: padding, bottom: padding)
			}
			if actions.isEmpty {
				Text(localized: .appUI.command.noActions)
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
					.frame(height: Metrics.rowHeight)
			}
		}
		.padding(.horizontal, Metrics.listInset)
		.padding(.vertical, padding)
	}

	private func row(_ action: CommandBarActionItem) -> some View {
		let highlighted = action.id == content.selectedID.wrappedValue

		// Plain glyphs as the destination picker's rows (DEV-1277); red marks a destructive one.
		let tint = action.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(BrowserTheme.text.opacity(0.85))
		return Button { content.onSelect(action.id) } label: {
			HStack(spacing: 6) {
				Image(systemName: action.symbol)
					.font(.system(size: Metrics.glyphSize, weight: .medium))
					.foregroundStyle(tint)
					.frame(width: Metrics.tileSize, height: Metrics.tileSize)
				Text(action.title)
					.lineLimit(1)
					.foregroundStyle(tint)
				Spacer(minLength: 8)
				if let shortcut = action.shortcut {
					Text(verbatim: shortcut)
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.State.opacity(0.62, contrast: contrast)))
						.padding(.horizontal, 6)
						.frame(minWidth: Metrics.keycapHeight, minHeight: Metrics.keycapHeight)
						.background(BrowserTheme.text.opacity(0.06), in: ArxControlShape())
						.accessibilityHidden(true)
				}
			}
			.font(.system(size: 13, weight: .medium))
			.padding(.leading, 6)
			.padding(.trailing, (Metrics.rowHeight - Metrics.keycapHeight) / 2)
			.frame(height: Metrics.rowHeight)
			.background { highlight(highlighted) }
			.arxListRow(gap: Metrics.rowSpacing)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.onContinuousHover { phase in
			guard
				case .active = phase,
				scrolling.pointerMoved(over: action.id),
				content.selectedID.wrappedValue != action.id
			else { return }

			content.selectedID.wrappedValue = action.id
		}
		.accessibilityLabel(action.title)
		.accessibilityAddTraits(highlighted ? .isSelected : [])
	}

	/// The highlighted action: the raised group's selected squircle, concentric with the list's
	/// corners.
	@ViewBuilder
	private func highlight(_ isHighlighted: Bool) -> some View {
		if isHighlighted {
			let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius - Metrics.listInset, style: .continuous)
			shape
				.fill(CommandBarGlassPalette.selectedFill)
				.overlay { shape.strokeBorder(CommandBarGlassPalette.selectedEdge, lineWidth: 0.5) }
		}
	}

	private func move(_ offset: Int) {
		guard !actions.isEmpty else { return }

		let current = actions.firstIndex { $0.id == content.selectedID.wrappedValue } ?? -offset
		let next = actions[min(max(current + offset, 0), actions.count - 1)]
		scrolling.keyboardMoved(to: next.id)
		content.selectedID.wrappedValue = next.id
		AccessibilityNotification.Announcement(next.title).post()
	}

	private func submit() {
		guard let id = content.selectedID.wrappedValue ?? actions.first?.id else { return }
		content.onSelect(id)
	}
}
