#if DEBUG
import BrowserCore
import BrowserEngineClient
import AppKit
import ChromiumBrowserEngine
import Foundation
import OSLog
import WebKit
import _ComposableArchitecture

/// The app smoke's overnight `webkit-fallback` phase (DEV-877), run only when the runner sets
/// `ARX_WEBKIT_FALLBACK_SMOKE`. Needs an engine with the protected media export.
///
/// An owned loopback page asks for Widevine with `navigator.requestMediaKeySystemAccess`, which
/// Arx's Chromium can't play, and creates its keys. The engine answers Widevine without a CDM
/// (DEV-1144), so access resolves and the keys are refused with NotSupportedError, as the
/// page's title says; with `ARX_WIDEVINE_ANSWER=off` access itself is refused. The fallback
/// prompt must appear on the page's window; Open in
/// WebKit must list the site and move the page, which must then show in WebKit at the same
/// address with its engine mark, and its WebKit view must fill the main window's page area: a page
/// WebKit loaded that no window shows reads as blank. Settings are restored afterwards.
///
/// A frame asks Chromium for its key systems once, and a same-site navigation can keep the frame
/// of an earlier page that already did, so nothing would be heard. The page therefore opens on
/// whichever loopback host (`localhost` or `127.0.0.1`) the tab isn't showing: a cross-site
/// navigation gets a new frame.
///
/// First (DEV-1211), on `[::1]`, a third loopback site nobody listed, a page creates keys (or is
/// refused access, with the answer off) and gives them to no media element, as a bot check may:
/// no prompt. The page that gets the prompt has a `<video>` that meets encrypted media, as a
/// streaming player's does. A player that keeps its video in a same-origin iframe and makes its
/// keys in the parent, on the other loopback host and unlisted too, gets the prompt. Then (DEV-1205), with the Widevine answer on, a page making bot
/// detection's DRM calls gets Chrome's answers and no prompt, and a page whose only request
/// (PlayReady) is refused gets the prompt, answered Stay on Page. Each stage navigates across
/// sites, so each gets a new frame.
///
/// Then (DEV-1000) the WebKit page opens the keys-only page at the listed site and goes back to
/// Chromium, where Arx keeps it. Its keys fail there with no media wanting them, and on a site the
/// person listed that still asks (DEV-1211): a streaming site's video falls back to WebKit with a
/// prompt, never silently (DEV-1188). The prompt must appear, and after Stay on Page the page
/// must stay in Chromium. If it moves anyway, the failure says how: the page's events, engine changes and
/// protected media requests while the phase watched, the `FairPlay` log, and which way the
/// router most likely moved it. Last, a page on the other loopback host that replaces itself
/// with the listed page by script must move to WebKit with no prompt.
///
/// A wait for a page in WebKit that times out says which of its conditions didn't hold, with the
/// page's state and its events since the stage began.
@MainActor
internal enum WebKitFallbackSmoke {
	internal static let page: String = "protected-media.html"
	internal static let redirect: String = "redirect-to-protected-media.html"

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			let tab = store.main.viewer.item.tab,
			pageEngines.engine(tab.id) == .chromium
		else { throw Failure.invalidFixture }

		let saved = store.settings.webKitPages
		defer { store.settings.$webKitPages.withLock { $0 = saved } }
		store.settings.$webKitPages.withLock { $0.isEnabled = true }

		// The host is chosen from the page the tab settled on: a navigation still loading could
		// replace the stage's own, as the full-screen stage's return once did.
		try await wait("The page did not finish loading") {
			engine.snapshot(tab.id).map { !$0.navigation.isLoading } ?? false
		}
		let shown = engine.snapshot(tab.id)?.navigation.url?.host()
		let host = shown == Self.localHost ? Self.loopbackAddress : Self.localHost
		let otherHost = host == Self.localHost ? Self.loopbackAddress : Self.localHost
		let answered = ProcessInfo.processInfo.environment["ARX_WIDEVINE_ANSWER"] != "off"

		// DEV-1205, with the Widevine answer on: a page that only probes, as bot detection
		// does, gets Chrome's answers and isn't offered WebKit; a page whose only request is
		// refused, with nothing granted, is.
		try await Self.keysOnlyStaysQuiet(tab.id, answered: answered, store: store, engine: engine, baseURL: baseURL)
		try await Self.framedPlayerOffersWebKit(
			tab.id,
			on: otherHost,
			answered: answered,
			store: store,
			engine: engine,
			baseURL: baseURL
		)
		if answered {
			try await Self.probeStaysQuiet(tab.id, on: host, store: store, engine: engine, baseURL: baseURL)
			try await Self.refusalOffersWebKit(tab.id, on: otherHost, store: store, engine: engine, baseURL: baseURL)
		}

