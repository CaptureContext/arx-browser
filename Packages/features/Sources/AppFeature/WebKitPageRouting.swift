import AppLinkClient
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import OSLog
import _ComposableArchitecture

/// What the app hears from the page engines (DEV-877).
@CasePathable
public enum WebKitPagesAction: Sendable {
	/// Starts listening to protected media requests and engine moves. Sent once at launch.
	case observe
	case protectedMediaRequested(ProtectedMediaRequest)
	case engineChanged(PageEngineChange)

	/// A WebKit page asked for a new window: a tab in the window showing that page.
	/// `isPageRequest`: the page asked on its own, with no modifier key, middle button or popup
	/// size, so a Favorite's or pinned tab's link settings apply (DEV-1312).
	case openNewTab(source: BrowserCore.Tab.ID, URL, isPageRequest: Bool = false)

	/// The FairPlay sites the bridge can keep in Chromium tabs changed (DEV-1151).
	case fairPlayOriginsChanged(Set<String>)
}

extension AppFeature.State {
	/// The fallback prompt for `request`, for a Chromium page of a site that isn't declined, with
	/// no prompt showing (a stale one is replaced), on the window showing the page. With WebKit
	/// pages on, it offers WebKit, listed site or not: a streaming site whose video fails in
	/// Chromium, such as a page kept there after Back, falls back with a prompt, never silently
	/// (DEV-1188). A likely bot check stays quiet (`asksAboutWebKit`, DEV-1211). With them off,
	/// it tells a listed site's page why it can't play and offers `app` (DEV-1000); other sites
	/// that ask may only be probing, so they hear nothing.
	internal func webKitPrompt(
		for request: ProtectedMediaRequest,
		engine: PageEngine,
		id: UUID,
		app: WebKitPrompt.SiteApp? = nil
	) -> WebKitPrompt.State? {
		let preferences = settings.webKitPages
		guard
			!shouldQuit,
			!checkingQuit,
			webKitPrompt.map(isStale) ?? true,
			engine == .chromium,
			WebKitPagePreferences.isSecure(request.url),
			!preferences.isDeclined(request.url),
			Self.asksAboutWebKit(request, preferences),
			let windowID = windowShowing(request.tabID)
		else { return nil }

		guard preferences.isEnabled else {
			guard preferences.listedSite(for: request.url) != nil else { return nil }
			return .init(id: id, windowID: windowID, request: request, kind: .unavailable(app: app))
		}
		return .init(id: id, windowID: windowID, request: request)
	}

	/// Max's rule (DEV-1211): a streaming site falls back to WebKit with a prompt, and a likely bot
	/// check stays in Chromium with none. Media that can't play asks anywhere. Keys made with no
	/// media wanting them ask only on a streaming site, where a player that stopped early does
	/// that: elsewhere it's a likely bot check. The engine answers a capability probe as Chrome
	/// does and reports nothing at all (DEV-1205).
	internal static func asksAboutWebKit(
		_ request: ProtectedMediaRequest,
		_ preferences: WebKitPagePreferences
	) -> Bool {
		switch request.reason {
		case .playbackFailed: true
		case .keysWithoutMedia: preferences.isStreamingSite(request.url)
		}
	}

	/// Whether `prompt` can no longer be seen or answered: its window closed or no longer shows its
	/// tab. The sheet shows only on that window, so such a prompt would hold back every later one.
	internal func isStale(_ prompt: WebKitPrompt.State) -> Bool {
		windowShowing(prompt.request.tabID) != prompt.windowID
	}

	/// The window whose page area shows the tab: a normal window's pane or a Little Arx.
	internal func windowShowing(_ tabID: BrowserCore.Tab.ID) -> UUID? {
		for host in (windowIsOpen ? [main] : []) + Array(windows) where !host.isClosing {
			if host.viewer.item.tab?.id == tabID || host.viewer.panes.contains(where: { $0.item.tab?.id == tabID }) {
				return host.id
			}
		}
		return littleWindows.first { $0.viewer.tab?.id == tabID }?.id
	}

	/// Every window's sidebar marks the tabs WebKit shows.
	internal mutating func publishWebKitTabs() {
		let tabs = webKitTabs
		if main.sidebar.webKitTabs != tabs { main.sidebar.webKitTabs = tabs }
		for id in windows.ids where windows[id: id]?.sidebar.webKitTabs != tabs {
			windows[id: id]?.sidebar.webKitTabs = tabs
		}
	}

	/// The FairPlay sites the bridge can keep in Chromium tabs, for every window's site menu, so
	/// its Open in WebKit shows where the router sends a page (DEV-1151).
	internal mutating func publishFairPlayOrigins() {
		let origins = fairPlayOrigins
		if main.siteMenu.fairPlayOrigins != origins { main.siteMenu.fairPlayOrigins = origins }
		for id in windows.ids where windows[id: id]?.siteMenu.fairPlayOrigins != origins {
			windows[id: id]?.siteMenu.fairPlayOrigins = origins
		}
		for id in floatingSiteMenus.ids where floatingSiteMenus[id: id]?.siteMenu.fairPlayOrigins != origins {
			floatingSiteMenus[id: id]?.siteMenu.fairPlayOrigins = origins
		}
	}
}

