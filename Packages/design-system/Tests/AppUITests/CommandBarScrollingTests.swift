import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// DEV-1265: while the person scrolls the command bar's results, nothing but their scroll moves
/// the list. Arrow keys still bring the highlight into view.
@MainActor
@Suite(.serialized, .renderTurn)
internal struct CommandBarScrollingTests {
	// MARK: - The policy

	@Test
	internal func aPointerRestingOverTheListAsItOpensHighlightsNothing() {
		let scrolling = CommandBarListScrolling(pointerLocation: Self.pointer)

		#expect(!scrolling.pointerMoved(over: "a", at: Self.pointer))
		#expect(scrolling.pointerMoved(over: "a", at: Self.movedPointer))
	}

	@Test
	internal func rowsSlidingUnderARestingPointerHighlightNothing() {
		let scrolling = CommandBarListScrolling(pointerLocation: nil)

		#expect(scrolling.pointerMoved(over: "a", at: Self.pointer))
		#expect(!scrolling.pointerMoved(over: "b", at: Self.pointer))
		#expect(!scrolling.pointerMoved(over: "c", at: Self.pointer))
	}

	@Test
	internal func movingWithinARowThatSlidUnderThePointerHighlightsIt() {
		let scrolling = CommandBarListScrolling(pointerLocation: Self.pointer)

		#expect(!scrolling.pointerMoved(over: "a", at: Self.pointer))
		#expect(scrolling.pointerMoved(over: "a", at: Self.movedPointer))
	}

	/// The host may refuse the pointer's highlight, as the bar does while ⌘K's panel is open, so
	/// the pointer moving within that row later still offers it again.
	@Test
	internal func aRowWhoseHighlightWasRefusedIsOfferedAgain() {
		let scrolling = CommandBarListScrolling(pointerLocation: nil)

		#expect(scrolling.pointerMoved(over: "a", at: Self.pointer))
		#expect(scrolling.pointerMoved(over: "a", at: Self.movedPointer))
	}

	@Test
	internal func theListNeverScrollsToThePointersHighlight() {
		let scrolling = CommandBarListScrolling(pointerLocation: nil)

		#expect(scrolling.pointerMoved(over: "a", at: Self.pointer))
		#expect(!scrolling.scrolls(to: "a"))
		// A highlight the host moves afterwards, as new results arrive, still scrolls.
		#expect(scrolling.scrolls(to: "b"))
	}

	@Test
	internal func duringAScrollOnlyTheKeyboardsHighlightScrollsTheList() {
		let scrolling = CommandBarListScrolling(pointerLocation: nil)
		scrolling.isScrolling = true

		#expect(!scrolling.scrolls(to: "a"))
		scrolling.keyboardMoved(to: "b")
		#expect(scrolling.scrolls(to: "b"))

		scrolling.isScrolling = false
		#expect(scrolling.scrolls(to: "c"))
	}

	// MARK: - The bar

	/// The recording's jump: the pointer highlights a row the list's bottom edge cuts, and the list
	/// used to scroll 36 points to show all of it, out from under the pointer.
	@Test
	internal func thePointersHighlightLeavesTheListWhereItIs() throws {
		let bar = HostedCommandBar()
		defer { bar.close() }
		bar.scroll(to: 20)

		#expect(bar.scrolling.pointerMoved(over: HostedCommandBar.cutRow, at: Self.pointer))
		bar.select(HostedCommandBar.cutRow)

		#expect(bar.offset == 20)
	}

	@Test
	internal func aHighlightTheHostMovesStillComesIntoView() throws {
		let bar = HostedCommandBar()
		defer { bar.close() }
		bar.scroll(to: 20)

		bar.select(HostedCommandBar.cutRow)

		#expect(bar.offset > 20)
	}

	@Test
	internal func theKeyboardsHighlightComesIntoViewEvenDuringAScroll() throws {
		let bar = HostedCommandBar()
		defer { bar.close() }
		bar.scroll(to: 20)
		bar.scrolling.isScrolling = true

		bar.scrolling.keyboardMoved(to: HostedCommandBar.cutRow)
		bar.select(HostedCommandBar.cutRow)

		#expect(bar.offset > 20)
	}

	// MARK: - DESIGN.md › Lists (DEV-1289)

	/// The first row keeps the list's inset when the keyboard moves back to it: the list scrolls
	/// to its very top, not only until the row shows.
	@Test
	internal func theFirstResultScrollsBackToTheTopWithTheInset() throws {
		let bar = HostedCommandBar()
		defer { bar.close() }
		bar.select("r11")
		#expect(bar.offset > 0)

		bar.scrolling.keyboardMoved(to: "r0")
		bar.select("r0")

		#expect(bar.offset == 0)
	}

	/// The last row scrolls in with Actions ⌘K's room under it: the list scrolls to its very end,
	/// whose padding reserves the floating button's height, inset and a gap.
	@Test
	internal func theLastResultScrollsToTheEndClearOfActions() throws {
		let bar = HostedCommandBar()
		defer { bar.close() }

		bar.scrolling.keyboardMoved(to: "r11")
		bar.select("r11")

		#expect(bar.offset > 0)
		#expect(bar.offset == bar.maximumOffset)
	}

