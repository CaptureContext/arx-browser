import BrowserCore
import CustomDump
import Foundation
@testable import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-871: nothing in Settings does nothing. Unfinished options show only with the
/// `ARX_PENDING_SETTINGS` feature flag, and Reset translation choices clears one profile's.
@Suite(.dependencies)
@MainActor
internal struct SettingsPendingOptionsTests {
	private static let work = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
	private static let personal = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)

	@Test
	internal func unfinishedOptionsStayHiddenWhenTheFeatureFlagIsOff() throws {
		let defaults = try #require(UserDefaults(suiteName: "SettingsPendingOptionsTests"))
		defaults.removePersistentDomain(forName: "SettingsPendingOptionsTests")

		// On by default (DEV-1143), in debug builds only.
		#expect(PendingSettingsFeatureFlag.isEnabled(environment: [:], defaults: defaults))
		#expect(!PendingSettingsFeatureFlag.isEnabled(environment: [PendingSettingsFeatureFlag.name: "0"], defaults: defaults))
		defaults.set("off", forKey: PendingSettingsFeatureFlag.name)
		#expect(!PendingSettingsFeatureFlag.isEnabled(environment: [:], defaults: defaults))
		defaults.removePersistentDomain(forName: "SettingsPendingOptionsTests")

		// Without the flag, the pages holding only unfinished options aren't listed.
		expectNoDifference(
			SettingsPage.available(showingPendingOptions: false, hasAICommands: false),
			[.profile, .searchShortcuts, .proxyLinks, .routing, .appLinks, .keptLoadedSites, .webKitSites, .featureFlags]
		)
	}

	@Test
	internal func resetTranslationChoicesClearsOnlyThatProfile() async {
		let state = SettingsFeature.State()
		state.$translation.withLock {
			$0 = .init()
			$0.provider = .google
			$0.targetLanguage = "uk"
			$0[Self.work] = .init(neverSites: ["example.com"], alwaysLanguages: ["fr"])
			$0[Self.personal] = .init(neverSites: ["news.example"])
		}
		let store = TestStore(initialState: state) { SettingsFeature() }
		store.exhaustivity = .off

		await store.send(.ui(.resetTranslationChoices(Self.work)))
		#expect(store.state.translation[Self.work].isEmpty)
		expectNoDifference(store.state.translation[Self.personal], .init(neverSites: ["news.example"]))
		expectNoDifference(store.state.translation.provider, .google)
		expectNoDifference(store.state.translation.targetLanguage, "uk")
	}
}
