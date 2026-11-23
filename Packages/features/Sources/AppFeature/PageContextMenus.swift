import AppUI
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// An item of a page's context menu the app carries out (DEV-814): the engine runs the
/// others (Cut, Copy, Look Up, Loop, Save Image As…) itself.
public enum PageContextAction: Equatable, Sendable {
	/// Search for the selection with the profile's search engine, in a new tab.
	case search(String)

	/// Share… the selection.
	case shareText(String)

	/// Open Image, Video or Audio in New Tab.
	case openInNewTab(URL)

	/// Picture in Picture: the tab's video in ArxPiP, or back from it, as Media's row does.
	case pictureInPicture

	public enum Kind: CaseIterable, Equatable, Hashable, Sendable {
		case search
		case shareText
		case openInNewTab
		case pictureInPicture
	}

	public var kind: Kind {
		switch self {
		case .search: .search
		case .shareText: .shareText
		case .openInNewTab: .openInNewTab
		case .pictureInPicture: .pictureInPicture
		}
	}
}

/// Context menu choices, Share… for a page, and the link menu's background tab, window and
/// download items (DEV-814, DEV-815, DEV-818, DEV-952). Save Image, Video or Audio As run in the engine.
@Reducer
internal struct PageContextMenus {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserDownloads)
	private var downloads

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.linkSharing)
	private var sharing

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.pageContextMenu) { state, value in
			let (tabID, action) = value
			guard
				let host = state.pageContextHost(showing: tabID),
				host.actions.contains(action.kind)
			else { return .none }

			switch action {
			case let .search(text):
				let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !query.isEmpty, let url = host.searchEngine.url(for: query) else { return .none }
				return state.openInNewTab(url, host: host)

			case let .openInNewTab(url):
				return state.openInNewTab(url, host: host)

			case .pictureInPicture:
				guard let source = state.pictureInPictureSource(for: tabID) else { return .none }
				let action: BrowserMediaSource.Action = source.isInPictureInPicture
				? .exitPictureInPicture
				: .enterPictureInPicture
				return .send(.media(.ui(.perform(source.id, action))))

			case let .shareText(text):
				let windowID = host.windowID
				return .run { [sharing] send in
					if case let .failed(message) = await sharing.shareContent(.text(text), windowID) {
						await send(.delegate(.commandFailed(message)))
					}
				}
			}
		}

		Pullback(\.sharePage) { state, value in
			let (item, windowID) = value
			guard item.url.hasWebScheme else { return .none }

			let result = LinkTransformer.copy([item], mode: .original, rules: state.settings.proxyLinkRules)
			state.linkActionGeneration += 1
			let generation = state.linkActionGeneration
			let paneID = state.linkFeedbackPaneID(in: windowID)
			return .run { [sharing] send in
				let outcome = await sharing.shareContent(.page(item.url, title: item.title), windowID)
				await send(.event(.linkActionFinished(generation, .init(
					windowID: windowID,
					paneID: paneID,
					result: result,
					status: .share(outcome)
				))))
			}
		}

		Pullback(\.openInNewWindow) { state, value in
			let (url, spaceID) = value
			guard
				url.hasWebScheme,
				state.workspace.spaces[id: spaceID] != nil
			else { return .none }

			// Launch onboarding comes first; a browser window opens when it ends (DEV-838).
			guard !state.mainWindowWaitsForOnboarding else {
				state.bringOnboardingForward()
				return .none
			}

			let id = uuid()
			state.appendBrowserWindow(id, spaceID: spaceID)
			return .send(.windows(.element(id: id, action: .ui(.openInNewTab(url)))))
		}

		Pullback(\.openLinkInBackgroundTab) { state, value in
			let (url, openerID, windowID) = value
			guard
				url.hasWebScheme,
				let host = state.window(windowID),
				!host.isPrivate,
				let opener = state.workspace.tabs[id: openerID],
				// The opener's own space, which a page floating in Page PiP keeps whatever its
				// window shows (DEV-1105). A Favorite has none: the window's while it shows the
				// Favorite's profile, else that profile's first space.
				let spaceIndex = state.workspace.spaces.firstIndex(where: {
					$0.id == state.workspace.spaceID(of: openerID) && $0.profileID == opener.profileID
				})
				?? state.workspace.spaces.firstIndex(where: {
					$0.id == host.sidebar.spaceID && $0.profileID == opener.profileID
				})
				?? state.workspace.spaces.firstIndex(where: { $0.profileID == opener.profileID })
			else { return .none }

			let tab = BrowserCore.Tab(
				id: .init(rawValue: uuid()),
				profileID: opener.profileID,
				restoration: .init(title: url.host() ?? url.absoluteString, url: url)
			)
			var organization = state.workspace
			organization.tabs.append(tab)
			AppFeature.State.placeLinkTab(
				tab.id,
				opener: opener.id,
				in: &organization,
				spaceIndex: spaceIndex
			)
			do {
				try organization.validate()
			} catch {
				return .none
			}

			state.publishAdditiveOrganization(organization, openedIn: windowID)
			return .merge(
				.send(.delegate(.save(state.workspace))),
				// It loads behind the page, as a ⌘-clicked link does. A page that can't load now
				// loads when its tab is shown.
				.run { [engine] _ in
					await withErrorReporting { try await engine.open(tab) }
				}
			)
		}

		// DEV-851: started here, while the link's menu is still current (it ends right after the
		// choice), from the link's own frame with its page's referrer, as Chrome's Save Link As.
		// An engine that can't starts a plain download, as before.
		Pullback(\.downloadLink) { state, context in
			guard
				context.item.url.hasWebScheme,
				state.workspace.profiles[id: context.profileID] != nil,
				state.downloadsReady
			else { return .none }

			let request = MainActor.assumeIsolated { [engine] in engine.startLinkContextDownload(context) }
			guard let request else { return .send(.downloadURL(context.item.url, context.profileID)) }

			return .run { [engine] send in
				do {
					_ = try await engine.linkContextDownload(context, request)
				} catch {
					await send(.delegate(.commandFailed(String.localized(.appUI.contextMenu.downloadFailed))))
				}
			}
		}

		Pullback(\.downloadURL) { state, value in
			let (url, profileID) = value
			guard
				url.hasWebScheme,
				state.workspace.profiles[id: profileID] != nil,
				state.downloadsReady
			else { return .none }

			return .run { [downloads] send in
				do {
					_ = try await downloads.start(profileID, url)
				} catch {
					await send(.delegate(.commandFailed(String.localized(.appUI.contextMenu.downloadFailed))))
				}
			}
		}
	}
}

