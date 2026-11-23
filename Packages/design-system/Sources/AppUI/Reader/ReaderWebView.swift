import AppKit
import BrowserCore
import SwiftUI
import WebKit

/// Shows a reader document in WebKit with the page's scripts off and nothing kept: no cookies,
/// no storage, no cache once it closes (DEV-1028). A link opens in the page under it, and Escape
/// closes reading mode. A new appearance restyles the document where it is, so it stays scrolled.
/// The Find bar searches the document (DEV-1066).
internal struct ReaderWebView: NSViewRepresentable {
	internal let article: ReaderArticle
	internal let appearance: ReaderAppearance
	internal let isFocused: Bool
	internal let find: ReaderFind
	internal let onFind: @MainActor (_ serial: UInt64, BrowserNavigation.FindResult?) -> Void
	internal let onOpenLink: @MainActor (URL) -> Void
	internal let onClose: @MainActor () -> Void

	internal func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	internal func makeNSView(context: Context) -> ReaderPageView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = false
		configuration.preferences.isElementFullscreenEnabled = false
		configuration.mediaTypesRequiringUserActionForPlayback = .all
		let view = ReaderPageView(frame: .zero, configuration: configuration)
		view.navigationDelegate = context.coordinator
		view.uiDelegate = context.coordinator
		view.allowsMagnification = true
		view.setAccessibilityLabel(article.title)
		let coordinator = context.coordinator
		coordinator.update(self)
		view.onClose = { [weak coordinator] in coordinator?.parent?.onClose() }
		view.wantsFocus = isFocused
		coordinator.load(article, appearance: appearance, in: view)

		// A search asked for while the article was read runs once it has loaded.
		coordinator.search(find, in: view)
		return view
	}

	internal func updateNSView(
		_ view: ReaderPageView,
		context: Context
	) {
		context.coordinator.update(self)
		view.wantsFocus = isFocused
		if context.coordinator.article != article {
			context.coordinator.load(article, appearance: appearance, in: view)
		} else if context.coordinator.appearance != appearance {
			context.coordinator.appearance = appearance
			view.evaluateJavaScript(ReaderDocument.restyle(appearance), in: nil, in: .defaultClient) { _ in }
		}
		context.coordinator.search(find, in: view)
	}

	internal static func dismantleNSView(
		_ view: ReaderPageView,
		coordinator: Coordinator
	) {
		view.stopLoading()
		view.navigationDelegate = nil
		view.uiDelegate = nil
		view.onClose = nil
	}

	@MainActor
	internal final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
		fileprivate var parent: ReaderWebView?
		fileprivate var article: ReaderArticle?
		fileprivate var appearance: ReaderAppearance?

		/// The document's own load, the one navigation it allows besides moving within it.
		private var isLoadingDocument: Bool = false

		/// The document has loaded, so it can be searched.
		private var isDocumentReady: Bool = false

		/// The Find bar's latest request, run once the document is ready.
		private var find: ReaderFind = .init()

		fileprivate func update(_ parent: ReaderWebView) {
			self.parent = parent
		}

		fileprivate func load(
			_ article: ReaderArticle,
			appearance: ReaderAppearance,
			in view: WKWebView
		) {
			self.article = article
			self.appearance = appearance
			isLoadingDocument = true
			isDocumentReady = false
			view.loadHTMLString(ReaderDocument.html(article, appearance: appearance), baseURL: article.url)
		}

		/// Runs a new Find request in the document, or keeps it until the document has loaded.
		fileprivate func search(
			_ find: ReaderFind,
			in view: WKWebView
		) {
			guard find != self.find else { return }
			self.find = find
			if isDocumentReady { run(find, in: view) }
		}

		private func run(
			_ find: ReaderFind,
			in view: WKWebView
		) {
			view.evaluateJavaScript(find.script, in: nil, in: .defaultClient) { [weak self] result in
				guard let self, self.find.serial == find.serial else { return }
				self.parent?.onFind(find.serial, ReaderFind.result(try? result.get()))
			}
		}

		internal func webView(
			_ webView: WKWebView,
			didFinish navigation: WKNavigation?
		) {
			guard !isDocumentReady else { return }
			isDocumentReady = true

			// A search that came before the document: a new one, in the document as it is now.
			guard !find.query.isEmpty else { return }
			var first = find
			first.newSession = true
			run(first, in: webView)
		}

		internal func webView(
			_ webView: WKWebView,
			decidePolicyFor action: WKNavigationAction
		) async -> WKNavigationActionPolicy {
			let decision = Self.decision(
				for: action.request.url,
				isLink: action.navigationType == .linkActivated,
				isMainFrame: action.targetFrame?.isMainFrame ?? true,
				isLoadingDocument: isLoadingDocument,
				article: article?.url
			)
			switch decision {
			case .load:
				isLoadingDocument = false
				return .allow

			case .scroll:
				return .allow

			case let .open(url):
				parent?.onOpenLink(url)
				return .cancel

			case .refuse:
				return .cancel
			}
		}

		/// A link that asks for a new window, such as from the link's menu, opens in the page too.
		internal func webView(
			_ webView: WKWebView,
			createWebViewWith configuration: WKWebViewConfiguration,
			for action: WKNavigationAction,
			windowFeatures: WKWindowFeatures
		) -> WKWebView? {
			if let url = action.request.url, Self.opensInPage(url) { parent?.onOpenLink(url) }
			return nil
		}

		internal enum Decision: Equatable {
			/// The reader's own document.
			case load

			/// A link to a place in the article.
			case scroll

			/// A link elsewhere, for the page under the reader.
			case open(URL)
			case refuse
		}

		internal static func decision(
			for url: URL?,
			isLink: Bool,
			isMainFrame: Bool,
			isLoadingDocument: Bool,
			article: URL?
		) -> Decision {
			guard let url, isMainFrame else { return .refuse }
			if isLoadingDocument, !isLink, withoutFragment(url) == article.map(withoutFragment) { return .load }
			if url.fragment != nil, withoutFragment(url) == article.map(withoutFragment) { return .scroll }
			guard isLink, opensInPage(url) else { return .refuse }
			return .open(url)
		}

		/// Web links, and email links, which the page hands to Mail as it would its own.
		private static func opensInPage(_ url: URL) -> Bool {
			["http", "https", "mailto"].contains(url.scheme?.lowercased())
		}

		private static func withoutFragment(_ url: URL) -> String {
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
			components?.fragment = nil
			return components?.string ?? url.absoluteString
		}
	}
}

/// The reader's WebKit view: it takes the keyboard when it appears in a focused pane, and again
/// when its pane is focused, so the article scrolls with the arrow keys and space bar, and Escape
/// closes it.
internal final class ReaderPageView: WKWebView {
	internal var onClose: (@MainActor () -> Void)?

	internal var wantsFocus: Bool = false {
		didSet {
			if wantsFocus, !oldValue { takeFocus() }
		}
	}

	internal override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if wantsFocus { takeFocus() }
	}

	private func takeFocus() {
		guard let window else { return }

		// After the update that asked for it, so a page focused in the same pass doesn't win.
		DispatchQueue.main.async { [weak self, weak window] in
			guard let self, let window, self.window === window, self.wantsFocus else { return }
			window.makeFirstResponder(self)
		}
	}

	internal override func keyDown(with event: NSEvent) {
		// Escape, without modifiers that make it something else.
		if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
			onClose?()
			return
		}
		super.keyDown(with: event)
	}
}
