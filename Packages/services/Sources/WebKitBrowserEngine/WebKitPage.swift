import AppKit
import BrowserCore
import WebKit

/// One tab's page in WebKit (DEV-877): a `WKWebView` in its profile's data store, with Safari's
/// user agent, WebKit's element full screen and WebKit's own Picture in Picture.
@MainActor
public final class WebKitPage: NSObject {
	public let tabID: Tab.ID
	public let profileID: Profile.ID
	public let isPrivate: Bool
	public let webView: WKWebView

	/// What the page shows now, reported to the router after every change.
	public private(set) var navigation: BrowserNavigation

	/// The tab came from a Chromium page that's still there: Back from this page's first entry
	/// returns to it.
	internal var returnsToChromium: Bool {
		didSet { publish() }
	}

	/// The Chromium page the tab left this page for (DEV-1293): it comes right after the entry the
	/// page showed then, in place of WebKit's entries after it, and Forward from there returns to
	/// it.
	internal var chromiumForward: SharedHistory.ChromiumPage? {
		didSet {
			hasForwardEdge = false
			captureForwardEdge()
			publish()
		}
	}

	/// Where the entry the Chromium page comes after is, from the current one, when it's set.
	internal var chromiumForwardEdgeOffset: Int = 0

	/// The entry the Chromium page comes after, and the one WebKit had after it then. A navigation
	/// from there to another page replaces them, the Chromium page included.
	private weak var forwardEdge: WKBackForwardListItem?
	private weak var forwardEdgeNext: WKBackForwardListItem?
	private var forwardEdgeHasNext = false
	private var hasForwardEdge = false

	internal var onNavigation: (@MainActor (BrowserNavigation) -> Void)?

	/// A change of the page's colors alone (DEV-1101), which `onNavigation` doesn't hear: the page's
	/// session, and what it authorized, stay as they were.
	internal var onColors: (@MainActor (BrowserNavigation) -> Void)?

	/// A link or script asked for a new window; the app opens it as a tab in WebKit. The flag is
	/// true when the page asked on its own (`WebKitPage.isPageRequest`), not the person with a
	/// modifier key or the middle button, and not for a popup it sizes (DEV-1312).
	internal var onNewTab: (@MainActor (URL, Bool) -> Void)?

	/// Back on the first entry of a page that came from Chromium.
	internal var onReturnToChromium: (@MainActor () -> Void)?

	/// Forward on the last entry of a page with a Chromium page ahead of it (DEV-1293).
	internal var onForwardToChromium: (@MainActor () -> Void)?

	/// Called before each main-frame navigation with its URL, so content rules can follow the
	/// site's own exception.
	internal var willNavigate: (@MainActor (WebKitPage, URL) -> Void)?

	/// Arx's page menu for this page's context menus (DEV-1199); none keeps WebKit's own.
	internal var pageMenu: (@MainActor () -> WebKitPageMenu?)?
	internal var dialogButtons: @MainActor () -> WebKitDialogButtons = { .untranslated }
	private var errorCode: Int?

	/// Whether the main frame's response being committed is a PDF, which WebKit shows in its viewer
	/// (DEV-1101); nil until a response arrives. A page WebKit restores from its back/forward cache
	/// commits without one.
	private var pendingResponseIsPDF: Bool?

	/// The history entries whose document is a PDF, so a restored entry keeps its kind.
	private let pdfEntries: NSHashTable<WKBackForwardListItem> = .weakObjects()
	private var observations: [NSKeyValueObservation] = []

	/// Arx's own back and forward swipe (DEV-1203); nil with `ARX_WEBKIT_SWIPE` off, where WebKit's
	/// own swipe runs.
	internal let historySwipe: WebKitHistorySwipe?

	/// What the history list calls the Chromium page the tab came from.
	internal var chromiumReturnTitle: String = ""

	/// Where that Chromium page is, for the history list (DEV-1293).
	internal var chromiumReturnURL: URL?
	private var downloads: WebKitDownloads = .init()

