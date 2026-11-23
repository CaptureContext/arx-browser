import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of a pane with no page (DEV-829): the Arx mark in the page card, in the
/// default and a strong chrome tint, and the Settings tiles with the Arx pane's mark beside
/// symbol tiles, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct BrowserEmptyPageSnapshotTests {
	@Test(arguments: [false, true])
	internal func emptyPage(dark: Bool) throws {
		let view = VStack(spacing: 16) {
			page(tint: .default)
			page(tint: .init(hue: 150, intensity: 0.35))
			HStack(spacing: 12) {
				ArxGlyphTile(glyph: .arxMark, tint: .blue, side: 22)
				ArxGlyphTile(glyph: .symbol("gearshape.fill"), tint: .gray, side: 22)
				ArxGlyphTile(glyph: .symbol("sparkles"), tint: .purple, side: 22)
				ArxHeaderBarIcon(glyph: .arxMark, tint: .blue)
				ArxHeaderBarIcon(systemImage: "gearshape.fill", tint: .gray)
			}
		}
		.environment(\.sidebarIsStatic, true)
		.padding(16)
		.background { BrowserChromeBackground(textured: true) }
		.fixedSize()

		try write(view, dark: dark, name: "empty-page-\(dark ? "dark" : "light").png")
	}

	/// DEV-1263: the three longest tips with the default keys, held still, each in its full box,
	/// so a tip too long for it shows clipped.
	@Test(arguments: [false, true])
	internal func longestHints(dark: Bool) throws {
		let texts: [String] = EmptyPageHints.texts(bindings: [])
		let longest: [String] = Array(texts.sorted { $0.count > $1.count }.prefix(3))
		let view = VStack(spacing: 16) {
			ForEach(longest.indices, id: \.self) { index in
				EmptyPageRollingHint(texts: longest, time: 0, cursor: .init(index: index, since: 0))
					.environment(\.emptyPageIsMoving, false)
					.border(.red.opacity(0.4))
			}
		}
		.padding(16)
		.background(BrowserTheme.page)
		.fixedSize()

		try write(view, dark: dark, name: "longest-hints-\(dark ? "dark" : "light").png")
	}

	private func page(tint: ChromeTint) -> some View {
		ZStack {
			BrowserTheme.page
			BrowserEmptyPage()
		}
		.frame(width: 560, height: 320)
		.browserPageCard()
		.environment(\.browserChromeTint, tint)
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
		for _ in 0..<6 {
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
