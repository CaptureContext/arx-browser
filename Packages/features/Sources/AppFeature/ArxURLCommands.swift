import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// Carries out an `arx://` address or a Shortcuts action (DEV-929). A space or profile that
/// isn't there does nothing rather than guessing another.
@Reducer
internal struct ArxURLCommands {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.arxURLCommand) { state, command in
			guard !state.shouldQuit, !state.checkingQuit else { return .none }

			switch command {
			case let .open(url, spaceName, profileName):
				let profile = profileName.flatMap { state.workspace.profile(named: $0) }
				guard profileName == nil || profile != nil else { return .none }

				if let spaceName {
					guard let space = state.workspace.space(named: spaceName, in: profile?.id)
					else { return .none }

					return .send(.ui(.openURLInSpace(url, space.id, .mainBrowser)))
				}
				if let profile {
					return .send(.ui(.routeURLs(
						[url],
						override: .init(scope: .profile(profile.id), mode: .mainBrowser)
					)))
				}

				// Neither named: Air Traffic Control decides, as for a link from another app.
				return .send(.ui(.routeURLs([url])))

			case let .littleArx(url, spaceName):
				let space = spaceName.flatMap { state.workspace.space(named: $0) }
				guard spaceName == nil || space != nil else { return .none }

				return .send(.ui(.openLittleArx(space?.id, url)))

			case let .switchSpace(name):
				guard
					let space = state.workspace.space(named: name),
					!state.mainWindowWaitsForOnboarding
				else { return .none }

				_ = state.openMainWindow()
				state.focusedWindowID = state.main.id

				// The focus request that also brings Arx forward.
				state.mediaSourceFocusRequest += 1
				return .send(.main(.sidebar(.ui(.spaceSelected(space.id)))))
			}
		}
	}
}
