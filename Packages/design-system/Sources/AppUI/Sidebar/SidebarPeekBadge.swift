import SwiftUI

/// The site a Peek shows, on the tab it was opened from (DEV-1224): while the Peek is open, that
/// tab's row shows the peeked site's favicon at its trailing end, and its Favorite tile a small
/// favicon badge at its top trailing corner.
public struct BrowserPeekedTab: Equatable, Sendable {
	/// The tab the Peek was opened from.
	public var tabID: UUID

	/// The peeked page's icon, `nil` before it has a page.
	public var siteIcon: SidebarItem.SiteIcon?

	/// The peeked page's title, for VoiceOver.
	public var title: String

	/// Drawn until the icon loads or when the site has none, such as the onboarding tour's
	/// sample sites, which name their drawn favicons here.
	public var symbol: String

	public init(
		tabID: UUID,
		siteIcon: SidebarItem.SiteIcon?,
		title: String,
		symbol: String = "globe"
	) {
		self.tabID = tabID
		self.siteIcon = siteIcon
		self.title = title
		self.symbol = symbol
	}

	/// Whether `itemID` is the tab the Peek was opened from.
	public func isOpened(from itemID: SidebarItem.ID) -> Bool {
		itemID == .tab(tabID)
	}
}

extension EnvironmentValues {
	/// The window's open Peek and the tab it came from, set by the window that hosts it.
	@Entry
	public var browserPeekedTab: BrowserPeekedTab? = nil
}

/// The peeked site's favicon on the tab that opened the Peek. Draws nothing for any other item.
internal struct SidebarPeekBadge: View {
	internal enum Placement {
		/// At the trailing end of a tab's row, on a faint rounded square.
		case row

		/// At the trailing end of a Split View member's segment, smaller, as segments are narrow.
		case segment

		/// Over a Favorite tile's top trailing corner, on a dark rounded square.
		case tile
	}

	private let itemID: SidebarItem.ID
	private let placement: Placement

	@Environment(\.browserPeekedTab)
	private var peek

	internal init(
		for itemID: SidebarItem.ID,
		placement: Placement
	) {
		self.itemID = itemID
		self.placement = placement
	}

	internal var body: some View {
		if let peek, peek.isOpened(from: itemID) {
			let metrics = Metrics(placement)
			BrowserSiteIcon(key: peek.siteIcon, size: metrics.iconSize, fallback: peek.symbol)
				.frame(width: metrics.size, height: metrics.size)
				.background(metrics.fill, in: ArxControlShape())
				.overlay {
					if placement == .tile {
						ArxControlShape()
							.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
					}
				}
				.browserShadow(placement == .tile ? .init(opacity: 0.3, radius: 3, y: 1) : .none)
				.transition(.opacity.combined(with: .scale(scale: 0.8)))
				.allowsHitTesting(false)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel(String.localized(.appUI.sidebar.peekBadge(peek.title)))
		}
	}

	private struct Metrics {
		let size: CGFloat
		let iconSize: CGFloat
		let fill: AnyShapeStyle

		init(_ placement: Placement) {
			switch placement {
			case .row:
				size = 24
				iconSize = 14
				fill = AnyShapeStyle(BrowserTheme.text.opacity(0.08))

			case .segment:
				size = 18
				iconSize = 12
				fill = AnyShapeStyle(BrowserTheme.text.opacity(0.08))

			case .tile:
				size = 22
				iconSize = 14
				fill = AnyShapeStyle(Color(white: 0.08))
			}
		}
	}
}
