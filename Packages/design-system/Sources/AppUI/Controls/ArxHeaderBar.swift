import SwiftUI

/// A modal's or pane's collapsed header bar (DEV-782, DEV-790, DEV-797): a glassy
/// squircle Close or Back button on the leading edge, an optional icon tile, the title in bold
/// with an optional subtitle under it, then raised controls and a squircle search button on the
/// trailing edge. Every raised control on the bar is ``ArxHeaderBarMetrics/controlHeight`` tall.
///
/// The title takes whatever room the controls leave and truncates first: the controls, an
/// expanded search included, always keep their full size.
///
/// It lays out its own row only and draws no background. Pin it over a scroll view with
/// ``SwiftUI/View/arxScrollBar(background:bar:)``, so content scrolls under it edge to edge and
/// the system's soft scroll edge blurs it beneath the bar.
///
/// ```swift
/// ArxHeaderBar(.close { dismiss() }, title: "Search Shortcuts", subtitle: "General") {
///     Button("Add") { add() }
///         .buttonStyle(.arxRaised(.capsule))
///     ArxHeaderSearch("Search built-in bangs", query: $query)
/// }
/// ```
public struct ArxHeaderBar<Trailing: View>: View {
	public typealias Leading = ArxHeaderBarLeading

	private let leading: Leading
	private let icon: ArxHeaderBarIcon?
	private let title: String
	private let subtitle: String?
	private let height: CGFloat
	private let trailing: Trailing
	private var titleReveal: CGFloat

	/// `icon` is a pane's own icon tile, beside its title. `height` is the bar's own: a modal's
	/// by default, or a pane's when it spans the title-bar area.
	public init(
		_ leading: Leading,
		icon: ArxHeaderBarIcon? = nil,
		title: String,
		subtitle: String? = nil,
		height: CGFloat = ArxHeaderBarMetrics.height,
		@ViewBuilder trailing: () -> Trailing
	) {
		self.leading = leading
		self.icon = icon
		self.title = title
		self.subtitle = subtitle
		self.height = height
		self.trailing = trailing()
		self.titleReveal = 1
	}

	/// Shows the icon and title only `progress` of the way, from 0 to 1: a pane whose own header
	/// scrolls under the bar reveals them as it goes, as System Settings does. Hidden, they
	/// leave their room, so the controls never move.
	public func titleReveal(_ progress: CGFloat) -> Self {
		var bar = self
		bar.titleReveal = min(max(progress, 0), 1)
		return bar
	}

	public var body: some View {
		HStack(spacing: ArxHeaderBarMetrics.spacing) {
			leadingButton
			HStack(spacing: ArxHeaderBarMetrics.spacing) {
				if let icon {
					icon
				}
				VStack(alignment: .leading, spacing: 1) {
					Text(title)
						.font(ArxHeaderBarMetrics.titleFont)
						.lineLimit(1)
						.truncationMode(.tail)
						.accessibilityAddTraits(.isHeader)
					if let subtitle, !subtitle.isEmpty {
						Text(verbatim: subtitle)
							.font(ArxHeaderBarMetrics.subtitleFont)
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.tail)
					}
				}
			}
			.accessibilityElement(children: .combine)
			.opacity(titleReveal)
			.offset(y: (1 - titleReveal) * 6)
			.accessibilityHidden(titleReveal < 0.5)

			// The title takes the slack and is the first to give way.
			.frame(maxWidth: .infinity, alignment: .leading)
			.layoutPriority(0)
			HStack(spacing: ArxHeaderBarMetrics.controlSpacing) {
				trailing
			}
			.fixedSize()
			.layoutPriority(1)
		}
		.controlSize(.regular)
		.arxRaisedControlHeight(ArxHeaderBarMetrics.controlHeight)
		.padding(.horizontal, ArxHeaderBarMetrics.horizontalPadding)
		.frame(maxWidth: .infinity)
		.frame(height: height)
	}

	@ViewBuilder
	private var leadingButton: some View {
		switch leading {
		case let .close(action):
			ArxHeaderIconButton(String.localized(.appUI.common.close), systemImage: "xmark", action: action)
				.keyboardShortcut(.cancelAction)

		case let .back(action):
			ArxHeaderIconButton(String.localized(.appUI.navigation.back), systemImage: "chevron.left", action: action)
				.keyboardShortcut("[", modifiers: .command)

		case .none:
			EmptyView()
		}
	}
}