	internal init(
		tabID: Tab.ID,
		profileID: Profile.ID,
		isPrivate: Bool,
		dataStore: WKWebsiteDataStore,
		returnsToChromium: Bool,
		swipes: Bool = FeatureFlag.webKitSwipe.isOn()
	) {
		self.tabID = tabID
		self.profileID = profileID
		self.isPrivate = isPrivate
		self.returnsToChromium = returnsToChromium
		self.navigation = .init(engine: .webKit)
		let view = WebKitPageView(frame: .zero, configuration: Self.configuration(dataStore))
		self.webView = view
		self.historySwipe = swipes ? WebKitHistorySwipe() : nil
		super.init()
		view.willOpenMenu = { [weak self] menu in self?.willOpenMenu(menu) }
		webView.navigationDelegate = self
		webView.uiDelegate = self
		webView.allowsBackForwardNavigationGestures = historySwipe == nil
		if let historySwipe { installSwipe(historySwipe, in: view) }
		webView.allowsMagnification = true
		webView.autoresizingMask = [.width, .height]
		observe()
	}

	/// Safari's application name for the user agent, from the installed Safari, so sites see
	/// the same browser they test with. Falls back to a recent version.
	internal static let safariApplicationName: String = {
		let info = Bundle(path: "/Applications/Safari.app")?.infoDictionary
		let version = info?["CFBundleShortVersionString"] as? String ?? "26.0"
		return "Version/\(version) Safari/605.1.15"
	}()

	private static func configuration(_ dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = dataStore
		configuration.applicationNameForUserAgent = safariApplicationName
		configuration.preferences.isElementFullscreenEnabled = true
		configuration.preferences.isFraudulentWebsiteWarningEnabled = true
		configuration.defaultWebpagePreferences.preferredContentMode = .desktop
		return configuration
	}

	// MARK: - Commands

	public func load(_ url: URL) {
		errorCode = nil
		webView.load(URLRequest(url: url))
	}

	public func goBack() {
		if webView.canGoBack {
			webView.goBack()
		} else if returnsToChromium {
			onReturnToChromium?()
		}
	}

	public func goForward() {
		if chromiumForward != nil, forwardItems.isEmpty {
			onForwardToChromium?()
		} else if webView.canGoForward {
			webView.goForward()
		}
	}

	/// WebKit's entries after the current one that Forward reaches before the Chromium page ahead,
	/// or all of them without one.
	internal var forwardItems: [WKBackForwardListItem] {
		let list = webView.backForwardList
		guard chromiumForward != nil else { return list.forwardList }
		return itemsBeforeChromium(in: list) ?? list.forwardList
	}

	private func captureForwardEdge() {
		let list = webView.backForwardList
		guard chromiumForward != nil, !hasForwardEdge, let current = list.currentItem else { return }
		let offset = list.item(at: chromiumForwardEdgeOffset) == nil ? 0 : chromiumForwardEdgeOffset
		forwardEdge = list.item(at: offset) ?? current
		forwardEdgeNext = list.item(at: offset + 1)
		forwardEdgeHasNext = forwardEdgeNext != nil
		hasForwardEdge = true
	}

	/// The entries from the current one's next to the one the Chromium page comes after; nil when
	/// the page navigated past it or replaced what came after it, which drops the Chromium page.
	private func itemsBeforeChromium(in list: WKBackForwardList) -> [WKBackForwardListItem]? {
		captureForwardEdge()
		guard hasForwardEdge else { return [] }
		guard let current = list.currentItem else { return [] }
		let items = list.backList + [current] + list.forwardList
		guard let edge = forwardEdge, let index = items.firstIndex(where: { $0 === edge }) else { return nil }
		let next = items.indices.contains(index + 1) ? items[index + 1] : nil
		let holds = forwardEdgeHasNext ? next != nil && next === forwardEdgeNext : next == nil
		let currentIndex = list.backList.count
		guard holds, currentIndex <= index else { return nil }
		return Array(items[(currentIndex + 1) ..< (index + 1)])
	}

