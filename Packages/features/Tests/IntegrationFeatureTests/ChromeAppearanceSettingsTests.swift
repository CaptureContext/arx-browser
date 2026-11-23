import AppFeature
import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

extension IntegrationFeatureTests {
	@Test
	internal func globalChromeAppearanceIsSetAndResetFromSettings() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		let appearance = ChromeAppearance(
			tint: .init(hue: 130, intensity: 0.8),
			grain: .init(isEnabled: false, intensity: 0.4, size: 2)
		)

		// The shared key carries the edit to the workspace document; AppFeature saves it.
		await store.send(.ui(.chromeAppearance(appearance))) {
			$0.$chromeAppearance.withLock { $0 = appearance }
		}

		// Committing the same value again changes nothing.
		await store.send(.ui(.chromeAppearance(appearance)))

		await store.send(.ui(.resetAppearance)) {
			$0.$chromeAppearance.withLock { $0 = .default }
		}
	}

	/// DEV-1286: removing the theme panel's added colors in Settings goes back to one color, and
	/// removing the last dot keeps no gradient.
	@Test
	internal func removingTheBrowserDefaultsAddedColorsDropsItsGradient() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		let two = AppearanceOverride(.default)
			.settingThemeColors([.init(hue: 200, intensity: 0.3), .init(hue: 20, intensity: 0.3)], over: .default)
			.applied(to: .default)
		await store.send(.ui(.chromeAppearance(two))) {
			$0.$chromeAppearance.withLock { $0 = two }
		}

		let one = AppearanceOverride(two)
			.settingThemeColors([.init(hue: 200, intensity: 0.3)], over: .default)
			.applied(to: .default)
		#expect(one.gradient == nil)
		await store.send(.ui(.chromeAppearance(one))) {
			$0.$chromeAppearance.withLock { $0.gradient = nil }
		}
	}

	@Test
	internal func globalChromeAppearanceIsClampedBeforeItIsSaved() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		await store.send(.ui(.chromeAppearance(.init(
			tint: .init(hue: 400, intensity: 2),
			grain: .init(isEnabled: true, intensity: 0.5, size: 7)
		)))) {
			$0.$chromeAppearance.withLock {
				$0 = .init(
					tint: .init(hue: 40, intensity: 1),
					grain: .init(isEnabled: true, intensity: 0.5, size: 3)
				)
			}
		}
	}

	@Test
	internal func profileAppearanceIsSetAndClearedFromSettings() async {
		let organization = fixture()
		let profileID = organization.profiles[0].id
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		let override = AppearanceOverride(tintHue: 330, grainEnabled: false)
		await store.send(.settings(.ui(.changeOrganization(.setProfileAppearance(profileID, override)))))
		await store.receive(\.delegate.save)
		expectNoDifference(store.state.workspace.profiles[id: profileID]?.appearance, override)

		await store.send(.settings(.ui(.changeOrganization(.setProfileAppearance(profileID, .init())))))
		await store.receive(\.delegate.save)
		expectNoDifference(store.state.workspace.profiles[id: profileID]?.appearance, nil)
	}

	@Test
	internal func spaceAppearanceIsSetAndClearedFromTheWindow() async {
		let organization = fixture()
		let space = organization.spaces[0]
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: space.id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.changeOrganization(.setProfileAppearance(
			space.profileID,
			.init(tintHue: 30, tintIntensity: 0.6)
		)))))
		await store.receive(\.delegate.save)

		// The space changes only its hue, and keeps its profile's intensity and the global grain.
		await store.send(.main(.ui(.changeOrganization(.setSpaceAppearance(space.id, .init(tintHue: 200))))))
		await store.receive(\.delegate.save)
		expectNoDifference(store.state.workspace.spaces[id: space.id]?.appearance, .init(tintHue: 200))
		expectNoDifference(store.state.main.sidebar.organization.spaces[id: space.id]?.appearance, .init(tintHue: 200))
		expectNoDifference(
			ChromeAppearance.resolve(
				global: store.state.settings.chromeAppearance,
				profile: store.state.workspace.profiles[id: space.profileID]?.appearance,
				space: store.state.workspace.spaces[id: space.id]?.appearance
			),
			.init(tint: .init(hue: 200, intensity: 0.6), grain: .default)
		)

		await store.send(.main(.ui(.changeOrganization(.setSpaceAppearance(space.id, .init())))))
		await store.receive(\.delegate.save)
		expectNoDifference(store.state.workspace.spaces[id: space.id]?.appearance, nil)
		expectNoDifference(
			store.state.workspace.appearance(ofSpace: space.id),
			.init(tintHue: 30, tintIntensity: 0.6)
		)
	}

	/// DEV-1170: Settings' browser default, a profile's off and a space's on, the most specific
	/// winning, and Inherit falling back a level.
	@Test
	internal func matchSiteIsChosenAtEveryLevel() async {
		let organization = fixture()
		let space = organization.spaces[0]
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: space.id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		func resolved() -> Bool {
			ChromeAppearance.resolve(
				global: store.state.settings.chromeAppearance,
				profile: store.state.workspace.profiles[id: space.profileID]?.appearance,
				space: store.state.workspace.spaces[id: space.id]?.appearance
			).matchesSite
		}
		#expect(!resolved())

		var everywhere = store.state.settings.chromeAppearance
		everywhere.matchesSite = true
		await store.send(.settings(.ui(.chromeAppearance(everywhere))))
		#expect(store.state.settings.chromeAppearance.matchesSite)
		#expect(resolved())

		await store.send(.settings(.ui(.changeOrganization(.setProfileAppearance(space.profileID, .init(matchesSite: false))))))
		await store.receive(\.delegate.save)
		#expect(!resolved())

		await store.send(.main(.ui(.changeOrganization(.setSpaceAppearance(space.id, .init(matchesSite: true))))))
		await store.receive(\.delegate.save)
		#expect(resolved())

		// Inherit in the space: back to its profile's off.
		await store.send(.main(.ui(.changeOrganization(.setSpaceAppearance(space.id, .init(matchesSite: true).inheritingMatchSite())))))
		await store.receive(\.delegate.save)
		expectNoDifference(store.state.workspace.spaces[id: space.id]?.appearance, nil)
		#expect(!resolved())
	}

	@Test
	internal func chromeAppearanceSurvivesTheWorkspaceFile() throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")

		var organization = fixture()
		organization.profiles[0].appearance = .init(tintIntensity: 0, grainSize: 2)
		organization.spaces[0].appearance = .init(theme: .dark, tintHue: 280, grainEnabled: false, matchesSite: false)
		var preferences = BrowserPreferences()
		preferences.chromeAppearance = .init(
			tint: .init(hue: 175, intensity: 0.45),
			grain: .init(intensity: 0.25),
			matchesSite: true
		)

		try BrowserWorkspaceClient(file: file).save(organization, preferences: preferences)
		let loaded = try BrowserWorkspaceClient(file: file).loadWithRecovery()
		let loadedOrganization = try #require(loaded.organization)
		expectNoDifference(loaded.preferences.chromeAppearance, preferences.chromeAppearance)
		expectNoDifference(loadedOrganization.profiles[0].appearance, organization.profiles[0].appearance)
		expectNoDifference(loadedOrganization.spaces[0].appearance, organization.spaces[0].appearance)
	}
}
