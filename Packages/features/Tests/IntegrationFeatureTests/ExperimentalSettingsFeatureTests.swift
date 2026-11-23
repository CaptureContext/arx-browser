import BrowserCore
import SettingsFeature
import Testing

/// DEV-778: Experimental has no experiments now, so Settings neither lists nor searches it.
@Suite(.dependencies)
@MainActor
internal struct ExperimentalSettingsFeatureTests {
	@Test
	internal func experimentalIsHiddenWhileItIsEmpty() {
		#expect(!SettingsCategory.available.contains(.experimental))
		#expect(!SettingsCategory.searchIndex.contains { $0.category == .experimental })
	}

	@Test
	internal func settingsStillCarriesTheExperimentsSet() {
		let state = SettingsFeature.State(category: .experimental)
		#expect(state.experiments == ExperimentalPreferences())
	}
}
