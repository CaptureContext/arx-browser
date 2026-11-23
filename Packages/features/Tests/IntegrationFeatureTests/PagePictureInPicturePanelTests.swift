import AppKit
import AppUI
import BrowserCore
import BrowserSurfaceClient
import CustomDump
import Foundation
import SwiftUI
import Testing
import _TestSupport

@testable import AppFeature

/// Page PiP's window after a resize (Max, 17 Nov): the page fills its card under the header, and
/// the window can't be made smaller than its minimum.
@MainActor
@Suite(.renderTurn, .dependencies, .serialized)
internal struct PagePictureInPicturePanelTests {
	/// The window's content gives AppKit the window's minimum, so a resize stops there. A plain
	/// hosting view gave only the header's, and a drag shrank the window to the header and the
	/// page to nothing.
	@Test
	internal func theContentKeepsTheWindowsMinimumSize() async throws {
		let (panel, _) = Self.floating()
		defer { Self.close(panel) }

		expectNoDifference(panel.contentMinSize, PagePictureInPicturePanel.minimumSize)
	}

	/// Grown, shrunk to the minimum and grown again, the page fills the card under the header.
	@Test
	internal func thePageFillsItsCardAfterEveryResize() async throws {
		let (panel, page) = Self.floating()
		defer { Self.close(panel) }

		let sizes: [NSSize] = [
			PagePictureInPicturePanel.defaultSize,
			.init(width: 900, height: 700),
			PagePictureInPicturePanel.minimumSize,
			.init(width: 300, height: 640),
			.init(width: 760, height: PagePictureInPicturePanel.minimumSize.height),
			PagePictureInPicturePanel.defaultSize,
		]
		for size in sizes {
			panel.setFrame(.init(origin: panel.frame.origin, size: size), display: true)
			panel.contentView?.layoutSubtreeIfNeeded()

			expectNoDifference(page.convert(page.bounds, to: nil), Self.card(in: size))
		}
	}

	/// Where the page belongs in a window of `size`: under the header, inset as Little Arx's card.
	private static func card(in size: NSSize) -> CGRect {
		let inset = BrowserMetrics.LittleArx.pageInset
		return .init(
			x: inset,
			y: inset,
			width: size.width - 2 * inset,
			height: size.height - BrowserMetrics.LittleArx.toolbarHeight - inset
		)
	}

	/// Page PiP's window with a stand-in page, mounted as the engine mounts one: filling its host
	/// and following it by autoresizing.
	private static func floating() -> (PagePictureInPicturePanel, NSView) {
		let page = NSView()
		let surface = BrowserSurfaceClient(
			attach: { _, host in
				guard page.superview !== host else { return }
				page.frame = host.bounds
				page.autoresizingMask = [.width, .height]
				host.addSubview(page)
			},
			detach: { _ in }
		)
		let panel = PagePictureInPicturePanel(
			contentSize: PagePictureInPicturePanel.defaultSize,
			on: NSScreen.main,
			siteKey: nil
		)
		panel.show(PagePictureInPictureView(
			tabID: .init(rawValue: UUID(1)),
			surface: surface,
			url: URL(string: "https://example.com"),
			isLoading: false,
			profiles: ([], nil),
			onSelectProfile: { _ in },
			onReturnToTab: {},
			onBack: nil,
			onForward: nil,
			onCopy: {},
			notice: nil,
			onVisibility: { _ in }
		))

		// On screen, where a hosting view hands AppKit its minimum, but out of sight.
		panel.setFrameOrigin(.init(x: -20_000, y: -20_000))
		panel.orderFrontRegardless()
		panel.contentView?.layoutSubtreeIfNeeded()
		panel.update()
		RunLoop.main.run(until: .now.addingTimeInterval(0.1))
		return (panel, page)
	}

	private static func close(_ panel: PagePictureInPicturePanel) {
		panel.contentView = nil
		panel.close()
	}
}