/// Where a context menu's app items land for a tab, resolved when the menu opens and again
/// when an item is chosen.
internal struct PageContextHost: Equatable {
	/// The browser window the items show in: a pane's window, or the one under a Peek.
	internal var windowID: UUID

	/// The window opens new tabs: a pane in a main or private window, not Peek or Little Arx.
	internal var opensTabs: Bool
	internal var profileID: Profile.ID
	internal var isPrivate: Bool
	internal var searchEngine: SearchEngine
	internal var actions: Set<PageContextAction.Kind>

	/// A page floating in Page PiP that no window shows (DEV-1123): `windowID` is the window it
	/// floats from, and its new tabs open next to it, in its own space, as its links do.
	internal var floatingTabID: BrowserCore.Tab.ID?

	internal init(
		windowID: UUID,
		opensTabs: Bool,
		profileID: Profile.ID,
		isPrivate: Bool,
		searchEngine: SearchEngine,
		actions: Set<PageContextAction.Kind>,
		floatingTabID: BrowserCore.Tab.ID? = nil
	) {
		self.windowID = windowID
		self.opensTabs = opensTabs
		self.profileID = profileID
		self.isPrivate = isPrivate
		self.searchEngine = searchEngine
		self.actions = actions
		self.floatingTabID = floatingTabID
	}
}

