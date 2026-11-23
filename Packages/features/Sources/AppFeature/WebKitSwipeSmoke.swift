#if DEBUG
import AppKit
import BrowserCore
import BrowserEngineClient
import CoreGraphics
import Foundation
import MainFeature
import WebKit
import WebKitBrowserEngine
import _ComposableArchitecture

/// The app smoke's overnight `webkit-swipe` phase (DEV-1203), run only when the runner sets
/// `ARX_WEBKIT_SWIPE_SMOKE`: Arx's own back and forward swipe on a WebKit page, in place of
/// WebKit's `allowsBackForwardNavigationGestures`.
///
/// The phase lists `localhost` for WebKit. Page A, in Chromium on `127.0.0.1`, follows its link to
/// page B on `localhost` by script, so the router moves the tab to WebKit as a page that reached a
/// listed site itself (`followsSite`). B's link, clicked in WebKit, opens C on the same site: the
/// WebKit page has two entries. Then, with synthesized precise trackpad scrolls delivered straight
/// to the WebKit page's view (`scrollWheel(with:)`, so the screen's focus doesn't matter):
///
/// 1. A swipe back lands on B, still in WebKit; a swipe forward on C, and back again on B.
/// 2. A swipe back from WebKit's first entry reopens the tab in Chromium on A, through the
///    router's Back path.
/// 3. The Forward command (⌘]) from A moves the tab to WebKit on B again. A swipe forward on A
///    would be Chromium's own swipe, which the gesture smoke's engine fixture covers, not this
///    phase.
/// 4. Forward into WebKit shows the WebKit page as it was: C is still ahead of B (DEV-1293).
/// 5. A swipe back that stops short of the threshold leaves the page on B in WebKit.
/// 6. An unlisted address typed on B opens in Chromium with B behind it: Back (⌘[) shows B in
///    WebKit again, and a swipe forward from there returns to the Chromium page (DEV-1293).
///
/// A swipe is a precise scroll: a began phase, changed phases whose horizontal travel is the
/// deltas over 800 points, and an ended phase, which navigates when the travel passed 0.16 (a
/// positive delta goes back, as on Chromium's touchless path). The fixture pages don't scroll
/// sideways, so the page leaves the first wheel unconsumed and the swipe is admitted.
///
/// With the `ARX_WEBKIT_SWIPE` feature flag off, WebKit's own swipe returns and these events
/// navigate nothing; that run is out of scope here. The tab ends in Chromium and the WebKit list
/// is restored.
@MainActor
internal enum WebKitSwipeSmoke {
	internal static let pageA: String = "webkit-swipe-a.html"
	internal static let pageB: String = "webkit-swipe-b.html"
	internal static let pageC: String = "webkit-swipe-c.html"

	/// The listed site: the fixture's other loopback name, so A, on `127.0.0.1`, isn't listed.
	internal static let listedHost: String = "localhost"

	/// A full swipe: 12 steps of 24 points, 0.36 of travel, past the 0.16 threshold even when the
	/// first step only picks the direction.
	internal static let fullSwipe: (steps: Int, points: Double) = (12, 24)

	/// A short swipe: 3 steps of 20 points, 0.075 of travel at most.
	internal static let shortSwipe: (steps: Int, points: Double) = (3, 20)

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient,
		pages: WebKitPages,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let tab = store.main.viewer.item.tab,
			pageEngines.engine(tab.id) == .chromium
		else { throw Failure.invalidFixture }

		let a = try Self.address(pageA, on: baseURL.host() ?? "127.0.0.1", baseURL: baseURL)
		let b = try Self.address(pageB, on: listedHost, baseURL: baseURL)
		let c = try Self.address(pageC, on: listedHost, baseURL: baseURL)
		guard a.host() != listedHost else { throw Failure.invalidFixture }

		let saved = store.settings.webKitPages
		defer { store.settings.$webKitPages.withLock { $0 = saved } }
		store.settings.$webKitPages.withLock { preferences in
			preferences.isEnabled = true
			preferences.add(b)
		}
		guard
			store.settings.webKitPages.opensInWebKit(b),
			!store.settings.webKitPages.opensInWebKit(a)
		else { throw Failure.invalidFixture }

		func inWebKit(_ message: String, at url: URL) async throws {
			try await waitForWebKit(
				message,
				tab.id,
				at: url,
				engine: engine,
				pageEngines: pageEngines,
				pages: pages,
				window: window
			)
		}

