import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The app-wide window background. Profiles and spaces build on it.
internal struct AppearanceSettingsSection: View {
	internal let store: StoreOf<SettingsFeature>

	internal init(store: StoreOf<SettingsFeature>) {
		self.store = store
	}

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.appearance.windowBackground),
			caption: String.localized(.appUI.appearance.backgroundDescription)
		) {
			// The theme panel a space's popover shows (DEV-1286), inline in the page.
			SpaceThemeEditor(
				level: .global,
				layout: .settings,
				choices: .init(store.chromeAppearance),
				inherited: .default,
				offersMatchSite: store.matchSiteAvailable,
				offersAccent: ChromeAccent.isEnabled(),
				onCommit: { store.send(.ui(.chromeAppearance($0.applied(to: .default)))) },
				onClear: { store.send(.ui(.resetAppearance)) },
				matchSiteRow: { AnyView($0.settingsAnchor(.matchSite)) }
			)
		}
	}
}