extension ArxHeaderBar where Trailing == EmptyView {
	public init(
		_ leading: Leading,
		icon: ArxHeaderBarIcon? = nil,
		title: String,
		subtitle: String? = nil,
		height: CGFloat = ArxHeaderBarMetrics.height
	) {
		self.init(leading, icon: icon, title: title, subtitle: subtitle, height: height) { EmptyView() }
	}
}

/// A pane's icon beside its title on a header bar: a white glyph on a tile of its tint, in the
/// control shape, as Settings' sidebar draws it, at ``ArxHeaderBarMetrics/iconSize``.
public struct ArxHeaderBarIcon: View {
	private let glyph: ArxGlyph
	private let tint: Color

	public init(
		glyph: ArxGlyph,
		tint: Color
	) {
		self.glyph = glyph
		self.tint = tint
	}

	public init(
		systemImage: String,
		tint: Color
	) {
		self.init(glyph: .symbol(systemImage), tint: tint)
	}

	public var body: some View {
		let side = ArxHeaderBarMetrics.iconSize
		ArxGlyphTile(glyph: glyph, tint: tint, side: side)
	}
}

/// A white glyph on a tile of its tint, in the control shape: Settings' sidebar rows and a
/// pane's header bar icon.
public struct ArxGlyphTile: View {
	private let glyph: ArxGlyph
	private let tint: Color
	private let side: CGFloat

	public init(
		glyph: ArxGlyph,
		tint: Color,
		side: CGFloat
	) {
		self.glyph = glyph
		self.tint = tint
		self.side = side
	}

	public var body: some View {
		Group {
			switch glyph {
			case let .symbol(name):
				Image(systemName: name)
					.font(.system(size: side * 0.55, weight: .semibold))
			case .arxMark:
				ArxMark(width: side * 0.62)
			}
		}
		.foregroundStyle(.white)
		.frame(width: side, height: side)
		.background(tint.gradient, in: ArxControlShape())
		.accessibilityHidden(true)
	}
}

/// What a header bar's leading button does.
public enum ArxHeaderBarLeading {
	/// Close, for a modal. Escape closes it too.
	case close(() -> Void)

	/// Back, for a page inside a pane. ⌘[ goes back too.
	case back(() -> Void)

	/// No button, for a pane's own bar.
	case none
}

/// A header bar's raised icon button, such as Close, Back or a bar's own action: a glassy squircle
/// as tall as the bar's other raised controls (DEV-790, DEV-797).
///
/// It shows the focus ring only when focus came to it from the keyboard, so a sheet's Close
/// button, which the sheet focuses as it opens, doesn't light up (DEV-797).
public struct ArxHeaderIconButton: View {
	private let title: String
	private let systemImage: String
	private let action: () -> Void

	/// `title` is its tooltip and what VoiceOver reads.
	public init(
		_ title: String,
		systemImage: String,
		action: @escaping () -> Void
	) {
		self.title = title
		self.systemImage = systemImage
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.font(.system(size: 14, weight: .medium))
		}
		.buttonStyle(.arxRaised(.square))
		.focusEffectDisabled()
		.help(title)
		.accessibilityLabel(Text(verbatim: title))
	}
}

/// A header bar's search (DEV-790, DEV-797): a glassy squircle with a magnifier that
/// expands into a wide field of the same glass, with continuous corners. ⌘F expands it too.
///
/// It stays expanded while it holds a query. Escape, the clear button, or leaving it empty
/// collapses it back into the button, clearing the query.
public struct ArxHeaderSearch: View {
	private let placeholder: String
	private let query: Binding<String>
	private let width: CGFloat