	/// A row in the middle scrolls in with Actions ⌘K's room below it too, so the button never
	/// covers the highlight the arrows moved to, and the list scrolls only as far as that: the
	/// highlight ends as far above the button as the button sits in from the glass (DEV-1318).
	@Test
	internal func aRowTheKeyboardReachesStopsClearOfActions() throws {
		let bar = HostedCommandBar()
		defer { bar.close() }

		bar.scrolling.keyboardMoved(to: "r6")
		bar.select("r6")

		// r6's highlight ends 16 + 7 × 54 − 2 = 392 points into the content; below it, the row's
		// half gap and Actions ⌘K's 51 points of room end the viewport.
		let palette = CommandBarStyle.palette
		let highlightEnd = palette.resultsTopPadding + 7 * (palette.rowHeight + palette.rowSpacing) - palette.rowSpacing
		#expect(abs(bar.offset + 300 - 51 - 1 - highlightEnd) < 0.5)
	}

	/// The gap between the last highlight and Actions ⌘K matches the button's own offset from
	/// the glass the rows sit on, the 12 points it floats in from the panel's edge less the
	/// 4-point bezel: Max's two red marks (DEV-1318).
	@Test
	internal func theGapAboveActionsMatchesItsOffsetBelow() {
		let style = CommandBarStyle.palette
		let raised = BrowserMetrics.CommandBar.Raised.self
		let reserve = ArxListLayout.floatingReserve(
			height: raised.floatingHeight,
			floatingInset: raised.floatingInset,
			contentInset: style.contentInset,
			rowGap: style.rowSpacing
		)

		// From the last highlight: its half gap, the reserve, then the bezel to the panel's edge.
		let highlightToEdge = style.rowSpacing / 2 + reserve + style.contentInset
		let gapAbove = highlightToEdge - raised.floatingInset - raised.floatingHeight
		let gapBelow = raised.floatingInset - style.contentInset

		#expect(gapAbove == gapBelow)
		#expect(gapAbove == 8)
		#expect(reserve == 51)
	}

	/// One result still leaves Actions ⌘K its room, so the button never hides the row's hint.
	@Test(arguments: [1, 2])
	internal func fewResultsLeaveRoomForActions(count: Int) {
		let style = CommandBarStyle.palette
		let bar = CommandBar(
			query: .constant("cap"),
			selectedID: .constant("r0"),
			results: (0..<count).map { CommandBarResult(id: "r\($0)", title: "Result", actionTitle: "Open", symbol: "globe") },
			onShowActions: {},
			onSelect: { _ in },
			onDismiss: {}
		)
		.environment(\.commandBarIsStatic, true)
		.frame(width: 573)
		let height = NSHostingView(rootView: bar).fittingSize.height
		let raised = BrowserMetrics.CommandBar.Raised.self

		// The last highlight stops the button's height, its inset and a gap above the panel's edge.
		// From the panel's top: its inset, the input, the divider, the first highlight's inset and
		// the rows.
		let lastHighlightBottom = 2 * style.contentInset + style.inputHeight + 1
		+ style.resultsTopPadding + CGFloat(count) * (style.rowHeight + style.rowSpacing) - style.rowSpacing
		- style.contentInset
		let gap = raised.floatingInset - style.contentInset
		#expect(height - lastHighlightBottom == raised.floatingHeight + raised.floatingInset + gap)
		#expect(height - lastHighlightBottom == 56)
	}

	private static let pointer = CGPoint(x: 400, y: 300)
	private static let movedPointer = CGPoint(x: 400, y: 301)
}

/// The palette with twelve results and Actions ⌘K in 300 points, hosted in a window far off every
/// screen. Rows are 54 points tall, their 52-point highlights 2 apart, so at an offset of 20 the
/// bottom edge cuts the sixth.
@MainActor
private final class HostedCommandBar {
	internal static let cutRow = "r5"

	internal let scrolling = CommandBarListScrolling(pointerLocation: nil)
	private var selectedID: String? = "r0"
	private let results: [CommandBarResult] = (0..<12).map {
		CommandBarResult(
			id: "r\($0)",
			title: "Result \($0)",
			subtitle: "https://example.com/\($0)",
			actionTitle: "Open",
			symbol: "globe"
		)
	}
	private let window: NSWindow
	private let host: NSHostingView<AnyView>

	internal init() {
		let size = CGSize(width: 600, height: 500)
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

	/// The offset with the list scrolled to its very end.
	internal var maximumOffset: CGFloat {
		guard let scrollView, let document = scrollView.documentView else { return -1 }
		return document.frame.height - scrollView.contentView.bounds.height
	}

	/// Moves the list as a scroll gesture does, behind SwiftUI's back.
	internal func scroll(to y: CGFloat) {
		guard let scrollView else { return }
		scrollView.contentView.scroll(to: .init(x: 0, y: y))
		scrollView.reflectScrolledClipView(scrollView.contentView)
		settle()
	}

	/// Highlights a result, as the bar's host does when its selection changes.
	internal func select(_ id: String) {
		selectedID = id
		render()
		settle()
	}

	internal func close() {
		window.close()
	}

	private var scrollView: NSScrollView? {
		Self.scrollViews(in: host).max { $0.frame.height < $1.frame.height }
	}

	private func render() {
		host.rootView = AnyView(
			CommandBar(
				query: .constant(""),
				selectedID: Binding(get: { self.selectedID }, set: { self.select($0 ?? "") }),
				results: results,
				onShowActions: {},
				maximumResultsHeight: 300,
				onSelect: { _ in },
				onDismiss: {}
			)
			.listScrolling(scrolling)
			.frame(width: 600)
		)
	}

	private func settle() {
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
		}
	}

	private static func scrollViews(in view: NSView) -> [NSScrollView] {
		(view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews(in:))
	}
}
