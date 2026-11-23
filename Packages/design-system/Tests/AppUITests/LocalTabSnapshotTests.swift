import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of a local-network tab's row (DEV-786), selected and not, beside an
/// ordinary tab, and of the developer header over a viewport with square top corners, in light
/// and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct LocalTabSnapshotTests {
	private static let local: SidebarItem = .init(
		id: .tab(UUID()),
		title: "CaptureContext: indie studio for Apple platforms",
		isPinned: false,
		localHost: "localhost:3000"
	)

	private static let remote: SidebarItem = .init(
		id: .tab(UUID()),
		title: "CaptureContext on GitHub",
		isPinned: false
	)

	@Test(arguments: [false, true])
	internal func rows(dark: Bool) throws {
		let directory = try Self.directory()
		let view = VStack(alignment: .leading, spacing: BrowserMetrics.Row.spacing) {
			SidebarRow(item: Self.remote, onAction: { _ in })
			SidebarRow(item: Self.local, selected: true, onAction: { _ in })
			SidebarRow(item: Self.local, onAction: { _ in })
			SidebarRow(item: Self.remote, selected: true, onAction: { _ in })
			SidebarRow(item: Self.local, onAction: { _ in })
				.environment(\.highlightsLocalTabs, false)
		}
		.frame(width: 240)
		.environment(\.sidebarIsStatic, true)
		.padding(12)
		.background { BrowserChromeBackground(textured: true) }
		.fixedSize()

		try write(view, dark: dark, name: "local-tab-rows-\(dark ? "dark" : "light").png", to: directory)
	}

	@Test(arguments: [false, true])
	internal func developerHeader(dark: Bool) throws {
		let directory = try Self.directory()
		let view = VStack(spacing: 0) {
			DeveloperHeader(url: URL(string: "http://localhost:3000/dashboard"), isActive: true, send: { _ in })
			ZStack {
				Color(red: 0.2, green: 0.45, blue: 0.9)
				Text(verbatim: "localhost:3000")
					.font(.title)
					.foregroundStyle(.white)
			}
			.clipShape(BrowserMetrics.PageCard.viewportShape(squaresTopCorners: true))
		}
		.frame(width: 520, height: 220)
		.browserPageCard()
		.padding(BrowserMetrics.PageCard.inset)
		.background { BrowserChromeBackground(textured: true) }
		.fixedSize()

		try write(view, dark: dark, name: "developer-header-\(dark ? "dark" : "light").png", to: directory)
	}

	private static func directory() throws -> URL {
		URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
	}

	private func write(
		_ view: some View,
		dark: Bool,
		name: String,
		to directory: URL
	) throws {
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
		try data.write(to: directory.appending(path: name))
		window.close()
	}
}
