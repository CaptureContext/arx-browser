import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of ⌃Tab's recent-tab switcher (DEV-544) over a page card, light and dark,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory: the previous tab chosen, a tab of another space,
/// an unloaded tab dimmed, a chat tab, and a long title.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct TabSwitcherSnapshotTests {
	@Test(arguments: [false, true])
	internal func switcher(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let size: CGSize = .init(width: 640, height: 420)
		let view = ZStack {
			BrowserChromeBackground(textured: true)
			Color.clear
				.browserPageCard()
				.padding(BrowserMetrics.PageCard.inset)
			TabSwitcherView(rows: Self.rows, selectedIndex: 1)
		}
		.environment(\.sidebarIsStatic, true)
		.frame(width: size.width, height: size.height)

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "tab-switcher-\(dark ? "dark" : "light").png"))
		window.close()
	}

	private static func id(_ number: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
	}

	private static let rows: [TabSwitcherRow] = [
		.init(
			id: id(1),
			title: "Arx — Linear",
			siteIcon: nil
		),
		.init(
			id: id(2),
			title: "Pull request: recent-tab switcher",
			siteIcon: nil
		),
		.init(
			id: id(3),
			title: "Weekend plans",
			spaceName: "Personal",
			siteIcon: nil
		),
		.init(
			id: id(4),
			title: "Swift Forums",
			siteIcon: nil,
			isUnloaded: true
		),
		.init(
			id: id(5),
			title: "Chat",
			siteIcon: nil,
			symbol: SidebarItem.assistantSymbol
		),
		.init(
			id: id(6),
			title: "A page whose title is far too long to fit on one row of the switcher",
			siteIcon: nil
		),
	]
}
