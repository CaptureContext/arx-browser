import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// One close attempt authorizes exactly the captured private sessions and contexts.
public struct PrivateWindowCloseRequest: Equatable, Sendable {
	public let token: UUID
	public let tabIDs: [BrowserCore.Tab.ID]
	public let profileIDs: [Profile.ID]
}

/// Private organization never enters the canonical workspace or save delegates.
@Reducer
internal struct PrivateWindows {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.newPrivateWindow) { state in
			openPrivateWindow(showing: nil, state: &state)
		}

		// Open Link in Private Window: the window shows the link once its profile is ready (DEV-815).
		Pullback(\.openInPrivateWindow) { state, value in
			let (url, opener) = value
			guard url.hasWebScheme else { return .none }
			return openPrivateWindow(showing: url, opener: opener, state: &state)
		}

		Pullback(\.event.privateWindowReady) { state, value in
			let (windowID, profileID, spaceID, linkedOpener) = value
			let url = state.privateWindowURLs.removeValue(forKey: windowID)
			guard !state.shouldQuit else {
				state.privateProfileOpeners[profileID] = nil
				return .run { [engine] _ in await engine.releasePrivateProfile(profileID) }
			}

			let title = String.localized(.appUI.menu.privateTitle)
			let organization = BrowserOrganization(
				profiles: [.init(id: profileID, name: title)],
				spaces: [.init(id: spaceID, profileID: profileID, name: title)]
			)
			var window = MainFeature.State(
				organization: organization,
				spaceID: spaceID,
				isPrivate: true,
				id: windowID
			)
			window.privateOpenerProfileID = linkedOpener
			window.captureAvailable = state.captureAvailable
			window.downloadsAvailable = state.downloadsReady
			window.commandBar.bangs = state.settings.bangs
			window.sidebarWidth = state.newWindowSidebarWidth
			state.windows.append(window)
			state.focusedWindowID = windowID

			if let url {
				return .send(.windows(.element(id: windowID, action: .ui(.openInNewTab(url)))))
			}
			return .send(.windows(.element(id: windowID, action: .ui(.openCommand(.newTab)))))
		}

		Pullback(\.event.privateWindowFailed) { state, value in
			let (windowID, profileID, message) = value
			state.privateWindowURLs[windowID] = nil

			// No window holds its opener now (ProfileLifetime, ProfileRetirement).
			state.privateProfileOpeners[profileID] = nil
			return .send(.delegate(.commandFailed(message)))
		}

		Pullback(\.ui.requestClosePrivateWindow) { state, id in
			guard
				!state.shouldQuit,
				let window = state.windows[id: id],
				window.isPrivate,
				!window.isClosing
			else { return .none }
			let request = PrivateWindowCloseRequest(token: uuid(), tabIDs: window.sidebar.organization.tabs.map(\.id),
				profileIDs: window.sidebar.organization.profiles.map(\.id))
			state.windows[id: id]?.isClosing = true
			state.privateWindowCloseRequests[id] = request

			return .run { [engine] send in
				for tab in request.tabIDs {
					guard !Task.isCancelled else { return }
					let approved = await engine.permitsClosing(tab)
					guard !Task.isCancelled else { return }
					if !approved {
						await send(.event(.privateWindowCloseDecision(id, request, false)))
						return
					}
				}
				guard !Task.isCancelled else { return }
				await send(.event(.privateWindowCloseDecision(id, request, true)))
			}.cancellable(id: CloseEffectID(windowID: id), cancelInFlight: true)
		}

		Pullback(\.event.privateWindowCloseDecision) { state, value in
			let (id, request, approved) = value
			guard
				state.privateWindowCloseRequests[id] == request,
				let window = state.windows[id: id],
				window.isPrivate,
				window.isClosing
			else { return .none }
			state.privateWindowCloseRequests[id] = nil
			state.windows[id: id]?.isClosing = false
			guard approved, !state.shouldQuit else { return .none }
			guard
				window.sidebar.organization.tabs.map(\.id) == request.tabIDs,
				window.sidebar.organization.profiles.map(\.id) == request.profileIDs
			else { return .send(.ui(.requestClosePrivateWindow(id))) }
			state.discardLinkFeedback(in: id)
			state.windows.remove(id: id)
			if state.focusedWindowID == id { state.focusedWindowID = nil }

			// Popup windows can share this exact private BrowserContext. An empty
			// surviving host still owns it and may create another private tab.
			let sharedProfiles = Set(state.windows.filter(\.isPrivate).flatMap {
				$0.sidebar.organization.profiles.map(\.id)
			})
			let releasedProfiles = request.profileIDs.filter { !sharedProfiles.contains($0) }
			for profile in releasedProfiles { state.privateProfileOpeners[profile] = nil }

			return .run { [engine] _ in
				for tab in request.tabIDs { await engine.close(tab) }
				for profile in releasedProfiles { await engine.releasePrivateProfile(profile) }
			}
		}
	}

	private struct CloseEffectID: Hashable { let windowID: UUID }

	/// Prepares a private profile for a new private window, which shows `url` once ready, or
	/// opens its command bar for a new tab.
	private func openPrivateWindow(
		showing url: URL?,
		opener sourceProfile: Profile.ID? = nil,
		state: inout State
	) -> Effect<Action> {
		// Launch onboarding comes first; a browser window opens when it ends (DEV-838).
		guard !state.mainWindowWaitsForOnboarding else {
			state.bringOnboardingForward()
			return .none
		}

		let windowID = uuid()
		if let url { state.privateWindowURLs[windowID] = url }
		let profileID = Profile.ID(rawValue: uuid())
		let spaceID = Space.ID(rawValue: uuid())

		// The window belongs to this profile: its private context is the profile's own, with the
		// extensions it allows in private windows (DEV-889), and its downloads folder and "Ask
		// where to save" follow the profile's (DEV-729).
		let opener = sourceProfile.flatMap { state.workspace.profiles[id: $0]?.id } ?? state.privateWindowOpener
		if let opener { state.privateProfileOpeners[profileID] = opener }

		return .run { [engine] send in
			do {
				// Native links the downloads only to a prepared opener, and never repairs
				// the link later. If the opener can't be prepared, the window still opens.
				var linkedOpener = opener
				if let opener {
					do {
						try await engine.prepareProfile(opener)
					} catch {
						linkedOpener = nil
					}
				}
				try await engine.preparePrivateProfile(profileID, linkedOpener)
				await send(.event(.privateWindowReady(windowID, profileID, spaceID, linkedOpener: linkedOpener)))
			} catch {
				await send(.event(.privateWindowFailed(windowID, profileID, error.localizedDescription)))
			}
		}
	}
}

extension AppFeature.State {
	/// The ordinary profile a new private window opens from: the focused window's, or the
	/// one a focused private window was opened from. With neither, as with no window focused
	/// in a headless run, the main window's profile, or else the workspace's first, so every
	/// private window belongs to a profile and runs the extensions it allows there (DEV-889).
	/// Nil only for a workspace with no profile.
	fileprivate var privateWindowOpener: Profile.ID? {
		let focused = focusedWindowID.flatMap { id in
			id == main.id && windowIsOpen ? main : windows[id: id]
		}
		if let focused {
			let profileID = focused.sidebar.space.profileID
			if !focused.isPrivate, workspace.profiles[id: profileID] != nil { return profileID }
			if focused.isPrivate, let opener = privateProfileOpeners[profileID] { return opener }
		}
		let mainProfileID = main.sidebar.space.profileID
		if workspace.profiles[id: mainProfileID] != nil { return mainProfileID }
		return workspace.profiles.first?.id
	}
}
