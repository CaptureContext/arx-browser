import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of DEV-1224's Peek polish: the tab a Peek came from, as a row and as a
/// Favorite tile, with the peeked site's badge, and Peek's Arx buttons at rest, hovered, pressed,
/// focused and disabled, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct PeekPolishSnapshotTests {
	private static let profileID: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000001")!
	private static let source: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000011")!
	private static let other: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000012")!

	private static var peek: BrowserPeekedTab {
		.init(
			tabID: source,
			siteIcon: .init(profileID: profileID, pageURL: URL(string: "https://www.youtube.com/watch?v=1224")!),
			title: "YouTube"
		)
	}

	@Test(arguments: [false, true])
	internal func rows(dark: Bool) throws {
		let view = VStack(spacing: BrowserMetrics.Row.spacing) {
			SidebarRow(
				item: .init(id: .tab(Self.source), title: "(75) YouTube", isPinned: false),
				selected: true,
				onAction: { _ in }
			)
			SidebarRow(
				item: .init(id: .tab(Self.other), title: "Point-Free", isPinned: false),
				onAction: { _ in }
			)
			SplitSidebarRow(
				item: .init(id: .tab(Self.other), title: "Linear"),
				split: .init(
					id: Self.other,
					members: [
						.init(id: .tab(Self.other), title: "Linear"),
						.init(id: .tab(Self.source), title: "YouTube"),
					]
				),
				selected: false,
				onAction: { _ in }
			)
		}
		.environment(\.browserPeekedTab, Self.peek)
		.padding(BrowserMetrics.Sidebar.horizontalPadding)
		.frame(width: 300)
		.background { BrowserChromeBackground(textured: true) }
		try write(view, dark: dark, name: "peek-source-rows")
	}

	@Test(arguments: [false, true])
	internal func tiles(dark: Bool) throws {
		let view = HStack(spacing: 8) {
			FavoriteTile(item: .init(id: .tab(Self.source), title: "Gmail"), onAction: { _ in })
			FavoriteTile(item: .init(id: .tab(Self.other), title: "Calendar"), onAction: { _ in })
		}
		.environment(\.browserPeekedTab, Self.peek)
		.padding(16)
		.frame(width: 220)
		.background { BrowserChromeBackground(textured: true) }
		try write(view, dark: dark, name: "peek-source-tiles")
	}

	@Test(arguments: [false, true])
	internal func controls(dark: Bool) throws {
		let states: [(String, ArxControlStateOverride, Bool)] = [
			("xmark", .init(), true),
			("arrow.up.left.and.arrow.down.right", .init(isHovered: true), true),
			("macwindow", .init(isPressed: true), true),
			("xmark", .init(isFocused: true), true),
			("macwindow", .init(), false),
		]
		let view = HStack(spacing: 14) {
			ForEach(Array(states.enumerated()), id: \.offset) { _, state in
				Button {} label: { Image(systemName: state.0) }
					.buttonStyle(BrowserPeekControlStyle(hint: ""))
					.arxControlState(state.1)
					.disabled(!state.2)
			}
		}
		.padding(20)
		.background(Color(white: dark ? 0.12 : 0.92))
		try write(view, dark: dark, name: "peek-controls")
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
