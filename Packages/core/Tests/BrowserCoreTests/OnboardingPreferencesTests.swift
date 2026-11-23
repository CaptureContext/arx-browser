import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct OnboardingPreferencesTests {
	@Test
	internal func olderSettingsDecodeAsNeverDismissedAndNothingCompleted() throws {
		let data = try JSONEncoder().encode(BrowserPreferences())
		var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		old["onboarding"] = nil
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: old)
		)
		expectNoDifference(decoded.onboarding, OnboardingPreferences())
		#expect(!decoded.onboarding.introductionDismissed)
		#expect(!decoded.onboarding.isCompleted(.migration))
	}

	@Test
	internal func dismissalAndCompletionRoundTripIndependently() throws {
		var preferences = BrowserPreferences()
		preferences.onboarding.introductionDismissed = true
		let dismissed = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONEncoder().encode(preferences)
		)
		expectNoDifference(dismissed.onboarding, OnboardingPreferences(introductionDismissed: true))
		#expect(!dismissed.onboarding.isCompleted(.migration))

		preferences.onboarding = .init()
		preferences.onboarding.complete(.migration)
		preferences.onboarding.complete(.migration)
		let completed = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONEncoder().encode(preferences)
		)
		expectNoDifference(completed.onboarding.completedSteps, [.migration])
		#expect(!completed.onboarding.introductionDismissed)
	}

	@Test
	internal func theProfileHeldForICloudRoundTrips() throws {
		// DEV-1215: older settings have none; a held Default survives a relaunch partway through.
		let older: Data = .init(#"{"introductionDismissed":false,"completedSteps":["welcome"]}"#.utf8)
		#expect(try JSONDecoder().decode(OnboardingPreferences.self, from: older).heldForICloud == nil)

		let held: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let preferences: OnboardingPreferences = .init(completedSteps: [.welcome, .iCloud], heldForICloud: held)
		let decoded = try JSONDecoder().decode(OnboardingPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded, preferences)
	}

	@Test
	internal func aRetiredStepIsDroppedNotAnError() throws {
		// `crashReports` was a step while crash reports could be shared (DEV-887).
		let data: Data = .init(#"{"introductionDismissed":true,"completedSteps":["welcome","crashReports","defaultBrowser"]}"#.utf8)
		let decoded = try JSONDecoder().decode(OnboardingPreferences.self, from: data)
		expectNoDifference(decoded.completedSteps, [.welcome, .defaultBrowser])
		#expect(decoded.introductionDismissed)
	}
}
