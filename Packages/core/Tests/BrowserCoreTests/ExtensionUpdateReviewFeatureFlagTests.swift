import BrowserCore
import Foundation
import Testing

internal struct ExtensionUpdateReviewFeatureFlagTests {
	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let suite = "ExtensionUpdateReviewFeatureFlagTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		// On by default (DEV-1143).
		#expect(ExtensionUpdateReviewFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(ExtensionUpdateReviewFeatureFlag.isOn(environment: ["ARX_EXTENSION_UPDATE_REVIEW": "on"], defaults: defaults))
		#expect(!ExtensionUpdateReviewFeatureFlag.isOn(environment: ["ARX_EXTENSION_UPDATE_REVIEW": "0"], defaults: defaults))

		defaults.set("off", forKey: "ARX_EXTENSION_UPDATE_REVIEW")
		#expect(!ExtensionUpdateReviewFeatureFlag.isOn(environment: [:], defaults: defaults))
		// The environment wins over user defaults.
		#expect(ExtensionUpdateReviewFeatureFlag.isOn(environment: ["ARX_EXTENSION_UPDATE_REVIEW": "yes"], defaults: defaults))
	}
}
