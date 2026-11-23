import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// DEV-1318: ⌃Tab's switcher lays its list out as DESIGN.md › Lists says, as the folder card's
/// search does: its inset is padding on the scrolled content, and the arrows bring a row in with
/// that inset, so the last highlight never ends flush with the card's edge.
@MainActor
@Suite(.serialized, .renderTurn)
internal struct TabSwitcherScrollingTests {
	/// The list's inset from the card at each end: the row's own half gap and the content padding.
	private static let inset: CGFloat = BrowserMetrics.TabSwitcher.padding

	@Test
	internal func theLastTabScrollsToTheEndWithTheInsetBelowIt() {
		let switcher = HostedTabSwitcher()
		defer { switcher.close() }

		switcher.select(HostedTabSwitcher.count - 1)

		#expect(switcher.offset > 0)
		#expect(switcher.offset == switcher.maximumOffset)
		// The last highlight ends the inset above the card's bottom edge.
		#expect(switcher.contentHeight - switcher.highlightEnd(HostedTabSwitcher.count - 1) == Self.inset)
	}

	@Test
	internal func theFirstTabScrollsBackToTheTopWithTheInset() {
		let switcher = HostedTabSwitcher()
		defer { switcher.close() }
		switcher.select(HostedTabSwitcher.count - 1)

		switcher.select(0)

		#expect(switcher.offset == 0)
	}

	/// A tab below the fold scrolls in only as far as it must, and with the inset under it.
	@Test
	internal func aTabTheArrowsReachKeepsTheInsetBelowIt() {
		let switcher = HostedTabSwitcher()
		defer { switcher.close() }

		switcher.select(9)

		let bottom = switcher.offset + switcher.viewportHeight
		#expect(abs(bottom - switcher.highlightEnd(9) - Self.inset) < 0.5)
	}

	/// Without scrolling, the card is as tall as its rows and the inset at each end.
	@Test(arguments: [1, 3, 9])
	internal func aShortListKeepsTheInsetAtBothEnds(count: Int) {
		let metrics = BrowserMetrics.TabSwitcher.self
		let switcher = HostedTabSwitcher(count: count)
		defer { switcher.close() }

		let highlights = CGFloat(count) * metrics.rowHeight + CGFloat(count - 1) * metrics.rowSpacing
		#expect(switcher.viewportHeight == highlights + 2 * Self.inset)
		#expect(switcher.maximumOffset == 0)
	}
}

/// ⌃Tab's switcher hosted in a window far off every screen, so its scroll view lays out and
/// scrolls as it does on screen.
@MainActor
private final class HostedTabSwitcher {
	internal static let count = 12

	private var selectedIndex = 0
	private let rows: [TabSwitcherRow]
	private let window: NSWindow
	private let host: NSHostingView<AnyView>

	internal init(count: Int = HostedTabSwitcher.count) {
		self.rows = (0..<count).map {
			TabSwitcherRow(
				id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!,
				title: "Tab \($0)",
				siteIcon: nil
			)
		}
		let size = CGSize(width: 500, height: 600)
		self.host = NSHostingView(rootView: AnyView(EmptyView()))
		host.frame = CGRect(origin: .zero, size: size)

		// Never shown: the window only gives the hosting view somewhere to lay out.
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		render()
		settle()
	}

	internal var offset: CGFloat {
		scrollView?.contentView.bounds.origin.y ?? -1
	}

	internal var viewportHeight: CGFloat {
		scrollView?.contentView.bounds.height ?? -1
	}

	internal var contentHeight: CGFloat {
		scrollView?.documentView?.frame.height ?? -1
	}

	/// The offset with the list scrolled to its very end.
	internal var maximumOffset: CGFloat {
		contentHeight - viewportHeight
	}

	/// Where row `index`'s highlight ends, from the top of the scrolled content.
	internal func highlightEnd(_ index: Int) -> CGFloat {
		let metrics = BrowserMetrics.TabSwitcher.self
		return metrics.padding + CGFloat(index + 1) * metrics.rowHeight + CGFloat(index) * metrics.rowSpacing
	}

	/// Moves the highlight, as ⌃Tab and the arrows do.
	internal func select(_ index: Int) {
		selectedIndex = index
		render()
		settle()
	}

	internal func close() {
		window.close()
	}

	private var scrollView: NSScrollView? {
		Self.scrollViews(in: host).first
	}

	private func render() {
		host.rootView = AnyView(TabSwitcherView(rows: rows, selectedIndex: selectedIndex))
	}

	private func settle() {
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
	}

	private static func scrollViews(in view: NSView) -> [NSScrollView] {
		(view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews(in:))
	}
}
