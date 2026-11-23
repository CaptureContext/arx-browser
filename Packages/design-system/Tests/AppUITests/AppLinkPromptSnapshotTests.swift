import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of the portrait app link prompt (DEV-872): Land with its script shown
/// and Always allow, and Open "App"?, in light and dark, when `ARX_DESIGN_SNAPSHOTS` names a
/// directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct AppLinkPromptSnapshotTests {
	@Test(arguments: [false, true])
	internal func prompts(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = HStack(alignment: .top, spacing: 16) {
			AppLinkPromptCard(
				icon: nil,
				symbol: "terminal",
				title: "Send This Link to Claude Work?",
				source: "claude.ai wants to open this link.",
				link: "claude://login/callback?code=4f1c2e9a-7b3d-4f0e-9c61-2a8d5e7f9b10&state=work",
				details: {
					Text("Arx runs your script with the link as $1.")
						.foregroundStyle(.secondary)
					Text(#"fxclaude open-url work "$1""#)
						.font(.callout.monospaced())
						.padding(8)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(.quaternary, in: ArxControlShape())
					Toggle("Always allow claude.ai to open this", isOn: .constant(false))
						.toggleStyle(.checkbox)
				},
				actions: {
					AppLinkPromptButton("Hide Script") {}
					AppLinkPromptButton("Cancel", keyHint: .escape) {}
					AppLinkPromptConfirm("Send to Claude Work", copyTitle: "Copy Link", onConfirm: {}, onCopy: {})
				}
			)
			.background(ArxModalMetrics.background)
			AppLinkPromptCard(
				icon: NSImage(named: NSImage.applicationIconName),
				symbol: "app",
				title: "Open “Claude”?",
				source: "claude.ai wants to open this link.",
				link: "claude://login/callback?code=1",
				details: { EmptyView() },
				actions: {
					AppLinkPromptButton("Cancel", keyHint: .escape) {}
					AppLinkPromptConfirm("Open Claude", copyTitle: "Copy Link", onConfirm: {}, onCopy: {})
				}
			)
			.background(ArxModalMetrics.background)
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
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
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "app-link-prompt-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
