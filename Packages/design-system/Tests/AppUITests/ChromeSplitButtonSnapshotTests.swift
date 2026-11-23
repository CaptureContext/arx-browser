import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of the chrome's split button (DEV-768), as Little Arx's "Open in" shows
/// it beside the URL bar, at rest and with each part hovered or pressed, light and dark, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct ChromeSplitButtonSnapshotTests {
	private typealias Part = ChromeSplitButtonPart

	private static let states: [(name: String, overrides: [Part: ArxControlStateOverride])] = [
		("normal", [:]),
		("main hovered", [.main: .init(isHovered: true)]),
		("main pressed", [.main: .init(isHovered: true, isPressed: true)]),
		("menu hovered", [.more: .init(isHovered: true)]),
		("menu pressed", [.more: .init(isHovered: true, isPressed: true)]),
	]

	@Test(arguments: [false, true])
	internal func states(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let url = try #require(URL(string: "https://github.com/capturecontext"))
		let view = VStack(alignment: .leading, spacing: 12) {
			ForEach(Self.states, id: \.name) { state in
				HStack(spacing: 6) {
					Text(verbatim: state.name)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.frame(width: 90, alignment: .leading)
					URLBar(
						url: url,
						height: BrowserMetrics.LittleArx.addressHeight,
						centersAddress: true,
						prominentActions: true,
						onActivate: {},
						onCopy: {}
					)
					.frame(width: 300)
					ChromeSplitButton(
						height: BrowserMetrics.LittleArx.addressHeight,
						moreHelp: "Move to Space",
						shortcut: nil,
						action: {},
						onMore: {},
						stateOverrides: state.overrides
					) {
						Text(verbatim: "Open in Personal")
						ChromeKeyHint("⌘O")
					}
				}
				.frame(height: BrowserMetrics.LittleArx.toolbarHeight)
			}
		}
		.environment(\.sidebarIsStatic, true)
		.padding(20)
		.background { BrowserChromeBackground(textured: true) }
		.fixedSize()

		try write(view, dark: dark, name: "chrome-split-button-\(dark ? "dark" : "light").png", to: directory)
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