	/// Shows the history WebKit saved for the tab (DEV-1293) at the entry it showed, or loads `url`
	/// afresh when there's none.
	internal func restore(
		_ state: Any?,
		url: URL
	) {
		errorCode = nil
		guard let state else { return load(url) }
		webView.interactionState = state
	}

	public func reload(bypassingCache: Bool) {
		errorCode = nil
		if bypassingCache {
			webView.reloadFromOrigin()
		} else {
			webView.reload()
		}
	}

	public func stop() { webView.stopLoading() }

	/// `id` is the entry's offset from the current one, as `navigation.history` numbers them, or
	/// the Chromium page behind or ahead of them (`SharedHistory`).
	public func goToEntry(_ id: Int) {
		if SharedHistory.behindIndex(id) != nil {
			if returnsToChromium { onReturnToChromium?() }
			return
		}
		if SharedHistory.aheadIndex(id) != nil {
			if chromiumForward != nil { onForwardToChromium?() }
			return
		}
		guard let item = webView.backForwardList.item(at: id) else { return }
		webView.go(to: item)
	}

	public func find(
		_ text: String,
		forward: Bool
	) async {
		let configuration = WKFindConfiguration()
		configuration.backwards = !forward
		configuration.caseSensitive = false
		configuration.wraps = true
		let found = (try? await webView.find(text, configuration: configuration))?.matchFound ?? false

		// WebKit tells whether there's a match, not how many.
		navigation.findResult = found ? .init(matches: 1, active: 1) : .init(matches: 0, active: 0)
		onNavigation?(navigation)
	}

	public func stopFind() {
		navigation.findResult = nil
		onNavigation?(navigation)
	}

	/// Leaves the page's element full screen, as Escape would (DEV-949). Nothing happens when
	/// the page isn't in full screen.
	public func exitFullScreen() {
		guard webView.fullscreenState != .notInFullscreen else { return }

		webView.closeAllMediaPresentations {}
	}

	/// Puts Arx's page items in a context menu WebKit is about to open (DEV-1199), with Exit
	/// Full Screen first while the page is in full screen.
	private func willOpenMenu(_ menu: NSMenu) {
		guard let pageMenu = pageMenu?() else { return }

		var exitFullScreen: (@MainActor () -> Void)?
		if webView.fullscreenState != .notInFullscreen {
			exitFullScreen = { [weak self] in self?.exitFullScreen() }
		}
		pageMenu.adjust(menu, for: tabID, exitFullScreen: exitFullScreen)
	}

	public var zoom: Double { Double(webView.pageZoom) }

	/// Steps the page's zoom through Chrome's levels, as Chromium pages do; WebKit keeps it
	/// for this page only.
	@discardableResult
	public func zoom(_ step: PageZoom) -> Double {
		let factor = step.factor(from: zoom) ?? 1
		webView.pageZoom = CGFloat(factor)
		return factor
	}

	public func close() {
		observations = []
		webView.stopLoading()
		webView.navigationDelegate = nil
		webView.uiDelegate = nil
		webView.removeFromSuperview()
		onNavigation = nil
		onColors = nil
		onNewTab = nil
		onReturnToChromium = nil
		willNavigate = nil
		pageMenu = nil
		(webView as? WebKitPageView)?.willOpenMenu = nil
		if let historySwipe {
			historySwipe.invalidate()
			(webView as? WebKitPageView)?.historySwipe = nil
			webView.configuration.userContentController.removeScriptMessageHandler(
				forName: WebKitSwipeScript.handlerName,
				contentWorld: WebKitSwipeScript.world
			)
		}
	}

	// MARK: - Navigation

