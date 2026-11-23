import BrowserCore
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

/// DEV-734: the theme, sound feedback and sharing the identity card.
@Suite(.dependencies)
@MainActor
internal struct AppearanceAndSoundSettingsTests {
	@Test
	internal func choosingAThemeSavesIt() async {
		let state = SettingsFeature.State(category: .appearance)
		state.$general.withLock { $0.appTheme = .system }
		let store = TestStore(initialState: state) { SettingsFeature() }

		// A shared key: AppFeature saves it, and BrowserWindow applies it to NSApp.
		await store.send(.ui(.appTheme(.dark))) {
			$0.$general.withLock { $0.appTheme = .dark }
		}
		await store.send(.ui(.appTheme(.light))) {
			$0.$general.withLock { $0.appTheme = .light }
		}
		await store.send(.ui(.appTheme(.system))) {
			$0.$general.withLock { $0.appTheme = .system }
		}
	}

	@Test
	internal func soundFeedbackTurnsOnAndOff() async {
		let state = SettingsFeature.State(category: .appearance)
		state.$general.withLock { $0.soundsEnabled = false }
		let store = TestStore(initialState: state) { SettingsFeature() }

		await store.send(.ui(.soundsEnabled(true))) {
			$0.$general.withLock { $0.soundsEnabled = true }
		}
		await store.send(.ui(.soundsEnabled(false))) {
			$0.$general.withLock { $0.soundsEnabled = false }
		}
	}

	@Test
	internal func sharingTheCardShowsTheShareSheetUntilItCloses() async {
		let store = TestStore(initialState: SettingsFeature.State(category: .arx)) { SettingsFeature() }

		await store.send(.ui(.shareIdentityCard)) {
			$0.isSharingIdentityCard = true
		}

		// A second press while the sheet is up changes nothing.
		await store.send(.ui(.shareIdentityCard))
		await store.send(.ui(.identityCardShareFinished)) {
			$0.isSharingIdentityCard = false
		}
	}

	@Test
	internal func themeDecodesAndFallsBackToSystem() throws {
		let saved = try JSONEncoder().encode(BrowserPreferences(appTheme: .dark))
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: saved).appTheme == .dark)

		// Saved before the setting existed, or by a newer build with a theme this one doesn't know.
		var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
		object.removeValue(forKey: "appTheme")
		let old = try JSONSerialization.data(withJSONObject: object)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: old).appTheme == .system)

		object["appTheme"] = "sepia"
		let newer = try JSONSerialization.data(withJSONObject: object)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: newer).appTheme == .system)
	}

	@Test
	internal func choosingAnAppIconSavesIt() async {
		let state = SettingsFeature.State(category: .appearance)
		state.$general.withLock { $0.appIcon = .dark }
		let store = TestStore(initialState: state) { SettingsFeature() }

		// A shared key: AppFeature saves it, and BrowserWindow puts it in the Dock (DEV-839).
		await store.send(.ui(.appIcon(.light))) {
			$0.$general.withLock { $0.appIcon = .light }
		}
		await store.send(.ui(.appIcon(.dark))) {
			$0.$general.withLock { $0.appIcon = .dark }
		}
	}

	@Test
	internal func theAppIconIsDarkUnlessChosenAndRoundTrips() throws {
		#expect(BrowserPreferences().appIcon == .dark)

		let saved = try JSONEncoder().encode(BrowserPreferences(appIcon: .light))
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: saved).appIcon == .light)

		// Saved before the setting existed, or by a newer build with an icon this one doesn't know.
		var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
		object.removeValue(forKey: "appIcon")
		let old = try JSONSerialization.data(withJSONObject: object)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: old).appIcon == .dark)

		object["appIcon"] = "rainbow"
		let newer = try JSONSerialization.data(withJSONObject: object)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: newer).appIcon == .dark)
	}
}
