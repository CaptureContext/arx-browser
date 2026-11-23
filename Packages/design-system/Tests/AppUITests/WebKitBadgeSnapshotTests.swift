import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of the WebKit badge (DEV-877, DEV-1242) when `ARX_DESIGN_SNAPSHOTS` names a
/// directory: on tab rows and on Favorites tiles, alone and beside an unread count or dot, light
/// and dark, at the sidebar's size and three times larger.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct WebKitBadgeSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func badges(_ appearance: NSAppearance.Name) throws {
		let view = VStack(alignment: .leading, spacing: 16) {
			Self.samples
			Self.samples
				.scaleEffect(3, anchor: .topLeading)
				.frame(width: 3 * 260, height: 3 * 92, alignment: .topLeading)
		}
		.padding(12)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.environment(\.sidebarIsStatic, true)
		try SidebarChromeSnapshot.write(
			view,
			size: .init(width: 3 * 260 + 24, height: 92 + 16 + 3 * 92 + 24),
			appearance: appearance,
			name: "webkit-badge"
		)
	}

	private static var samples: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				FavoriteTile(item: item(1, "Music", usesWebKit: true), onAction: { _ in })
				FavoriteTile(item: item(2, "Video", usesWebKit: true, unread: .count(8)), onAction: { _ in })
				FavoriteTile(item: item(3, "Films", usesWebKit: true, unread: .dot), onAction: { _ in })
				FavoriteTile(item: item(4, "Chromium", usesWebKit: false, unread: .count(3)), onAction: { _ in })
			}
			.frame(width: 252)
			SidebarRow(item: item(5, "Music in WebKit", usesWebKit: true), onAction: { _ in })
				.frame(width: 252)
		}
	}

	private static func item(
		_ id: UInt8,
		_ title: String,
		usesWebKit: Bool,
		unread: UnreadBadge? = nil
	) -> SidebarItem {
		.init(
			id: .tab(UUID(uuid: (id, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))),
			title: title,
			symbol: "music.note",
			tint: .green,
			usesWebKit: usesWebKit,
			unread: unread.map { SidebarItem.Unread(badge: $0, host: "\(id).example") }
		)
	}
}