		func inChromium(_ message: String, at url: URL) async throws {
			try await waitForChromium(message, tab.id, at: url, store: store, engine: engine, pageEngines: pageEngines)
		}

		// The phase before this one may have just moved the tab back to Chromium: the router marks
		// it Chromium at once and opens its Chromium page in a task of its own, so a command sent
		// before that page exists finds no session.
		try await waitForChromiumPage("The tab's Chromium page did not open", tab.id, engine: engine, pageEngines: pageEngines)
		print("ARX_WEBKIT_SWIPE_SMOKE ready: \(Self.state("start", tab.id, engine: engine, pageEngines: pageEngines))")

		// A follows its link once it sees `#follow`, dropping the fragment first, so Back to A
		// doesn't follow it again.
		guard let follow = URL(string: a.absoluteString + "#follow") else { throw Failure.invalidFixture }
		do {
			try await engine.command(tab.id, .navigate(follow))
		} catch {
			throw Failure.commandFailed("Opening A: \(error)", Self.state("Opening A", tab.id, engine: engine, pageEngines: pageEngines))
		}
		try await inWebKit("A's link to B did not move the tab to WebKit", at: b)
		print("ARX_WEBKIT_SWIPE_SMOKE followed")

		// B's link, clicked in WebKit, opens C: two WebKit entries.
		// The script ends in a value: an undefined result fails the asynchronous call.
		guard let page = pages.page(tab.id) else { throw Failure.noWebKitPage }
		_ = try await page.webView.evaluateJavaScript("document.getElementById('next').click(); true")
		try await inWebKit("B's link did not open C in WebKit", at: c)

		try await swipe(.back, tab.id, pages: pages)
		try await inWebKit("A swipe back from C did not land on B in WebKit", at: b)
		print("ARX_WEBKIT_SWIPE_SMOKE back in WebKit")

		try await swipe(.forward, tab.id, pages: pages)
		try await inWebKit("A swipe forward from B did not land on C in WebKit", at: c)
		try await swipe(.back, tab.id, pages: pages)
		try await inWebKit("A second swipe back from C did not land on B in WebKit", at: b)
		print("ARX_WEBKIT_SWIPE_SMOKE forward in WebKit")

		// Back from WebKit's first entry: the router reopens Chromium where the tab came from.
		try await swipe(.back, tab.id, pages: pages)
		try await inChromium("A swipe back from B did not reopen A in Chromium", at: a)

		// The reopened page steps back to A from B, a listed address: it must stay on A.
		try await Task.sleep(for: .seconds(1))
		try await inChromium("The reopened page did not stay on A in Chromium", at: a)
		print("ARX_WEBKIT_SWIPE_SMOKE back to Chromium")

		// Forward from A, as ⌘] sends it: Chromium goes to B, which the router follows to WebKit.
		let paneID = store.main.viewer.activePaneID
		try await wait("Forward is not enabled on A") {
			store.main.commandContext(in: paneID).map(BrowserCommand.goForward.isEnabled(in:)) ?? false
		}
		store.send(.main(.ui(.paneCommand(.goForward, paneID))))
		try await inWebKit("Forward from A did not move the tab to WebKit on B", at: b)
		print("ARX_WEBKIT_SWIPE_SMOKE forward command")

		// DEV-1293: Forward into WebKit shows the WebKit page as it was, C still ahead of B.
		try await wait("The WebKit page Forward showed lost C ahead of B") {
			pages.page(tab.id)?.webView.canGoForward == true
		}
		try await swipe(.forward, tab.id, pages: pages)
		try await inWebKit("A swipe forward from B after Forward into WebKit did not land on C", at: c)
		try await swipe(.back, tab.id, pages: pages)
		try await inWebKit("A swipe back from C after Forward into WebKit did not land on B", at: b)
		print("ARX_WEBKIT_SWIPE_SMOKE forward kept WebKit history")

		// A swipe back short of the threshold navigates nothing.
		try await swipe(.back, tab.id, distance: shortSwipe, pages: pages)
		try await Task.sleep(for: .seconds(2))
		try await inWebKit("A short swipe back from B navigated", at: b)
		print("ARX_WEBKIT_SWIPE_SMOKE short swipe stayed")

