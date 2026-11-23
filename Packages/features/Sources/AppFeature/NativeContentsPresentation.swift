import BrowserCore
import BrowserEngineClient
import Foundation
import LittleArxFeature
import MainFeature
import PeekFeature
import SidebarFeature
import _ComposableArchitecture

/// Publishes only an already-adopted native session. No path recreates its URL.
@Reducer
internal struct NativeContentsPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		// An extension's options open in Little Arx on a space of its profile (DEV-1185), from the
		// site menu, Settings › Extensions or `chrome.runtime.openOptionsPage()`, and so do the
		// options Chrome embeds in its own extensions page. The page is in no space's tabs.
		Pullback(\.event.extensionViewCreated) { state, offer in
			guard
				!state.shouldQuit,
				!state.checkingQuit,
				offer.tab.profileID == offer.profileID,
				offer.tab.reopeningURL.scheme == "chrome-extension",
				offer.tab.reopeningURL.host == offer.extensionID,
				state.workspace.profiles.ids.contains(offer.profileID),
				let spaceID = state.extensionOptionsSpace(offer.profileID),
				!state.containsTab(offer.tab.id),
				MainActor.assumeIsolated({ engine.snapshot(offer.tab.id) }) != nil
			else { return .none }

			let id = uuid()
			state.littleWindows.append(.init(
				id: id,
				spaceID: spaceID,
				tab: offer.tab,
				bangs: state.settings.bangs,
				captureAvailable: state.captureAvailable,
				downloadsAvailable: state.downloadsReady,
				mediaAvailable: state.media.isAvailable
			))
			state.initialExtensionOptions[offer.tab.id] = .init(
				offer: offer,
				windowID: id,
				previousFocus: state.focusedWindowID
			)
			state.focusedWindowID = id
			return .none
		}

		Pullback(\.event.extensionOptionsSettled) { state, offer in
			guard state.initialExtensionOptions[offer.tab.id]?.offer == offer
			else { return .none }

			state.initialExtensionOptions[offer.tab.id] = nil
			return .none
		}

		// The engine revokes an options page while it's being handed over, before anything else
		// runs: only the Little Arx made for it closes, and the engine has the page already.
		Pullback(\.event.extensionOptionsRevoked) { state, offer in
			guard
				let initial = state.initialExtensionOptions[offer.tab.id],
				initial.offer == offer
			else { return .none }

			state.initialExtensionOptions[offer.tab.id] = nil
			guard
				let little = state.littleWindows[id: initial.windowID],
				little.tab.id == offer.tab.id,
				little.tab.profileID == offer.profileID,
				little.tab.reopeningURL.scheme == "chrome-extension",
				little.tab.reopeningURL.host == offer.extensionID
			else { return .none }

			state.littleWindows.remove(id: little.id)
			state.littleWindowsOnOtherDesktopSpaces.remove(little.id)
			if state.focusedWindowID == little.id { state.focusedWindowID = initial.previousFocus }
			return .none
		}

		Pullback(\.event.browserNewContents) { state, value in
			let (offer, shiftHeld, modified, origin) = value
			if offer.isPrivate { return presentPrivate(offer, in: &state) }

			guard
				let source = MainActor.assumeIsolated({ engine.snapshot(offer.sourceTabID) }),
				source.revision == offer.sourceSessionRevision,
				source.documentRevision == offer.sourceDocumentRevision,
				MainActor.assumeIsolated({ engine.snapshot(offer.tab.id) }) != nil,
				let placement = state.nativeContentPlacement(
					tabID: offer.sourceTabID,
					profileID: offer.tab.profileID,
					isPrivate: false
				),
				let spaceID = state.nativeContentsSpace(placement),
				let spaceIndex = state.workspace.spaces.firstIndex(where: {
					$0.id == spaceID && $0.profileID == offer.tab.profileID
				}),
				!state.workspace.tabs.ids.contains(offer.tab.id)
			else { return .none }

			// Little Arx keeps its links (DEV-855): a new tab or popup from its page opens in
			// a new Little Arx, never in the main window. Peek over it keeps its own routing.
			if placement.peekID == nil, let source = state.littleWindows[id: placement.windowID] {
				return presentInLittleArx(offer, spaceID: source.spaceID, opener: source.id, in: &state)
			}

			// A page's popup (`window.open` with window features, as sign-ins open) goes into a new
			// Little Arx from anywhere (DEV-1186): a window, a floating page or Peek. It's never a
			// new main window, and it keeps its opener so the sign-in can finish and close itself.
			if offer.disposition == .popup {
				return presentInLittleArx(offer, spaceID: spaceID, opener: placement.windowID, in: &state)
			}

			let isWindowSource = placement.peekID == nil
				&& state.littleWindows[id: placement.windowID] == nil

			// A Favorite's or pinned tab's page asking for a tab of its own (`target="_blank"`,
			// `window.open` without window features, a form aimed at a new tab) goes where
			// Settings send that tab's links to other sites (DEV-1312), as Gmail's account switch
			// does from a mail Favorite. The engine's page moves there as it is, opener and all.
			// A ⌘-click, a middle click or any other click with a modifier is the person's own
			// choice of a tab, and New Tab or Current Tab keep the tab Chromium asked for.
			if isWindowSource, offer.disposition == .foregroundTab, !modified {
				switch state.crossSiteLinkRoute(from: offer.sourceTabID) {
				case .peek?:
					// A floating page has no pane for a Peek to cover (DEV-1105); where Peek
					// can't open, the tab opens as it would without the setting. A window with a
					// Peek open has no placement, so no Peek here has to close first.
					if
						placement.floatingTabID == nil,
						let source = state.peekSource(windowID: placement.windowID, paneID: placement.paneID),
						source.profileID == offer.tab.profileID,
						PeekFeature.previewURL(offer.tab.restoration.url.absoluteString) != nil
					{
						return .send(.peekNewContents(offer.tab, source, origin: origin))
					}

				case .littleArx?:
					return presentInLittleArx(offer, spaceID: spaceID, opener: placement.windowID, in: &state)

				case .newTab?, .newWindow?, .privateWindow?, .mainWindow?, nil:
					break
				}
			}

			// A floating page's window shows its tabs only while it shows the page's space
			// (DEV-1105); otherwise a foreground one gets a window of its own, as Peek's.
			let hasOrdinarySourcePane = isWindowSource
				&& (placement.floatingTabID == nil || state.window(placement.windowID)?.sidebar.spaceID == spaceID)

			// Settings decide whether a window's link tabs come forward (DEV-952), a floating page's
			// too; Peek keeps Chromium's choice.
			let disposition = isWindowSource
			? state.linkTabDisposition(offer.disposition, shiftHeld: shiftHeld)
			: offer.disposition

			var organization = state.workspace
			organization.tabs.append(offer.tab)
			AppFeature.State.placeLinkTab(
				offer.tab.id,
				opener: offer.sourceTabID,
				in: &organization,
				spaceIndex: spaceIndex
			)
			do {
				try organization.validate()
			} catch {
				return .none
			}

			state.publishAdditiveOrganization(organization, openedIn: placement.windowID)
			let save: Effect<Action> = .send(.delegate(.save(state.workspace)))

			if disposition == .backgroundTab { return save }

			if disposition == .foregroundTab && hasOrdinarySourcePane {
				state.focusedWindowID = placement.windowID
				let present: Action

				if placement.windowID == state.main.id {
					present = .main(.present(offer.tab.id, in: placement.paneID))
				} else {
					present = .windows(.element(
						id: placement.windowID,
						action: .present(offer.tab.id, in: placement.paneID)
					))
				}

				return .merge(save, .send(present))
			}

			// A window request (Shift-click) or a foreground child of Peek owns a normal window.
			// Keep its live opener and any before-unload state in the source host.
			var presentation = organization
			for index in presentation.spaces.indices {
				presentation.spaces[index].selectedTabID = index == spaceIndex ? offer.tab.id : nil
			}
			let windowID = uuid()
			var window = MainFeature.State(
				organization: presentation,
				spaceID: spaceID,
				id: windowID
			)
			window.captureAvailable = state.captureAvailable
			window.downloadsAvailable = state.downloadsReady
			window.mediaAvailable = state.media.isAvailable
			window.commandBar.bangs = state.settings.bangs
			window.sidebarWidth = state.newWindowSidebarWidth
			state.windows.append(window)

			// The popup's window keeps it, not the opener's (DEV-822).
			state.giveOpenTabs([offer.tab.id], to: windowID)
			state.focusedWindowID = windowID

			// A new window's viewer stays empty until its tab is presented.
			return .merge(
				save,
				.send(.windows(.element(id: windowID, action: .present(offer.tab.id, in: window.viewer.activePaneID))))
			)
		}
	}

	/// The adopted page goes into a new Little Arx on its source's space, in no space's
	/// tabs, as a page torn off a window does. Its native opener link is untouched, so
	/// `window.opener` and `postMessage` still reach the source page. `opener` is the window
	/// showing the source page, which takes the keyboard back when the new one closes.
	private func presentInLittleArx(
		_ offer: BrowserNewContents,
		spaceID: Space.ID,
		opener: UUID,
		in state: inout State
	) -> Effect<Action> {
		guard
			!offer.isPrivate,
			state.workspace.spaces[id: spaceID]?.profileID == offer.tab.profileID,
			!state.allTabIDs.contains(offer.tab.id)
		else { return .none }

		let id = uuid()
		var little = LittleArxFeature.State(
			id: id,
			spaceID: spaceID,
			tab: offer.tab,
			bangs: state.settings.bangs,
			captureAvailable: state.captureAvailable,
			downloadsAvailable: state.downloadsReady,
			mediaAvailable: state.media.isAvailable
		)
		little.openerWindowID = opener
		state.littleWindows.append(little)

		// A background tab (⌘-click) opens behind: the source keeps the keyboard.
		if offer.disposition != .backgroundTab { state.focusedWindowID = id }
		return .none
	}

	private func presentPrivate(
		_ offer: BrowserNewContents,
		in state: inout State
	) -> Effect<Action> {
		guard
			let source = MainActor.assumeIsolated({ engine.snapshot(offer.sourceTabID) }),
			source.revision == offer.sourceSessionRevision,
			source.documentRevision == offer.sourceDocumentRevision,
			MainActor.assumeIsolated({ engine.snapshot(offer.tab.id) }) != nil,
			let placement = state.nativeContentPlacement(
				tabID: offer.sourceTabID,
				profileID: offer.tab.profileID,
				isPrivate: true
			),
			var host = state.windows[id: placement.windowID],
			host.isPrivate,
			let profile = host.sidebar.organization.profiles[id: offer.tab.profileID],
			!state.allTabIDs.contains(offer.tab.id)
		else { return .none }

		if offer.disposition == .foregroundTab || offer.disposition == .backgroundTab {
			var organization = host.sidebar.organization
			guard let index = organization.spaces.index(id: host.sidebar.spaceID)
			else { return .none }

			organization.tabs.append(offer.tab)
			AppFeature.State.placeLinkTab(
				offer.tab.id,
				opener: offer.sourceTabID,
				in: &organization,
				spaceIndex: index
			)
			do {
				try organization.validate()
			} catch {
				return .none
			}

			host.sidebar.organization = organization
			host.knownTabIDs.insert(offer.tab.id)
			state.windows[id: host.id] = host
			guard offer.disposition == .foregroundTab else { return .none }

			state.focusedWindowID = host.id
			return .send(.windows(.element(
				id: host.id,
				action: .present(offer.tab.id, in: placement.paneID)
			)))
		}

		let spaceID = Space.ID(rawValue: uuid())
		let organization = BrowserOrganization(
			profiles: [profile],
			spaces: [.init(
				id: spaceID,
				profileID: profile.id,
				name: host.sidebar.space.name,
				unpinnedTabs: [offer.tab.id],
				selectedTabID: offer.tab.id
			)],
			tabs: [offer.tab]
		)
		var childHost = MainFeature.State(
			organization: organization,
			spaceID: spaceID,
			isPrivate: true,
			id: uuid()
		)

		// DEV-956: the same private context, so the same opener's extensions.
		childHost.privateOpenerProfileID = host.privateOpenerProfileID
		childHost.captureAvailable = state.captureAvailable
		childHost.downloadsAvailable = state.downloadsReady
		childHost.commandBar.bangs = state.settings.bangs
		childHost.sidebarWidth = state.newWindowSidebarWidth
		state.windows.append(childHost)
		state.focusedWindowID = childHost.id
		return .send(.windows(.element(id: childHost.id, action: .present(offer.tab.id, in: childHost.viewer.activePaneID))))
	}

}

