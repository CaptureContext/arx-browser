import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// DEV-995: the URL bar's copy-link and site-menu buttons show whenever a tab's page is shown,
/// hovered or not, and never without one.
@Suite
internal struct URLBarActionVisibilityTests {
	@Test
	internal func showWhileAPageIsShown() {
		#expect(URLBar.showsActions(hasPage: true))
	}

	@Test
	internal func hideWithoutATab() {
		#expect(!URLBar.showsActions(hasPage: false))
	}
}

/// Writes offscreen PNGs of the sidebar's URL bar (idle, hovered, focused), the Favorites grid
/// (one open, none open), Little Arx's URL bar, the footer space hint and the footer buttons'
/// hover and press on the chrome, light and dark, in the default, a strong and a neutral tint,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory (DEV-788).
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct SidebarTopStyleSnapshotTests {
	private static let tints: [(name: String, tint: ChromeTint)] = [
		("default", .default),
		("orange", .init(hue: 20, intensity: 1)),
		("neutral", .init(hue: 0, intensity: 0)),
	]

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func urlBar(_ appearance: NSAppearance.Name) throws {
		let url = try #require(URL(string: "https://capturecontext.dev/arx"))
		for (name, tint) in Self.tints {
			let view = VStack(alignment: .leading, spacing: 12) {
				URLBar(url: url, onActivate: {}, onCopy: {})
				URLBar(url: url, onActivate: {}, onCopy: {})
					.arxControlState(.init(isHovered: true))
				URLBar(url: url, onActivate: {}, onCopy: {})
					.arxControlState(.init(isFocused: true))
				URLBar(url: nil, onActivate: {}, onCopy: {})
			}
			.frame(width: 260)
			.padding(16)
			.environment(\.browserChromeTint, tint)
			try SidebarChromeSnapshot.write(
				view
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(BrowserChromeBackground(textured: true).environment(\.browserChromeTint, tint)),
				size: .init(width: 292, height: 204),
				appearance: appearance,
				name: "url-bar-states-\(name)"
			)
		}
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func favorites(_ appearance: NSAppearance.Name) throws {
		let items: [SidebarItem] = [
			.init(id: .tab(Self.id(10)), title: "Mail", symbol: "envelope.fill", tint: .blue),
			.init(id: .tab(Self.id(11)), title: "Calendar", symbol: "calendar", tint: .orange),
			.init(id: .tab(Self.id(12)), title: "Notes", symbol: "note.text", tint: .yellow),
			.init(id: .tab(Self.id(13)), title: "Music", symbol: "music.note", tint: .pink),
		]
		for (name, tint) in Self.tints {
			let view = VStack(spacing: 12) {
				FavoritesGrid(items: items, selectedID: .tab(Self.id(11)), availableHeight: 400, onAction: { _ in })
				FavoritesGrid(items: items, selectedID: nil, availableHeight: 400, onAction: { _ in })
				HStack(spacing: BrowserMetrics.Favorites.spacing) {
					FavoriteTile(item: items[0], onAction: { _ in })
						.arxControlState(.init(isHovered: true))
					FavoriteTile(item: items[1], onAction: { _ in })
						.arxControlState(.init(isFocused: true))
					FavoriteTile(item: items[2], selected: true, onAction: { _ in })
						.arxControlState(.init(isFocused: true))
				}
			}
			.frame(width: 260)
			.padding(16)
			.environment(\.browserChromeTint, tint)
			try SidebarChromeSnapshot.write(
				view
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(BrowserChromeBackground(textured: true).environment(\.browserChromeTint, tint)),
				size: .init(width: 292, height: 204),
				appearance: appearance,
				name: "favorites-\(name)"
			)
		}
	}

	/// Little Arx's address row: the prominent URL bar with a leading chip, actions always shown.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func littleArxURLBar(_ appearance: NSAppearance.Name) throws {
		let url = try #require(URL(string: "https://capturecontext.dev/arx"))
		for (name, tint) in Self.tints {
			let leading = Text(verbatim: "Personal")
				.font(.system(size: 11, weight: .semibold))
				.padding(.horizontal, 6)
			let view = VStack(spacing: 12) {
				URLBar(
					url: url,
					height: BrowserMetrics.LittleArx.addressHeight,
					centersAddress: true,
					prominentActions: true,
					leading: AnyView(leading),
					onActivate: {},
					onCopy: {}
				)
				URLBar(
					url: url,
					height: BrowserMetrics.LittleArx.addressHeight,
					centersAddress: true,
					prominentActions: true,
					leading: AnyView(leading),
					onActivate: {},
					onCopy: {}
				)
				.arxControlState(.init(isHovered: true))
			}
			.frame(width: 360)
			.padding(16)
			.environment(\.browserChromeTint, tint)
			try SidebarChromeSnapshot.write(
				view
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(BrowserChromeBackground(textured: true).environment(\.browserChromeTint, tint)),
				size: .init(width: 392, height: 104),
				appearance: appearance,
				name: "little-arx-url-bar-\(name)"
			)
		}
	}

	/// The hint pill above a hovered footer space, with and without a profile and keys.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func spaceHint(_ appearance: NSAppearance.Name) throws {
		for (name, tint) in Self.tints {
			let view = VStack(alignment: .leading, spacing: 16) {
				SidebarSpaceHint(space: .init(
					id: Self.id(1),
					name: "Work",
					symbol: "briefcase",
					profileName: "Personal",
					shortcut: ["⌃", "1"]
				))
				SidebarSpaceHint(space: .init(
					id: Self.id(2),
					name: "Reading",
					symbol: "book",
					profileName: nil,
					shortcut: []
				))
			}
			.padding(20)
			.environment(\.browserChromeTint, tint)
			try SidebarChromeSnapshot.write(
				view
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(BrowserChromeBackground(textured: true).environment(\.browserChromeTint, tint)),
				size: .init(width: 292, height: 130),
				appearance: appearance,
				name: "space-hint-\(name)"
			)
		}
	}

	/// The footer's spaces and + at rest, hovered and pressed, beside the selected space.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func footerHover(_ appearance: NSAppearance.Name) throws {
		for (name, tint) in Self.tints {
			let view = HStack(spacing: BrowserMetrics.SpaceSwitcher.spacing) {
				SidebarSpaceButton(name: "Work", symbol: "briefcase", isSelected: true, onSelect: {}, onDropTabs: { _ in })
				SidebarSpaceButton(name: "Home", symbol: "house", isSelected: false, onSelect: {}, onDropTabs: { _ in })
				SidebarSpaceButton(name: "Reading", symbol: "book", isSelected: false, onSelect: {}, onDropTabs: { _ in })
					.arxControlState(.init(isHovered: true))
				SidebarSpaceButton(name: "Music", symbol: "music.note", isSelected: false, onSelect: {}, onDropTabs: { _ in })
					.arxControlState(.init(isHovered: true, isPressed: true))
				Spacer()
				SidebarCreateButton(help: "New Tab", sections: [])
				SidebarCreateButton(help: "New Tab", sections: [])
					.arxControlState(.init(isHovered: true))
				SidebarCreateButton(help: "New Tab", sections: [])
					.arxControlState(.init(isHovered: true, isPressed: true))
			}
			.font(.system(size: BrowserMetrics.SpaceSwitcher.symbolSize - 2, weight: .medium))
			.foregroundStyle(BrowserTheme.secondary)
			.padding(.horizontal, 14)
			.frame(height: BrowserMetrics.SpaceSwitcher.height)
			.environment(\.browserChromeTint, tint)
			try SidebarChromeSnapshot.write(
				view
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(BrowserChromeBackground(textured: true).environment(\.browserChromeTint, tint)),
				size: .init(width: 320, height: BrowserMetrics.SpaceSwitcher.height),
				appearance: appearance,
				name: "footer-hover-\(name)"
			)
		}
	}

	/// The sidebar's top (DEV-1252): the URL bar over two rows of
	/// Favorites, among them a WebKit page alone, with an unread count and with an unread dot
	/// (DEV-1242).
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func pinnedHeader(_ appearance: NSAppearance.Name) throws {
		let url = try #require(URL(string: "https://www.google.com"))
		let items: [SidebarItem] = [
			.init(id: .tab(Self.id(10)), title: "Mail", symbol: "envelope.fill", tint: .blue),
			.init(id: .tab(Self.id(11)), title: "Calendar", symbol: "calendar", tint: .orange),
			.init(id: .tab(Self.id(12)), title: "Music", symbol: "music.note", tint: .green, usesWebKit: true),
			.init(id: .tab(Self.id(13)), title: "Notes", symbol: "note.text", tint: .yellow),
			.init(
				id: .tab(Self.id(14)),
				title: "Video",
				symbol: "play.rectangle.fill",
				tint: .pink,
				usesWebKit: true,
				unread: .init(badge: .count(83), host: "video.example")
			),
			.init(
				id: .tab(Self.id(15)),
				title: "Chat",
				symbol: "bubble.left.fill",
				tint: .blue,
				unread: .init(badge: .count(5), host: "chat.example")
			),
			.init(
				id: .tab(Self.id(16)),
				title: "Films",
				symbol: "film",
				tint: .lavender,
				usesWebKit: true,
				unread: .init(badge: .dot, host: "films.example")
			),
			.init(id: .tab(Self.id(17)), title: "Docs", symbol: "doc.text", tint: .white),
		]
		let width: CGFloat = 286
		let view = SidebarPinnedHeader(
			url: url,
			favorites: items,
			selectedID: .tab(Self.id(11)),
			splitIDs: [],
			availableHeight: 400,
			onAction: { _ in },
			onCopyURL: {}
		)
		.frame(width: width)
		.padding(.top, 12)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		try SidebarChromeSnapshot.write(
			view,
			size: .init(width: width, height: 180),
			appearance: appearance,
			name: "pinned-header"
		)
	}

	private static func id(_ value: UInt8) -> UUID {
		UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
	}
}
