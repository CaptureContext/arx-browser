import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of the toast (DEV-769) at the top-right of a page card, in two chrome
/// tints, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory. Offscreen renders can't
/// draw Liquid Glass, so these show its material fallback.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct ArxToastSnapshotTests {
	@Test(arguments: [false, true])
	internal func toasts(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = VStack(spacing: 16) {
			page(tint: .default) {
				ArxToast("Copied Current URL") { shareButton }
			}
			page(tint: .default, hovered: true) {
				ArxToast("Copied Clean Link") {
					Button("Copy Original") {}
						.buttonStyle(.arxRaised(size: .small))
					shareButton
				}
			}
			page(tint: .init(hue: 150, intensity: 0.35)) {
				ArxToast("Couldn't Copy Link", detail: "The link could not be written to the clipboard.")
			}
		}
		.environment(\.sidebarIsStatic, true)
		.padding(16)
		.background { BrowserChromeBackground(textured: true) }
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
		try data.write(to: directory.appending(path: "toast-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// The toast at a browser window's corner (DEV-823): the window's content runs under its
	/// transparent title bar, the page card sits ``BrowserMetrics/PageCard/inset`` in from the
	/// window's edges, and the toast as far below the page's top as in from its trailing edge.
	@Test(arguments: [false, true])
	internal func windowCorner(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let inset: CGFloat = BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset
		let size: CGSize = .init(width: 640, height: 260)
		let view = ZStack {
			BrowserChromeBackground(textured: true)
			Color.clear
				.browserPageCard()
				.padding(BrowserMetrics.PageCard.inset)
		}
		.ignoresSafeArea()
		.arxToast(isPresented: true, topInset: inset, trailingInset: inset) {
			ArxToast("Copied Current URL") { shareButton }
		}
		.environment(\.sidebarIsStatic, true)
		.frame(width: size.width, height: size.height)

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .closable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
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
		try data.write(to: directory.appending(path: "toast-corner-\(dark ? "dark" : "light").png"))
		window.close()
	}

	private var shareButton: some View {
		Button {} label: { Image(systemName: "square.and.arrow.up") }
			.buttonStyle(.arxRaised(size: .small))
	}

	/// A page card with a few lines of text, with the toast placed as a window places it.
	private func page<Toast: View>(
		tint: ChromeTint,
		hovered: Bool = false,
		@ViewBuilder toast: () -> Toast
	) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.12)).frame(width: 220, height: 14)
			RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)).frame(width: 380, height: 10)
			RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)).frame(width: 320, height: 10)
		}
		.padding(24)
		.frame(width: 560, height: 150, alignment: .bottomLeading)
		.browserPageCard()
		.arxToast(isPresented: true) {
			toast().arxControlState(.init(isHovered: hovered ? true : nil))
		}
		.environment(\.browserChromeTint, tint)
	}
}
