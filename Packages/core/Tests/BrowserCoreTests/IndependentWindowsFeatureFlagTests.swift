import BrowserCore
import Foundation
import Testing

internal struct IndependentWindowsFeatureFlagTests {
	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let suite = "IndependentWindowsFeatureFlagTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(IndependentWindowsFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(IndependentWindowsFeatureFlag.isOn(environment: ["ARX_INDEPENDENT_WINDOWS": "1"], defaults: defaults))
		#expect(!IndependentWindowsFeatureFlag.isOn(environment: ["ARX_INDEPENDENT_WINDOWS": "0"], defaults: defaults))
		#expect(!IndependentWindowsFeatureFlag.isOn(environment: ["ARX_INDEPENDENT_WINDOWS": "No"], defaults: defaults))

		defaults.set("false", forKey: "ARX_INDEPENDENT_WINDOWS")
		#expect(!IndependentWindowsFeatureFlag.isOn(environment: [:], defaults: defaults))
		// The environment wins over user defaults.
		#expect(IndependentWindowsFeatureFlag.isOn(environment: ["ARX_INDEPENDENT_WINDOWS": "yes"], defaults: defaults))
	}
}
