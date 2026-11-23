import AppKit
import WebKit

extension WebKitPage {
	/// Gives the page Arx's swipe: its script in a world of its own, the script's answers, and
	/// the page's history for the list. The router supplies where Back and Forward go.
	internal func installSwipe(
		_ swipe: WebKitHistorySwipe,
		in view: WebKitPageView
	) {
		let controller = view.configuration.userContentController
		controller.addUserScript(WebKitSwipeScript.userScript)
		controller.add(
			WebKitSwipeMessages(swipe),
			contentWorld: WebKitSwipeScript.world,
			name: WebKitSwipeScript.handlerName
		)
		view.historySwipe = swipe
		swipe.entries = { [weak self] direction in self?.swipeEntries(direction) ?? [] }
		swipe.historyIdentity = { [weak self] in self?.historyIdentity ?? [] }
	}

	/// The history list for a swipe, nearest first; Back ends at the Chromium page the tab came
	/// from, and Forward at the one it went back from.
	internal func swipeEntries(_ direction: WebKitSwipeDirection) -> [WebKitHistorySwipe.Entry] {
		let list = webView.backForwardList
		switch direction {
		case .back:
			var entries = list.backList.reversed().enumerated().map { offset, item in
				WebKitHistorySwipe.Entry(
					title: Self.title(of: item),
					host: Self.host(of: item),
					navigation: .entry(-(offset + 1))
				)
			}
			if returnsToChromium {
				entries.append(
					.init(title: chromiumReturnTitle, host: chromiumReturnTitle, navigation: .returnToChromium)
				)
			}
			return entries

		case .forward:
			var entries = forwardItems.enumerated().map { offset, item in
				WebKitHistorySwipe.Entry(
					title: Self.title(of: item),
					host: Self.host(of: item),
					navigation: .entry(offset + 1)
				)
			}

			// Forward ends at the Chromium page the tab went back from (DEV-1293).
			if let forward = chromiumForward {
				let host = forward.url.host() ?? forward.url.absoluteString
				entries.append(
					.init(title: forward.title.isEmpty ? host : forward.title, host: host, navigation: .forwardToChromium)
				)
			}
			return entries
		}
	}

	/// The history entries in order, the current one, and whether Back or Forward leaves for
	/// Chromium.
	private var historyIdentity: [ObjectIdentifier] {
		let list = webView.backForwardList
		let items = list.backList + [list.currentItem].compactMap(\.self) + list.forwardList

		// The current entry again on its own: moving between the same entries changes it.
		let current = list.currentItem.map { [ObjectIdentifier($0)] } ?? []
		return items.map(ObjectIdentifier.init) + current
			+ (returnsToChromium ? [ObjectIdentifier(self)] : [])
			+ (chromiumForward != nil ? [ObjectIdentifier(webView)] : [])
	}

	private static func title(of item: WKBackForwardListItem) -> String {
		if let title = item.title, !title.isEmpty { return title }
		return self.host(of: item)
	}

	private static func host(of item: WKBackForwardListItem) -> String {
		item.url.host() ?? item.url.absoluteString
	}
}

/// Hands the swipe script's answers to the swipe. The content controller keeps it, so it holds
/// the swipe weakly.
@MainActor
private final class WebKitSwipeMessages: NSObject, WKScriptMessageHandler {
	private weak var swipe: WebKitHistorySwipe?

	init(_ swipe: WebKitHistorySwipe) {
		self.swipe = swipe
	}

	func userContentController(
		_ userContentController: WKUserContentController,
		didReceive message: WKScriptMessage
	) {
		guard var answer = WebKitSwipeScript.Answer(message.body) else { return }

		// A frame can't see whether the page around it scrolls that way or contains its overscroll,
		// so a gesture that reaches one stays the page's for good, even if a later wheel reaches
		// the main frame.
		if !message.frameInfo.isMainFrame { answer.consumed = true }
		swipe?.acknowledge(answer)
	}
}