extension AppFeature.State {
	/// The host showing `tabID` and the context menu items it can carry out now.
	internal func pageContextHost(showing tabID: BrowserCore.Tab.ID) -> PageContextHost? {
		guard !shouldQuit, !checkingQuit else { return nil }

		let windowID: UUID
		let opensTabs: Bool
		let profileID: Profile.ID
		let isPrivate: Bool
		var floatingTabID: BrowserCore.Tab.ID?
		let targets = commandTargets(showing: tabID)
		switch targets.count == 1 ? targets.first : nil {
		case nil:
			// A page floating in Page PiP that nothing else shows acts from the window it floats
			// from, never on that window's own pane (DEV-1123).
			guard
				targets.isEmpty,
				let floating = pagePictureInPicture,
				floating.tabID == tabID,
				floating.isFloating,
				hasLinkActionHost(floating.windowID),
				let window = window(floating.windowID),
				!window.transferInProgress,
				!window.pendingTabCloses.contains(tabID),
				let tab = pagePictureInPictureBackgroundTab(tabID, in: floating.windowID)
			else { return nil }
			windowID = floating.windowID
			opensTabs = true
			profileID = tab.profileID
			isPrivate = window.isPrivate
			floatingTabID = tabID

		case let .peek(id)?:
			guard
				let peek = peeks[id: id],
				hasLinkActionHost(peek.source.windowID)
			else { return nil }
			windowID = peek.source.windowID
			opensTabs = false
			profileID = peek.tab.profileID
			isPrivate = false

		case let .window(id, paneID)?:
			if let little = littleWindows[id: id] {
				guard paneID == nil || paneID == little.id else { return nil }
				windowID = id
				opensTabs = false
				profileID = little.tab.profileID
				isPrivate = false
			} else {
				guard
					let window = window(id),
					hasLinkActionHost(id),
					paneID != nil
				else { return nil }

				windowID = id
				opensTabs = true
				profileID = window.sidebar.space.profileID
				isPrivate = window.isPrivate
			}

		default:
			return nil
		}

		let profiles = isPrivate
		? window(windowID)?.sidebar.organization.profiles
		: workspace.profiles

		var actions: Set<PageContextAction.Kind> = [.shareText]
		if opensTabs { actions.formUnion([.search, .openInNewTab]) }
		if pictureInPictureSource(for: tabID) != nil { actions.insert(.pictureInPicture) }

		return PageContextHost(
			windowID: windowID,
			opensTabs: opensTabs,
			profileID: profileID,
			isPrivate: isPrivate,
			searchEngine: profiles?[id: profileID]?.searchEngine ?? .google,
			actions: actions,
			floatingTabID: floatingTabID
		)
	}

	/// The tab's video as Media lists it, when ArxPiP can take it or give it back now.
	internal func pictureInPictureSource(for tabID: BrowserCore.Tab.ID) -> BrowserMediaSource? {
		media.visibleSources.first {
			$0.id.tabID == tabID
			&& ($0.supports(.enterPictureInPicture) || $0.supports(.exitPictureInPicture))
		}
	}

	/// A new tab for `url` from a context menu's host: next to a floating page in its own space
	/// (DEV-1123), or in the window's active pane.
	fileprivate func openInNewTab(
		_ url: URL,
		host: PageContextHost
	) -> Effect<AppFeature.Action> {
		guard url.hasWebScheme else { return .none }

		// A private window has one organization, so its new tab is the floating page's too.
		if let floating = host.floatingTabID, !host.isPrivate {
			return .send(.openLinkInBackgroundTab(url, opener: floating, windowID: host.windowID))
		}
		return openInNewTab(url, windowID: host.windowID)
	}

	/// A new tab for `url` in a window's active pane.
	fileprivate func openInNewTab(
		_ url: URL,
		windowID: UUID
	) -> Effect<AppFeature.Action> {
		guard url.hasWebScheme else { return .none }
		return windowID == main.id
		? .send(.main(.ui(.openInNewTab(url))))
		: .send(.windows(.element(id: windowID, action: .ui(.openInNewTab(url)))))
	}
}

extension BrowserOrganization {
	/// The space a tab is pinned or open in; `nil` for a Favorite, which belongs to none.
	fileprivate func spaceID(of tabID: BrowserCore.Tab.ID) -> Space.ID? {
		switch location(of: tabID) {
		case let .pinned(spaceID, _), let .unpinned(spaceID): spaceID
		case .favorite, nil: nil
		}
	}
}
