import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of the command bar's "Ask an agent ⇥" hint (DEV-751), at rest and
/// hovered, alone and in the palette and address field, light and dark, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct CommandBarKeyHintSnapshotTests {
	@Test(arguments: [false, true])
	internal func agentHint(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let results: [CommandBarResult] = [
			.init(id: "a", title: "asd", subtitle: "Google Search", actionTitle: "Search", symbol: "magnifyingglass"),
		]
		let view = VStack(alignment: .leading, spacing: 18) {
			ForEach([false, true], id: \.self) { hovered in
				HStack(spacing: 12) {
					Text(hovered ? "hover" : "rest")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.frame(width: 50, alignment: .leading)
					CommandBarKeyHintButton("Ask an agent", key: "⇥", keyName: "Tab") {}
				}
				.arxControlState(.init(isHovered: hovered))
			}
			ForEach([CommandBarStyle.palette, .urlField], id: \.inputHeight) { style in
				CommandBar(
					query: .constant("asd"),
					selectedID: .constant("a"),
					results: results,
					style: style,
					onAskAgent: {},
					onSelect: { _ in },
					onDismiss: {}
				)
				.frame(width: 640)
			}
		}
		.environment(\.commandBarIsStatic, true)
		.padding(24)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		try write(view, dark: dark, to: directory.appending(path: "command-bar-agent-hint-\(dark ? "dark" : "light").png"))
	}

	/// DEV-779: the hint stays at the input's trailing edge however many search suggestions
	/// and pages fill the list, as for "test" in ⌘T and ⌘K.
	@Test(arguments: [false, true])
	internal func agentHintWithAFullList(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let results: [CommandBarResult] = [
			.init(id: "search", title: "test", subtitle: "Google Search", actionTitle: "Search", symbol: "magnifyingglass"),
		] + ["test speed", "test internet speed", "testosterone", "test my webcam"].map {
			.init(id: $0, title: $0, subtitle: "Google Search", actionTitle: "Search", symbol: "magnifyingglass")
		} + [
			.init(id: "page-1", title: "Speedtest by Ookla", subtitle: "speedtest.net", actionTitle: "Open", symbol: "globe"),
			.init(id: "page-2", title: "Test Page", subtitle: "example.com/test", actionTitle: "Open", symbol: "globe"),
		]
		let view = VStack(alignment: .leading, spacing: 18) {
			ForEach([CommandBarStyle.palette, .urlField], id: \.inputHeight) { style in
				CommandBar(
					query: .constant("test"),
					selectedID: .constant("search"),
					results: results,
					style: style,
					onAskAgent: {},
					onSelect: { _ in },
					onDismiss: {}
				)
				.frame(width: 640)
			}
		}
		.environment(\.commandBarIsStatic, true)
		.padding(24)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		try write(
			view,
			dark: dark,
			to: directory.appending(path: "command-bar-agent-hint-full-\(dark ? "dark" : "light").png")
		)
	}

	/// DEV-954: a long address ends where the hint begins, in the palette (⌘T, ⌘K) and the
	/// address field (⌘L), drawn by the live field rather than the static stand-in.
	@Test(arguments: [false, true])
	internal func agentHintWithALongAddress(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let address = "github.com/CaptureContext/homebrew-tap/blob/main/Formula/arx.rb"
		let layouts: [(style: CommandBarStyle, width: CGFloat)] = [
			(.palette, BrowserMetrics.CommandBar.width),
			(.urlField, BrowserMetrics.CommandBar.URLField.minimumWidth),
		]
		let view = VStack(alignment: .leading, spacing: 18) {
			ForEach(layouts, id: \.width) { layout in
				CommandBar(
					query: .constant(address),
					selectedID: .constant(nil),
					results: [],
					style: layout.style,
					inputSymbol: "globe",
					onAskAgent: {},
					onSelect: { _ in },
					onDismiss: {}
				)
				.frame(width: layout.width)
			}
		}
		.padding(24)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		try write(
			view,
			dark: dark,
			to: directory.appending(path: "command-bar-agent-hint-long-address-\(dark ? "dark" : "light").png")
		)
	}

	private func write(
		_ view: some View,
		dark: Bool,
		to url: URL
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
		try data.write(to: url)
		window.close()
	}
}
