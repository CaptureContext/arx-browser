import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of WebKit pages' rows (DEV-877), selected and not, so the Safari mark's
/// place on the icon's corner can be checked, in light and dark, when `ARX_DESIGN_SNAPSHOTS` names
/// a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct WebKitMarkSnapshotTests {
	private static func item(_ title: String, symbol: String) -> SidebarItem {
		.init(id: .tab(UUID()), title: title, symbol: symbol, isPinned: false, usesWebKit: true)
	}

	@Test(arguments: [false, true])
	internal func rows(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = VStack(alignment: .leading, spacing: BrowserMetrics.Row.spacing) {
			SidebarRow(item: Self.item("Netflix", symbol: "square.fill"), onAction: { _ in })
			SidebarRow(item: Self.item("GitHub", symbol: "circle.fill"), selected: true, onAction: { _ in })
		}
		.frame(width: 240)
		.environment(\.sidebarIsStatic, true)
		.padding(12)
		.background { BrowserChromeBackground(textured: true) }
		.fixedSize()

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
		try data.write(to: directory.appending(path: "webkit-mark-rows-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
