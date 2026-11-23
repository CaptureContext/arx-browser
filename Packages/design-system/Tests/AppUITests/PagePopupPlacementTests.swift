import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Where a window's bottom pop-ups go (DEV-1260): centred on the page area beside the sidebar,
/// on either side or hidden, a toast's inset above the page's bottom edge. They were laid out
/// against the whole window, so an expanded sidebar pushed them off the page's centre.
@MainActor
@Suite(.renderTurn)
internal struct PagePopupPlacementTests {
	private static let size: CGSize = .init(width: 900, height: 500)
	private static let sidebarWidth: CGFloat = 240
	private static let inset: CGFloat = BrowserMetrics.PageCard.inset
	private static let popup: CGSize = .init(width: 300, height: 80)

	internal enum Sidebar: CaseIterable, Sendable {
		case leading
		case trailing
		case hidden
	}

	@Test(arguments: Sidebar.allCases)
	internal func popupCentresOnThePageBesideTheSidebar(sidebar: Sidebar) throws {
		let frame: FrameBox = .init()
		let pageFrame: FrameBox = .init()
		let window = Self.window(sidebar: sidebar, frame: frame, page: pageFrame)
		defer { window.close() }

		let popup = try #require(frame.value)
		let page = try #require(pageFrame.value)
		#expect(abs(page.width - Self.page(sidebar: sidebar).width) < 0.5)
		#expect(abs(popup.midX - page.midX) < 0.5)
		#expect(abs(popup.maxY - (page.maxY - PagePopupMetrics.bottomInset)) < 0.5)
		#expect(abs(popup.width - Self.popup.width) < 0.5)
		// Centred on the window, as `main` placed it, it would sit half the sidebar off the page's
		// centre.
		if sidebar != .hidden {
			#expect(abs(popup.midX - Self.size.width / 2) > Self.sidebarWidth / 2 - Self.inset)
		}
	}

	@Test
	internal func withoutAPageAreaPopupsCentreOnTheView() {
		let bounds: CGRect = .init(origin: .zero, size: Self.size)
		#expect(PagePopupMetrics.area(page: nil, in: bounds) == bounds)
		#expect(PagePopupMetrics.area(page: .init(x: 2_000, y: 0, width: 10, height: 10), in: bounds) == bounds)
	}

	@Test
	internal func aNarrowPageNarrowsThePopup() {
		let area: CGRect = .init(x: 240, y: 8, width: 200, height: 400)
		let frame = PagePopupMetrics.frame(size: Self.popup, in: area)
		#expect(frame.width == 200 - 2 * PagePopupMetrics.sideInset)
		#expect(frame.midX == area.midX)
		#expect(frame.maxY == area.maxY - PagePopupMetrics.bottomInset)
	}

	/// The page card's frame in the window for a sidebar `sidebar`, as the browser lays it out.
	private static func page(sidebar: Sidebar) -> CGRect {
		switch sidebar {
		case .leading:
			CGRect(x: sidebarWidth, y: inset, width: size.width - sidebarWidth - inset, height: size.height - 2 * inset)
		case .trailing:
			CGRect(x: inset, y: inset, width: size.width - sidebarWidth - inset, height: size.height - 2 * inset)
		case .hidden:
			CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
		}
	}

	private static func window(
		sidebar: Sidebar,
		frame: FrameBox,
		page pageFrame: FrameBox
	) -> NSWindow {
		let page = page(sidebar: sidebar)
		let view = ZStack(alignment: .topLeading) {
			Color.clear
			Color.gray
				.pagePopupArea()
				.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { pageFrame.value = $0 }
				.frame(width: page.width, height: page.height)
				.offset(x: page.minX, y: page.minY)
		}
		.frame(width: size.width, height: size.height)

		// As the browser's main view, under the title bar.
		.ignoresSafeArea()
		.pagePopups {
			Color.blue
				.frame(width: popup.width, height: popup.height)
				.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame.value = $0 }
		}
		let host = NSHostingView(rootView: view)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .closable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		return window
	}

	private final class FrameBox {
		internal var value: CGRect?
	}
}
