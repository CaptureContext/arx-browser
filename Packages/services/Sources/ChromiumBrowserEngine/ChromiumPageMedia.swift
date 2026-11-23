import BrowserCore
import ChromiumEngine
import Foundation

/// A message a bridged page sent (DEV-1144): the tab, the engine's number for the document that
/// sent it, and its text.
public struct PageMediaMessage: Equatable, Sendable {
	public var tabID: Tab.ID
	public var document: UInt64
	public var text: String

	/// The page is a private window's, whose media Arx never names outside it.
	public var isPrivate: Bool

	public init(
		tabID: Tab.ID,
		document: UInt64,
		text: String,
		isPrivate: Bool = false
	) {
		self.tabID = tabID
		self.document = document
		self.text = text
		self.isPrivate = isPrivate
	}
}

extension ChromiumBrowserEngine {
	/// Whether the engine has the page media bridge (DEV-1144).
	public var supportsPageMedia: Bool {
		runtime.supportsPageMedia
	}

	/// Runs `script` in the main world of `origins`' top-level documents from their next
	/// navigation and hands their messages to `handler`. Nil turns the bridge off for the next
	/// documents. False when the engine lacks the bridge or refused the input.
	@discardableResult
	public func setPageMediaBridge(
		origins: [String],
		script: String,
		handler: (@MainActor (PageMediaMessage) -> Void)?
	) -> Bool {
		guard let handler else {
			return runtime.setPageMediaBridge(origins: [], script: "", handler: nil)
		}

		return runtime.setPageMediaBridge(origins: origins, script: script) { [weak self] page, message in
			guard let id = self?.tabID(of: page)
			else { return }

			handler(.init(tabID: id, document: message.document, text: message.text, isPrivate: page.isPrivate))
		}
	}

	/// Sends `text` to `document` in `tab`'s page. False when the tab has no Chromium page or
	/// that document is gone.
	public func sendPageMedia(
		_ text: String,
		to document: UInt64,
		in tab: Tab.ID
	) -> Bool {
		guard let page = chromiumPage(tab)
		else { return false }

		return runtime.sendPageMedia(text, to: document, on: page)
	}

	/// Keeps `tab`'s page out of Chromium's freezing while `document`'s media plays outside
	/// Chromium, or ends that (DEV-1151). False when the tab has no Chromium page, the engine
	/// lacks the lease, or `document` is gone.
	@discardableResult
	public func setPageMediaKeepsRunning(
		_ keeps: Bool,
		document: UInt64,
		in tab: Tab.ID
	) -> Bool {
		guard let page = chromiumPage(tab)
		else { return false }

		return runtime.setPageMediaKeepsRunning(keeps, document: document, on: page)
	}
}
