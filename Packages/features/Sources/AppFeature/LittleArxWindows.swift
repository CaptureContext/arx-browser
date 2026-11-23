import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import Foundation
import LittleArxFeature
import _ComposableArchitecture

@Reducer
internal struct LittleArxWindows {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.browserSurface)
	private var surface

	@Dependency(\.date.now)
	private var now

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.openLittleArx) { state, value in
			let (spaceID, requestedURL) = value
			let focusedSpace = state.focusedWindowID.flatMap { windowID in
				state.littleWindows[id: windowID]?.spaceID
				?? state.windows[id: windowID]?.sidebar.spaceID
			}
			let active = focusedSpace ?? state.main.sidebar.spaceID
			let destination = state.workspace.spaces.ids.contains(active)
			? active : state.main.sidebar.spaceID
			guard let space = state.workspace.spaces[id: (spaceID ?? destination)]
			else { return .none }

			let id = uuid()
			let url = requestedURL ?? URL(string: "about:blank")!
			let tab = BrowserCore.Tab(
				id: .init(rawValue: uuid()),
				profileID: space.profileID,
				restoration: .init(
					title: url.host() ?? "Little Arx",
					url: url
				)
			)
			state.littleWindows.append(.init(
				id: id,
				spaceID: space.id,
				tab: tab,
				isCommandOnly: requestedURL == nil,
				bangs: state.settings.bangs,
				captureAvailable: state.captureAvailable,
				downloadsAvailable: state.downloadsReady,
				mediaAvailable: state.media.isAvailable,
				launcherSuggestions: requestedURL == nil ? state.littleArxSuggestions(profileID: space.profileID) : [],
				launcherProfileIDs: requestedURL == nil ? state.littleArxProfileIDs : []
			))

			// The launcher searches with its profile's engine, as the main window's bar (DEV-1331).
			let searchEngine = state.workspace.profiles[id: space.profileID]?.searchEngine ?? .google
			state.littleWindows[id: id]?.commandBar.searchEngine = searchEngine
			state.focusedWindowID = id
			return .none
		}

		// The launcher's profile picker chose another profile (DEV-1331): its pages, icons and
		// search engine, and nothing of the one before.
		Pullback(\.littleWindows) { state, action in
			guard
				case let .element(id, .delegate(.launcherProfileRequested(profileID))) = action,
				let little = state.littleWindows[id: id],
				little.isCommandOnly,
				!little.isPrivate,
				let profile = state.littleArxLauncherProfile(profileID)
			else { return .none }

			return .send(.littleWindows(.element(id: id, action: .useLauncherProfile(profile))))
		}

		Pullback(\.event.desktopSpaceChanged) { state, elsewhere in
			state.littleWindowsOnOtherDesktopSpaces = elsewhere.littleWindowsElsewhere
				.intersection(state.littleWindows.ids)
			state.windowsOnOtherDesktopSpaces = elsewhere.windowsElsewhere
				.filter { $0 == state.main.id || state.windows[id: $0] != nil }
			return .none
		}

		Pullback(\.littleWindows) { state, action in
			guard
				case let .element(id, .delegate(.selectProfile(profileID))) = action,
				state.littleWindows[id: id]?.peekID == nil,
				state.workspace.profiles.ids.contains(profileID),
				let space = state.workspace.spaces.first(where: { $0.profileID == profileID })
			else { return .none }

			return .send(.littleWindows(.element(
				id: id,
				action: .changeProfile(profileID, space.id)
			)))
		}

		Pullback(\.littleWindows) { state, action in
			guard
				case let .element(id, .delegate(delegate)) = action,
				let little = state.littleWindows[id: id],
				little.peekID == nil
			else { return .none }

			switch delegate {
			case .close:
				guard little.isCommandOnly else { return .none }

			case let .closeApproved(request):
				guard little.isClosing, little.closeRequest == request else { return .none }

				// Used while its page was asked, or no longer meant to be archived: it stays (DEV-1138).
				if request.isAutomatic, !state.littleArxIsStillDue(id, now: now) {
					state.littleWindows[id: id]?.isClosing = false
					state.littleWindows[id: id]?.closeRequest = nil
					state.littleArxArchiving.remove(id)
					state.restartLittleArxClock(id, now: now)
					return .none
				}
				guard request.matches(little) else {
					state.littleWindows[id: id]?.isClosing = false
					state.littleWindows[id: id]?.closeRequest = nil
					return .none
				}

			default: return .none
			}

			let tabID = little.tab.id
			state.discardLinkFeedback(in: id)
			state.littleWindows.remove(id: id)
			state.littleWindowsOnOtherDesktopSpaces.remove(id)
			state.forgetDetachedChatSurfaces()
			if state.focusedWindowID == id {
				state.focusedWindowID = state.focusAfterClosingLittleArx(little)
			}
			let close: Effect<Action> = .run { [engine] _ in await engine.close(tabID) }

			// A closed page goes to Recently Closed and the Tab Archive (DEV-728); it
			// never reopens on its own. A launcher that never opened a page has nothing, and a
			// private Little Arx's page is never kept (DEV-1323).
			guard
				!little.isCommandOnly,
				!little.isPrivate,
				let organization = state.archivingClosedLittlePage(little, closedAt: now, uuid: { uuid() })
			else { return close }

			state.publishAdditiveOrganization(organization)

			// Every ordinary window with its archive loaded shows the new entry at once.
			let refreshes = state.windows
				.filter { !$0.isPrivate && $0.archive.profileID != nil }
				.map { Effect<Action>.send(.windows(.element(id: $0.id, action: .refreshArchive))) }
			return .merge([
				close,
				.send(.delegate(.save(organization))),
				state.main.archive.profileID == nil ? .none : .send(.main(.refreshArchive)),
			] + refreshes)
		}

		Pullback(\.openInMainWindow) { state, value in
			let (url, spaceID) = value
			guard
				url.hasWebScheme,
				state.workspace.spaces[id: spaceID] != nil
			else { return .none }

			// Launch onboarding holds the main window back until it ends (DEV-838).
			guard state.openMainWindow() else { return .none }

			// The Little Arx's space, so the link stays in its profile.
			if state.main.sidebar.spaceID != spaceID { state.main.sidebar.selectSpace(spaceID) }
			state.appActivationRequest += 1
			state.focusedWindowID = state.main.id
			return .send(.main(.ui(.openInNewTab(url))))
		}

		// A page that closes itself (a sign-in popup once it has messaged its opener) closes its
		// Little Arx (DEV-855). Blink ran the page's before-unload before asking.
		Pullback(\.event.pageCloseRequested) { state, tabID in
			guard
				let little = state.littleWindows.first(where: { $0.tab.id == tabID }),
				little.peekID == nil,
				!little.isCommandOnly
			else { return .none }

			return .send(.littleWindows(.element(id: little.id, action: .event(.pageClosed))))
		}

		// A profile change replaced the window's tab (the child already has the new one): a torn-off
		// chat tab's surface goes with the old one (DEV-793).
		Pullback(\.littleWindows) { state, action in
			guard case .element(_, .event(.profileChanged)) = action
			else { return .none }

			state.forgetDetachedChatSurfaces()
			return .none
		}

		Pullback(\.main.delegate.requestTearOff) { state, value in
			let (tabID, point) = value
			guard state.tearOffIsAllowed(tabID) else { return .none }

			return .send(.main(.tearOff(tabID, point)))
		}

		Pullback(\.windows) { state, action in
			guard
				case let .element(id, .delegate(.requestTearOff(tabID, point))) = action,
				state.tearOffIsAllowed(tabID)
			else { return .none }

			return .send(.windows(.element(id: id, action: .tearOff(tabID, point))))
		}

		Pullback(\.main.delegate.moveToLittleArx) { state, value in
			let (tab, spaceID, point) = value
			return tearOff(tab, from: spaceID, at: point, state: &state)
		}

		Pullback(\.windows) { state, action in
			guard case let .element(_, .delegate(.moveToLittleArx(tab, spaceID, point))) = action
			else { return .none }

			return tearOff(tab, from: spaceID, at: point, state: &state)
		}

		Pullback(\.event.tabTornOff) { state, value in
			let (tab, spaceID, point) = value
			state.tabsTearingOff.remove(tab.id)

			// The page stays in its space's profile: Little Arx never carries it into another.
			guard
				let space = state.workspace.spaces[id: spaceID],
				space.profileID == tab.profileID,
				!state.littleWindows.contains(where: { $0.tab.id == tab.id })
			else {
				// Nothing shows the tab now: its chat surface, media handoff and page go.
				state.forgetDetachedChatSurfaces()
				state.mediaRehostingSources.remove(tab.id)
				guard
					state.workspace.tabs[id: tab.id] == nil,
					!state.littleWindows.contains(where: { $0.tab.id == tab.id })
				else { return .none }

				return .run { [engine] _ in await engine.close(tab.id) }
			}

			let id = uuid()
			state.littleWindows.append(.init(
				id: id,
				spaceID: space.id,
				tab: tab,
				bangs: state.settings.bangs,
				captureAvailable: state.captureAvailable,
				downloadsAvailable: state.downloadsReady,
				mediaAvailable: state.media.isAvailable,
				origin: point
			))
			state.focusedWindowID = id
			return .none
		}

		Pullback(\.littleWindows) { _, action in
			guard case let .element(_, .delegate(.copyURL(url))) = action else { return .none }
			return .send(.delegate(.copyURL(url)))
		}

		// Open in Peek from the command bar's actions (DEV-810), over the window's page.
		Pullback(\.littleWindows) { state, action in
			guard
				case let .element(id, .delegate(.openInPeek(url))) = action,
				let source = state.peekSource(windowID: id, paneID: id)
			else { return .none }

			return .send(.ui(.peekURLFromSource(url, source, origin: nil)))
		}

		Pullback(\.littleWindows) { state, action in
			guard
				case let .element(id, .delegate(.promote(destination))) = action,
				let little = state.littleWindows[id: id],
				little.peekID == nil
			else { return .none }
			let requestID = state.automation.hostTransitions[id]

			// Launch onboarding holds the main window back until it ends (DEV-838).
			guard !state.mainWindowWaitsForOnboarding else {
				state.bringOnboardingForward()
				return .send(.event(.littlePromotionFailed(
					id,
					String.localized(.appUI.onboarding.finishFirst),
					automationRequestID: requestID
				)))
			}
			guard let space = state.workspace.spaces[id: destination] else {
				return .send(.event(.littlePromotionFailed(
					id,
					String.localized(.appUI.preview.invalidMove),
					automationRequestID: requestID
				)))
			}

			let source = little.tab
			let sameProfile = source.profileID == space.profileID
			let tab = sameProfile ? source : BrowserCore.Tab(
				id: .init(rawValue: uuid()),
				profileID: space.profileID,
				restoration: source.restoration
			)

			// A chat tab dropped outside every window (DEV-793) has no page: it goes back to the
			// sidebar without one.
			guard !source.isChat else {
				return .send(.event(.littlePromotionReady(id, source, tab, destination, automationRequestID: requestID)))
			}

			return .run { [engine] send in
				if !sameProfile, !(await engine.permitsClosing(source.id)) {
					await send(.event(.littlePromotionFailed(id, "", automationRequestID: requestID)))
					return
				}
				do {
					try await engine.open(tab)
					await send(.event(.littlePromotionReady(id, source, tab, destination, automationRequestID: requestID)))
				} catch {
					let message = error.localizedDescription
					await send(.event(.littlePromotionFailed(id, message, automationRequestID: requestID)))
				}
			}
		}

		Pullback(\.event.littlePromotionFailed) { state, value in
			let (id, error, requestID) = value
			guard state.automationHostCallbackIsCurrent(id, requestID: requestID)
			else { return .none }
			guard state.littleWindows[id: id] != nil else { return .none }
			state.failAutomationHostTransition(id, requestID: requestID, failure: .engineFailed)
			return .send(.littleWindows(.element(id: id, action: .event(.promotionFailed(error)))))
		}

		Pullback(\.event.littlePromotionReady) { state, value in
			let (id, source, tab, destination, requestID) = value
			guard state.automationHostCallbackIsCurrent(id, requestID: requestID)
			else { return .none }
			let automationAllowed: Bool
			if state.automation.hostTransitions[id] != nil {
				let snapshotIDs = state.automationSnapshotTabIDs
				let snapshots = MainActor.assumeIsolated {
					Dictionary(uniqueKeysWithValues: snapshotIDs.compactMap { id in engine.snapshot(id).map { (id, $0) } })
				}
				automationAllowed = state.automationAllowsHostTransition(
					id,
					requestID: requestID,
					snapshots: snapshots,
					now: now
				)
			} else {
				automationAllowed = true
			}
			guard
				automationAllowed,
				state.littleWindows[id: id]?.tab == source,
				let index = state.workspace.spaces.index(id: destination),
				state.workspace.spaces[index].profileID == tab.profileID
			else {
				state.failAutomationHostTransition(id, requestID: requestID, failure: .staleTarget)
				return .merge(
					.send(.littleWindows(.element(id: id, action: .event(.promotionFailed(String.localized(.appUI.preview.invalidMove)))))),
					.run { [engine] _ in
						if source.id != tab.id { await engine.close(tab.id) }
					}
				)
			}

			var organization = state.workspace
			do {
				try organization.update {
					$0.tabs.append(tab)

					// Little Arx has no tab in the space to go next to, so its tab is the first of
					// the open tabs, as ⌘T's and a bookmark's are (DEV-1325).
					$0.placeOpenedTab(tab.id, inSpaceAt: index, opener: nil)
					$0.spaces[index].selectedTabID = tab.id
				}

			} catch {
				state.failAutomationHostTransition(id, requestID: requestID, failure: .engineFailed)
				return .merge(
					.send(.littleWindows(.element(id: id, action: .event(.promotionFailed(error.localizedDescription))))),
					.run { [engine] _ in
						if source.id != tab.id { await engine.close(tab.id) }
					}
				)
			}

			// The tab goes to the ordinary window used last, which keeps it (DEV-1155).
			let windowID = state.littlePromotionWindowID

			// Little Arx as Page PiP opened in a space from its space picker or ⌘1–9 (DEV-1184):
			// the page floats on, as Page PiP of its new tab.
			let floats = requestID == nil
			&& state.littleWindows[id: id]?.isPictureInPicture == true
			&& PagePictureInPictureSpacesFeatureFlag.isOn()
			let isMain = windowID == state.main.id
			state.publishAdditiveOrganization(organization, openedIn: isMain ? nil : windowID)
			if isMain {
				state.main.sidebar.selectSpace(destination)
				state.main.sidebar.select(tab.id)
			} else {
				state.windows[id: windowID]?.sidebar.selectSpace(destination)
				state.windows[id: windowID]?.sidebar.select(tab.id)
			}
			state.discardLinkFeedback(in: id)
			state.littleWindows.remove(id: id)

			// Into another profile the tab got a new ID; the old one's chat surface goes.
			state.forgetDetachedChatSurfaces()
			state.completeAutomationHostTransition(id, requestID: requestID)
			if isMain { state.openMainWindow() }
			state.appActivationRequest += 1
			state.focusedWindowID = windowID
			let context = TabPresentationContext(state)

			// Publish membership before yielding, but release the former host before
			// attaching its page to an ordinary pane.
			return .merge(
				.send(.delegate(.save(organization))),
				.run { [engine, surface] send in
					await surface.release(source.id)
					if source.id != tab.id { await engine.close(source.id) }
					await send(.event(.littlePromotionReleased(tab, context)))
					if floats { await send(.ui(.presentTabInPictureInPicture(tab.id, windowID: windowID))) }
				}
			)
		}

		Pullback(\.event.littlePromotionReleased) { state, value in
			let (tab, context) = value
			var current = TabPresentationContext(state)

			// Activation can acknowledge the main-window focus committed above, and a page loading on
			// its own meanwhile doesn't count (DEV-1078). A newer selection, host, navigation to
			// another address or utility still invalidates the handoff.
			current.windowActivationRevision = context.windowActivationRevision
			guard context.ignoringLoadProgress == current.ignoringLoadProgress else { return .none }

			return OrdinaryTabPresentation().focus(tab, state: &state)
		}
	}

	/// The window takes the tab out of its space right after this. Its page view lets go of the
	/// page before Little Arx attaches it; until then the tab's chat surface is kept.
	private func tearOff(
		_ tab: BrowserCore.Tab,
		from spaceID: Space.ID,
		at point: CGPoint,
		state: inout State
	) -> Effect<Action> {
		state.tabsTearingOff.insert(tab.id)
		return .run { [surface] send in
			await surface.release(tab.id)
			await send(.event(.tabTornOff(tab, spaceID, point)))
		}
	}
}

