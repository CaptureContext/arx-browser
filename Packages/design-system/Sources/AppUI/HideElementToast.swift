import BrowserCore
import SwiftUI

/// Hide Element's toast (DEV-1298), at the page's bottom right while the mode is on, on raised
/// glass: what a click does, Undo (⌘Z) and Done (Escape). Return, or its chevron, opens it into
/// the list of the elements hidden on the site, the same entries the site menu's Hidden Elements
/// lists, each with a button that shows it again.
///
/// The list grows upward from the bar, so the bar stays where the pointer left it. Its rows
/// touch, and its highlight is concentric with the toast's corners (DESIGN.md).
public struct HideElementToast: View {
	/// An element hidden on the site.
	public struct Entry: Equatable, Identifiable, Sendable {
		/// Its line of My filters, `site##selector`.
		public var id: String

		/// What the outline's label called it, else its selector.
		public var title: String

		/// Its kind and its selector.
		public var detail: String

		/// An SF Symbol for its kind.
		public var symbol: String

		public init(
			id: String,
			title: String,
			detail: String,
			symbol: String
		) {
			self.id = id
			self.title = title
			self.detail = detail
			self.symbol = symbol
		}
	}

	/// A line under what a click does, in place of the hint.
	public enum Note: Equatable, Sendable {
		/// The last pick went from the page but couldn't be saved.
		case refused
	}

	private let site: String
	private let entries: [Entry]
	private let isExpanded: Bool
	private let selection: Entry.ID?
	private let canUndo: Bool
	private let note: Note?
	private let reloadsWhenDone: Bool
	private let undo: () -> Void
	private let done: () -> Void
	private let toggle: () -> Void
	private let show: (Entry.ID) -> Void

	@State
	private var hovered: Entry.ID?

	public init(
		site: String,
		entries: [Entry],
		isExpanded: Bool,
		selection: Entry.ID? = nil,
		canUndo: Bool,
		note: Note? = nil,
		reloadsWhenDone: Bool = false,
		undo: @escaping () -> Void,
		done: @escaping () -> Void,
		toggle: @escaping () -> Void,
		show: @escaping (Entry.ID) -> Void
	) {
		self.site = site
		self.entries = entries
		self.isExpanded = isExpanded
		self.selection = selection
		self.canUndo = canUndo
		self.note = note
		self.reloadsWhenDone = reloadsWhenDone
		self.undo = undo
		self.done = done
		self.toggle = toggle
		self.show = show
	}

