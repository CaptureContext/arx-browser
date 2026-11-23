import BrowserCore
import Foundation
import Testing

/// How see-through the browser window's chrome is (DEV-1286): the tint's intensity sets it, never
/// below 0.7, and it's solid with the flag off, Reduce Transparency or Increase Contrast.
internal struct TranslucentChromeTests {
	@Test
	internal func intensityZeroIsTheClearestTheChromeGets() {
		#expect(opacity(0) == 0.7)
	}

	@Test
	internal func theDefaultIntensityIsAThirdOfTheWayToSolid() {
		#expect(abs(opacity(ChromeTint.default.intensity) - 0.8) < 1e-9)
	}

	@Test(arguments: [0.6, 0.8, 1])
	internal func fromSixtyPercentTheChromeIsSolid(_ intensity: Double) {
		#expect(opacity(intensity) == 1)
	}

	@Test
	internal func itGrowsLinearlyBetween() {
		#expect(abs(opacity(0.3) - 0.85) < 1e-9)
		#expect(opacity(0.1) < opacity(0.2))
		#expect(opacity(0.2) < opacity(0.5))
	}

	@Test(arguments: [-1, -Double.infinity, 2, Double.infinity, Double.nan])
	internal func outOfRangeIntensitiesNeverMakeItClearerThanTheMinimumOrPastSolid(_ intensity: Double) {
		let value = opacity(intensity)
		#expect(value >= TranslucentChrome.minimumOpacity)
		#expect(value <= 1)
	}

	@Test(arguments: [0, 0.2, 0.5])
	internal func reduceTransparencyMakesItSolid(_ intensity: Double) {
		#expect(opacity(intensity, reduceTransparency: true) == 1)
	}

	@Test(arguments: [0, 0.2, 0.5])
	internal func increaseContrastMakesItSolid(_ intensity: Double) {
		#expect(opacity(intensity, increaseContrast: true) == 1)
	}

	@Test(arguments: [0, 0.2, 0.5])
	internal func withTheFlagOffItsSolid(_ intensity: Double) {
		#expect(opacity(intensity, isEnabled: false) == 1)
	}

	@Test
	internal func theFlagIsOnByDefaultAndOffTurnsItOff() throws {
		let defaults = try #require(UserDefaults(suiteName: "TranslucentChromeTests.\(UUID().uuidString)"))
		#expect(TranslucentChrome.isEnabled(environment: [:], defaults: defaults))
		#expect(!TranslucentChrome.isEnabled(environment: [TranslucentChrome.featureFlag: "off"], defaults: defaults))
		#expect(TranslucentChrome.featureFlag == "ARX_TRANSLUCENT_CHROME")
		#expect(FeatureFlag.translucentChrome.needsRelaunch)
	}

	private func opacity(
		_ intensity: Double,
		isEnabled: Bool = true,
		reduceTransparency: Bool = false,
		increaseContrast: Bool = false
	) -> Double {
		TranslucentChrome.opacity(
			intensity: intensity,
			isEnabled: isEnabled,
			reduceTransparency: reduceTransparency,
			increaseContrast: increaseContrast
		)
	}
}
