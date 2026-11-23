import Foundation
import SwiftUI

/// What a favorite's hover card adds for its site (DEV-802): unread mail or recent pages.
/// The feature reads it in the favorite's own profile; nothing here fetches.
public struct SidebarSitePreview: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		case mail
		case recentPages
	}

	public struct Item: Identifiable, Equatable, Sendable {
		public var id: String
		public var title: String

		/// A sender, or a page's place on the site.
		public var detail: String?
		public var date: Date?

		public init(
			id: String,
			title: String,
			detail: String? = nil,
			date: Date? = nil
		) {
			self.id = id
			self.title = title
			self.detail = detail
			self.date = date
		}
	}

	public var kind: Kind
	public var items: [Item]

	/// How many there are in all, when the site says; it may be more than the items listed.
	public var total: Int?

	/// The source can't be read right now, such as mail while its page isn't open.
	public var needsOpenPage: Bool

	public init(
		kind: Kind,
		items: [Item] = [],
		total: Int? = nil,
		needsOpenPage: Bool = false
	) {
		self.kind = kind
		self.items = items
		self.total = total
		self.needsOpenPage = needsOpenPage
	}

	/// At most this many items show on a card.
	public static let limit: Int = 5
}

/// The site's rows under a favorite's card: a small heading over a glass tile of raised rows
/// (DEV-1275).
internal struct SidebarSitePreviewSection: View {
	private let preview: SidebarSitePreview

	internal init(preview: SidebarSitePreview) {
		self.preview = preview
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Text(heading)
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(BrowserTheme.secondary)
				Spacer(minLength: 8)
				if let total = preview.total, total > 0 {
					Text(localized: .appUI.sidebar.previewUnreadCount(total))
						.font(.system(size: 11))
						.foregroundStyle(BrowserTheme.secondary)
						.monospacedDigit()
				}
			}
			.padding(.horizontal, 6)
			VStack(alignment: .leading, spacing: SidebarPreviewGlassMetrics.rowSpacing) {
				if let message {
					SidebarPreviewGlassMessage(message)
				} else {
					ForEach(preview.items.prefix(SidebarSitePreview.limit)) { item in
						SidebarPreviewRaisedRow(
							title: item.title,
							detail: sidebarPreviewDetail(item.detail.map { Text($0) }, lastUsed: item.date),
							titleWeight: preview.kind == .mail ? .medium : .regular
						)
					}
				}
			}
			.padding(SidebarPreviewGlassMetrics.tileInset)
			.sidebarPreviewGlass()
		}
		.accessibilityElement(children: .combine)
	}

	private var heading: String {
		switch preview.kind {
		case .mail: String.localized(.appUI.sidebar.previewUnreadMail)
		case .recentPages: String.localized(.appUI.sidebar.previewRecentPages)
		}
	}

	private var message: String? {
		if preview.needsOpenPage { return String.localized(.appUI.sidebar.previewOpenForMail) }
		guard preview.items.isEmpty else { return nil }
		return switch preview.kind {
		case .mail: String.localized(.appUI.sidebar.previewNoUnreadMail)
		case .recentPages: String.localized(.appUI.sidebar.previewNoRecentPages)
		}
	}
}
