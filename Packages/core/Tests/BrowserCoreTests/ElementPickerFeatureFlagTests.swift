import BrowserCore
import Foundation
import Testing

internal struct ElementPickerFeatureFlagTests {
	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let suite = "ElementPickerFeatureFlagTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		// On by default (DEV-1143).
		#expect(ElementPickerFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(ElementPickerFeatureFlag.isOn(environment: ["ARX_ELEMENT_PICKER": "on"], defaults: defaults))
		#expect(!ElementPickerFeatureFlag.isOn(environment: ["ARX_ELEMENT_PICKER": "0"], defaults: defaults))

		defaults.set("off", forKey: "ARX_ELEMENT_PICKER")
		#expect(!ElementPickerFeatureFlag.isOn(environment: [:], defaults: defaults))
		// The environment wins over user defaults.
		#expect(ElementPickerFeatureFlag.isOn(environment: ["ARX_ELEMENT_PICKER": "yes"], defaults: defaults))
	}
}
