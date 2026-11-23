import AppKit
import BrowserCore
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// DEV-922: Handoff for the front window's page.
@Suite(.dependencies)
@MainActor
internal struct HandoffTests {
	@Test
	internal func onlyWebPagesComeInFromAnotherDevice() async throws {
		let web = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
		web.webpageURL = URL(string: "https://capturecontext.dev/arx")
		#expect(HandoffActivity.incomingURL(web) == URL(string: "https://capturecontext.dev/arx"))

		// AppKit itself refuses webpage URLs that aren't http(s).
		let empty = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
		#expect(HandoffActivity.incomingURL(empty) == nil)

		let other = NSUserActivity(activityType: "dev.capturecontext.arx.other")
		other.webpageURL = URL(string: "https://capturecontext.dev")
		#expect(HandoffActivity.incomingURL(other) == nil)
	}

	@Test
	internal func handoffIsOnByDefaultAndOlderPreferencesKeepIt() async throws {
		#expect(BrowserPreferences().handoffEnabled)
		let old = Data(#"{"grainEnabled":true,"grainIntensity":0.35,"grainSize":1,"searchShortcuts":[]}"#.utf8)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: old).handoffEnabled)

		var preferences = BrowserPreferences()
		preferences.handoffEnabled = false
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		#expect(!decoded.handoffEnabled)
	}

	@Test
	internal func theSettingTurnsHandoffOff() async throws {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.state.$general.withLock { $0.handoffEnabled = true }

		await store.send(.ui(.handoffEnabled(false)))
		#expect(!store.state.general.handoffEnabled)
	}
}