extension AppFeature.State {
	/// The organization with a closed Little Arx page added to its space's archive, or nil
	/// when there's nothing to keep: a page that isn't http(s), or a space that's gone.
	internal func archivingClosedLittlePage(
		_ little: LittleArxFeature.State,
		closedAt: Date,
		uuid: () -> UUID
	) -> BrowserOrganization? {
		var tab = little.tab
		if let url = little.viewer.navigation.url, url.hasWebScheme {
			tab.restoration.url = url
		}
		if !little.viewer.navigation.title.isEmpty {
			tab.restoration.title = little.viewer.navigation.title
		}
		var organization = workspace
		guard
			(try? organization.archiveDetachedTab(
				tab,
				spaceID: little.spaceID,
				closedAt: closedAt,
				groupID: uuid(),
				id: .init(rawValue: uuid())
			)) == true
		else { return nil }

		return organization
	}
}

extension AppFeature.State {
	/// Whether a tab dropped outside every window may leave for Little Arx (DEV-793). A Peek that
	/// shows the tab owns its page until its handoff ends, so the tab stays.
	internal func tearOffIsAllowed(_ tabID: BrowserCore.Tab.ID) -> Bool {
		!peeks.contains { $0.tab.id == tabID }
		&& !tabsTearingOff.contains(tabID)
		&& !littleWindows.contains { $0.tab.id == tabID }
	}
}

extension AppFeature.State {
	/// Which window takes the keyboard after a focused Little Arx closes. A popup hands it back
	/// to the Little Arx that opened it (DEV-855), unless that one is on another macOS desktop
	/// Space: bringing it forward would pull it over here or switch Spaces (DEV-931), so
	/// nothing takes the keyboard and the active Space stays as it is. A popup from a window
	/// hands it back to that window while it's open, on the same terms (DEV-1186).
	internal func focusAfterClosingLittleArx(_ little: LittleArxFeature.State) -> UUID? {
		guard let opener = little.openerWindowID else { return nil }

		if littleWindows[id: opener] != nil {
			return littleWindowsOnOtherDesktopSpaces.contains(opener) ? nil : opener
		}

		let isOpen = opener == main.id ? windowIsOpen : windows[id: opener] != nil
		guard isOpen, !windowsOnOtherDesktopSpaces.contains(opener) else { return nil }

		return opener
	}
}