	private func observe() {
		observations = [
			webView.observe(\.url) { [weak self] _, _ in self?.changed() },
			webView.observe(\.title) { [weak self] _, _ in self?.changed() },
			webView.observe(\.isLoading) { [weak self] _, _ in self?.changed() },
			webView.observe(\.canGoBack) { [weak self] _, _ in self?.changed() },
			webView.observe(\.canGoForward) { [weak self] _, _ in self?.changed() },
			// DEV-1101: Match site follows the page's colors.
			webView.observe(\.themeColor) { [weak self] _, _ in self?.changed() },
			webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in self?.changed() },
		]
	}

	/// WebKit reports its properties on the main thread.
	nonisolated private func changed() {
		MainActor.assumeIsolated { publish() }
	}

	internal func publish() {
		let list = webView.backForwardList
		var forwardItems = list.forwardList
		if chromiumForward != nil {
			guard let items = itemsBeforeChromium(in: list) else {
				// Publishes again without it.
				chromiumForward = nil
				return
			}
			forwardItems = items
		}
		var history: [BrowserNavigation.Entry] = []
		for (offset, item) in list.backList.enumerated() {
			history.append(.init(
				id: offset - list.backList.count,
				url: item.url,
				title: item.title ?? "",
				isCurrent: false
			))
		}
		if let current = list.currentItem {
			history.append(.init(id: 0, url: current.url, title: current.title ?? "", isCurrent: true))
		}
		for (offset, item) in forwardItems.enumerated() {
			history.append(.init(id: offset + 1, url: item.url, title: item.title ?? "", isCurrent: false))
		}

		// The Chromium pages on either side, which the history list offers as the router reaches
		// them (DEV-1293).
		if returnsToChromium, let url = chromiumReturnURL {
			history.insert(.init(id: SharedHistory.behindID, url: url, title: chromiumReturnTitle, isCurrent: false), at: 0)
		}
		if let forward = chromiumForward {
			history.append(.init(id: SharedHistory.aheadID, url: forward.url, title: forward.title, isCurrent: false))
		}
		let previous = navigation

		// A swipe never outlives the page it began on.
		if webView.url != previous.url { historySwipe?.invalidate() }
		navigation = .init(
			url: webView.url ?? navigation.url,
			title: webView.title ?? "",
			isLoading: webView.isLoading,
			errorCode: errorCode,
			findResult: navigation.findResult,
			canGoBack: webView.canGoBack || returnsToChromium,
			canGoForward: !forwardItems.isEmpty || chromiumForward != nil,
			history: history,
			engine: .webKit,
			colors: colors
		)
		var recolored = previous
		recolored.colors = navigation.colors
		if previous.colors != navigation.colors, recolored == navigation {
			onColors?(navigation)
		} else {
			onNavigation?(navigation)
		}
	}

	/// The current history entry shows a PDF.
	private var showsPDF: Bool {
		webView.backForwardList.currentItem.map(pdfEntries.contains) ?? false
	}

	/// The page's theme color for its light or dark scheme, and its background:
	/// `underPageBackgroundColor` follows the page's own until an app sets one, which Arx doesn't.
	/// None for a PDF: the viewer's grey isn't the site's, as the Chromium engine reports it.
	private var colors: PageColors {
		guard !showsPDF else { return .none }

		return .init(
			themeARGB: webView.themeColor.flatMap(Self.argb),
			backgroundARGB: Self.argb(webView.underPageBackgroundColor)
		)
	}

	/// `0xAARRGGBB` in sRGB, as the Chromium engine reports colors; nil for a pattern or a color
	/// that has no sRGB form.
	private static func argb(_ color: NSColor) -> UInt32? {
		guard let color = color.usingColorSpace(.sRGB) else { return nil }
		func byte(_ component: CGFloat) -> UInt32 {
			UInt32((min(max(component, 0), 1) * 255).rounded())
		}
		return byte(color.alphaComponent) << 24
		| byte(color.redComponent) << 16
		| byte(color.greenComponent) << 8
		| byte(color.blueComponent)
	}

	private func fail(_ error: any Error) {
		let error = error as NSError

		// A cancelled load, or one a download or policy decision interrupted, isn't a failure.
		if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
		if error.domain == WKError.errorDomain, error.code == 102 { return }
		errorCode = Self.netErrorCode(error)
		publish()
	}

	/// Chromium's net error for a WebKit or URL loading error, so the page shows Arx's own
	/// failure page as it does for Chromium pages.
	internal static func netErrorCode(_ error: NSError) -> Int {
		guard error.domain == NSURLErrorDomain else { return -2 }
		switch error.code {
		case NSURLErrorTimedOut: return -7
		case NSURLErrorCannotConnectToHost: return -102
		case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return -105
		case NSURLErrorNotConnectedToInternet: return -106
		case NSURLErrorSecureConnectionFailed: return -107
		case NSURLErrorNetworkConnectionLost: return -100
		case NSURLErrorServerCertificateHasBadDate: return -201
		case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot: return -202
		case NSURLErrorServerCertificateNotYetValid: return -201
		default: return -2
		}
	}
}

