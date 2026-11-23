import AppUI
import Foundation
import SwiftUI
import Testing

@testable import ChatFeature

/// DEV-998: offscreen PNGs of each Markdown element in an answer, in light and dark, at the chat
/// panel's width, when `ARX_DESIGN_SNAPSHOTS` names a directory. `table-wide` is wider than the
/// panel and scrolls sideways with its long cells wrapped.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct ChatMarkdownSnapshotTests {
	internal enum Element: String, CaseIterable, Sendable {
		case headings
		case emphasis
		case code
		case lists
		case quote
		case rule
		case table
		case tableWide = "table-wide"
		case streaming
	}

	@Test(arguments: Element.allCases)
	internal func element(_ element: Element) throws {
		let width: CGFloat = ChatMetrics.panelWidth
		for dark in [false, true] {
			let view = ZStack(alignment: .topLeading) {
				BrowserChromeBackground(textured: true)
				ChatMarkdownView(markdown: Self.markdown(element), size: 13.5, isStreaming: element == .streaming)
					.foregroundStyle(BrowserTheme.text)
					.frame(width: width - 28)
					.fixedSize(horizontal: false, vertical: true)
					.padding(14)
			}
			try ChatPanelSnapshotTests.write(
				view,
				size: .init(width: width, height: Self.height(element)),
				dark: dark,
				name: "chat-markdown-\(element.rawValue)-\(dark ? "dark" : "light").png"
			)
		}
	}

	private static func height(_ element: Element) -> CGFloat {
		switch element {
		case .headings, .lists, .tableWide: 300
		case .code, .table: 220
		case .emphasis, .quote, .rule, .streaming: 160
		}
	}

	private static func markdown(_ element: Element) -> String {
		switch element {
		case .headings:
			"""
			# A first heading
			## A second heading
			### A third heading
			#### A fourth heading

			Body text under them.
			"""

		case .emphasis:
			"""
			Text with **strong**, *emphasis*, ***both***, `inline code`, ~~struck out~~ and \
			[a link](https://example.com).
			"""

		case .code:
			"""
			Run this:

			```swift
			let page = try await browser.open(URL(string: "https://example.com")!, inNewTab: true)
			print(page.title)
			```
			"""

		case .lists:
			"""
			1. First step
			2. Second step, long enough that it wraps onto a second line in the panel
			   - A nested point
			     1. Deeper still
			   - Another point
			3. Third step

			- [x] Read the page
			- [ ] Write the summary
			"""

		case .quote:
			"""
			> A quote from the page
			> > and one inside it
			"""

		case .rule:
			"""
			Above the rule.

			---

			Below the rule.
			"""

		case .table:
			"""
			| Plan | Seats | Price |
			|:-----|:-----:|------:|
			| Free | 1 | $0 |
			| Team | 10 | $120 |
			| Business |  | Contact us |
			"""

		case .tableWide:
			"""
			| Product | Region | Seats | Notes from the vendor's page | Price |
			|:--|:--|:-:|:--|--:|
			| Alpha | Europe | 25 | Billed yearly, with a discount for teams that sign up before the end of the quarter | $1,200 |
			| Beta | Americas | 5 | A short note | $90 |
			"""

		case .streaming:
			"""
			Here's the comparison, still **arriving

			| Name | Value |
			"""
		}
	}
}
