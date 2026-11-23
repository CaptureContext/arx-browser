import AppUpdaterClient
import SettingsFeature
import SwiftUI
import _ComposableArchitecture

/// What's New after an update (DEV-888). SettingsFeature holds it while the updater reports it;
/// the main window shows it as a sheet, and its link opens the full release notes in a new tab.
@Reducer
internal struct WhatsNewPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.settings.delegate.openReleaseNotes) { _, url in
			.send(.main(.ui(.openInNewTab(url))))
		}
	}
}
