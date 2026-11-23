import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// The command bar's one look, Raised (DEV-1277): a glass panel in a physical bezel with Actions
/// ⌘K floating over its bottom-right corner, as Figma's Components • CommandBar draws it. With
/// `ARX_DESIGN_SNAPSHOTS` naming a directory, writes it in light and dark over a busy page and
/// over an empty one, with ⌘K's actions closed and open.
@MainActor
@Suite(.renderTurn)
internal struct CommandBarRaisedTests {
	private static let results: [CommandBarResult] = [
		.init(id: "tab", title: "CaptureContext", subtitle: "https://capturecontext.dev", actionTitle: "Switch to Tab", symbol: "globe"),
		.init(id: "history", title: "CaptureContext", subtitle: "https://capturecontext.dev", actionTitle: "Open URL", symbol: "clock.arrow.circlepath"),
		.init(id: "other", title: "Arx Manual", subtitle: "https://manual.arx.capturecontext.dev", actionTitle: "Open URL", symbol: "clock.arrow.circlepath"),
		.init(id: "search", title: "cap", subtitle: "Google Search", actionTitle: "Command", symbol: "magnifyingglass"),
		.init(id: "off", title: "Capture Area", subtitle: "Capture", actionTitle: "Command", symbol: "camera.viewfinder", isEnabled: false),
		.init(id: "table", title: "Cap Table", subtitle: "https://cap.example", actionTitle: "Open URL", symbol: "clock.arrow.circlepath"),
		.init(id: "capital", title: "Capital One", subtitle: "https://capitalone.com", actionTitle: "Switch to Tab", symbol: "globe"),
		.init(id: "caps", title: "Caps Lock", subtitle: "Settings › Keyboard", actionTitle: "Show in Settings", symbol: "gearshape"),
	]

	private static let actions: [CommandBarActionItem] = [
		.init(id: "primary", title: "Switch to Tab", symbol: "square.on.square", shortcut: "↩"),
		.init(id: "peek", title: "Open in Peek", symbol: "eye", shortcut: "⇧↩"),
		.init(id: "little", title: "Open in Little Arx", symbol: "macwindow", shortcut: "⌥⌘↩"),
		.init(id: "copy", title: "Copy URL", symbol: "link", shortcut: "⇧⌘C"),
		.init(id: "close", title: "Close Tab", symbol: "xmark", shortcut: "⌃X", isDestructive: true),
	]

	/// Eight results fill the palette: 476 points, the bezel's insets, the input, the divider
	/// and the results' room.
	@Test
	internal func thePaletteIsAsTallAsFigmasWithEightResults() {
		let size = NSHostingView(rootView: bar(style: .palette)).fittingSize
		let metrics = BrowserMetrics.CommandBar.self
		#expect(size.height == 476)
		#expect(size.height == 2 * metrics.contentInset + metrics.inputHeight + 1 + metrics.maximumResultsHeight)
	}

	/// The rows sit 12 points in from the panel's edge, so their corners are concentric with its 24.
	@Test
	internal func theRowsAreConcentricWithThePanel() {
		let style = CommandBarStyle.palette
		#expect(style.cornerRadius == 24)
		#expect(style.rowCornerRadius == style.cornerRadius - style.contentInset - style.resultsPadding)
		#expect(style.rowCornerRadius == 12)
	}

	/// Opening the actions changes nothing about the bar's size: the button, and the search field
	/// that takes its place, float over the results.
	@Test(arguments: [CommandBarStyle.palette, .urlField, .launcher])
	internal func theActionsFloatOverTheBar(style: CommandBarStyle) {
		let closed = NSHostingView(rootView: bar(style: style)).fittingSize
		let open = NSHostingView(rootView: bar(style: style, actionsOpen: true)).fittingSize
		#expect(closed == open)
	}

	@Test
	internal func keycapsSplitModifiersFromTheKey() {
		#expect(CommandBarActionsButton.keycaps("⌘K") == ["⌘", "K"])
		#expect(CommandBarActionsButton.keycaps("⌘↩") == ["⌘", "↩"])
		#expect(CommandBarActionsButton.keycaps("⌥⇧⌘P") == ["⌥", "⇧", "⌘", "P"])
		#expect(CommandBarActionsButton.keycaps("↩") == ["↩"])
		#expect(CommandBarActionsButton.keycaps("⌘") == ["⌘"])
	}

	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [false, true]
	)
	internal func look(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let sheet = VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .top, spacing: 0) {
				bar(style: .palette)
					.padding(40)
					.background { Self.busyPage }
					.clipped()
				bar(style: .palette, actionsOpen: true)
					.padding(40)
					.background { Self.busyPage }
					.clipped()
			}
			HStack(alignment: .top, spacing: 0) {
				bar(style: .urlField, results: Array(Self.results.prefix(4)))
					.padding(40)
					.background { Self.busyPage }
					.clipped()
				bar(style: .launcher, results: Array(Self.results.prefix(3)))
					.padding(40)
					.background(BrowserTheme.page)
			}
		}
		.environment(\.commandBarIsStatic, true)
		let name = "command-bar-raised-\(dark ? "dark" : "light").png"
		try write(sheet, dark: dark, to: directory.appending(path: name))
	}

	private func bar(
		style: CommandBarStyle,
		results: [CommandBarResult] = Self.results,
		actionsOpen: Bool = false
	) -> some View {
		CommandBar(
			query: .constant("cap"),
			selectedID: .constant("tab"),
			results: results,
			style: style,
			onAskAgent: {},
			onShowActions: {},
			actionsPanel: actionsOpen ? .init(
				title: "CaptureContext",
				query: .constant(""),
				selectedID: .constant("peek"),
				actions: Self.actions,
				onSelect: { _ in },
				onDismiss: {}
			) : nil,
			onSelect: { _ in },
			onDismiss: {}
		)
		.frame(width: style == .launcher ? BrowserMetrics.LittleArx.Launcher.width : 573)
		.environment(\.commandBarIsStatic, true)
	}

	/// A page with colour, type and edges under the bar, as a news site would put there.
	private static var busyPage: some View {
		ZStack(alignment: .topLeading) {
			LinearGradient(colors: [.orange, .pink, .indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
			VStack(alignment: .leading, spacing: 10) {
				ForEach(0..<16, id: \.self) { line in
					Text(verbatim: "Swift 6.4 released: typed throws everywhere, faster builds, line \(line)")
						.font(.system(size: line.isMultiple(of: 4) ? 22 : 14, weight: line.isMultiple(of: 4) ? .bold : .regular))
						.foregroundStyle(line.isMultiple(of: 3) ? Color.white : Color.black)
				}
			}
			.padding(16)
		}
	}

	private func write(
		_ view: some View,
		dark: Bool,
		to file: URL
	) throws {
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
		try data.write(to: file)
		window.close()
	}
}
