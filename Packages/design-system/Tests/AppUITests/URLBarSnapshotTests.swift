import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of the address bars' copy-link and site-menu buttons, light and dark,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory: the sidebar's at rest with a short and a long
/// address and with no tab, Little Arx's prominent layout (DEV-739), and split pane headers with a
/// page and without one (DEV-995).
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct URLBarSnapshotTests {
	@Test(arguments: [false, true])
	internal func actions(dark: Bool) throws {
		let short = try #require(URL(string: "https://capturecontext.dev/arx"))
		let long = try #require(URL(string: "https://www.figma.com/design/j6ck6pjiiys14acwutb4rk/dashboard-flaws?node-id=0-1"))

		// At rest, not hovered: the buttons show while a page is shown (DEV-995).
		let view = VStack(alignment: .leading, spacing: 16) {
			URLBar(url: short, onActivate: {}, onCopy: {})
				.frame(width: 260)
			URLBar(url: long, onActivate: {}, onCopy: {})
				.frame(width: 260)
			URLBar(url: nil, onActivate: {}, onCopy: {})
				.frame(width: 260)
			URLBar(url: short, prominentActions: true, onActivate: {}, onCopy: {})
				.frame(width: 360)
		}
		.environment(\.sidebarIsStatic, true)
		.padding(24)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		try Self.write(view, dark: dark, name: "url-bar-actions")
	}

	/// The sidebar's address bar plain, hovered and pressed, with `ARX_INLINE_BUTTONS` off
	/// (`url-bar-buttons-before`) and on (`url-bar-buttons`). The state reaches every control in
	/// a row, so a hovered row shows the field and both buttons hovered at once.
	@Test(arguments: [false, true])
	internal func buttonStates(dark: Bool) throws {
		let url = try #require(URL(string: "https://capturecontext.dev/arx"))
		let states: [(String, ArxControlStateOverride)] = [
			("Plain", .init()),
			("Hovered", .init(isHovered: true)),
			("Pressed", .init(isHovered: true, isPressed: true)),
		]
		let wasEnabled = ChromeInlineButtons.isEnabled
		defer { ChromeInlineButtons.isEnabled = wasEnabled }
		for (isEnabled, name) in [(false, "url-bar-buttons-before"), (true, "url-bar-buttons")] {
			ChromeInlineButtons.isEnabled = isEnabled
			let view = VStack(alignment: .leading, spacing: 14) {
				ForEach(states, id: \.0) { title, state in
					HStack(spacing: 14) {
						Text(verbatim: title)
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
							.frame(width: 56, alignment: .trailing)
						URLBar(url: url, onActivate: {}, onCopy: {})
							.frame(width: 260)
							.arxControlState(state)
					}
				}
			}
			.environment(\.sidebarIsStatic, true)
			.padding(24)
			.background(Color(nsColor: .windowBackgroundColor))
			.fixedSize()

			try Self.write(view, dark: dark, name: name)
		}
	}

	@Test(arguments: [false, true])
	internal func paneHeaderActions(dark: Bool) throws {
		let short = try #require(URL(string: "https://capturecontext.dev/"))
		let long = try #require(URL(string: "https://rezka.ag/ua/films/drama/3311-babaduk-2014.html"))
		let view = VStack(alignment: .leading, spacing: 12) {
			Self.paneHeader(url: short)
			Self.paneHeader(url: long)
			Self.paneHeader(url: nil)
		}
		.padding(16)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		try Self.write(view, dark: dark, name: "pane-header-actions")
	}

	/// A split pane header as the viewer lays it out: the address centred, its buttons and the
	/// close button at the end.
	private static func paneHeader(url: URL?) -> some View {
		HStack(spacing: 0) {
			Color.clear
				.frame(maxWidth: .infinity)
			Group {
				if let url {
					PaneAddress(url: url)
				} else {
					Text(String.localized(.appUI.url.search))
				}
			}
			.font(.system(size: BrowserMetrics.PaneHeader.hostFontSize))
			.layoutPriority(1)
			HStack(spacing: 2) {
				if let url {
					PaneHeaderActions(url: url, isActive: true, onActivate: {}, onCopy: {})
				}
				Button {} label: { Image(systemName: "xmark") }
			}
			.frame(maxWidth: .infinity, alignment: .trailing)
		}
		.buttonStyle(BrowserToolbarButtonStyle())
		.font(.system(size: BrowserMetrics.PaneHeader.symbolSize, weight: .medium))
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.horizontal, BrowserMetrics.PaneHeader.horizontalPadding)
		.frame(width: 420, height: BrowserMetrics.PaneHeader.height)
		.background(BrowserTheme.page.opacity(0.6), in: .rect(cornerRadius: 6))
	}

	private static func write(
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
		defer { window.close() }
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
	}
}