	public var body: some View {
		VStack(spacing: 0) {
			if isExpanded {
				list
				Divider()
					.padding(.horizontal, Metrics.inset)
			}
			bar
		}
		.frame(width: Metrics.width)
		.arxFloatingGlass(cornerRadius: Metrics.cornerRadius)
		.focusEffectDisabled()
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text(localized: .appUI.hideElement.command))
	}

	// MARK: - Bar

	private var bar: some View {
		HStack(spacing: Metrics.spacing) {
			FigmaSymbol(.scope, pointSize: 15)
				.foregroundStyle(Self.red)
			VStack(alignment: .leading, spacing: 1) {
				Text(localized: .appUI.hideElement.toast.title)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(BrowserTheme.text)
				Text(hint)
					.font(.system(size: 11))
					.foregroundStyle(BrowserTheme.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			HStack(spacing: 4) {
				Button(action: toggle) {
					Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
						.font(.system(size: 11, weight: .semibold))
				}
				.buttonStyle(.arxRaised(.square, size: .small))
				.help(String.localized(.appUI.siteMenu.hiddenElements))
				.accessibilityLabel(Text(localized: .appUI.siteMenu.hiddenElements))
				.accessibilityAddTraits(isExpanded ? .isSelected : [])
				Button(action: undo) {
					keyLabel(String.localized(.appUI.menu.undo), key: "⌘Z")
				}
				.buttonStyle(.arxRaised(size: .small))
				.disabled(!canUndo)
				Button(action: done) {
					keyLabel(String.localized(.appUI.common.done), key: "esc")
				}
				.buttonStyle(.arxRaised(size: .small))
			}
			.fixedSize()
		}
		.padding(.leading, Metrics.leadingPadding)
		.padding(.trailing, Metrics.trailingPadding)
		.padding(.vertical, 8)
		.frame(minHeight: Metrics.barHeight)
	}

	private var hint: String {
		if note == .refused { return String.localized(.appUI.hideElement.toast.refused) }
		return isExpanded
		? String.localized(.appUI.hideElement.toast.closeListHint)
		: String.localized(.appUI.hideElement.toast.listHint)
	}

	/// A button's title with its key after it, dimmer, as a menu shows a shortcut.
	private func keyLabel(
		_ title: String,
		key: String
	) -> some View {
		HStack(spacing: 5) {
			Text(verbatim: title)
			Text(verbatim: key)
				.foregroundStyle(BrowserTheme.secondary)
				.accessibilityHidden(true)
		}
		.font(.system(size: 12, weight: .medium))
	}

	// MARK: - List

	private var list: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(localized: .appUI.hideElement.toast.listTitle(site))
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(BrowserTheme.secondary)
				.lineLimit(1)
				.padding(.horizontal, Metrics.leadingPadding)
				.padding(.top, 10)
				.padding(.bottom, 4)
				.accessibilityAddTraits(.isHeader)
			if entries.isEmpty {
				Text(localized: .appUI.hideElement.toast.empty)
					.font(.system(size: 12))
					.foregroundStyle(BrowserTheme.secondary)
					.padding(.horizontal, Metrics.leadingPadding)
					.padding(.vertical, 8)
			} else {
				ScrollViewReader { proxy in
					ScrollView {
						VStack(spacing: 0) {
							ForEach(entries) { entry in
								row(entry)
									.id(entry.id)
							}
						}

						// The list's inset is its content's padding, so the last row scrolls clear.
						.padding(.horizontal, Metrics.inset)
						.padding(.bottom, Metrics.inset / 2)
					}
					.scrollBounceBehavior(.basedOnSize)
					.frame(maxHeight: Metrics.rowHeight * Metrics.visibleRows)
					.fixedSize(horizontal: false, vertical: true)
					.onChange(of: selection) { _, selection in
						guard let selection else { return }
						withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(selection) }
					}
				}
				Text(localized: .appUI.hideElement.toast.listKeys)
					.font(.system(size: 11))
					.foregroundStyle(BrowserTheme.secondary)
					.padding(.horizontal, Metrics.leadingPadding)
					.padding(.top, 2)
					.padding(.bottom, reloadsWhenDone ? 2 : 8)
					.accessibilityHidden(true)
			}
			if reloadsWhenDone {
				Text(localized: .appUI.hideElement.toast.reloadNote)
					.font(.system(size: 11))
					.foregroundStyle(BrowserTheme.secondary)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.horizontal, Metrics.leadingPadding)
					.padding(.bottom, 8)
			}
		}
	}

	private func row(_ entry: Entry) -> some View {
		let isHighlighted = entry.id == selection || entry.id == hovered
		return HStack(spacing: 8) {
			Image(systemName: entry.symbol)
				.font(.system(size: 12))
				.foregroundStyle(BrowserTheme.secondary)
				.frame(width: 18)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 1) {
				Text(verbatim: entry.title)
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(BrowserTheme.text)
					.lineLimit(1)
				Text(verbatim: entry.detail)
					.font(.system(size: 10.5))
					.foregroundStyle(BrowserTheme.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			Button {
				show(entry.id)
			} label: {
				Image(systemName: "eye")
					.font(.system(size: 11, weight: .medium))
			}
			.buttonStyle(.arxRaised(.square, size: .small))
			.help(String.localized(.appUI.hideElement.toast.showAgain))
			.accessibilityLabel(Text(localized: .appUI.siteMenu.showHiddenElementNamed(entry.title)))
		}
		.padding(.horizontal, Metrics.rowPadding)
		.frame(height: Metrics.rowHeight - Metrics.rowGap)
		.background {
			// Concentric with the toast's corners: its radius less the list's inset.
			RoundedRectangle(cornerRadius: Metrics.cornerRadius - Metrics.inset, style: .continuous)
				.fill(isHighlighted ? BrowserTheme.hover : .clear)
		}

		// Rows touch: the gap between highlights is padding inside each row.
		.padding(.vertical, Metrics.rowGap / 2)
		.contentShape(Rectangle())
		.onHover { isHovering in
			if isHovering {
				hovered = entry.id
			} else if hovered == entry.id {
				hovered = nil
			}
		}
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(entry.id == selection ? .isSelected : [])
	}

	/// Hide Element's red: the design system's red accent preset, which reads on light and dark
	/// pages without looking like an error.
	public static let red: Color = {
		let rgb = ChromeAccent.Preset.red.accent
		return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
	}()

	public enum Metrics {
		public static let width: CGFloat = 430
		public static let cornerRadius: CGFloat = 14
		public static let barHeight: CGFloat = 48

		/// The list's inset from the toast's edges.
		public static let inset: CGFloat = 6
		public static let rowHeight: CGFloat = 42
		public static let rowGap: CGFloat = 2
		public static let visibleRows: CGFloat = 6
		internal static let rowPadding: CGFloat = 8
		internal static let spacing: CGFloat = 10
		internal static let leadingPadding: CGFloat = 14
		internal static let trailingPadding: CGFloat = 8

		/// Between the toast and the page's edges.
		public static let edgeInset: CGFloat = 14

		/// How close the outline may come before the toast moves away.
		public static let clearance: CGFloat = 12

		/// How faint the toast gets when the outline is under it in either corner.
		public static let fadedOpacity: Double = 0.6
	}
}

