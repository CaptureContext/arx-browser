import SwiftUI

/// A page's favicon at any size, from the environment's ``BrowserSiteIconLoader``, with a
/// symbol until it loads or when the site has none. Chat attachment chips and the chat's
/// attach menu use it for tabs (DEV-798).
public struct BrowserSiteIcon: View {
	private let key: SidebarItem.SiteIcon?
	private let size: CGFloat
	private let fallback: String

	public init(
		key: SidebarItem.SiteIcon?,
		size: CGFloat = 14,
		fallback: String = "globe"
	) {
		self.key = key
		self.size = size
		self.fallback = fallback
	}

	public var body: some View {
		FavoriteSiteIcon(
			key: key,
			fallback: fallback,
			tint: .white,
			size: size,
			fallbackSize: size * 0.85,
			fallbackWeight: .regular
		)
		.frame(width: size, height: size)
	}
}