// MARK: - WKNavigationDelegate

extension WebKitPage: WKNavigationDelegate {
	public func webView(
		_ webView: WKWebView,
		decidePolicyFor navigationAction: WKNavigationAction,
		preferences: WKWebpagePreferences
	) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
		guard let url = navigationAction.request.url
		else { return (.cancel, preferences) }

		if navigationAction.shouldPerformDownload { return (.download, preferences) }
		let scheme = url.scheme?.lowercased() ?? ""

		// Other apps' links (mailto:, zoommtg:, …) aren't followed from a WebKit page.
		guard ["http", "https", "about", "blob", "data", "file"].contains(scheme)
		else { return (.cancel, preferences) }

		if navigationAction.targetFrame == nil {
			// A script's window may have a popup's size, which only `createWebViewWith` sees, so
			// it goes on there (DEV-1312). A link or a form has none and opens here.
			if Self.isScriptWindow(navigationAction.navigationType) { return (.allow, preferences) }
			onNewTab?(url, Self.isPageRequest(navigationAction, windowFeatures: nil))
			return (.cancel, preferences)
		}
		if navigationAction.targetFrame?.isMainFrame == true {
			errorCode = nil
			willNavigate?(self, url)
		}
		return (.allow, preferences)
	}

	public func webView(
		_ webView: WKWebView,
		decidePolicyFor navigationResponse: WKNavigationResponse
	) async -> WKNavigationResponsePolicy {
		guard navigationResponse.canShowMIMEType else { return .download }

		if navigationResponse.isForMainFrame {
			pendingResponseIsPDF = navigationResponse.response.mimeType?.lowercased() == "application/pdf"
		}
		return .allow
	}

	public func webView(
		_ webView: WKWebView,
		navigationAction: WKNavigationAction,
		didBecome download: WKDownload
	) {
		downloads.adopt(download)
	}

	public func webView(
		_ webView: WKWebView,
		navigationResponse: WKNavigationResponse,
		didBecome download: WKDownload
	) {
		downloads.adopt(download)
	}

	public func webView(
		_ webView: WKWebView,
		didFailProvisionalNavigation navigation: WKNavigation!,
		withError error: any Error
	) {
		pendingResponseIsPDF = nil
		fail(error)
	}

	/// A new main-frame navigation starts without a response, so one an abandoned navigation left
	/// never marks the entry the next one commits (DEV-1101).
	public func webView(
		_ webView: WKWebView,
		didStartProvisionalNavigation navigation: WKNavigation!
	) {
		pendingResponseIsPDF = nil

		// A held swipe was admitted by the document that's leaving (DEV-1203).
		historySwipe?.invalidate()
	}

	public func webView(
		_ webView: WKWebView,
		didFail navigation: WKNavigation!,
		withError error: any Error
	) {
		fail(error)
	}

	/// The committed document's kind goes with its history entry (DEV-1101). A restore from the
	/// back/forward cache has no response, and the entry keeps the kind it had.
	public func webView(
		_ webView: WKWebView,
		didCommit navigation: WKNavigation!
	) {
		defer { pendingResponseIsPDF = nil }
		historySwipe?.invalidate()
		guard
			let isPDF = pendingResponseIsPDF,
			let entry = webView.backForwardList.currentItem
		else { return }

		if isPDF {
			pdfEntries.add(entry)
		} else {
			pdfEntries.remove(entry)
		}
		publish()
	}

	public func webView(
		_ webView: WKWebView,
		didFinish navigation: WKNavigation!
	) {
		publish()
	}

	public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		errorCode = BrowserNavigation.Failure.rendererStoppedCode
		publish()
	}
}

