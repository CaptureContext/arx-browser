import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// A click on a site's notification in Notification Center finds its tab (DEV-885).
///
/// The site answers first: its page's `window.focus()` or its service worker's
/// `client.focus()` shows that tab, and `clients.openWindow()` opens a new tab in the
/// notification's profile. When the site doesn't answer, Arx shows the newest tab of the
/// site in that profile, or opens the site's origin there when it has none (a closed tab).
/// An unloaded tab loads again as it's shown.
@Reducer
internal struct WebNotifications {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.event.pageActivationRequested) { state, tabID in
			guard state.acceptsNotificationActivation else { return .none }

			// A Little Arx or a Peek showing the tab comes forward as it is.
			if let little = state.littleWindows.first(where: { $0.tab.id == tabID && !$0.isClosing }) {
				state.focusedWindowID = little.id
				state.mediaSourceFocusRequest += 1
				return .none
			}
			if let peek = state.peeks.first(where: { $0.tab.id == tabID }) {
				state.focusedWindowID = peek.source.windowID
				state.mediaSourceFocusRequest += 1
				return .none
			}
			guard
				let tab = state.workspace.tabs[id: tabID],
				OrdinaryTabPresentation().canFocus(tab, state: state)
			else { return .none }

			return state.showNotificationTab(tab)
		}

		Pullback(\.event.notificationWindowOpened) { state, tab in
			guard
				state.acceptsNotificationActivation,
				state.workspace.profiles.ids.contains(tab.profileID),
				!state.allTabIDs.contains(tab.id),
				MainActor.assumeIsolated({ engine.snapshot(tab.id) }) != nil,
				let spaceID = state.notificationSpaceID(for: tab.profileID),
				let spaceIndex = state.workspace.spaces.firstIndex(where: { $0.id == spaceID })
			else { return .none }

			var organization = state.workspace
			organization.tabs.append(tab)
			organization.spaces[spaceIndex].unpinnedTabs.append(tab.id)
			do {
				try organization.validate()
			} catch {
				return .none
			}

			state.publishAdditiveOrganization(organization)
			return .merge(
				.send(.delegate(.save(state.workspace))),
				state.showNotificationTab(tab)
			)
		}

		Pullback(\.event.notificationClicked) { state, click in
			guard
				!click.isHandled,
				state.acceptsNotificationActivation,
				state.workspace.profiles.ids.contains(click.profileID)
			else { return .none }

			let urls: (BrowserCore.Tab) -> URL? = { tab in
				MainActor.assumeIsolated { engine.snapshot(tab.id)?.navigation.url }
			}
			if
				let tab = state.notificationTab(for: click, currentURL: urls),
				OrdinaryTabPresentation().canFocus(tab, state: state)
			{
				return state.showNotificationTab(tab)
			}

			// The site's tab was closed: open its origin in the notification's profile. With
			// Settings' choice off, only when Chrome would: a page's own notification that outlived
			// it. A service worker that answered nothing gets nothing, as in Chrome.
			guard state.settings.general.notificationsOpenClosedSites || click.pageIsGone
			else { return .none }

			state.mediaSourceFocusRequest += 1
			return .send(.ui(.routeURLs(
				[click.origin],
				override: .init(scope: .profile(click.profileID), mode: .mainBrowser)
			)))
		}
	}
}

extension AppFeature.State {
	fileprivate var acceptsNotificationActivation: Bool {
		!shouldQuit && !checkingQuit && !profileRetirement.isBusy
	}

	/// Shows the tab and brings Arx forward, from behind other apps or a minimized window.
	fileprivate mutating func showNotificationTab(_ tab: BrowserCore.Tab) -> Effect<AppFeature.Action> {
		// The focus request that also activates the app and restores a minimized window.
		mediaSourceFocusRequest += 1
		return OrdinaryTabPresentation().focus(tab, state: &self)
	}

	/// The space a notification's new tab goes into: the main window's space when it uses the
	/// profile, else the profile's most recent space, else its first.
	internal func notificationSpaceID(for profileID: Profile.ID) -> Space.ID? {
		let candidates = [main.sidebar.spaceID] + recentSpaceIDs + workspace.spaces.map(\.id)
		return candidates.first { workspace.spaces[id: $0]?.profileID == profileID }
	}

	/// The tab a notification click shows: one of the profile's tabs at the notification's
	/// origin, preferring the main window's selected tab, then its space, then the profile's
	/// most recent spaces. `currentURL` is a loaded tab's address; other tabs use their
	/// restoration address.
	internal func notificationTab(
		for click: BrowserNotificationClick,
		currentURL: (BrowserCore.Tab) -> URL?
	) -> BrowserCore.Tab? {
		let matches = workspace.tabs.filter { tab in
			tab.profileID == click.profileID
			&& Self.sameOrigin(currentURL(tab) ?? tab.restoration.url, click.origin)
		}
		guard !matches.isEmpty else { return nil }

		if
			let selected = main.sidebar.selectedTab?.id,
			let tab = matches.first(where: { $0.id == selected })
		{ return tab }

		let locations = workspace.tabLocations
		let spaceOrder = [main.sidebar.spaceID] + recentSpaceIDs + workspace.spaces.map(\.id)
		for spaceID in spaceOrder {
			// The newest first: tabs are appended as they open.
			let tab = matches.last { tab in
				switch locations[tab.id] {
				case .unpinned(spaceID), .pinned(spaceID, _): true
				default: false
				}
			}
			if let tab { return tab }
		}

		return matches.last
	}

	private static func sameOrigin(
		_ url: URL,
		_ origin: URL
	) -> Bool {
		guard
			let scheme = url.scheme?.lowercased(),
			let host = url.host()?.lowercased(),
			scheme == origin.scheme?.lowercased(),
			host == origin.host()?.lowercased()
		else { return false }

		return effectivePort(url) == effectivePort(origin)
	}

	private static func effectivePort(_ url: URL) -> Int? {
		url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
	}
}
