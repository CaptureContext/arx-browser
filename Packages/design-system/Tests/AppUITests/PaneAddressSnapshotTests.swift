import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of split pane addresses (DEV-993), a short one and long ones in a
/// narrow and a wide pane, in light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct PaneAddressSnapshotTests {
	@Test(arguments: [false, true])
	internal func addresses(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let short = try #require(URL(string: "https://capturecontext.dev/"))
		let long = try #require(URL(string: "https://rezka.ag/ua/films/drama/3311-babaduk-2014.html"))
		let longer = try #require(URL(string: "https://www.figma.com/design/j6ck6pjiiys14acwutb4rk/dashboard-flaws?node-id=0-1&t=abc"))
		let view = VStack(alignment: .leading, spacing: 12) {
			ForEach(Array([(short, 360.0), (long, 360.0), (long, 180.0), (longer, 360.0), (longer, 120.0)].enumerated()), id: \.offset) { _, row in
				PaneAddress(url: row.0)
					.font(.system(size: BrowserMetrics.PaneHeader.hostFontSize))
					.foregroundStyle(BrowserTheme.secondary)
					.frame(width: row.1, alignment: .leading)
					.padding(.horizontal, 8)
					.frame(height: BrowserMetrics.PaneHeader.height)
					.background(BrowserTheme.page.opacity(0.6), in: .rect(cornerRadius: 6))
			}
		}
		.padding(16)
		.background(Color(nsColor: .windowBackgroundColor))
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
		defer { window.close() }
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "pane-address-\(dark ? "dark" : "light").png"))
	}
}
