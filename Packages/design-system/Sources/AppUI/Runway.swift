import BrowserCore
import SwiftUI

/// A profile the Runway offers, with the space the link would open in: the profile's most
/// recent one.
public struct RunwayOption: Identifiable, Equatable, Sendable {
	public let id: Profile.ID
	public let name: String
	public let spaceName: String
	public let spaceIcon: String?

	public init(
		id: Profile.ID,
		name: String,
		spaceName: String,
		spaceIcon: String? = nil
	) {
		self.id = id
		self.name = name
		self.spaceName = spaceName
		self.spaceIcon = spaceIcon
	}
}

/// The Runway: the panel at the pointer that asks which profile a link from another app opens
/// in (DEV-858), in the AI chat's and Settings' raised glass.
///
/// A glass search field and Close sit over a glass tile of profiles. Each row is an
/// ``ArxRaisedButtonStyle/item``: hovering lights an inset squircle, pressing darkens it, and the
/// row Return opens is the darker selected squircle, which the arrow keys move without drawing
/// a focus ring. ⌘1–⌘9 open the first nine. The regular Runway is a panel that also names the link
/// and the keys; the compact one is only its controls, each on its own glass with no panel
/// behind them.
///
/// The view only draws. Its owner keeps the query and selection, gives the search field the
/// keyboard and answers the keys.
public struct RunwayView: View {
	private let appearance: RunwayAppearance
	private let url: URL
	private let options: [RunwayOption]
	private let selectedID: Profile.ID?
	private let query: Binding<String>
	private let isSearching: FocusState<Bool>.Binding
	private let onOpen: (Profile.ID) -> Void
	private let onDrop: () -> Void

	/// Rows drawn hovered or pressed, for snapshots.
	private var rowStates: [Profile.ID: ArxControlStateOverride] = [:]

	/// `options` are the ones the query leaves.
	public init(
		appearance: RunwayAppearance,
		url: URL,
		options: [RunwayOption],
		selectedID: Profile.ID?,
		query: Binding<String>,
		isSearching: FocusState<Bool>.Binding,
		onOpen: @escaping (Profile.ID) -> Void,
		onDrop: @escaping () -> Void
	) {
		self.appearance = appearance
		self.url = url
		self.options = options
		self.selectedID = selectedID
		self.query = query
		self.isSearching = isSearching
		self.onOpen = onOpen
		self.onDrop = onDrop
	}

	private typealias Metrics = BrowserMetrics.LittleArx.Runway

	public var body: some View {
		switch appearance {
		case .regular: regular
		case .compact: compact
		}
	}