		let url = try Self.address(page, on: host, baseURL: baseURL)
		try await engine.command(tab.id, .navigate(url))

		// The page asks once it has drawn; the prompt goes on the main window.
		do {
			try await wait("The fallback prompt did not appear") {
				store.webKitPrompt?.request.tabID == tab.id
				&& store.webKitPrompt?.windowID == store.main.id
			}
		} catch Failure.timedOut(_) {
			throw Failure.timedOut(Self.noPrompt(tab.id, store: store, engine: engine, pageEngines: pageEngines))
		}
		guard
			let prompt = store.webKitPrompt,
			prompt.request.url.host() == host,
			!store.settings.webKitPages.opensInWebKit(url)
		else { throw Failure.unexpectedPrompt }

		let expected = answered ? "Protected media keys refused: NotSupportedError" : "Protected media refused"
		try await wait("The page's protected media title isn't \"\(expected)\"") {
			engine.snapshot(tab.id)?.navigation.title == expected
		}
		print(answered ? "ARX_WIDEVINE_ANSWER_SMOKE answered" : "ARX_WIDEVINE_ANSWER_SMOKE off")

		let moveTrace = Trace(tab.id, engine: engine, pageEngines: pageEngines)
		defer { moveTrace.stop() }
		store.send(.webKitPrompt(.ui(.openInWebKitButtonTapped)))

		try await waitForWebKit(
			"The page did not move to WebKit",
			tab.id,
			at: url,
			afterPrompt: true,
			store: store,
			engine: engine,
			pageEngines: pageEngines,
			trace: moveTrace
		)
		moveTrace.stop()
		try await wait("The WebKit page is not in the window") { Self.showsWebKitPage(in: window) }

		// The WebKit page opens the keys-only page at the listed site, then goes back to Chromium,
		// where Arx keeps it. Its keys fail with no media wanting them: on a listed site that asks,
		// as a streaming player that stops early does (DEV-1211), and the page is offered WebKit
		// rather than moved (DEV-1188). Stay on Page leaves it there.
		let keysOnly = try Self.address(keysOnlyPage, on: host, baseURL: baseURL)
		try await engine.command(tab.id, .navigate(keysOnly))
		try await wait("The WebKit page did not open the keys-only page") {
			pageEngines.engine(tab.id) == .webKit
			&& engine.snapshot(tab.id)?.navigation.url?.path() == keysOnly.path()
		}
		let trace = Trace(tab.id, engine: engine, pageEngines: pageEngines)
		defer { trace.stop() }
		try await returnToChromium(tab.id, store: store, pageEngines: pageEngines)
		do {
			try await wait("The kept page's fallback prompt did not appear") {
				pageEngines.engine(tab.id) != .chromium
				|| store.webKitPrompt?.request.tabID == tab.id
				&& store.webKitPrompt?.windowID == store.main.id
			}
		} catch Failure.timedOut(_) {
			throw Failure.timedOut(Self.noPrompt(tab.id, store: store, engine: engine, pageEngines: pageEngines))
		}
		guard pageEngines.engine(tab.id) == .chromium else {
			throw Failure.didNotStay(Self.didNotStay(tab.id, at: keysOnly, trace: trace, store: store, engine: engine))
		}
		guard
			let kept = store.webKitPrompt,
			kept.kind == .offer,
			kept.request.url.host() == host
		else { throw Failure.unexpectedPrompt }
		let keysOnlyTitle = Self.keysOnlyTitle(answered: answered)
		try await wait("The kept page's title isn't \"\(keysOnlyTitle)\"") {
			engine.snapshot(tab.id)?.navigation.title == keysOnlyTitle
		}
		print("ARX_WEBKIT_FALLBACK_KEPT_SMOKE offered")

		store.send(.webKitPrompt(.ui(.stayButtonTapped)))
		try await wait("The kept page's fallback prompt did not close") { store.webKitPrompt == nil }
		try await Task.sleep(for: .seconds(2))
		trace.stop()
		guard pageEngines.engine(tab.id) == .chromium else {
			throw Failure.didNotStay(Self.didNotStay(tab.id, at: keysOnly, trace: trace, store: store, engine: engine))
		}
		guard !store.settings.webKitPages.isDeclined(keysOnly) else { throw Failure.unexpectedPrompt }

