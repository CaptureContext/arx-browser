import BrowserCore
import Foundation
import Testing

internal struct HideElementFeatureFlagTests {
	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let suite = "HideElementFeatureFlagTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		// On by default (DEV-1143).
		#expect(HideElementFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(HideElementFeatureFlag.isOn(environment: ["ARX_HIDE_ELEMENT": "1"], defaults: defaults))
		#expect(HideElementFeatureFlag.isOn(environment: ["ARX_HIDE_ELEMENT": "Yes"], defaults: defaults))
		#expect(!HideElementFeatureFlag.isOn(environment: ["ARX_HIDE_ELEMENT": "0"], defaults: defaults))

		defaults.set("false", forKey: "ARX_HIDE_ELEMENT")
		#expect(!HideElementFeatureFlag.isOn(environment: [:], defaults: defaults))
		// The environment wins over user defaults.
		#expect(HideElementFeatureFlag.isOn(environment: ["ARX_HIDE_ELEMENT": "yes"], defaults: defaults))
	}
}