/// Where Hide Element's toast sits (DEV-1298): the bottom right, unless the outlined element is
/// there, when it moves to the bottom left; with the outline at both, it stays and fades, so it
/// never covers what's being chosen. While the pointer is over it, it holds still and solid
/// (DEV-1315), so it never moves out from under a click or fades while it's being read.
public enum HideElementToastPlacement: Equatable, Sendable {
	case trailing
	case leading
	case faded

	/// - Parameters:
	///   - target: The outline's box in the page's points, top-left origin.
	///   - toast: The toast's size.
	///   - page: The page's size.
	///   - current: Where it is now, which it keeps while that's still clear.
	///   - isPointerOver: Whether the pointer is over the toast, which then keeps its place,
	///     solid, whatever is outlined.
	public static func resolve(
		target: CGRect?,
		toast: CGSize,
		page: CGSize,
		current: Self = .trailing,
		isPointerOver: Bool = false
	) -> Self {
		// A faded toast sits at the bottom right, so solid it's there too.
		if isPointerOver { return current == .faded ? .trailing : current }
		guard let target, !target.isEmpty else { return current == .faded ? .trailing : current }

		typealias Metrics = HideElementToast.Metrics
		let y = page.height - Metrics.edgeInset - toast.height
		let trailing = CGRect(x: page.width - Metrics.edgeInset - toast.width, y: y, width: toast.width, height: toast.height)
		let leading = CGRect(x: Metrics.edgeInset, y: y, width: toast.width, height: toast.height)
		func isClear(_ frame: CGRect) -> Bool {
			!frame.insetBy(dx: -Metrics.clearance, dy: -Metrics.clearance).intersects(target)
		}

		if current == .leading, isClear(leading) { return .leading }
		if isClear(trailing) { return .trailing }
		if isClear(leading) { return .leading }
		return .faded
	}
}
