import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct ChromeAppearanceTests {
	private let global: ChromeAppearance = .init(
		tint: .init(hue: 30, intensity: 0.5),
		grain: .init(isEnabled: true, intensity: 0.3, size: 2)
	)

	// MARK: - Resolution

	@Test
	internal func withoutOverridesTheGlobalAppearanceApplies() {
		expectNoDifference(ChromeAppearance.resolve(global: global, profile: nil, space: nil), global)
		expectNoDifference(ChromeAppearance.resolve(global: global, profile: .init(), space: .init()), global)
	}

	@Test
	internal func aProfileOverridesOnlyWhatItChooses() {
		let profile = AppearanceOverride(tintHue: 200, grainEnabled: false)
		expectNoDifference(
			ChromeAppearance.resolve(global: global, profile: profile, space: nil),
			.init(
				tint: .init(hue: 200, intensity: 0.5),
				grain: .init(isEnabled: false, intensity: 0.3, size: 2)
			)
		)
	}

	@Test
	internal func aSpaceWinsOverItsProfileOneSettingAtATime() {
		let profile = AppearanceOverride(tintHue: 200, tintIntensity: 0.9, grainSize: 3)

		// The space changes only the tint's hue: intensity comes from the profile and grain from both levels above.
		let space = AppearanceOverride(tintHue: 120, grainIntensity: 0.6)
		expectNoDifference(
			ChromeAppearance.resolve(global: global, profile: profile, space: space),
			.init(
				tint: .init(hue: 120, intensity: 0.9),
				grain: .init(isEnabled: true, intensity: 0.6, size: 3)
			)
		)
	}

	@Test
	internal func clearingASpaceFallsBackToItsProfileThenToTheGlobalAppearance() {
		let profile = AppearanceOverride(tintIntensity: 0)
		let space = AppearanceOverride(tintIntensity: 1, grainEnabled: false)
		expectNoDifference(
			ChromeAppearance.resolve(global: global, profile: profile, space: space.inheritingTint()).tint.intensity,
			0
		)
		expectNoDifference(
			ChromeAppearance.resolve(global: global, profile: profile, space: space.inheritingGrain()).grain,
			global.grain
		)
		expectNoDifference(ChromeAppearance.resolve(global: global, profile: nil, space: nil), global)
	}

	@Test
	internal func outOfRangeOverridesAreClampedAndNonNumbersIgnored() {
		let resolved = AppearanceOverride(
			tintHue: -30,
			tintIntensity: 4,
			grainIntensity: .nan,
			grainSize: 9
		).applied(to: global)
		expectNoDifference(resolved.tint, .init(hue: 330, intensity: 1))
		expectNoDifference(resolved.grain.intensity, 0)
		expectNoDifference(resolved.grain.size, 3)

		expectNoDifference(AppearanceOverride(tintHue: .infinity).applied(to: global).tint, global.tint)
	}

	@Test
	internal func organizationMergesTheSpaceOverItsProfile() throws {
		var organization = fixture()
		let space = organization.spaces[0]
		organization = try organization.applying(
			.setProfileAppearance(space.profileID, .init(theme: .dark, tintHue: 10)),
			uuid: { UUID() }
		)
		organization = try organization.applying(
			.setSpaceAppearance(space.id, .init(grainEnabled: false)),
			uuid: { UUID() }
		)
		expectNoDifference(
			organization.appearance(ofSpace: space.id),
			.init(theme: .dark, tintHue: 10, grainEnabled: false)
		)
	}

	@Test
	internal func settingAnEmptyOverrideClearsIt() throws {
		var organization = fixture()
		let space = organization.spaces[0]
		organization = try organization.applying(.setSpaceAppearance(space.id, .init(tintHue: 10)), uuid: { UUID() })
		organization = try organization.applying(
			.setProfileAppearance(space.profileID, .init(tintIntensity: 0.4)),
			uuid: { UUID() }
		)
		organization = try organization.applying(.setSpaceAppearance(space.id, .init()), uuid: { UUID() })
		organization = try organization.applying(.setProfileAppearance(space.profileID, .init()), uuid: { UUID() })
		expectNoDifference(organization.spaces[0].appearance, nil)
		expectNoDifference(organization.profiles[0].appearance, nil)
	}

	// MARK: - Persistence

	@Test
	internal func appearanceRoundTripsThroughPreferencesAndTheOrganization() throws {
		var preferences = BrowserPreferences()
		preferences.chromeAppearance = global
		let decodedPreferences = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONEncoder().encode(preferences)
		)
		expectNoDifference(decodedPreferences.chromeAppearance, global)

		var organization = fixture()
		organization.profiles[0].appearance = .init(tintHue: 300, grainSize: 1.5)
		organization.spaces[0].appearance = .init(theme: .light, tintIntensity: 0.7, grainEnabled: false)
		let decodedOrganization = try JSONDecoder().decode(
			BrowserOrganization.self,
			from: JSONEncoder().encode(organization)
		)
		expectNoDifference(decodedOrganization, organization)
	}

	@Test
	internal func filesFromBeforeTintsDecodeWithTheShippedLook() throws {
		let preferences = Data(#"{"grainEnabled":false,"grainIntensity":0.35,"grainSize":2,"searchShortcuts":[]}"#.utf8)
		expectNoDifference(
			try JSONDecoder().decode(BrowserPreferences.self, from: preferences).chromeAppearance,
			.init(tint: .default, grain: .init(isEnabled: false, intensity: 0.35, size: 2))
		)

		let override = Data(#"{"theme":"dark","grainEnabled":false}"#.utf8)
		expectNoDifference(
			try JSONDecoder().decode(AppearanceOverride.self, from: override),
			.init(theme: .dark, grainEnabled: false)
		)
	}

	@Test
	internal func overridesLeaveUnchosenSettingsOutOfTheFile() throws {
		let data = try JSONEncoder().encode(AppearanceOverride(tintHue: 90))
		let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		expectNoDifference(object.keys.sorted(), ["tintHue"])
	}

	// MARK: - Palette

	@Test(arguments: ChromePalette.Surface.allCases, [false, true])
	internal func theDefaultTintKeepsTheShippedColors(
		surface: ChromePalette.Surface,
		isDark: Bool
	) {
		let derived = ChromePalette(tint: .default, surface: surface, isDark: isDark)
		let shipped = ChromePalette.shipped(surface, isDark: isDark)
		for (lhs, rhs) in [(derived.top, shipped.top), (derived.bottom, shipped.bottom)] {
			#expect(abs(lhs.red - rhs.red) < 1e-6)
			#expect(abs(lhs.green - rhs.green) < 1e-6)
			#expect(abs(lhs.blue - rhs.blue) < 1e-6)
		}
	}

	@Test(arguments: ChromePalette.Surface.allCases, [false, true])
	internal func neutralIsGreyAtTheShippedLightness(
		surface: ChromePalette.Surface,
		isDark: Bool
	) {
		let neutral = ChromePalette(tint: .init(hue: 0, intensity: 0), surface: surface, isDark: isDark)
		let shipped = ChromePalette.shipped(surface, isDark: isDark)
		for (stop, reference) in [(neutral.top, shipped.top), (neutral.bottom, shipped.bottom)] {
			#expect(abs(stop.red - stop.green) < 1e-9 && abs(stop.green - stop.blue) < 1e-9)
			#expect(abs(stop.luma - reference.luma) < 1e-9)
		}
	}

	/// Hover, selection and the page hairline are drawn over these stops, so their lightness must hold.
	@Test(arguments: ChromePalette.Surface.allCases, [false, true])
	internal func everyTintKeepsItsLightnessInGamut(
		surface: ChromePalette.Surface,
		isDark: Bool
	) {
		let shipped = ChromePalette.shipped(surface, isDark: isDark)
		for hue in stride(from: 0.0, to: 360, by: 15) {
			for intensity in stride(from: 0.0, through: 1, by: 0.1) {
				let palette = ChromePalette(tint: .init(hue: hue, intensity: intensity), surface: surface, isDark: isDark)
				for (stop, reference) in [(palette.top, shipped.top), (palette.bottom, shipped.bottom)] {
					for component in [stop.red, stop.green, stop.blue] {
						#expect((0 ... 1).contains(component))
					}

					// Light stops darken by up to 0.04 to make room for color; dark ones keep their lightness.
					let drift = reference.luma - stop.luma
					#expect(drift > -1e-9 && drift <= (isDark ? 1e-9 : 0.04 + 1e-9))
				}
			}
		}
	}

	@Test
	internal func vibrantCarriesMoreColorThanTheDefault() {
		func chroma(_ rgb: ChromePalette.RGB) -> Double {
			max(rgb.red, rgb.green, rgb.blue) - min(rgb.red, rgb.green, rgb.blue)
		}
		for isDark in [false, true] {
			let standard = ChromePalette(tint: .default, surface: .sidebar, isDark: isDark)
			let vibrant = ChromePalette(tint: .init(intensity: 1), surface: .sidebar, isDark: isDark)
			#expect(chroma(vibrant.top) > 3 * chroma(standard.top))
		}
	}

	private func fixture() -> BrowserOrganization {
		let profile = Profile(id: .init(rawValue: UUID(1)), name: "Personal")
		return BrowserOrganization(
			profiles: [profile],
			spaces: [.init(id: .init(rawValue: UUID(2)), profileID: profile.id, name: "Home")]
		)
	}
}

extension UUID {
	fileprivate init(_ value: UInt8) {
		self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}
