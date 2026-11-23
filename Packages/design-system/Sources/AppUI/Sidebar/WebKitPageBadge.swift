import SwiftUI

/// The small Safari compass at the bottom right of a WebKit page's icon (DEV-877), on tab rows and
/// Favorites tiles alike (DEV-1242): the blue compass on a squircle of the window's background, so
/// it reads over any icon.
internal struct WebKitPageBadge: View {
	internal var body: some View {
		// Whole points only: the compass, its backing and the offset all land on pixel edges, so
		// the backing is equally wide on every side. A font-sized symbol or a fractional backing
		// put the compass half a pixel off its centre.
		Image(systemName: "safari.fill")
			.resizable()
			.scaledToFit()
			.foregroundStyle(.white, .blue)
			.frame(width: Self.compassSize, height: Self.compassSize)
			.background(
				RoundedRectangle(cornerRadius: Self.backingCornerRadius, style: .continuous)
					.fill(.background)
					.padding(-Self.backingInset)
			)
			.offset(x: Self.offset, y: Self.offset)
			.help(String.localized(.appUI.sidebar.webKitPage))
			.accessibilityElement()
			.accessibilityLabel(Text(localized: .appUI.sidebar.webKitPage))
	}

	internal static let compassSize: CGFloat = 8

	/// How far the backing reaches past the compass on each side.
	internal static let backingInset: CGFloat = 1

	/// How far the badge sits past the icon's bottom-right corner.
	internal static let offset: CGFloat = 3

	internal static var backingSize: CGFloat { compassSize + 2 * backingInset }

	/// A quarter of the backing's side, drawn continuous.
	internal static var backingCornerRadius: CGFloat { backingSize / 4 }
}

extension View {
	/// The WebKit badge at the bottom right of an icon, when `usesWebKit`.
	internal func webKitPageBadge(_ usesWebKit: Bool) -> some View {
		overlay(alignment: .bottomTrailing) {
			if usesWebKit { WebKitPageBadge() }
		}
	}
}
