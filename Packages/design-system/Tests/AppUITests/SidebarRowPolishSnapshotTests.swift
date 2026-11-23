import AppKit
@testable import AppUI
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of polished sidebar rows (`SidebarRowPolish`) beside the earlier ones, in
/// light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory: a long-titled tab plain,
/// hovered, with the pointer on its close button and selected, and folders closed, open and
/// collapsed with a tab showing.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct SidebarRowPolishSnapshotTests {
	private static let tab: SidebarItem = .init(
		id: .tab(UUID()),
		title: "PR Flow - How a PR Gets Reviewed and Merged in Our Team",
		isPinned: false
	)

	private static let pinned: SidebarItem = .init(
		id: .tab(UUID()),
		title: "Pull Requests - Mine, in review and waiting",
		isPinned: true
	)

	private static func folder(expanded: Bool) -> SidebarItem {
		.init(
			id: .folder(UUID()),
			title: "Reading list for the weekend",
			children: [tab],
			isExpanded: expanded
		)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func tabRows(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			HStack(alignment: .top, spacing: 24) {
				Self.tabs(polished: false)
				Self.tabs(polished: true)
			}
			.padding(12),
			size: .init(width: 560, height: 360),
			appearance: appearance,
			name: "sidebar-row-polish-tabs"
		)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func folderRows(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			HStack(alignment: .top, spacing: 24) {
				Self.folders(polished: false)
				Self.folders(polished: true)
			}
			.padding(12),
			size: .init(width: 560, height: 200),
			appearance: appearance,
			name: "sidebar-row-polish-folders"
		)
	}

	/// The folder icons alone, closed, open and collapsed with a tab showing, at 1x and 2x, for a
	/// pixel-level look at 4x.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua], [1, 2] as [CGFloat])
	internal func folderIcons(
		_ appearance: NSAppearance.Name,
		scale: CGFloat
	) throws {
		let directory = try #require(SidebarChromeSnapshot.directory)

		// Each in the row's 16-point icon frame, as a sidebar row places it.
		let view = HStack(spacing: 12) {
			SidebarFolderIcon(isExpanded: false)
				.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
			SidebarFolderIcon(isExpanded: true)
				.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
			SidebarFolderIcon(isExpanded: false, isPartlyRevealed: true)
				.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
		}
		.padding(8)
		.frame(width: 96, height: 32, alignment: .topLeading)
		.background { BrowserChromeBackground(textured: true) }
		.environment(\.sidebarRowPolish, true)
		.environment(\.sidebarIsStatic, true)
		.environment(\.browserAccentIsEnabled, true)

		let size = CGSize(width: 96, height: 32)
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: appearance)
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
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
		let representation = try #require(NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: Int(size.width * scale),
			pixelsHigh: Int(size.height * scale),
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		))
		representation.size = size
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let name = "sidebar-folder-icons-\(appearance == .darkAqua ? "dark" : "light")-\(Int(scale))x.png"
		try data.write(to: directory.appending(path: name))
		window.close()
	}

	private static func tabs(polished: Bool) -> some View {
		column(polished: polished) {
			SidebarRow(item: tab, onAction: { _ in })
			SidebarRow(item: tab, hover: .row, onAction: { _ in })
			SidebarRow(item: tab, hover: .control, onAction: { _ in })
			SidebarRow(item: tab, selected: true, onAction: { _ in })
			SidebarRow(item: tab, selected: true, hover: .row, onAction: { _ in })
			SidebarRow(item: tab, selected: true, hover: .control, onAction: { _ in })
			SidebarRow(item: pinned, selected: true, hover: .control, onAction: { _ in })
			SidebarRow(item: pinned, hover: .control, onAction: { _ in })
		}
	}

	private static func folders(polished: Bool) -> some View {
		column(polished: polished) {
			SidebarRow(item: folder(expanded: false), onAction: { _ in })
			SidebarRow(item: folder(expanded: true), onAction: { _ in })
			SidebarRow(item: folder(expanded: false), isPartlyRevealed: true, onAction: { _ in })
			SidebarRow(item: folder(expanded: false), hover: .row, onAction: { _ in })
		}
	}

	private static func column(
		polished: Bool,
		@ViewBuilder rows: () -> some View
	) -> some View {
		VStack(alignment: .leading, spacing: BrowserMetrics.Row.spacing) {
			Text(verbatim: polished ? "ARX_SIDEBAR_ROW_POLISH on" : "off")
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(BrowserTheme.secondary)
				.padding(.leading, BrowserMetrics.Row.horizontalPadding)
			rows()
		}
		.frame(width: 250)
		.environment(\.sidebarRowPolish, polished)
		.environment(\.sidebarIsStatic, true)
		.environment(\.browserAccentIsEnabled, true)
	}
}

/// The flag reads like every beta flag: on unless it's turned off.
@Suite
internal struct SidebarRowPolishFlagTests {
	@Test
	internal func isOnUnlessTurnedOff() {
		#expect(SidebarRowPolish.isOn(read: { _ in nil }))
		#expect(SidebarRowPolish.isOn(read: { _ in "1" }))
		#expect(SidebarRowPolish.isOn(read: { _ in "on" }))
		for off in ["0", "false", "no", "off", "OFF"] {
			#expect(!SidebarRowPolish.isOn(read: { _ in off }), "\(off)")
		}
	}
}