extension AppFeature.State {
	/// The space an extension's options open on (DEV-1185): the focused window's while it's in the
	/// extension's profile, else that profile's first space.
	internal func extensionOptionsSpace(_ profileID: Profile.ID) -> Space.ID? {
		let focused = focusedWindowID.flatMap { id in
			littleWindows[id: id]?.spaceID ?? window(id)?.sidebar.spaceID
		}
		if let focused, workspace.spaces[id: focused]?.profileID == profileID { return focused }
		return workspace.spaces.first { $0.profileID == profileID }?.id
	}
}

extension AppFeature.State {
	internal func nativeContentsSpace(_ placement: LinkContextPlacement) -> Space.ID? {
		if let peekID = placement.peekID { return peeks[id: peekID]?.source.spaceID }
		if let tabID = placement.floatingTabID { return floatingPageSpace(tabID, windowID: placement.windowID) }
		if let little = littleWindows[id: placement.windowID] { return little.spaceID }
		if placement.windowID == main.id { return main.sidebar.spaceID }
		return windows[id: placement.windowID]?.sidebar.spaceID
	}
}

internal struct InitialExtensionOptions: Equatable {
	internal let offer: BrowserExtensionViewOffer
	internal let windowID: UUID
	internal let previousFocus: UUID?

	internal init(
		offer: BrowserExtensionViewOffer,
		windowID: UUID,
		previousFocus: UUID?
	) {
		self.offer = offer
		self.windowID = windowID
		self.previousFocus = previousFocus
	}
}

