import AppKit
import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ViewerItemFeature

/// Writes offscreen PNGs of the find bar (DEV-1272), light and dark, when `ARX_DESIGN_SNAPSHOTS`
/// names a directory: empty, with a query and its count, with a query that matches nothing, and
/// with a long query and a long count, each with Previous and Next (DEV-1297),
/// over a light page, a dark page and a window with a theme's tint and texture.
@MainActor
@Suite(.renderTurn, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct FindInPageBarSnapshotTests {
	private enum Backdrop: CaseIterable {
		case lightPage
		case darkPage
		case theme
	}

	@Test(arguments: [false, true])
	internal func bar(dark: Bool) throws {
		let view = VStack(spacing: 0) {
			ForEach(Backdrop.allCases, id: \.self) { backdrop in
				HStack(spacing: 0) {
					Self.cell(query: "", result: nil, over: backdrop)
					Self.cell(query: "Arx", result: .init(matches: 26, active: 1), over: backdrop)
					Self.cell(query: "zzz", result: .init(matches: 0, active: 0), over: backdrop)

					// A long count keeps its room; the query gives way (DEV-1297).
					Self.cell(query: "a much longer query", result: .init(matches: 1024, active: 128), over: backdrop)
				}
			}
		}
		try Self.write(view, name: "find-bar-\(dark ? "dark" : "light").png", dark: dark)
	}

	private static func cell(
		query: String,
		result: BrowserNavigation.FindResult?,
		over backdrop: Backdrop
	) -> some View {
		FindInPageBar(query: query, result: result, onChange: { _ in }, onStep: { _ in }, onDismiss: {})
			.padding(BrowserMetrics.FindBar.inset)
			.frame(width: BrowserMetrics.FindBar.width + 2 * 28, height: 72)
			.background { Self.background(backdrop) }
			.environment(\.browserChromeTint, backdrop == .theme ? .init(hue: 150, intensity: 0.35) : .default)
			.environment(\.browserFilmGrain, backdrop == .theme ? .init(intensity: 1, texture: .jeans) : .init())
	}

	@ViewBuilder
	private static func background(_ backdrop: Backdrop) -> some View {
		switch backdrop {
		case .lightPage:
			Color.white
		case .darkPage:
			Color(white: 0.11)
		case .theme:
			BrowserChromeBackground(textured: true)
		}
	}

	private static func write(
		_ view: some View,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
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
		try data.write(to: directory.appending(path: name))
		window.close()
	}
}
