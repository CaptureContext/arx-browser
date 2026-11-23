import BrowserCore
import BrowserEngineClient
import DefaultBrowserClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// `chrome://` and `arc://` links from pages, and `arc://` and `arx://settings` from other apps
/// (DEV-1193).
@CasePathable
public enum BrowserLinksAction: Sendable {
	/// A page asked to open a `chrome://` or `arc://` link, through the external-link offer.
	case pageLink(BrowserExternalLink)

	/// Another app opened an `arc://` link or an `arx://settings/…` address with Arx.
	case outsideLink(URL)

	/// The browser didn't take the link handed to it.
	case browserDidNotOpen(BrowserSchemeLink, BrowserLinkPrompt.Origin)
}

/// Opens a `chrome://` or `arc://` link where `BrowserSchemeLink.decision` says (DEV-1193):
/// Arx's place for it, through DEV-1189's `SettingsAddress` routing, Arc, or App Links' built-in
/// handler for Chrome's pages, whose prompt offers Chrome and Arx. "Arx can't open this" is a
/// sheet on the window the link came from. Behind the `ARX_BROWSER_LINKS` feature flag.
@Reducer
internal struct BrowserLinkRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.browserLinks)
	private var browserLinks

	internal var body: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.browserLinks.pageLink) { state, request in
				guard
					FeatureFlag.browserLinks.isOn(),
					let link = BrowserSchemeLink(string: request.link),
					let placement = state.nativeContentPlacement(
						tabID: request.sourceTabID,
						profileID: request.profileID,
						isPrivate: request.isPrivate
					)
				else { return .none }

				// The page's own profile: a floating page's may differ from its window's.
				let origin: BrowserLinkPrompt.Origin = .init(
					windowID: placement.windowID,
					profileID: request.isPrivate ? nil : request.profileID,
					source: .page
				)
				return open(link, from: origin, request: request, state: &state)
			}

			Pullback(\.browserLinks.outsideLink) { state, url in
				guard
					FeatureFlag.browserLinks.isOn(),
					!state.shouldQuit,
					!state.checkingQuit
				else { return .none }

				let origin: BrowserLinkPrompt.Origin = .init(
					windowID: state.main.id,
					profileID: state.browserLinkProfileID(state.main.id),
					source: .otherApp
				)

				// `arx://settings/…` from Terminal or another app: Settings at its place.
				if url.scheme?.lowercased() == SettingsAddress.arxScheme {
					guard let address = SettingsAddress(url) else { return .none }
					return openInArx(address, from: origin, state: &state)
				}

				// Another browser's scheme from outside is only ever Arc's.
				guard let link = BrowserSchemeLink(url), link.browser == .arc else { return .none }
				return open(link, from: origin, request: nil, state: &state)
			}

			Pullback(\.browserLinks.browserDidNotOpen) { state, value in
				let (link, origin) = value
				return present(.init(id: uuid(), origin: origin, link: link), state: &state)
			}

			// App Links' prompt for Chrome's pages: Open in Arx (DEV-1193).
			Pullback(\.appLinkPrompt.delegate.openInArx) { state, value in
				let (place, windowID, profileID) = value
				let origin: BrowserLinkPrompt.Origin = .init(windowID: windowID, profileID: profileID, source: .page)
				return openInArx(place, from: origin, state: &state)
			}

			Pullback(\.browserLinkPrompt.delegate.dismissed) { state, id in
				guard state.browserLinkPrompt?.id == id else { return .none }
				state.browserLinkPrompt = nil
				return .none
			}
		}
		.ifLet(\.browserLinkPrompt, action: \.browserLinkPrompt) { BrowserLinkPrompt() }
	}

	/// Where `link` goes now. Whether its browser is installed is looked up as it opens.
	private func open(
		_ link: BrowserSchemeLink,
		from origin: BrowserLinkPrompt.Origin,
		request: BrowserExternalLink?,
		state: inout State
	) -> Effect<Action> {
		let client = browserLinks
		let browser = MainActor.assumeIsolated { client.application(link.browser.identifiers) }

		switch link.decision(browserIsInstalled: { browser != nil }) {
		case let .openInArx(place):
			return openInArx(place, from: origin, state: &state)

		case .openInBrowser:
			return openInBrowser(link, from: origin)

		case .appLinks:
			guard let request, let browser else { return .none }
			return offerToAppLinks(request, chrome: browser, state: &state)

		case .cannotOpen:
			return present(.init(id: uuid(), origin: origin, link: link), state: &state)

		case .refuse:
			return .none
		}
	}

	/// A page's `chrome://` link while Chrome is installed: App Links' built-in handler for
	/// Chrome's pages takes it, saved with the person's handlers the first time, so its prompt,
	/// Always allow and Settings › Links › App Links work as for any app's link.
	private func offerToAppLinks(
		_ request: BrowserExternalLink,
		chrome: URL,
		state: inout State
	) -> Effect<Action> {
		let application = AppLinkApplication(
			path: chrome.path(percentEncoded: false),
			bundleID: Bundle(url: chrome)?.bundleIdentifier,
			name: FileManager.default.displayName(atPath: chrome.path(percentEncoded: false))
				.replacingOccurrences(of: ".app", with: "")
		)
		state.settings.$routingPreferences.withLock { preferences in
			preferences.appLinks = preferences.appLinks.including(.chromePages(application: application))
		}

		// The built-in handler takes the link: no other app is asked about.
		guard let presentation = state.appLinkPresentation(for: request, hasSystemApp: false) else { return .none }
		return .send(.presentAppLink(presentation))
	}

	/// One notice at a time: a link that comes while one shows is dropped, as App Links does,
	/// unless the one showing lost its window. A notice whose window went meanwhile, such as
	/// after a browser that didn't take the link, goes on the main window, so it never waits
	/// where nobody can see or answer it.
	private func present(
		_ prompt: BrowserLinkPrompt.State,
		state: inout State
	) -> Effect<Action> {
		// A notice whose window went can't be seen or answered: it gives way.
		if let current = state.browserLinkPrompt {
			guard !state.isOpenBrowserLinkWindow(current.windowID) else { return .none }
			state.browserLinkPrompt = nil
		}

		var prompt = prompt
		if !state.isOpenBrowserLinkWindow(prompt.windowID) {
			var origin = prompt.origin
			origin.windowID = state.main.id
			prompt = .init(id: prompt.id, origin: origin, link: prompt.link)
		}
		if prompt.windowID == state.main.id, !state.windowIsOpen {
			guard state.openMainWindow() else { return .none }
			state.focusedWindowID = state.main.id
		}
		state.browserLinkPrompt = prompt
		return .none
	}

	/// Arx's place, for the profile the link came from. Downloads, History and Extensions run
	/// directly rather than through a window's commands, which a Little Arx, a Peek or a floating
	/// page can't run, and which would take the profile of whatever window ran them.
	private func openInArx(
		_ place: SettingsAddress,
		from origin: BrowserLinkPrompt.Origin,
		state: inout State
	) -> Effect<Action> {
		guard case let .command(command) = place else {
			return SiteMenuRouting.open(place, profileID: origin.profileID, target: state.commandTarget(in: origin.windowID))
		}

		switch command {
		case .extensions:
			// A private window's link has no profile's extensions to show: Settings at Profiles.
			guard let profileID = origin.profileID else {
				return SiteMenuRouting.open(.profile(.page), profileID: nil, target: .application)
			}
			return .send(.ui(.openExtensions(profileID)))

		case .downloads, .showHistory:
			guard let windowID = state.browserLinkWindow(origin.windowID) else { return .none }

			// Downloads and History show the profile of the window they open in. When that's not
			// the link's, its own profile's page in Settings holds both.
			guard state.browserLinkProfileID(windowID) == origin.profileID else {
				return SiteMenuRouting.open(.profile(.page), profileID: origin.profileID, target: .application)
			}
			if command == .downloads { return .send(.ui(.openDownloads(windowID))) }

			// The window comes forward with its History, from behind a Little Arx or the Dock.
			state.focusedWindowID = windowID
			state.mediaSourceFocusRequest += 1
			let open: MainFeature.Action = .ui(.openLibrary(.history))
			return windowID == state.main.id
			? .send(.main(open))
			: .send(.windows(.element(id: windowID, action: open)))

		default:
			guard let windowID = state.browserLinkWindow(origin.windowID) else { return .none }
			return SiteMenuRouting.open(
				place,
				profileID: origin.profileID,
				target: .window(windowID, paneID: state.commandPaneID(in: windowID))
			)
		}
	}

	private func openInBrowser(
		_ link: BrowserSchemeLink,
		from origin: BrowserLinkPrompt.Origin
	) -> Effect<Action> {
		.run { [browserLinks] send in
			let application = await browserLinks.application(link.browser.identifiers)
			let opened = if let application { await browserLinks.open(link.url, application) } else { false }
			guard !opened else { return }

			await send(.browserLinks(.browserDidNotOpen(link, origin)))
		}
	}

}