	private var regular: some View {
		VStack(alignment: .leading, spacing: Metrics.spacing) {
			HStack(spacing: Metrics.spacing) {
				VStack(alignment: .leading, spacing: 0) {
					Text(localized: .appUI.routing.pickProfile)
						.font(.system(size: 13, weight: .medium))
						.foregroundStyle(BrowserTheme.text.opacity(0.85))
					Text(verbatim: Self.address(url))
						.font(.system(size: 11))
						.foregroundStyle(BrowserTheme.secondary)
						.truncationMode(.middle)
						.help(url.absoluteString)
				}
				.lineLimit(1)
				.padding(.leading, 6)
				Spacer(minLength: 0)
				closeButton
			}
			searchField
			profiles
			HStack(spacing: 12) {
				keyHint("return", String.localized(.appUI.routing.openLink))
				keyHint("esc", String.localized(.appUI.routing.dropLink))
			}
			.padding(.horizontal, 6)
		}
		.padding(Metrics.panelPadding)
		.frame(width: Metrics.regularWidth)
		.background { BrowserChromeBackground(textured: false) }
		.clipShape(.rect(cornerRadius: Metrics.panelCornerRadius, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous)
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: 1)
		}
		.browserShadow(BrowserMetrics.FloatingSidebar.shadow)
		.arxRaisedControlHeight(Metrics.controlHeight)
	}

	private var compact: some View {
		VStack(spacing: Metrics.spacing) {
			HStack(spacing: Metrics.compactControlSpacing) {
				searchField
					.background { Self.backing(ArxRaisedShape()) }
				closeButton
					.background { Self.backing(ArxRaisedShape()) }
					.arxRaisedControlHeight(Metrics.compactCloseSize)
			}
			profiles
				.background {
					Self.backing(RoundedRectangle(cornerRadius: Metrics.tileCornerRadius, style: .continuous))
				}
		}
		.frame(width: Metrics.compactWidth)
		.arxRaisedControlHeight(Metrics.controlHeight)
	}

	/// The chrome behind a compact control's glass, so the glass reads the same over any page,
	/// with the shadow a panel would cast.
	private static func backing(_ shape: some Shape) -> some View {
		BrowserChromeBackground(textured: false)
			.clipShape(shape)
			.browserShadow(BrowserMetrics.FloatingSidebar.shadow)
	}

	// MARK: - Controls

	private var closeButton: some View {
		Button(action: onDrop) {
			Image(systemName: "xmark")
				.font(.system(size: 14, weight: .medium))
		}
		.buttonStyle(.arxRaised(.square))
		.focusable(false)
		.help(String.localized(.appUI.routing.dropLink))
		.accessibilityLabel(Text(localized: .appUI.routing.dropLink))
	}

	/// The glass of ``ArxHeaderSearch``, without its collapsing: the Runway's field keeps the
	/// keyboard while the Runway is open, and Esc drops the link instead of clearing it.
	private var searchField: some View {
		HStack(spacing: 7) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 13, weight: .medium))
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)

			// Drawn by hand, because a plain text field colors its prompt like its text.
			ZStack(alignment: .leading) {
				if query.wrappedValue.isEmpty {
					Text(localized: .appUI.routing.searchProfiles)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.allowsHitTesting(false)
						.accessibilityHidden(true)
				}
				TextField(String.localized(.appUI.routing.searchProfiles), text: query, prompt: Text(verbatim: ""))
					.textFieldStyle(.plain)
					.focused(isSearching)
					.accessibilityLabel(Text(localized: .appUI.routing.searchProfiles))
			}
			if !query.wrappedValue.isEmpty {
				Button {
					query.wrappedValue = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.focusable(false)
				.help(String.localized(.appUI.common.closeSearch))
				.accessibilityLabel(Text(localized: .appUI.common.closeSearch))
			}
		}
		.font(.system(size: 13))
		.padding(.leading, 13)
		.padding(.trailing, 10)
		.frame(maxWidth: .infinity)
		.frame(height: Metrics.controlHeight)
		.background { ArxGlassTile(cornerRadius: ArxRaisedShape.cornerRadius(forSide: Metrics.controlHeight)) }
		.contentShape(ArxRaisedShape())
		.onTapGesture { isSearching.wrappedValue = true }
	}

	private func keyHint(
		_ key: String,
		_ title: String
	) -> some View {
		HStack(spacing: 5) {
			ChromeKeyHint(key)
			Text(verbatim: title)
				.font(.system(size: 11))
				.foregroundStyle(BrowserTheme.secondary)
		}
	}

	// MARK: - Profiles

	private var profiles: some View {
		let shape = RoundedRectangle(cornerRadius: Metrics.tileCornerRadius, style: .continuous)
		return Group {
			if options.isEmpty {
				empty
			} else if options.count > Metrics.visibleRows {
				ScrollViewReader { proxy in
					ScrollView {
						rows
					}
					.scrollIndicators(.never)
					.frame(height: Self.listHeight(rows: Metrics.visibleRows))
					.onChange(of: selectedID) { _, id in
						guard let id else { return }
						withAnimation(.easeOut(duration: 0.12)) { proxy.scrollToListRow(id) }
					}
				}
			} else {
				rows
			}
		}
		.background { ArxGlassTile(cornerRadius: Metrics.tileCornerRadius) }
		.clipShape(shape)
	}

	/// DESIGN.md › Lists (DEV-1289): rows touch, each holding half the gap around its squircle,
	/// and the tile's inset is padding on the scrolled content, which scrolling to a row brings in
	/// with it.
	private var rows: some View {
		let padding = ArxListLayout.contentPadding(inset: Metrics.tileInset, gap: Metrics.rowSpacing)
		return VStack(spacing: 0) {
			ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
				row(option, number: index + 1)
					.arxListRow(gap: Metrics.rowSpacing)
					.arxListRowAnchor(option.id, top: padding, bottom: padding)
			}
		}
		.padding(.horizontal, Metrics.tileInset)
		.padding(.vertical, padding)
	}

	private func row(
		_ option: RunwayOption,
		number: Int
	) -> some View {
		let isSelected = option.id == selectedID

		// The item style pads its label at both sides; the row's own insets are measured from its edge.
		let itemPadding = ArxRaisedPalette.itemPadding(.regular)
		return Button { onOpen(option.id) } label: {
			HStack(spacing: Metrics.rowIconSpacing) {
				SpaceIconImage(rawValue: option.spaceIcon ?? SpaceIcon.dot.rawValue)
					.font(.system(size: 13, weight: .medium))
					.frame(width: Metrics.rowIconSize, height: Metrics.rowIconSize)
				VStack(alignment: .leading, spacing: 0) {
					Text(verbatim: option.name)
						.font(.system(size: 13, weight: .medium))
					Text(verbatim: option.spaceName)
						.font(.system(size: 11))
						.foregroundStyle(BrowserTheme.secondary)
				}
				.lineLimit(1)
				.frame(maxWidth: .infinity, alignment: .leading)
				if number <= Metrics.numberedRows {
					Self.shortcut(number)
				}
			}
			.padding(.leading, Metrics.rowLeadingInset - itemPadding)
			.padding(.trailing, Metrics.shortcutInset - itemPadding)
			.frame(maxWidth: .infinity)
		}
		.buttonStyle(.arxRaised(.item, isSelected: isSelected))
		.controlSize(.regular)
		.focusable(false)
		.arxControlState(rowStates[option.id] ?? .init())
		.arxRaisedControlHeight(Metrics.rowHeight + 2 * Metrics.tileInset)
		.accessibilityLabel(Text(verbatim: "\(option.name), \(option.spaceName)"))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}

	/// A row's ⌘1–⌘9: `ChromeKeyHint`'s chip, as wide for any digit, its text centered, and
	/// rounded to sit concentric in the row's corner.
	private static func shortcut(_ number: Int) -> some View {
		Text(verbatim: "⌘\(number)")
			.font(.system(size: 11, weight: .medium))
			.foregroundStyle(BrowserTheme.secondary)
			.monospacedDigit()
			.fixedSize()
			.frame(minWidth: Metrics.shortcutTextWidth)
			.padding(.horizontal, 5)
			.frame(height: Metrics.shortcutHeight)
			.background(.primary.opacity(0.07), in: .rect(cornerRadius: Metrics.shortcutCornerRadius, style: .continuous))
			.accessibilityHidden(true)
	}

	private var empty: some View {
		VStack(spacing: 2) {
			Text(localized: .appUI.routing.noProfileMatches(query.wrappedValue))
				.font(.system(size: 13, weight: .medium))
				.foregroundStyle(BrowserTheme.text.opacity(0.85))
			Text(localized: .appUI.routing.escapeDropsLink)
				.font(.system(size: 11))
				.foregroundStyle(BrowserTheme.secondary)
		}
		.lineLimit(1)
		.padding(.vertical, 14)
		.padding(.horizontal, 10)
		.frame(maxWidth: .infinity)
	}

	/// Draws these rows hovered or pressed. For snapshots only.
	internal func rowStates(_ states: [Profile.ID: ArxControlStateOverride]) -> Self {
		var view = self
		view.rowStates = states
		return view
	}

	// MARK: - Layout

	/// The tile's height for `rows` rows, inset included.
	public static func listHeight(rows: Int) -> CGFloat {
		let rows = CGFloat(max(rows, 1))
		return rows * Metrics.rowHeight + (rows - 1) * Metrics.rowSpacing + 2 * Metrics.tileInset
	}

	/// The link without its scheme, as the address bar shows it.
	private static func address(_ url: URL) -> String {
		guard let host = url.host() else { return url.absoluteString }
		let path = url.path()
		return path.isEmpty || path == "/" ? host : host + path
	}
}
