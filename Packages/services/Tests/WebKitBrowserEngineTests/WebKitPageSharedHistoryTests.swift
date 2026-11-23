import BrowserCore
import Foundation
import Testing
import WebKit

@testable import WebKitBrowserEngine

/// A WebKit page's side of the history it shares with the tab's Chromium page (DEV-1293).
@Suite(.serialized)
@MainActor
internal struct WebKitPageSharedHistoryTests {
	private func page() -> WebKitPage {
		.init(
			tabID: .init(rawValue: UUID()),
			profileID: .init(rawValue: UUID()),
			isPrivate: true,
			dataStore: .nonPersistent(),
			returnsToChromium: false,
			swipes: true
		)
	}

	private func document(_ name: String) -> URL {
		URL(string: "data:text/html,<title>\(name)</title><p>\(name)")!
	}

	private func waitFor(_ condition: @MainActor () -> Bool) async throws {
		for _ in 0 ..< 300 where !condition() {
			try await Task.sleep(for: .milliseconds(20))
		}
		#expect(condition())
	}

	@Test
	internal func aChromiumPageAheadTakesThePlaceOfTheEntriesAfterTheOneShown() async throws {
		let page = page()
		page.load(document("one"))
		try await waitFor { page.webView.backForwardList.currentItem?.url == document("one") && !page.webView.isLoading }
		page.load(document("two"))
		try await waitFor { page.webView.backForwardList.currentItem?.url == document("two") && !page.webView.isLoading }
		page.goBack()
		try await waitFor { page.webView.backForwardList.currentItem?.url == document("one") && !page.webView.isLoading }
		#expect(page.navigation.canGoForward)

		// The tab left "one" for a typed address in Chromium, and came back to it.
		var forwarded = 0
		page.onForwardToChromium = { forwarded += 1 }
		page.chromiumForward = .init(url: URL(string: "https://typed.example/")!, title: "Typed")

		// "two" is no longer ahead; the Chromium page is.
		#expect(page.forwardItems.isEmpty)
		#expect(page.navigation.canGoForward)
		#expect(page.navigation.history.map(\.id) == [0, SharedHistory.aheadID])
		#expect(page.navigation.history.last?.url == URL(string: "https://typed.example/"))
		#expect(page.swipeEntries(.forward).map(\.navigation) == [.forwardToChromium])

		page.goForward()
		#expect(forwarded == 1)
		#expect(page.webView.backForwardList.currentItem?.url == document("one"))
	}

	@Test
	internal func aNewPageFromTheEntryShownDropsTheChromiumPageAhead() async throws {
		let page = page()
		page.load(document("one"))
		try await waitFor { page.webView.backForwardList.currentItem?.url == document("one") && !page.webView.isLoading }
		page.chromiumForward = .init(url: URL(string: "https://typed.example/")!, title: "Typed")
		#expect(page.navigation.canGoForward)

		page.load(document("three"))
		try await waitFor { page.webView.backForwardList.currentItem?.url == document("three") && !page.webView.isLoading }

		#expect(page.chromiumForward == nil)
		#expect(!page.navigation.canGoForward)
		#expect(page.navigation.history.allSatisfy { SharedHistory.aheadIndex($0.id) == nil })
	}

	@Test
	internal func theChromiumPageBehindIsInTheHistoryList() async throws {
		let page = page()
		page.returnsToChromium = true
		page.chromiumReturnURL = URL(string: "https://news.example/")!
		page.chromiumReturnTitle = "news.example"
		var returned = 0
		page.onReturnToChromium = { returned += 1 }
		page.load(document("one"))
		try await waitFor { page.webView.backForwardList.currentItem?.url == document("one") && !page.webView.isLoading }

		#expect(page.navigation.history.first?.id == SharedHistory.behindID)
		#expect(page.navigation.history.first?.url == URL(string: "https://news.example/"))
		page.goToEntry(SharedHistory.behindID)
		#expect(returned == 1)
	}
}
