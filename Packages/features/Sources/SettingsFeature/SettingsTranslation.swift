import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Settings › General › Translation (DEV-996, behind `ARX_TRANSLATE`): who translates pages,
/// Apple's quality, and the language pages are translated into. A shared key: AppFeature's
/// translation reads it as it changes.
@Reducer
internal struct SettingsTranslation {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.translationProvider) { state, provider in
			state.$translation.withLock { $0.provider = provider }
			return .none
		}

		Pullback(\.ui.translationQuality) { state, quality in
			state.$translation.withLock { $0.quality = quality }
			return .none
		}

		Pullback(\.ui.translationTarget) { state, target in
			state.$translation.withLock { $0.targetLanguage = target }
			return .none
		}

		// That profile's choices only: the provider, quality, target language and every other
		// profile's choices stay (DEV-871).
		Pullback(\.ui.resetTranslationChoices) { state, profileID in
			state.$translation.withLock { $0[profileID] = .init() }
			return .none
		}
	}
}
