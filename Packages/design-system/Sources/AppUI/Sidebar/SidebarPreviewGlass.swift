import SwiftUI

/// The raised glass hover previews are drawn in (DEV-1275), after the Destination Picker's
/// compact version: no panel, only glass pieces floating beside the row. Each piece is an
/// ``ArxGlassTile`` on its own piece of the sidebar's chrome background, so it reads the same
/// over any page, light or dark.
internal enum SidebarPreviewGlassMetrics {
	/// A tile holding a picture, rows or a tab's details.
	internal static let tileRadius: CGFloat = 14

	/// Between a tile's edge and what it holds: a picture or a row's inset squircle.
	internal static let tileInset: CGFloat = ArxRaisedPalette.inset

	/// Between the floating pieces.
	internal static let spacing: CGFloat = 8

	/// A search field's and a Close button's height.
	internal static let controlHeight: CGFloat = ArxFloatingGlass.controlHeight
	internal static let rowHeight: CGFloat = 40
	internal static let rowSpacing: CGFloat = 2
	internal static let folderWidth: CGFloat = 300
	internal static let tabWidth: CGFloat = 264

	/// A folder's rows scroll past this.
	internal static let listMaxHeight: CGFloat = 360

	/// Room around the pieces inside the panel, so their shadows aren't cut off.
	internal static let shadowMargin: CGFloat = 14
	internal static let shadow: BrowserShadow = ArxFloatingGlass.shadow

	internal static var rowRadius: CGFloat {
		ArxRaisedPalette.insetRadius(tileRadius: tileRadius)
	}
}

extension View {
	/// Puts this on raised glass over its own piece of the chrome background, with a soft shadow.
	internal func sidebarPreviewGlass(
		cornerRadius: CGFloat = SidebarPreviewGlassMetrics.tileRadius
	) -> some View {
		arxFloatingGlass(cornerRadius: cornerRadius)
	}
}

/// A row in a preview's glass tile, after the Destination Picker's raised rows: an icon, a title
/// and a line under it. Selected draws the darker edged inset squircle, as Return would open it.
internal struct SidebarPreviewRaisedRow<Icon: View>: View {
	private let title: String
	private let detail: Text?
	private let titleWeight: Font.Weight
	private let isSelected: Bool
	private let icon: Icon?

	internal init(
		title: String,
		detail: Text?,
		titleWeight: Font.Weight = .medium,
		isSelected: Bool = false,
		@ViewBuilder icon: () -> Icon
	) {
		self.title = title
		self.detail = detail
		self.titleWeight = titleWeight
		self.isSelected = isSelected
		self.icon = icon()
	}

	internal var body: some View {
		let shape = RoundedRectangle(cornerRadius: SidebarPreviewGlassMetrics.rowRadius, style: .continuous)
		HStack(spacing: 8) {
			if let icon {
				icon.frame(width: 20)
			}
			VStack(alignment: .leading, spacing: 0) {
				Text(title)
					.font(.system(size: 13, weight: titleWeight))
					.foregroundStyle(BrowserTheme.text.opacity(0.85))
					.lineLimit(1)
					.truncationMode(.tail)
				if let detail {
					detail
						.font(.system(size: 11))
						.foregroundStyle(BrowserTheme.secondary)
						.lineLimit(1)
						.truncationMode(.tail)
				}
			}
			Spacer(minLength: 0)
		}
		.padding(.leading, icon == nil ? 10 : 6)
		.padding(.trailing, 10)
		.frame(minHeight: SidebarPreviewGlassMetrics.rowHeight)
		.background {
			if isSelected {
				shape
					.fill(ArxRaisedPalette.selectedFill)
					.overlay { shape.strokeBorder(ArxRaisedPalette.selectedEdge, lineWidth: 0.5) }
			}
		}
		.contentShape(shape)
	}
}

extension SidebarPreviewRaisedRow where Icon == EmptyView {
	internal init(
		title: String,
		detail: Text?,
		titleWeight: Font.Weight = .medium
	) {
		self.title = title
		self.detail = detail
		self.titleWeight = titleWeight
		self.isSelected = false
		self.icon = nil
	}
}

/// A glass tile's message in place of its rows, such as an empty folder's.
internal struct SidebarPreviewGlassMessage: View {
	private let text: String

	internal init(_ text: String) {
		self.text = text
	}

	internal var body: some View {
		Text(text)
			.font(.system(size: 12))
			.foregroundStyle(BrowserTheme.secondary)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity)
			.padding(.horizontal, 10)
			.padding(.vertical, 12)
	}
}

/// "site · last use", or whichever of the two there is.
internal func sidebarPreviewDetail(
	_ lead: Text?,
	lastUsed: Date?
) -> Text? {
	let date: Text? = lastUsed.map { Text($0, format: .relative(presentation: .named)) }
	switch (lead, date) {
	case let (lead?, date?): return lead + Text(verbatim: " · ") + date
	case let (lead?, nil): return lead
	case let (nil, date?): return date
	case (nil, nil): return nil
	}
}
