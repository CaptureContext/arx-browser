import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Where `arxToast` puts its toast (DEV-823): its insets are measured from the view's own edges,
/// so in a browser window, whose content runs under a transparent title bar, the toast sits as
/// far below the page's top as in from its trailing edge.
@MainActor
@Suite(.renderTurn)
internal struct ArxToastPlacementTests {
	@Test(arguments: [false, true])
	internal func toastSitsAtEqualTopAndTrailingInsets(titled: Bool) throws {
		let frame = FrameBox()
		let inset: CGFloat = BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset
		let view = Color.clear
			.ignoresSafeArea()
			.arxToast(isPresented: true, topInset: inset, trailingInset: inset) {
				ArxToast("Copied Current URL")
					.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame.value = $0 }
			}
		let size: CGSize = .init(width: 640, height: 400)
		let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: titled ? [.titled, .closable, .fullSizeContentView] : [.borderless],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer { window.close() }
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		if titled { #expect(host.safeAreaInsets.top > 0) }

		let toast = try #require(frame.value)
		#expect(abs(toast.minY - inset) < 0.5)
		#expect(abs((size.width - toast.maxX) - inset) < 0.5)
	}

	private final class FrameBox {
		internal var value: CGRect?
	}
}