		// Another site replaces itself with the listed page by script: no link click Arx could
		// take. The page moves to WebKit on its own.
		var start = try Self.address(redirect, on: otherHost, baseURL: baseURL)
		start.append(queryItems: [.init(name: "to", value: host)])
		let redirectTrace = Trace(tab.id, engine: engine, pageEngines: pageEngines)
		defer { redirectTrace.stop() }
		try await engine.command(tab.id, .navigate(start))
		try await waitForWebKit(
			"The redirected page did not move to WebKit",
			tab.id,
			at: url,
			afterPrompt: false,
			store: store,
			engine: engine,
			pageEngines: pageEngines,
			trace: redirectTrace
		)
		redirectTrace.stop()
		guard store.webKitPrompt == nil else { throw Failure.unexpectedPrompt }
		try await wait("The redirected WebKit page is not in the window") { Self.showsWebKitPage(in: window) }

		// Back to Chromium, as the site menu's switch does, so later phases see their own engine.
		try await returnToChromium(tab.id, store: store, pageEngines: pageEngines)

		print("ARX_WEBKIT_FALLBACK_SMOKE_SUCCESS")
		fflush(stdout)
	}

	internal static let localHost: String = "localhost"
	internal static let loopbackAddress: String = "127.0.0.1"

	/// DEV-1211: creates keys and gives them to no media element, on `[::1]`, a loopback site the
	/// other stages don't use, so it gets a new frame and nobody listed it.
	internal static let keysOnlyPage: String = "create-keys-only.html"
	internal static let ipv6Loopback: String = "[::1]"

	/// The keys-only page's title: its keys refused with the Widevine answer on, its access
	/// refused with the answer off.
	internal static func keysOnlyTitle(answered: Bool) -> String {
		answered ? "Keys only: keys refused: NotSupportedError" : "Keys only: access refused"
	}

	/// The keys-only page, as a bot check may, creates keys (or is refused access) and gives them
	/// to no media element. On a site nobody listed, no prompt may come for longer than the
	/// engine waits for a grant after a refusal (3 seconds).
	private static func keysOnlyStaysQuiet(
		_ id: BrowserCore.Tab.ID,
		answered: Bool,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		baseURL: URL
	) async throws {
		let url = try Self.address(keysOnlyPage, on: ipv6Loopback, baseURL: baseURL)
		try await engine.command(id, .navigate(url))
		let expected = keysOnlyTitle(answered: answered)
		try await wait("The keys-only page's title isn't \"\(expected)\"") {
			engine.snapshot(id)?.navigation.title == expected
		}
		try await Task.sleep(for: .seconds(5))
		guard store.webKitPrompt == nil else { throw Failure.keysOnlyOffered }
		print("ARX_KEYS_ONLY_SMOKE quiet")
	}

	/// DEV-1211: makes its keys while its same-origin iframe's `<video>` meets encrypted media.
	internal static let framedPlayerPage: String = "framed-player.html"

	/// The framed player: media in a same-origin frame of the page counts for keys made in
	/// another, so on a site nobody listed it still gets the prompt; the phase stays on the page.
	private static func framedPlayerOffersWebKit(
		_ id: BrowserCore.Tab.ID,
		on host: String,
		answered: Bool,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		baseURL: URL
	) async throws {
		let url = try Self.address(framedPlayerPage, on: host, baseURL: baseURL)
		try await engine.command(id, .navigate(url))
		try await wait("The framed player got no fallback prompt") {
			store.webKitPrompt?.request.tabID == id
			&& store.webKitPrompt?.windowID == store.main.id
		}
		guard store.webKitPrompt?.request.url.host() == host else { throw Failure.unexpectedPrompt }
		let expected = answered ? "Framed player keys refused: NotSupportedError" : "Framed player refused"
		try await wait("The framed player's title isn't \"\(expected)\"") {
			engine.snapshot(id)?.navigation.title == expected
		}

		store.send(.webKitPrompt(.ui(.stayButtonTapped)))
		try await wait("The fallback prompt stayed after Stay on Page") { store.webKitPrompt == nil }
		guard
			!store.settings.webKitPages.opensInWebKit(url),
			!store.settings.webKitPages.isDeclined(url)
		else { throw Failure.unexpectedPrompt }
		print("ARX_FRAMED_PLAYER_SMOKE offered")
	}

	internal static let probePage: String = "drm-probe.html"
	internal static let refusedPage: String = "refused-protected-media.html"

	/// Chrome on a Mac answers bot detection's DRM probe so: Widevine and Clear Key, without
	/// persistent licences (DEV-1205).
	internal static let probeAnswer: String =
		"DRM probe: decodingInfo=true wv=true wvp=false pr=false ck=true pt=false fp=false"

	/// The probe page makes Fingerprint's DRM calls (resend.com). Its title must read Chrome's
	/// answers, and no prompt may come for longer than the engine waits for a grant after a
	/// refusal (3 seconds).
	private static func probeStaysQuiet(
		_ id: BrowserCore.Tab.ID,
		on host: String,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		baseURL: URL
	) async throws {
		let url = try Self.address(probePage, on: host, baseURL: baseURL)
		try await engine.command(id, .navigate(url))
		try await wait("The DRM probe's title isn't \"\(probeAnswer)\"") {
			engine.snapshot(id)?.navigation.title == probeAnswer
		}
		try await Task.sleep(for: .seconds(5))
		guard store.webKitPrompt == nil else { throw Failure.probeOffered }
		print("ARX_DRM_PROBE_SMOKE quiet")
	}

	/// The refused page asks only for PlayReady, which is refused, and is granted nothing: the
	/// prompt comes, and the phase stays on the page.
	private static func refusalOffersWebKit(
		_ id: BrowserCore.Tab.ID,
		on host: String,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		baseURL: URL
	) async throws {
		let url = try Self.address(refusedPage, on: host, baseURL: baseURL)
		try await engine.command(id, .navigate(url))
		try await wait("The refused page got no fallback prompt") {
			store.webKitPrompt?.request.tabID == id
			&& store.webKitPrompt?.windowID == store.main.id
		}
		guard
			store.webKitPrompt?.request.url.host() == host,
			engine.snapshot(id)?.navigation.title == "Protected media refused: NotSupportedError"
		else { throw Failure.unexpectedPrompt }

		store.send(.webKitPrompt(.ui(.stayButtonTapped)))
		try await wait("The fallback prompt stayed after Stay on Page") { store.webKitPrompt == nil }
		guard !store.settings.webKitPages.opensInWebKit(url) else { throw Failure.unexpectedPrompt }
		print("ARX_DRM_REFUSAL_SMOKE offered")
	}

	/// Whether the window's page area shows a WebKit page: a visible web view with a size, in the
	/// window. The phase has one WebKit page at a time.
	private static func showsWebKitPage(in window: NSWindow) -> Bool {
		guard let content = window.contentView else { return false }
		return webViews(in: content).contains { view in
			view.window === window
			&& !view.isHiddenOrHasHiddenAncestor
			&& view.bounds.width > 0
			&& view.bounds.height > 0
		}
	}

	private static func webViews(in view: NSView) -> [WKWebView] {
		if let webView = view as? WKWebView { return [webView] }
		return view.subviews.flatMap(webViews)
	}

	/// The fixture's `file` on `host`, at the base URL's port.
	internal static func address(
		_ file: String,
		on host: String,
		baseURL: URL
	) throws -> URL {
		let address = baseURL.deletingLastPathComponent().appending(path: file)
		guard var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)
		else { throw Failure.invalidFixture }

		parts.host = host
		guard let url = parts.url else { throw Failure.invalidFixture }
		return url
	}

	/// What the page did when no prompt came. The page titles itself once its request settles:
	/// still "loading" means it never asked (it didn't draw a frame), "refused" or "granted" that
	/// it asked and Arx heard nothing. A page still at the address before it either never got the
	/// navigation or failed to load the fixture: the error code and history tell which.
	private static func noPrompt(
		_ id: BrowserCore.Tab.ID,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient
	) -> String {
		let navigation = engine.snapshot(id)?.navigation
		let prompt = store.webKitPrompt.map { prompt in
			"a prompt for tab \(prompt.request.tabID.rawValue) on window \(prompt.windowID) (main \(store.main.id))"
		} ?? "no prompt"
		let history = (navigation?.history ?? [])
			.map { entry in (entry.isCurrent ? "*" : "") + entry.url.absoluteString }
			.joined(separator: ", ")
		return [
			"The fallback prompt did not appear:",
			"the page is \"\(navigation?.title ?? "?")\" at \(navigation?.url?.absoluteString ?? "?")",
			"in \(pageEngines.engine(id)), loading \(navigation?.isLoading ?? false),",
			"error \(navigation?.errorCode.map(String.init) ?? "none"), history [\(history)];",
			"\(prompt)",
		].joined(separator: " ")
	}

	/// Waits for the tab to show `url`'s page in WebKit. After the fallback prompt's Open in
	/// WebKit (`afterPrompt`), the prompt has closed, the site is listed, the sidebar marks the
	/// tab and the page reports WebKit too. A wait that times out says which of these didn't hold,
	/// with the page's state and what happened since `trace` started (DEV-1188).
	private static func waitForWebKit(
		_ message: String,
		_ id: BrowserCore.Tab.ID,
		at url: URL,
		afterPrompt: Bool,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient,
		trace: Trace
	) async throws {
		var conditions: [(name: String, holds: () -> Bool)] = [
			("the router shows WebKit", { pageEngines.engine(id) == .webKit }),
			("the page is at \(url.host() ?? "?")\(url.path())", {
				engine.snapshot(id)?.navigation.url?.host() == url.host()
				&& engine.snapshot(id)?.navigation.url?.path() == url.path()
			}),
		]
		if afterPrompt {
			conditions += [
				("the prompt closed", { store.webKitPrompt == nil }),
				("the site is listed", { store.settings.webKitPages.opensInWebKit(url) }),
				("the sidebar marks WebKit", { store.main.sidebar.webKitTabs.contains(id) }),
				("the page reports WebKit", { engine.snapshot(id)?.navigation.engine == .webKit }),
			]
		}
		do {
			try await wait(message) { conditions.allSatisfy { $0.holds() } }
		} catch Failure.timedOut(_) {
			let failed = conditions.filter { !$0.holds() }.map(\.name)
			let navigation = engine.snapshot(id)?.navigation
			let prompt = store.webKitPrompt.map { "a prompt for \($0.request.url.absoluteString)" } ?? "no prompt"
			throw Failure.timedOut([
				"\(message): not \(failed.joined(separator: ", "));",
				"the page is at \(navigation?.url?.absoluteString ?? "?") in \(pageEngines.engine(id).rawValue),",
				"reporting \(navigation?.engine.rawValue ?? "?"), loading \(navigation?.isLoading ?? false),",
				"error \(navigation?.errorCode.map(String.init) ?? "none"), history [\(Self.history(navigation))]; \(prompt).",
				"Events: \(trace.lines.isEmpty ? "none" : trace.lines.joined(separator: " | ")).",
			].joined(separator: " "))
		}
	}

	/// Why the kept page moved to WebKit again, as far as the phase can tell. The router logs
	/// a move after failed protected media (`protectedMediaRequested`); a move that follows the
	/// listed site from the page's history isn't logged. That one comes after an entry off the
	/// kept site ends the keeping, as a reopened page's restored history may show while loading.
	private static func didNotStay(
		_ id: BrowserCore.Tab.ID,
		at url: URL,
		trace: Trace,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient
	) -> String {
		let preferences = store.settings.webKitPages
		let site = preferences.listedSite(for: url) ?? "none"
		let log = fairPlayLog(since: trace.date)
		let decision = if log.contains(where: { $0.contains("moving the page to WebKit") }) {
			"the router moved it after its protected media failed (protectedMediaRequested)"
		} else if trace.leftSite(site) {
			"no protected media move was logged, and the page showed an entry off the kept site: "
			+ "that ended the keeping, and the router followed the listed site from its history"
		} else {
			"no protected media move was logged: the router followed the listed site from the page's history"
		}
		let navigation = engine.snapshot(id)?.navigation
		return [
			"the page is at \(navigation?.url?.absoluteString ?? "?") in \(navigation?.engine.rawValue ?? "?");",
			"kept site \(site), listed \(preferences.sites), opens in WebKit \(preferences.opensInWebKit(url)),",
			"plays only in WebKit \(preferences.playsProtectedMediaOnlyInWebKit(url));",
			"history [\(Self.history(navigation))];",
			"likely \(decision).",
			"Events: \(trace.lines.isEmpty ? "none" : trace.lines.joined(separator: " | ")).",
			"FairPlay log: \(log.isEmpty ? "nothing" : log.joined(separator: " | ")).",
		].joined(separator: " ")
	}

	fileprivate static func history(_ navigation: BrowserNavigation?) -> String {
		(navigation?.history ?? [])
			.map { entry in (entry.isCurrent ? "*" : "") + "\(entry.id) " + entry.url.absoluteString }
			.joined(separator: ", ")
	}

	/// This process's `FairPlay` log entries since `date`: where the router and the app sent each
	/// failed protected media request.
	private static func fairPlayLog(since date: Date) -> [String] {
		do {
			let store = try OSLogStore(scope: .currentProcessIdentifier)
			let entries = try store.getEntries(
				at: store.position(date: date),
				matching: NSPredicate(
					format: "subsystem == %@ AND category == %@",
					"dev.capturecontext.arx",
					"FairPlay"
				)
			)
			return entries
				.compactMap { $0 as? OSLogEntryLog }
				.map { entry in
					String(format: "%.2f s ", entry.date.timeIntervalSince(date)) + entry.composedMessage
				}
		} catch {
			return ["unreadable: \(error)"]
		}
	}

	private static func returnToChromium(
		_ id: BrowserCore.Tab.ID,
		store: StoreOf<AppFeature>,
		pageEngines: PageEngineClient
	) async throws {
		guard await pageEngines.move(id, .chromium, nil) else { throw Failure.didNotReturn }
		try await wait("The page did not return to Chromium") {
			pageEngines.engine(id) == .chromium && !store.main.sidebar.webKitTabs.contains(id)
		}
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
		case unexpectedPrompt
		case didNotReturn
		case didNotStay(String)
		case probeOffered
		case keysOnlyOffered
		case timedOut(String)

		internal var description: String {
			switch self {
			case .invalidFixture: "The WebKit fallback fixture isn't a loopback Chromium tab"
			case .unexpectedPrompt: "The fallback prompt named another page or came when none should, a page's title was wrong, or Stay on Page changed the site's list"
			case .didNotReturn: "The page didn't move back to Chromium"
			case let .didNotStay(diagnosis): "The page Arx showed in Chromium at a listed site moved to WebKit again: " + diagnosis
			case .probeOffered: "A page that only probed DRM support was offered WebKit"
			case .keysOnlyOffered: "A page that made keys for no media, on a site nobody listed, was offered WebKit"
			case let .timedOut(message): message
			}
		}
	}
}

