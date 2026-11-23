import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1138: the interval idle Little Arx windows are archived after.
internal struct LittleArxArchivingTests {
	@Test
	internal func theIntervalIsSavedAndOlderFilesReadAsNever() throws {
		var preferences = BrowserPreferences()
		#expect(preferences.littleArxArchiveInterval == nil)
		preferences.littleArxArchiveInterval = .hour
		let encoded = try JSONEncoder().encode(preferences)
		expectNoDifference(try JSONDecoder().decode(BrowserPreferences.self, from: encoded).littleArxArchiveInterval, .hour)
		expectNoDifference(preferences.linkClicks.littleArxArchiveInterval, .hour)

		var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object["littleArxArchiveInterval"] = "fortnight"
		let unknown = try JSONSerialization.data(withJSONObject: object)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: unknown).littleArxArchiveInterval == nil)
		object.removeValue(forKey: "littleArxArchiveInterval")
		let older = try JSONSerialization.data(withJSONObject: object)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: older).littleArxArchiveInterval == nil)
	}

	@Test
	internal func intervalsRunFromFifteenMinutesToADay() {
		let minutes: [TimeInterval] = [15, 60, 720, 1_440]
		expectNoDifference(LittleArxArchiveInterval.allCases.map(\.duration), minutes.map { $0 * 60 })
	}

	/// On by default for the beta (Max, 17 Nov), with the interval at Never so nothing is archived
	/// until someone picks one.
	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let defaults = try #require(UserDefaults(suiteName: "LittleArxArchivingTests"))
		defaults.removePersistentDomain(forName: "LittleArxArchivingTests")
		#expect(LittleArxAutoArchiveFeatureFlag.isEnabled(environment: [:], defaults: defaults))
		#expect(!LittleArxAutoArchiveFeatureFlag.isEnabled(environment: [LittleArxAutoArchiveFeatureFlag.name: "0"], defaults: defaults))
		defaults.set("off", forKey: LittleArxAutoArchiveFeatureFlag.name)
		#expect(!LittleArxAutoArchiveFeatureFlag.isEnabled(environment: [:], defaults: defaults))
		defaults.removePersistentDomain(forName: "LittleArxArchivingTests")
		#expect(BrowserPreferences().littleArxArchiveInterval == nil)
	}
}