// MARK: - WKUIDelegate

extension WebKitPage: WKUIDelegate {
	public func webView(
		_ webView: WKWebView,
		createWebViewWith configuration: WKWebViewConfiguration,
		for navigationAction: WKNavigationAction,
		windowFeatures: WKWindowFeatures
	) -> WKWebView? {
		// Popups open as tabs in WebKit; a script's window.opener doesn't follow them.
		if let url = navigationAction.request.url, url.hasWebScheme {
			onNewTab?(url, Self.isPageRequest(navigationAction, windowFeatures: windowFeatures))
		}
		return nil
	}

	/// Whether the page asked for the new window on its own, as `target="_blank"` or
	/// `window.open` without a size does (DEV-1312): no modifier key and no middle button, which
	/// are the person's choice of a tab, and no width or height, which make a popup such as a
	/// sign-in's.
	internal static func isPageRequest(
		_ action: WKNavigationAction,
		windowFeatures: WKWindowFeatures?
	) -> Bool {
		isPageRequest(
			modifiers: action.modifierFlags,
			buttonNumber: action.buttonNumber,
			isSized: windowFeatures?.width != nil || windowFeatures?.height != nil
		)
	}

	/// Whether a new window comes from a script (`window.open`) rather than a link or a form, so
	/// its window features decide whether it's a popup.
	internal static func isScriptWindow(_ type: WKNavigationType) -> Bool {
		type != .linkActivated && type != .formSubmitted
	}

	internal static func isPageRequest(
		modifiers: NSEvent.ModifierFlags,
		buttonNumber: Int,
		isSized: Bool
	) -> Bool {
		modifiers.intersection([.shift, .option, .command, .control]).isEmpty
		&& buttonNumber < 2
		&& !isSized
	}

	public func webView(
		_ webView: WKWebView,
		runJavaScriptAlertPanelWithMessage message: String,
		initiatedByFrame frame: WKFrameInfo
	) async {
		_ = await present(message, buttons: [dialogButtons().ok], host: frame.securityOrigin.host)
	}

	public func webView(
		_ webView: WKWebView,
		runJavaScriptConfirmPanelWithMessage message: String,
		initiatedByFrame frame: WKFrameInfo
	) async -> Bool {
		await present(
			message,
			buttons: [dialogButtons().ok, dialogButtons().cancel],
			host: frame.securityOrigin.host
		) == .alertFirstButtonReturn
	}

	public func webView(
		_ webView: WKWebView,
		runOpenPanelWith parameters: WKOpenPanelParameters,
		initiatedByFrame frame: WKFrameInfo
	) async -> [URL]? {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = parameters.allowsMultipleSelection
		panel.canChooseDirectories = parameters.allowsDirectories
		panel.canChooseFiles = true
		guard let window = webView.window else {
			return panel.runModal() == .OK ? panel.urls : nil
		}
		return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
	}

	private func present(
		_ message: String,
		buttons: [String],
		host: String
	) async -> NSApplication.ModalResponse {
		let alert = NSAlert()
		alert.messageText = host.isEmpty ? message : host
		alert.informativeText = host.isEmpty ? "" : message
		for title in buttons { alert.addButton(withTitle: title) }
		guard let window = webView.window
		else { return alert.runModal() }

		return await alert.beginSheetModal(for: window)
	}
}
