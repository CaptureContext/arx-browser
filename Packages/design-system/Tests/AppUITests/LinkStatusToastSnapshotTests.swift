import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of the link status (DEV-1111) at a page card's bottom-left corner, light
/// and dark: a short address, a long one truncated in the middle, and actions with the address
/// inside them, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct LinkStatusToastSnapshotTests {
	private static let long = "github.com/emilkowalski/skills/tree/main/skills/apple-design/references/motion-and-springs.md"

	@Test(arguments: [false, true])
	internal func linkStatus(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = VStack(spacing: 16) {
			page { LinkStatusToast(address: "example.com/about") }
			page { LinkStatusToast(address: Self.long) }
			page { LinkStatusToast(verb: "Open", address: "example.com/about", action: "in a new tab and go to it") }
			page { LinkStatusToast(verb: "Open", address: Self.long, action: "in a new tab and go to it") }
			page { LinkStatusToast(verb: "Download", address: "example.com/files/report.pdf") }
		}
		.padding(16)
		.background { BrowserChromeBackground(textured: true) }
		.environment(\.sidebarIsStatic, true)
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
		try data.write(to: directory.appending(path: "link-status-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// A page card with a few lines of text, the status at its bottom-left corner, no wider than
	/// two thirds of the page, as the presenter places it.
	private func page<Status: View>(@ViewBuilder status: () -> Status) -> some View {
		let width: CGFloat = 520
		return VStack(alignment: .leading, spacing: 10) {
			RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.12)).frame(width: 220, height: 14)
			RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)).frame(width: 380, height: 10)
		}
		.padding(24)
		.frame(width: width, height: 110, alignment: .topLeading)
		.browserPageCard()
		.overlay(alignment: .bottomLeading) {
			status()
				.frame(maxWidth: width * LinkStatusToastMetrics.maximumWidthFraction, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
				.padding(LinkStatusToastMetrics.edgeInset)
		}
	}
}