		// DEV-1293: an unlisted address typed on B opens it in Chromium, with B behind it. Back (⌘[)
		// shows B in WebKit again, and a swipe forward from B's last entry returns to Chromium.
		let typed = try Self.address(pageA, on: baseURL.host() ?? "127.0.0.1", baseURL: baseURL)
		try await engine.command(tab.id, .navigate(typed))
		try await inChromium("An unlisted address typed on B did not open in Chromium", at: typed)
		try await wait("Back is not enabled on the Chromium page opened from B") {
			store.main.commandContext(in: paneID).map(BrowserCommand.goBack.isEnabled(in:)) ?? false
		}
		store.send(.main(.ui(.paneCommand(.goBack, paneID))))
		try await inWebKit("Back from the Chromium page did not show B in WebKit again", at: b)
		print("ARX_WEBKIT_SWIPE_SMOKE back into WebKit")

		try await wait("The WebKit page Back showed has no way forward to Chromium") {
			engine.snapshot(tab.id)?.navigation.canGoForward == true
		}
		try await swipe(.forward, tab.id, pages: pages)
		try await inChromium("A swipe forward from B did not return to the Chromium page", at: typed)
		print("ARX_WEBKIT_SWIPE_SMOKE forward out of WebKit")

		// Back in Chromium, so later phases see their own engine.
		try await waitForChromiumPage("The tab's Chromium page did not reopen", tab.id, engine: engine, pageEngines: pageEngines)
		print("ARX_WEBKIT_SWIPE_SMOKE_SUCCESS")
		fflush(stdout)
	}


	// MARK: - Swipes

	internal enum Direction {
		case back
		case forward

		/// Back is a positive horizontal delta, natural scrolling or not.
		internal var sign: Double {
			switch self {
			case .back: 1
			case .forward: -1
			}
		}
	}

	/// One trackpad swipe on the tab's WebKit page: began, `distance.steps` changed phases of
	/// `distance.points` each, then ended. It waits for the page's answer about the first wheel
	/// before moving on.
	private static func swipe(
		_ direction: Direction,
		_ id: BrowserCore.Tab.ID,
		distance: (steps: Int, points: Double) = fullSwipe,
		pages: WebKitPages
	) async throws {
		guard let view = pages.page(id)?.webView else { throw Failure.noWebKitPage }

		try deliver(phase: .began, deltaX: 0, to: view)
		try await Task.sleep(for: .milliseconds(200))
		for _ in 0 ..< distance.steps {
			try deliver(phase: .changed, deltaX: direction.sign * distance.points, to: view)
			try await Task.sleep(for: .milliseconds(16))
		}
		try deliver(phase: .ended, deltaX: 0, to: view)
	}

	private enum Phase: Int64 {
		case began = 1
		case changed = 2
		case ended = 4
	}

	private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
	private static let setWindowLocation: SetWindowLocation? = dlsym(
		UnsafeMutableRawPointer(bitPattern: -2),
		"CGEventSetWindowLocation"
	).map { unsafeBitCast($0, to: SetWindowLocation.self) }

	/// Reports once whether AppKit gave the synthesized event the view's window.
	private static var reportedEventWindow: Bool = false

	/// A precise, non-momentum scroll over the middle of `view`, straight to its `scrollWheel`.
	/// The event names the view's window and where in it the fingers are, so AppKit can resolve
	/// its window; an NSEvent made from a CGEvent may still have none.
	private static func deliver(
		phase: Phase,
		deltaX: Double,
		to view: WKWebView
	) throws {
		guard let window = view.window else { throw Failure.noWebKitPage }

		let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
		let screenPoint = window.convertPoint(toScreen: view.convert(center, to: nil))
		let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
		let globalPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
		let windowTop = primaryHeight - window.frame.maxY

		guard let event = CGEvent(
			scrollWheelEvent2Source: nil,
			units: .pixel,
			wheelCount: 2,
			wheel1: 0,
			wheel2: Int32(deltaX.rounded()),
			wheel3: 0
		) else { throw Failure.noEvent }

		event.flags = []
		event.location = globalPoint
		event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
		event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
		event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
		event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
		event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX.rounded()))
		event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltaX)

		// kCGMouseEventWindowUnderMousePointer and …ThatCanHandleThisEvent.
		for field in [51, 52] {
			if let key = CGEventField(rawValue: UInt32(field)) {
				event.setIntegerValueField(key, value: Int64(window.windowNumber))
			}
		}
		setWindowLocation?(event, CGPoint(x: globalPoint.x - window.frame.minX, y: globalPoint.y - windowTop))

		guard let scroll = NSEvent(cgEvent: event) else { throw Failure.noEvent }
		if !reportedEventWindow {
			reportedEventWindow = true
			let resolved = scroll.window === window ? "the view's" : scroll.window == nil ? "none" : "another"
			print("ARX_WEBKIT_SWIPE_SMOKE event window: \(resolved)")
		}
		view.scrollWheel(with: scroll)
	}

	// MARK: - Waiting

	/// Waits for the tab to show `url` in WebKit, loaded, in `window`.
	private static func waitForWebKit(
		_ message: String,
		_ id: BrowserCore.Tab.ID,
		at url: URL,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient,
		pages: WebKitPages,
		window: NSWindow
	) async throws {
		do {
			try await wait(message) {
				guard
					pageEngines.engine(id) == .webKit,
					let view = pages.page(id)?.webView,
					let navigation = engine.snapshot(id)?.navigation
				else { return false }

				return !navigation.isLoading
				&& navigation.url?.host() == url.host()
				&& navigation.url?.path() == url.path()
				&& view.window === window
				&& !view.isHiddenOrHasHiddenAncestor
				&& view.bounds.width > 0
				&& view.bounds.height > 0
			}
		} catch Failure.timedOut(_) {
			throw Failure.timedOut(Self.state(message, id, engine: engine, pageEngines: pageEngines))
		}
	}

	/// Waits for the tab to show `url` in Chromium, loaded, with no WebKit mark in the sidebar.
	private static func waitForChromium(
		_ message: String,
		_ id: BrowserCore.Tab.ID,
		at url: URL,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient
	) async throws {
		do {
			try await wait(message) {
				guard
					pageEngines.engine(id) == .chromium,
					let navigation = engine.snapshot(id)?.navigation
				else { return false }

				return !navigation.isLoading
				&& navigation.url?.host() == url.host()
				&& navigation.url?.path() == url.path()
				&& !store.main.sidebar.webKitTabs.contains(id)
			}
		} catch Failure.timedOut(_) {
			throw Failure.timedOut(Self.state(message, id, engine: engine, pageEngines: pageEngines))
		}
	}

	/// Waits for the tab to be in Chromium with a Chromium page that has finished loading.
	private static func waitForChromiumPage(
		_ message: String,
		_ id: BrowserCore.Tab.ID,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient
	) async throws {
		do {
			try await wait(message) {
				pageEngines.engine(id) == .chromium && engine.snapshot(id).map { !$0.navigation.isLoading } == true
			}
		} catch Failure.timedOut(_) {
			throw Failure.timedOut(Self.state(message, id, engine: engine, pageEngines: pageEngines))
		}
	}

	/// The tab's engine, address, loading state and history, for a wait that timed out.
	private static func state(
		_ message: String,
		_ id: BrowserCore.Tab.ID,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient
	) -> String {
		let snapshot = engine.snapshot(id)
		let navigation = snapshot?.navigation
		let history = (navigation?.history ?? [])
			.map { entry in (entry.isCurrent ? "*" : "") + entry.url.absoluteString }
			.joined(separator: ", ")
		return [
			"\(message): the tab is in \(pageEngines.engine(id).rawValue)",
			snapshot == nil ? "with no page in that engine," : "with a page,",
			"at \(navigation?.url?.absoluteString ?? "?"), loading \(navigation?.isLoading ?? false),",
			"error \(navigation?.errorCode.map(String.init) ?? "none"), history [\(history)]",
		].joined(separator: " ")
	}

	/// The fixture's `file` on `host`, at the base URL's port.
	private static func address(
		_ file: String,
		on host: String,
		baseURL: URL
	) throws -> URL {
		let address = baseURL.deletingLastPathComponent().appending(path: file)
		guard var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)
		else { throw Failure.invalidFixture }

		parts.host = host
		parts.fragment = nil
		parts.query = nil
		guard let url = parts.url else { throw Failure.invalidFixture }
		return url
	}

	private static func wait(
		_ message: String,
		_ condition: () -> Bool
	) async throws {
		for _ in 0 ..< 200 {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut(message)
	}

	internal enum Failure: Error, CustomStringConvertible {
		case invalidFixture
		case noWebKitPage
		case noEvent
		case commandFailed(String, String)
		case timedOut(String)

		internal var description: String {
			switch self {
			case .invalidFixture: "The WebKit swipe fixture isn't a loopback Chromium tab with an unlisted page A and a listed page B"
			case .noWebKitPage: "The tab has no WebKit page in a window to swipe on"
			case .noEvent: "A trackpad scroll event couldn't be made"
			case let .commandFailed(error, state): "\(error); \(state)"
			case let .timedOut(message): message
			}
		}
	}
}
#endif