extension AppFeature.State {
	/// The space a page floating in Page PiP belongs to (DEV-1105): its own, or for a Favorite
	/// the window's while it shows the Favorite's profile, else that profile's first space.
	fileprivate func floatingPageSpace(
		_ tabID: BrowserCore.Tab.ID,
		windowID: UUID
	) -> Space.ID? {
		let host = window(windowID)
		switch host?.sidebar.organization.location(of: tabID) {
		case let .pinned(spaceID, _), let .unpinned(spaceID):
			return spaceID

		case let .favorite(profileID):
			return floatingSpace(of: profileID, windowID: windowID)

		case nil:
			return nil
		}
	}

	/// A space of `profileID` for a Favorite floating in Page PiP from `windowID` (DEV-1105): the
	/// window's while it shows that profile, else the profile's first. Its links open there, and
	/// its visits are recorded there (DEV-1154), never in another profile's space.
	internal func floatingSpace(
		of profileID: Profile.ID,
		windowID: UUID
	) -> Space.ID? {
		let host = window(windowID)
		if let host, host.sidebar.space.profileID == profileID { return host.sidebar.spaceID }
		return (host?.sidebar.organization ?? workspace).spaces.first { $0.profileID == profileID }?.id
	}
}

extension AppFeature.State {
	/// Where a tab a link opened goes in its space (DEV-1243, DEV-1325): directly below the tab
	/// that opened it, or first among the space's open tabs when a bookmark opened it, in the
	/// foreground or the background alike.
	internal static func placeLinkTab(
		_ tabID: BrowserCore.Tab.ID,
		opener: BrowserCore.Tab.ID,
		in organization: inout BrowserOrganization,
		spaceIndex: Int
	) {
		// Split View and tab groups take the new tab in, or keep out of its way, before publishing.
		defer {
			organization.normalizeSplits()
			organization.normalizeTabGroups()
		}
		organization.placeOpenedTab(tabID, inSpaceAt: spaceIndex, opener: opener)
	}

	/// Whether a tab a link opens in a window comes forward (DEV-952).
	///
	/// Chromium has chosen from the click: ⌘-click and middle-click make a background tab, the
	/// same with Shift a foreground one, and a page's own new tab (`target=_blank`) a foreground
	/// one. When Settings › General › Tabs brings link tabs forward, the clicks swap; a page's
	/// own new tab keeps Chromium's choice. Shift tells ⇧⌘-click from a page's own tab: it's
	/// read when the tab arrives, so letting go of it very quickly counts as no Shift. Headless
	/// runs show nothing, so they keep Chromium's choice.
	internal func linkTabDisposition(
		_ disposition: BrowserNewContents.Disposition,
		shiftHeld: Bool
	) -> BrowserNewContents.Disposition {
		guard
			!automation.isUnattended,
			settings.general.switchesToLinkTabs
		else { return disposition }

		switch disposition {
		case .backgroundTab: return .foregroundTab
		case .foregroundTab: return shiftHeld ? .backgroundTab : .foregroundTab
		case .window, .popup: return disposition
		}
	}
}