	@SwiftUI.State
	private var isExpanded: Bool

	@FocusState
	private var isFocused: Bool

	@Environment(\.arxRaisedControlHeight)
	private var raisedHeight: CGFloat?

	/// `isExpanded` opens it from the start, as a snapshot does.
	public init(
		_ placeholder: String,
		query: Binding<String>,
		width: CGFloat = ArxHeaderBarMetrics.searchWidth,
		isExpanded: Bool = false
	) {
		self.placeholder = placeholder
		self.query = query
		self.width = width
		self._isExpanded = .init(initialValue: isExpanded)
	}

	public var body: some View {
		let height = raisedHeight ?? ArxHeaderBarMetrics.controlHeight
		Group {
			if isExpanded || !query.wrappedValue.isEmpty {
				HStack(spacing: 7) {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 13, weight: .medium))
						.foregroundStyle(.secondary)
						.accessibilityHidden(true)

					// Drawn by hand, because a plain text field colors its prompt like its text.
					ZStack(alignment: .leading) {
						if query.wrappedValue.isEmpty {
							Text(verbatim: placeholder)
								.foregroundStyle(.secondary)
								.lineLimit(1)
								.allowsHitTesting(false)
								.accessibilityHidden(true)
						}
						TextField(placeholder, text: query, prompt: Text(verbatim: ""))
							.textFieldStyle(.plain)
							.focused($isFocused)
							.accessibilityLabel(Text(verbatim: placeholder))
							.onKeyPress(.escape) {
								collapse()
								return .handled
							}
					}
					Button(action: collapse) {
						Image(systemName: "xmark.circle.fill")
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.help(String.localized(.appUI.common.closeSearch))
					.accessibilityLabel(Text(localized: .appUI.common.closeSearch))
				}
				.font(.system(size: 13))
				.padding(.leading, 13)
				.padding(.trailing, 10)
				.frame(width: width, height: height)
				.background { ArxGlassTile(cornerRadius: ArxRaisedShape.cornerRadius(forSide: height)) }
				.contentShape(ArxRaisedShape())
				.onTapGesture { isFocused = true }
				.onChange(of: isFocused) { _, focused in
					if !focused, query.wrappedValue.isEmpty { collapse() }
				}
				.transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))

			} else {
				Button(action: expand) {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 14, weight: .medium))
				}
				.buttonStyle(.arxRaised(.square))
				.focusEffectDisabled()
				.help(String.localized(.appUI.common.search))
				.accessibilityLabel(Text(localized: .appUI.common.search))
				.keyboardShortcut("f", modifiers: .command)
				.transition(.opacity)
			}
		}
		.animation(.smooth(duration: 0.22), value: isExpanded)
	}

	private func expand() {
		isExpanded = true
		Task { @MainActor in isFocused = true }
	}

	private func collapse() {
		query.wrappedValue = ""
		isExpanded = false
		isFocused = false
	}
}

public enum ArxHeaderBarMetrics {
	/// A modal's bar. A pane's bar spans the title-bar area and sets its own height.
	public static let height: CGFloat = 56

	public static let horizontalPadding: CGFloat = 14

	/// Between the leading button and the title, and the title and the controls.
	public static let spacing: CGFloat = 10

	/// Between the trailing controls.
	public static let controlSpacing: CGFloat = 6

	/// Every raised control on the bar: the leading squircle, text controls and the search (DEV-790).
	public static let controlHeight: CGFloat = 36

	/// A pane's icon tile beside its title.
	public static let iconSize: CGFloat = 30

	/// An expanded search's width: wide enough to read a query.
	public static let searchWidth: CGFloat = 300

	public static let titleFont: Font = .system(size: 15, weight: .bold)

	public static let subtitleFont: Font = .system(size: 11, weight: .regular)
}
