import AppUI
import SettingsFeature
import _ComposableArchitecture

@MainActor
internal struct PreviewAppearancePreferences {
	internal static let store: StoreOf<SettingsFeature> = .init(
		initialState: .init()
	) {
		SettingsFeature()
	}

	internal init() {}

	internal var grain: FilmGrainStyle {
		let grain = Self.store.chromeAppearance.grain
		return .init(
			isEnabled: grain.isEnabled,
			intensity: grain.intensity,
			size: grain.size
		)
	}
}