extension AppFeature.State {
	/// The profile a window shows, Little Arx's included; nil for a private window.
	internal func browserLinkProfileID(_ id: UUID) -> Profile.ID? {
		// The main window keeps its space while it's closed; a link from another app reopens it.
		if id == main.id { return main.isPrivate ? nil : main.sidebar.space.profileID }
		return windowProfileID(id) ?? littleWindows[id: id]?.tab.profileID
	}

	/// The browser window a link from `windowID` opens a library or panel in: that window when
	/// it's another browser window, else the main window, opened if it was closed. Nil while
	/// launch onboarding holds the main window back.
	internal mutating func browserLinkWindow(_ windowID: UUID) -> UUID? {
		if windowID != main.id, windows[id: windowID] != nil { return windowID }
		guard windowIsOpen || openMainWindow() else { return nil }
		return main.id
	}

	/// Whether a browser-link prompt can show on this window now: the main window (opened if
	/// needed), another window, or a Little Arx that isn't closing.
	internal func isOpenBrowserLinkWindow(_ id: UUID) -> Bool {
		if id == main.id { return true }
		if windows[id: id] != nil { return true }
		guard let little = littleWindows[id: id] else { return false }
		return !little.isClosing
	}
}

extension BrowserSchemeLink.Browser {
	/// The browser's bundle identifiers, for finding it on this Mac.
	internal var identifiers: [String] {
		switch self {
		case .chrome: BrowserLinkClient.chromeIdentifiers
		case .arc: BrowserLinkClient.arcIdentifiers
		}
	}
}
