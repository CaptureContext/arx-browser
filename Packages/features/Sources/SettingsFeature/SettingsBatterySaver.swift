import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Settings › General › Battery Saver (DEV-915). A shared key: AppFeature saves the edit, and
/// the app's Battery Saver controller hands it to the engine.
@Reducer
internal struct SettingsBatterySaver {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.batterySaverMode) { state, mode in
			state.$batterySaver.withLock { $0 = mode }
			return .none
		}
	}
}
