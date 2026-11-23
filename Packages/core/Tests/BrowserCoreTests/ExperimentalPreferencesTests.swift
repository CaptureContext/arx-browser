import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-748, DEV-778: Settings › Experimental's set. It has no experiments now; saved sets from
/// earlier builds still decode.
internal struct ExperimentalPreferencesTests {
	@Test
	internal func preferencesSavedBeforeExperimentsGetTheDefaults() throws {
		var preferences = BrowserPreferences()
		preferences.hapticsEnabled = false
		let data = try JSONEncoder().encode(preferences)
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(values.removeValue(forKey: "experiments") != nil, "experiments are saved")

		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(decoded.experiments == .init())
		#expect(!decoded.hapticsEnabled)
	}

	@Test
	internal func experimentsRoundTrip() throws {
		let preferences = BrowserPreferences()
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded, preferences)
	}

	@Test(arguments: [
		"legacy",
		"log",
		"document",
		"studio",
		"command",
		"compact",
		"cards",
		"hologram",
	])
	internal func anEarlierBuildsChatStyleDecodesWithoutLosingOtherPreferences(saved: String) throws {
		var preferences = BrowserPreferences()
		preferences.soundsEnabled = true
		let data = try JSONEncoder().encode(preferences)
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["experiments"] = ["chatStyle": saved]

		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(decoded.experiments == .init())
		#expect(decoded.soundsEnabled)

		let experiments = try JSONDecoder().decode(
			ExperimentalPreferences.self,
			from: JSONSerialization.data(withJSONObject: ["chatStyle": saved])
		)
		#expect(experiments == .init())
	}

	@Test
	internal func aDamagedSetFallsBackWithoutLosingOtherPreferences() throws {
		var preferences = BrowserPreferences()
		preferences.soundsEnabled = true
		let data = try JSONEncoder().encode(preferences)
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["experiments"] = "not a set"

		let damaged = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(damaged.experiments == .init())
		#expect(damaged.soundsEnabled)
	}
}