/// What happened to a tab while the phase watched it: its page's events, its engine changes and
/// the failed protected media requests the router passed on to the app, each with the time since
/// the trace started. The router keeps only a page's newest event for a slow reader, so the
/// events are a sample; engine changes and requests are all there.
@MainActor
private final class Trace {
	internal let date: Date = .now
	internal private(set) var lines: [String] = []

	/// Each event's current history entry, to tell whether the page left the kept site.
	private var hosts: [String] = []
	private let start: ContinuousClock.Instant = .now
	private var tasks: [Task<Void, Never>] = []

	internal init(
		_ id: BrowserCore.Tab.ID,
		engine: BrowserEngineClient,
		pageEngines: PageEngineClient
	) {
		let events = engine.events(id)
		let changes = pageEngines.changes()
		let requests = pageEngines.protectedMediaRequests()
		tasks = [
			Task { [weak self] in
				for await navigation in events { self?.note(navigation) }
			},
			Task { [weak self] in
				for await change in changes where change.tabID == id {
					self?.note("engine \(change.engine.rawValue)")
				}
			},
			Task { [weak self] in
				for await request in requests where request.tabID == id {
					self?.note("protected media failed, passed to the app: \(request.url.absoluteString)")
				}
			},
		]
	}

	internal func stop() {
		for task in tasks { task.cancel() }
		tasks = []
	}

	/// Whether an event showed a current entry off `site`.
	internal func leftSite(_ site: String) -> Bool {
		hosts.contains { !WebKitPagePreferences.covers(site, host: $0) }
	}

	private func note(_ navigation: BrowserNavigation) {
		let current = navigation.history.first(where: \.isCurrent)
		if let host = current.flatMap({ WebKitPagePreferences.host(of: $0.url) }) { hosts.append(host) }
		note([
			"\(navigation.engine.rawValue) \(navigation.url?.absoluteString ?? "?")",
			"loading \(navigation.isLoading)",
			navigation.errorCode.map { "error \($0)" } ?? "",
			"history [\(WebKitFallbackSmoke.history(navigation))]",
		].filter { !$0.isEmpty }.joined(separator: " "))
	}

	private func note(_ line: String) {
		let elapsed = start.duration(to: .now).components
		let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
		lines.append("\(milliseconds) ms " + line)
	}
}
#endif
