import BrowserCore
import BrowserEngineClient
import Foundation
import LittleArxFeature
import _ComposableArchitecture

@CasePathable
public enum PrivateLittleArxAction: Sendable {
	/// Opens `url` in a private Little Arx with this ID, once its profile is ready.
	case open(UUID, URL)
	case profileReady(UUID, Profile.ID)
	case profileFailed(UUID)
	/// Closes the window without asking its page, and releases its profile. Before the window
	/// opened, it won't open.
	case close(UUID)

	@CasePathable
	public enum Delegate: Sendable {
		/// The window is on screen.
		case opened(UUID)
		/// Its profile couldn't be prepared: no window.
		case failed(UUID)
	}

	case delegate(Delegate)
}

/// Private Little Arx windows (DEV-1323), an internal capability. Each window's page runs in a
/// private profile prepared for it alone, as a private window's does, and released when it
/// closes. The window never joins the workspace or the archive (`LittleArxFeature.State.isPrivate`).
///
/// Nothing a person can do opens one yet: no command, menu, shortcut, setting or tool. Its only
/// caller is the member number's sign-in (`MemberSignInWindows`). Offering it to people is DEV-1329.
@Reducer
internal struct PrivateLittleArx {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.privateLittleArx.open) { state, value in
			let (windowID, url) = value
			guard
				state.privateLittleArxPending[windowID] == nil,
				state.littleWindows[id: windowID] == nil
			else { return .none }

			let profileID: Profile.ID = .init(rawValue: uuid())
			state.privateLittleArxPending[windowID] = url
			return .run { [engine] send in
				do {
					try await engine.preparePrivateProfile(profileID, nil)
					await send(.privateLittleArx(.profileReady(windowID, profileID)))
				} catch {
					await send(.privateLittleArx(.profileFailed(windowID)))
				}
			}
		}

		Pullback(\.privateLittleArx.profileFailed) { state, windowID in
			guard state.privateLittleArxPending.removeValue(forKey: windowID) != nil else { return .none }

			return .send(.privateLittleArx(.delegate(.failed(windowID))))
		}

		Pullback(\.privateLittleArx.profileReady) { state, value in
			let (windowID, profileID) = value
			// Closed while its profile was being prepared: the profile goes now.
			guard let url = state.privateLittleArxPending.removeValue(forKey: windowID) else {
				return .run { [engine] _ in await engine.releasePrivateProfile(profileID) }
			}

			let tab: BrowserCore.Tab = .init(
				id: .init(rawValue: uuid()),
				profileID: profileID,
				restoration: .init(title: url.host() ?? "Little Arx", url: url)
			)
			// The space only tints the window; the page stays in its own profile.
			var little: LittleArxFeature.State = .init(
				id: windowID,
				spaceID: state.main.sidebar.spaceID,
				tab: tab,
				isCommandOnly: false,
				bangs: state.settings.bangs,
				captureAvailable: false,
				downloadsAvailable: false,
				mediaAvailable: false,
				launcherSuggestions: []
			)
			little.isPrivate = true
			little.openerWindowID = state.focusedWindowID
			state.littleWindows.append(little)
			state.privateLittleArxProfiles[windowID] = profileID
			state.focusedWindowID = windowID
			state.appActivationRequest += 1
			return .send(.privateLittleArx(.delegate(.opened(windowID))))
		}

		Pullback(\.privateLittleArx.close) { state, windowID in
			guard state.privateLittleArxPending.removeValue(forKey: windowID) == nil else { return .none }
			guard
				let profileID = state.privateLittleArxProfiles.removeValue(forKey: windowID),
				let little = state.littleWindows[id: windowID]
			else { return .none }

			state.discardLinkFeedback(in: windowID)
			state.littleWindows.remove(id: windowID)
			state.littleWindowsOnOtherDesktopSpaces.remove(windowID)
			if state.focusedWindowID == windowID {
				state.focusedWindowID = state.focusAfterClosingLittleArx(little)
			}
			let tabID = little.tab.id
			return .run { [engine] _ in
				await engine.close(tabID)
				await engine.releasePrivateProfile(profileID)
			}
		}

		// Closed by hand or by its page: LittleArxWindows removes the window and closes the page;
		// its profile goes here.
		Pullback(\.littleWindows) { state, action in
			guard
				case let .element(id, .delegate(.closeApproved)) = action,
				let profileID = state.privateLittleArxProfiles.removeValue(forKey: id)
			else { return .none }

			return .run { [engine] _ in await engine.releasePrivateProfile(profileID) }
		}
	}
}