/// The fallback prompt, the sidebar's engine mark and WebKit popups (DEV-877).
@Reducer
internal struct WebKitPageRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.pageEngines)
	private var pageEngines

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.appLinks)
	private var appLinks

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.webKitPages.observe) { _ in
				.merge(
					.run { [pageEngines] send in
						for await request in await pageEngines.protectedMediaRequests() {
							await send(.webKitPages(.protectedMediaRequested(request)))
						}
					},
					.run { [pageEngines] send in
						for await change in await pageEngines.changes() {
							await send(.webKitPages(.engineChanged(change)))
						}
					}
				)
				.cancellable(id: Cancellation.observe, cancelInFlight: true)
			}

			Pullback(\.webKitPages.protectedMediaRequested) { state, request in
				let engine = MainActor.assumeIsolated { [pageEngines] in pageEngines.engine(request.tabID) }
				let app = state.settings.webKitPages.isEnabled ? nil : siteApp(for: request.url)
				guard let prompt = state.webKitPrompt(for: request, engine: engine, id: uuid(), app: app) else {
					let preferences = state.settings.webKitPages
					let tab = String(request.tabID.rawValue.uuidString.prefix(8))
					let pages = preferences.isEnabled ? "on" : "off"
					let declined = preferences.isDeclined(request.url)
					let listed = preferences.listedSite(for: request.url) != nil
					let reason = request.reason == .playbackFailed ? "playback failed" : "keys without media"
					let streaming = preferences.isStreamingSite(request.url)
					log.notice(
						"Tab \(tab, privacy: .public): no WebKit prompt; \(reason, privacy: .public), engine \(engine.rawValue, privacy: .public), WebKit pages \(pages, privacy: .public), declined \(declined, privacy: .public), listed \(listed, privacy: .public), streaming \(streaming, privacy: .public)"
					)
					return .none
				}

				state.webKitPrompt = prompt
				return .none
			}

			Pullback(\.webKitPages.engineChanged) { state, change in
				switch change.engine {
				case .webKit: state.webKitTabs.insert(change.tabID)
				case .chromium: state.webKitTabs.remove(change.tabID)
				}
				state.publishWebKitTabs()

				// A prompt for a page that moved has nothing left to ask.
				if state.webKitPrompt?.request.tabID == change.tabID, change.engine == .webKit {
					state.webKitPrompt = nil
				}
				return .none
			}

			Pullback(\.webKitPages.openNewTab) { state, value in
				let (source, url, isPageRequest) = value
				guard let windowID = state.windowShowing(source) else { return .none }

				// A Favorite's or pinned tab's page asking for a tab goes where Settings send its
				// links to other sites (DEV-1312), as from a Chromium page. WebKit keeps no opener.
				if
					isPageRequest,
					let route = state.crossSiteLinkRoute(from: source),
					route == .peek || route == .littleArx,
					let profileID = state.workspace.tabs[id: source]?.profileID,
					let placement = state.nativeContentPlacement(tabID: source, profileID: profileID, isPrivate: false),
					placement.peekID == nil,
					let action = state.linkOpenAction(url, route: route, placement: placement, origin: nil)
				{
					return .send(action)
				}
				if state.windowIsOpen, state.main.id == windowID {
					return .send(.main(.ui(.openInNewTab(url))))
				}
				if state.windows[id: windowID] != nil {
					return .send(.windows(.element(id: windowID, action: .ui(.openInNewTab(url)))))
				}

				// Little Arx has one page: its popups open as tabs in the main window, as its
				// Open in Main Window does.
				guard let little = state.littleWindows[id: windowID] else { return .none }
				return .send(.openInMainWindow(url, little.spaceID))
			}

			Pullback(\.webKitPages.fairPlayOriginsChanged) { state, origins in
				state.fairPlayOrigins = origins
				state.publishFairPlayOrigins()
				return .none
			}

			Pullback(\.webKitPrompt.delegate.answered) { state, value in
				let (request, answer) = value
				state.webKitPrompt = nil
				switch answer {
				case .openInWebKit:
					// The page may have gone elsewhere while the prompt showed: the offer was for
					// the address that asked.
					let current = MainActor.assumeIsolated { [engine] in engine.snapshot(request.tabID)?.navigation.url }
					guard current == request.url else { return .none }
					state.settings.$webKitPages.withLock { _ = $0.add(request.url) }
					return .run { [pageEngines] _ in
						_ = await pageEngines.move(request.tabID, .webKit, request.url)
					}

				case let .openApp(url, dontAskAgain):
					if dontAskAgain {
						state.settings.$webKitPages.withLock { $0.decline(request.url) }
					}
					return .run { [appLinks] _ in
						_ = await appLinks.openApp(url, nil)
					}

				case let .stay(dontAskAgain):
					if dontAskAgain {
						state.settings.$webKitPages.withLock { $0.decline(request.url) }
					}
					return .none
				}
			}

			// A window opened since the last move shows the marks too, and its site menu knows the
			// FairPlay sites.
			Reduce { state, _ in
				if !state.webKitTabs.isEmpty { state.publishWebKitTabs() }
				if !state.fairPlayOrigins.isEmpty { state.publishFairPlayOrigins() }
				return .none
			}
		}
		.ifLet(\.webKitPrompt, action: \.webKitPrompt) { WebKitPrompt() }
	}

	/// The installed app that plays `url`'s site, when there is one.
	private func siteApp(for url: URL) -> WebKitPrompt.SiteApp? {
		guard let link = StreamingAppLink.url(for: url) else { return nil }
		return MainActor.assumeIsolated { [appLinks] in
			appLinks.appName(link).map { .init(name: $0, url: link, path: appLinks.appPath(link)) }
		}
	}

	private enum Cancellation: Hashable {
		case observe
	}
}

/// DEV-1188: why a Chromium page whose protected media failed got no WebKit prompt, in the
/// FairPlay log category. Never a page's address.
private let log: Logger = .init(subsystem: "dev.capturecontext.arx", category: "FairPlay")
