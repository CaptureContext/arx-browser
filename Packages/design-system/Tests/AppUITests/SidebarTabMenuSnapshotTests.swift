import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// The four tab menus in `SidebarTabMenu`'s order (DEV-1250), drawn as a menu lists them, in
/// light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory: a regular tab playing sound, a
/// pinned tab, a Favorite and a selection of three tabs. A context menu can't be drawn offscreen,
/// so each item is a row with its title, a submenu's with ▸, and each group ends at a divider.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SidebarTabMenuSnapshotTests {
	private static let traits: SidebarTabMenu.Traits = .init(
		hasAudio: true,
		hasVolume: true,
		canKeepSiteLoaded: true
	)

	@Test(arguments: [false, true])
	internal func menus(dark: Bool) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let selection: SidebarTabMenu.Selection = .init(openTabCount: 2, savedTabCount: 1)
		let menus = HStack(alignment: .top, spacing: 16) {
			Self.menu("Tab", SidebarTabMenu.groups(for: .tab, traits: Self.traits), kind: .tab)
			Self.menu("Pinned tab", SidebarTabMenu.groups(for: .pinned, traits: Self.traits), kind: .pinned)
			Self.menu("Favorite", SidebarTabMenu.groups(for: .favorite, traits: Self.traits), kind: .favorite)
			Self.menu("Three tabs", SidebarTabMenu.groups(for: .selection(selection)), kind: .selection(selection))
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		try write(menus, dark: dark, to: directory.appending(path: "tab-menus-\(dark ? "dark" : "light").png"))
	}

	private static func menu(
		_ title: String,
		_ groups: [[SidebarTabMenu.Item]],
		kind: SidebarTabMenu.Kind
	) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 5) {
				ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
					if index > 0 { Divider() }
					ForEach(group, id: \.self) { item in
						Text(verbatim: Self.title(of: item, kind: kind))
					}
				}
			}
			.font(.system(size: 13))
			.padding(10)
			.frame(width: 230, alignment: .leading)
			.background(.regularMaterial, in: .rect(cornerRadius: 8))
		}
	}

	private static func title(
		of item: SidebarTabMenu.Item,
		kind: SidebarTabMenu.Kind
	) -> String {
		let count: Int = 3
		switch item {
		case .copy: return String.localized(.appUI.links.copyMenu.title) + "  ▸"
		case .peek: return String.localized(.appUI.peek.title)
		case .changeIcon: return String.localized(.appUI.sidebar.changeIcon)
		case .rename: return String.localized(.appUI.common.rename)
		case .updateSavedURL: return String.localized(.appUI.sidebar.updateSavedURL)
		case .mute: return String.localized(.appUI.media.muteTab)
		case .volume: return String.localized(.appUI.media.volumeMenu)
		case .pictureInPicture: return String.localized(.appUI.media.tabPicture.menu) + "  ▸"
		case .badges: return String.localized(.appUI.unreadBadges.tabMenu) + "  ▸"
		case .keepSiteLoaded: return String.localized(.appUI.sidebar.keepSiteLoaded)
		case .keepAgentTab: return String.localized(.appUI.automation.keepTab)
		case .addSplit: return BrowserCommand.newSplit.title
		case .duplicate:
			return kind == .tab || kind == .pinned
			? BrowserCommand.duplicateTab.title
			: String.localized(.appUI.sidebar.duplicateTabs(count))
		case .addToNewGroup:
			return kind == .tab
			? String.localized(.appUI.sidebar.addTabToNewGroup)
			: String.localized(.appUI.sidebar.groupTabs(2))
		case .moveTo: return String.localized(.appUI.move.choose)
		case .moveToWindow:
			return kind == .tab || kind == .pinned
			? String.localized(.appUI.sidebar.openInNewWindow) + "\n" + String.localized(.appUI.sidebar.moveToWindow) + "  ▸"
			: String.localized(.appUI.sidebar.moveTabsToWindow(count)) + "  ▸"
		case .close:
			switch kind {
			case .tab: return String.localized(.appUI.sidebar.closeNamedTab("Example"))
			case .pinned: return String.localized(.appUI.sidebar.resetNamedTab("Example"))
			case .favorite: return String.localized(.appUI.sidebar.closeResetFavorite)
			case .selection: return String.localized(.appUI.sidebar.closeTabs(count))
			}
		case .closeOthers: return String.localized(.appUI.sidebar.closeOtherTabs)
		case .closeBelow: return String.localized(.appUI.sidebar.closeTabsBelow)
		case .pin: return String.localized(.appUI.sidebar.pinTabs(2))
		case .unpin:
			return kind == .pinned || kind == .favorite
			? String.localized(.appUI.move.unpin)
			: String.localized(.appUI.sidebar.unpinTabs(1))
		case .archive: return String.localized(.appUI.sidebar.archiveTabs(2))
		case .removeFavorite: return String.localized(.appUI.sidebar.removeFavorite)
		}
	}

	private func write(
		_ view: some View,
		dark: Bool,
		to file: URL
	) throws {
		let host = NSHostingView(rootView: view.fixedSize())
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: file)
		window.close()
	}
}
