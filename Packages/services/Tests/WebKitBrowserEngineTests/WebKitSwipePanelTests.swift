import AppKit
import Foundation
import Testing

@testable import WebKitBrowserEngine

/// DEV-1203: the WebKit swipe indicator, ported from Chromium's `panel.mm`.
@Suite
@MainActor
internal struct WebKitSwipePanelTests {
	private typealias Metrics = WebKitSwipePanel.Metrics

	/// A window far off every screen, never made key, with a page-sized view to swipe.
	private func source() -> (NSWindow, NSView) {
		let window: NSWindow = .init(
			contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let view: NSView = .init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
		window.contentView = view
		window.orderBack(nil)
		return (window, view)
	}

	/// Lets arming's 0.22 s animation finish, as panel.mm animates it too.
	private func settle() {
		RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
	}

	@Test
	internal func showsAfterAnUpdateAndFillsAtFullProgress() {
		let (window, view) = self.source()
		defer { window.close() }

		let panel: WebKitSwipePanel = .init(source: view, direction: .back)
		panel.update(progress: 0.5, armed: false, selected: 0)
		#expect(panel.isVisible)
		#expect(!panel.isFilled)
		#expect(!panel.isArmed)

		panel.update(progress: 1, armed: false, selected: 0)
		#expect(panel.isFilled)
		#expect(!panel.isArmed)
	}

	private func rows(_ count: Int) -> [WebKitSwipePanel.Row] {
		(0..<count).map { .init(title: "Page \($0 + 1)", host: "example.com") }
	}

	@Test
	internal func armsWithEntriesIntoAListBesideTheSolidCircle() {
		let (window, view) = self.source()
		defer { window.close() }

		let panel: WebKitSwipePanel = .init(source: view, direction: .back)
		panel.setEntries(self.rows(3))
		panel.update(progress: 1, armed: false, selected: 0)
		#expect(!panel.isListVisible)

		panel.update(progress: 1, armed: true, selected: 1)
		self.settle()
		#expect(panel.isArmed)
		#expect(!panel.isFilled)
		#expect(panel.isListVisible)
		// The circle stays a circle; the list opens beside it.
		#expect(panel.indicatorFrame.size == NSSize(width: Metrics.circle, height: Metrics.circle))
		#expect(panel.listFrame.width == Metrics.listWidth)
		#expect(panel.listFrame.minX == panel.indicatorFrame.midX + Metrics.ring / 2 + Metrics.listGap)
	}

	/// DEV-1276: five rows at most, the window starting two above the selection and clamped to
	/// the ends.
	@Test
	internal func showsAtMostFiveRowsAroundTheSelection() {
		#expect(WebKitSwipePanel.windowStart(selected: 2, count: 3) == 0)
		#expect(WebKitSwipePanel.windowStart(selected: 4, count: 5) == 0)
		#expect((0..<10).map { WebKitSwipePanel.windowStart(selected: $0, count: 10) } == [0, 0, 0, 1, 2, 3, 4, 5, 5, 5])
	}

	/// DEV-1276: the selected row is always level with the arrow; the list moves only near the ends.
	@Test(arguments: [3, 5, 10])
	internal func keepsTheSelectionLevelWithTheArrow(_ count: Int) {
		let (window, view) = self.source()
		defer { window.close() }

		let panel: WebKitSwipePanel = .init(source: view, direction: .back)
		panel.setEntries(self.rows(count))
		let shown: CGFloat = CGFloat(min(count, Metrics.maxRows))
		var tops: [CGFloat] = []
		for selected in 0..<count {
			panel.update(progress: 1, armed: true, selected: selected)
			self.settle()
			#expect(panel.selectedRowFrame.midY == panel.indicatorFrame.midY)
			#expect(panel.listFrame.height == 2 * Metrics.listPadding + shown * Metrics.rowPitch - Metrics.rowSpacing)
			tops.append(panel.listFrame.maxY)
		}

		// The list holds still while the window scrolls through the middle.
		if count == 10 {
			#expect(Set(tops[2...7]).count == 1)
			#expect(tops[0] < tops[1] && tops[1] < tops[2])
			#expect(tops[7] < tops[8] && tops[8] < tops[9])
		}
	}

	/// DEV-1292: back's list runs down from the nearest entry, forward's runs up from it.
	@Test
	internal func forwardSlotsRunBottomUp() {
		#expect((0..<4).map { WebKitSwipePanel.slot(of: $0, count: 4, direction: .back) } == [0, 1, 2, 3])
		#expect((0..<4).map { WebKitSwipePanel.slot(of: $0, count: 4, direction: .forward) } == [3, 2, 1, 0])
	}

	/// DEV-1292: forward's list mirrors back's. It rises from the arrow with the nearest entry at the
	/// bottom, level with the arrow, and further entries above it; back's hangs down with the
	/// nearest on top.
	@Test(arguments: [WebKitSwipeDirection.back, .forward], [1, 3, 5, 10])
	internal func forwardMirrorsBack(
		_ direction: WebKitSwipeDirection,
		_ count: Int
	) {
		let (window, view) = self.source()
		defer { window.close() }

		let panel: WebKitSwipePanel = .init(source: view, direction: direction)
		panel.setEntries(self.rows(count))
		var edges: [CGFloat] = []
		var rows: [CGFloat] = []
		for selected in 0..<count {
			panel.update(progress: 1, armed: true, selected: selected)
			self.settle()
			#expect(panel.selectedRowFrame.midY == panel.indicatorFrame.midY)
			rows.append(panel.selectedRowFrame.midY)
			edges.append(direction == .back ? panel.listFrame.maxY : panel.listFrame.minY)
			if selected == 0 {
				// Nearest entry first: the edge row beside the arrow, the tile on the far side.
				let inset: CGFloat = Metrics.listPadding + Metrics.rowHeight / 2
				switch direction {
				case .back: #expect(panel.listFrame.maxY == panel.indicatorFrame.midY + inset)
				case .forward: #expect(panel.listFrame.minY == panel.indicatorFrame.midY - inset)
				}
			}
		}

		// The selection stays level with the arrow, so the list itself moves: up for back (rows
		// further down come up to the arrow), down for forward.
		for (previous, next) in zip(edges, edges.dropFirst()) {
			switch direction {
			case .back: #expect(next >= previous)
			case .forward: #expect(next <= previous)
			}
		}
		if count == 10 {
			#expect(Set(edges[2...7]).count == 1)
		}
	}

	@Test
	internal func dismisses() {
		let (window, view) = self.source()
		defer { window.close() }

		let panel: WebKitSwipePanel = .init(source: view, direction: .forward)
		panel.update(progress: 0.5, armed: true, selected: 0)
		panel.dismiss()
		#expect(!panel.isVisible)
		#expect(!panel.isArmed)
		#expect(window.childWindows?.isEmpty ?? true)
	}

	@Test
	internal func dismissesWhenReleased() {
		let (window, view) = self.source()
		defer { window.close() }

		do {
			let panel: WebKitSwipePanel = .init(source: view, direction: .back)
			panel.update(progress: 0.5, armed: false, selected: 0)
			#expect(window.childWindows?.count == 1)
		}
		#expect(window.childWindows?.isEmpty ?? true)
	}

	@Test
	internal func doesNothingWithoutAWindow() {
		let view: NSView = .init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
		let panel: WebKitSwipePanel = .init(source: view, direction: .back)
		panel.update(progress: 1, armed: true, selected: 0)
		#expect(!panel.isVisible)
		#expect(!panel.isArmed)
	}

	/// Back sits inset from the left edge, forward from the right, both centred vertically.
	@Test(arguments: [WebKitSwipeDirection.back, .forward])
	internal func sitsOnTheSwipedEdge(_ direction: WebKitSwipeDirection) {
		let (window, view) = self.source()
		defer { window.close() }

		let panel: WebKitSwipePanel = .init(source: view, direction: direction)
		panel.update(progress: 0.5, armed: false, selected: 0)

		let sourceFrame: NSRect = window.convertToScreen(view.convert(view.bounds, to: nil))
		#expect(panel.panelFrame == sourceFrame)

		let frame: NSRect = panel.indicatorFrame
		let edgeGap: CGFloat = Metrics.inset + Metrics.ring / 2 - Metrics.circle / 2
		#expect(frame.size == NSSize(width: Metrics.circle, height: Metrics.circle))
		#expect(frame.midY == view.bounds.midY)
		switch direction {
		case .back: #expect(frame.minX == edgeGap)
		case .forward: #expect(frame.maxX == view.bounds.width - edgeGap)
		}

		// Armed, the list opens beside the circle, away from the swiped edge.
		panel.setEntries(self.rows(2))
		panel.update(progress: 1, armed: true, selected: 0)
		self.settle()
		#expect(panel.indicatorFrame == frame)
		let list: NSRect = panel.listFrame
		switch direction {
		case .back: #expect(list.minX == frame.maxX + (Metrics.ring - Metrics.circle) / 2 + Metrics.listGap)
		case .forward: #expect(list.maxX == frame.minX - (Metrics.ring - Metrics.circle) / 2 - Metrics.listGap)
		}
	}
}
