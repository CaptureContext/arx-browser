import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-919: a space's or profile's gradient of two or three colors at an angle.
internal struct ChromeGradientTests {
	private let gradient: ChromeGradient = .init(
		stops: [.init(hue: 300, intensity: 0.4), .init(hue: 30, intensity: 0.4)],
		angle: 90
	)

	@Test
	internal func aSpacesGradientWinsOverItsProfilesAndPlainChoosesTheTintsOwn() {
		let profile = AppearanceOverride(gradient: gradient)
		let resolved = AppearanceOverride().over(profile).applied(to: .default)
		expectNoDifference(resolved.gradient, gradient)

		let plain = AppearanceOverride(gradient: .plain).over(profile).applied(to: .default)
		#expect(plain.gradient == nil)
		#expect(AppearanceOverride().applied(to: .default).gradient == nil)
		#expect(AppearanceOverride(gradient: gradient).overridesTint)
		#expect(AppearanceOverride(gradient: gradient).inheritingTint().gradient == nil)
	}

	@Test
	internal func gradientsAreRepairedOrRefused() {
		let wide = ChromeGradient(stops: gradient.stops + [.init(hue: 90, intensity: 1)], angle: -90)
		expectNoDifference(wide.normalized, .init(stops: gradient.stops, angle: 270))
		#expect(ChromeGradient(stops: [.init(hue: .nan, intensity: 1)]).normalized == nil)
		#expect(ChromeGradient(stops: gradient.stops, angle: .infinity).normalized == nil)
		// A broken gradient falls back to the level above's.
		let broken = AppearanceOverride(gradient: .init(stops: gradient.stops, angle: .nan))
		#expect(broken.applied(to: .init(gradient: gradient)).gradient == gradient)
	}

	@Test
	internal func appearancesWithoutAGradientStillDecode() throws {
		let data = try JSONEncoder().encode(AppearanceOverride(tintHue: 10))
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["gradient"] = nil
		let decoded = try JSONDecoder().decode(AppearanceOverride.self, from: JSONSerialization.data(withJSONObject: values))
		expectNoDifference(decoded, .init(tintHue: 10))

		let saved = try JSONDecoder().decode(
			AppearanceOverride.self,
			from: JSONEncoder().encode(AppearanceOverride(gradient: gradient))
		)
		expectNoDifference(saved.gradient, gradient)
	}
}
