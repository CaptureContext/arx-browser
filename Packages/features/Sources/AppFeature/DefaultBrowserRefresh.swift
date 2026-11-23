import OnboardingFeature
import SettingsFeature
import _ComposableArchitecture

/// Reads the default browser again when the app becomes active, because the person
/// can change it in System Settings while Arx is in the background.
///
/// Only an open Settings window and a visible default-browser onboarding page check;
/// otherwise nothing reaches the default-browser client. A visible connect-your-agent page
/// reads its providers' sign-ins again the same way, and the import page checks Full Disk
/// Access for Safari again.
@Reducer
internal struct DefaultBrowserRefresh {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.event.applicationBecameActive) { state in
			var effects: [Effect<Action>] = []
			if state.settingsIsOpen {
				effects.append(.send(.settings(.event(.applicationBecameActive))))
			}
			if state.onboarding?.page.defaultBrowser != nil {
				effects.append(.send(.onboarding(.page(.defaultBrowser(.event(.applicationBecameActive))))))
			}

			// Someone may have allowed Full Disk Access for Safari's import meanwhile (DEV-840).
			if state.onboarding?.page.migration != nil {
				effects.append(.send(.onboarding(.page(.migration(.event(.applicationBecameActive))))))
			}

			// Someone may have signed in to Claude Code or Codex in Terminal meanwhile.
			if state.onboarding?.page.connectAgent != nil {
				effects.append(.send(.onboarding(.page(.connectAgent(.event(.applicationBecameActive))))))
			}
			return .merge(effects)
		}
	}
}
