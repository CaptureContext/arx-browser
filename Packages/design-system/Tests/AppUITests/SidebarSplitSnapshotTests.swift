import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of Split View in every list (DEV-1006): a pinned split's row in Pinned,
/// one in a folder, and a split with a Favorite, whose tile stays highlighted beside the open
/// tab's row, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SidebarSplitSnapshotTests {
	@Test(arguments: [false, true])
	internal func pinnedSplits(dark: Bool) throws {
		let folder = SidebarItem(
			id: .folder(Self.id(20)),
			title: "Reading",
			symbol: "folder.fill",
			tint: .lavender,
			isExpanded: true
		)
		let view = VStack(spacing: BrowserMetrics.Row.spacing) {
			SplitSidebarRow(
				item: Self.tab(1, "Linear"),
				split: .init(id: Self.id(50), members: [Self.tab(1, "Linear"), Self.tab(2, "GitHub")]),
				selected: true,
				onAction: { _ in }
			)
			SidebarRow(item: Self.tab(3, "Calendar"), selected: false, onAction: { _ in })
			SidebarRow(item: folder, selected: false, onAction: { _ in })
			SplitSidebarRow(
				item: Self.tab(4, "Point-Free"),
				split: .init(
					id: Self.id(51),
					members: [Self.tab(4, "Point-Free"), Self.tab(5, "Swift Forums")],
					isVertical: true
				),
				depth: 1,
				selected: false,
				onAction: { _ in }
			)
			SidebarRow(item: Self.tab(6, "Hacker News"), depth: 1, selected: false, onAction: { _ in })
		}
		.padding(BrowserMetrics.Sidebar.horizontalPadding)
		.frame(width: 260)
		.background { BrowserChromeBackground(textured: true) }
		try write(view, dark: dark, name: "split-pinned-rows")
	}

	@Test(arguments: [false, true])
	internal func favoriteInASplit(dark: Bool) throws {
		let favorites = [Self.tab(7, "Mail"), Self.tab(8, "Calendar"), Self.tab(9, "Music")]
		let view = VStack(spacing: 12) {
			FavoritesGrid(
				items: favorites,
				selectedID: nil,
				splitIDs: [favorites[1].id, .tab(Self.id(10))],
				availableHeight: 400,
				onAction: { _ in }
			)
			VStack(spacing: BrowserMetrics.Row.spacing) {
				SidebarRow(item: Self.tab(10, "Meeting notes", isPinned: false), selected: true, onAction: { _ in })
				SidebarRow(item: Self.tab(11, "Design review", isPinned: false), selected: false, onAction: { _ in })
			}
		}
		.padding(BrowserMetrics.Sidebar.horizontalPadding)
		.frame(width: 260)
		.background { BrowserChromeBackground(textured: true) }
		try write(view, dark: dark, name: "split-favorite")
	}

	private static func id(_ value: UInt8) -> UUID {
		UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}

	private static func tab(
		_ value: UInt8,
		_ title: String,
		isPinned: Bool = true
	) -> SidebarItem {
		.init(id: .tab(id(value)), title: title, isPinned: isPinned)
	}

	private func write(
		_ view: some View,
		dark: Bool,
		name: String
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(rootView: view)
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
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
