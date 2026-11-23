import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of ⌘K's actions panel (DEV-810): alone, filtered, and opened from the
/// corner of the palette and the address field, light and dark, when `ARX_DESIGN_SNAPSHOTS`
/// names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct CommandBarActionsSnapshotTests {
	private let actions: [CommandBarActionItem] = [
		.init(id: "primary", title: "Open", symbol: "arrow.up.right", shortcut: "↩"),
		.init(id: "switch", title: "Switch to Tab", symbol: "square.on.square", shortcut: "⌃↩"),
		.init(id: "peek", title: "Open in Peek", symbol: "eye", shortcut: "⇧↩"),
		.init(id: "little", title: "Open in Little Arx", symbol: "macwindow", shortcut: "⌥⌘↩"),
		.init(id: "copy", title: "Copy URL", symbol: "link", shortcut: "⇧⌘C"),
		.init(id: "delete", title: "Delete from History", symbol: "trash", shortcut: "⌃X", isDestructive: true),
		.init(id: "delete-site", title: "Delete All from capturecontext.dev", symbol: "trash.square", shortcut: "⌃⇧X", isDestructive: true),
	]

	private let results: [CommandBarResult] = [
		.init(id: "tab", title: "CaptureContext", subtitle: "https://capturecontext.dev", actionTitle: "Switch to Tab", symbol: "globe"),
		.init(id: "history", title: "CaptureContext", subtitle: "https://capturecontext.dev", actionTitle: "Open URL", symbol: "clock.arrow.circlepath"),
		.init(id: "other", title: "Arx Manual", subtitle: "https://manual.arx.capturecontext.dev", actionTitle: "Open URL", symbol: "clock.arrow.circlepath"),
		.init(id: "search", title: "cap", subtitle: "Google Search", actionTitle: "Command", symbol: "magnifyingglass"),
		.init(id: "more", title: "Capture Area", subtitle: "Capture", actionTitle: "Command", symbol: "camera.viewfinder"),
		.init(id: "last", title: "Cap Table", subtitle: "https://cap.example", actionTitle: "Open URL", symbol: "clock.arrow.circlepath"),
	]

	@Test(arguments: [false, true])
	internal func panel(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = HStack(alignment: .top, spacing: 24) {
			CommandBarActionsPanel(content(query: "", selected: "primary", actions: actions))
			CommandBarActionsPanel(content(query: "delete", selected: "delete", actions: actions.filter { $0.isDestructive }))
			CommandBarActionsPanel(content(query: "zzz", selected: nil, actions: []))
		}
		.environment(\.commandBarIsStatic, true)
		.padding(32)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		try write(view, dark: dark, to: directory.appending(path: "command-bar-actions-panel-\(dark ? "dark" : "light").png"))
	}

	@Test(arguments: [false, true])
	internal func panelOverTheBar(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = VStack(alignment: .leading, spacing: 24) {
			ForEach([CommandBarStyle.palette, .urlField], id: \.inputHeight) { style in
				ForEach([false, true], id: \.self) { isOpen in
					CommandBar(
						query: .constant("cap"),
						selectedID: .constant("history"),
						results: results,
						style: style,
						onShowActions: {},
						actionsPanel: isOpen ? content(query: "", selected: "peek", actions: actions) : nil,
						onSelect: { _ in },
						onDismiss: {}
					)
					.frame(width: 573)
				}
			}
		}
		.environment(\.commandBarIsStatic, true)
		.padding(32)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		try write(view, dark: dark, to: directory.appending(path: "command-bar-actions-bar-\(dark ? "dark" : "light").png"))
	}

	private func content(
		query: String,
		selected: String?,
		actions: [CommandBarActionItem]
	) -> CommandBarActionsContent {
		.init(
			title: "CaptureContext",
			query: .constant(query),
			selectedID: .constant(selected),
			actions: actions,
			onSelect: { _ in },
			onDismiss: {}
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
