import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct ChromeAccentTests {
	private let red: ChromeAccent = ChromeAccent.Preset.red.accent
	private let green: ChromeAccent = ChromeAccent.Preset.green.accent
	private let teal: ChromeAccent = ChromeAccent.Preset.teal.accent

	// MARK: - Resolution

	@Test
	internal func theMostSpecificAccentWins() {
		let global = ChromeAppearance(accent: red)
		let profile = AppearanceOverride(accent: green)
		let space = AppearanceOverride(accent: teal)

		expectNoDifference(ChromeAppearance.resolve(global: global, profile: nil, space: nil).accent, red)
		expectNoDifference(ChromeAppearance.resolve(global: global, profile: profile, space: nil).accent, green)
		expectNoDifference(ChromeAppearance.resolve(global: global, profile: profile, space: space).accent, teal)
	}

	@Test
	internal func clearingAnOverrideFallsBackToTheLevelAbove() {
		let global = ChromeAppearance(accent: red)
		let profile = AppearanceOverride(tintHue: 30, accent: green)
		let space = AppearanceOverride(accent: teal)

		expectNoDifference(
			ChromeAppearance.resolve(global: global, profile: profile, space: space.inheritingAccent()).accent,
			green
		)
		expectNoDifference(
			ChromeAppearance.resolve(global: global, profile: profile.inheritingAccent(), space: nil).accent,
			red
		)

		// Clearing the accent keeps the profile's other choices.
		expectNoDifference(profile.inheritingAccent(), .init(tintHue: 30))
		#expect(ChromeAppearance.resolve(global: .init(), profile: nil, space: nil).accent == nil)
	}

	@Test
	internal func aSpacesAccentAndMatchSiteAreChosenApart() {
		let space = AppearanceOverride(matchesSite: true, accent: teal)
		let resolved = ChromeAppearance.resolve(global: .init(), profile: nil, space: space)
		expectNoDifference(resolved.accent, teal)

		// With Match site, the site sets the background and the accent stays the chosen one.
		let site = ChromePalette(site: .init(argb: 0xFF10_2040), surface: .sidebar, isDark: false)
		let accent = ChromeAccent.resolve(
			resolved.accent,
			tint: resolved.tint,
			background: site.top.mixed(with: site.bottom),
			isDark: false
		)
		#expect(accent.contrast(with: site.top.mixed(with: site.bottom)) >= ChromeAccent.minimumContrast(isDark: false))
		#expect(Self.hue(of: accent).distance(to: Self.hue(of: teal.rgb)) < 2)
	}

	// MARK: - Automatic

	@Test(arguments: [false, true])
	internal func automaticKeepsArxsAccentForTheDefaultTint(isDark: Bool) {
		expectNoDifference(ChromeAccent.automatic(tint: .default, isDark: isDark), ChromeAccent.shipped(isDark: isDark))
	}

	@Test
	internal func automaticTurnsWithTheSpacesTint() {
		let shipped = ChromeAccent.shipped(isDark: false)
		let orange = ChromeAccent.automatic(tint: .init(hue: 30, intensity: 0.5), isDark: false)
		#expect(abs(Self.hue(of: orange) - (Self.hue(of: shipped) - 210 + 360).truncatingRemainder(dividingBy: 360)) < 1)
		expectNoDifference(Self.brightness(of: orange).rounded(toPlaces: 3), Self.brightness(of: shipped).rounded(toPlaces: 3))
	}

	// MARK: - Contrast

	@Test(arguments: ChromeAccent.Preset.allCases)
	internal func everyPresetReadsOnTheSidebar(preset: ChromeAccent.Preset) {
		for isDark in [false, true] {
			let sidebar = ChromePalette(tint: .default, surface: .sidebar, isDark: isDark)
			let background = sidebar.top.mixed(with: sidebar.bottom)
			let accent = ChromeAccent.resolve(preset.accent, tint: .default, background: background, isDark: isDark)
			#expect(accent.contrast(with: background) >= ChromeAccent.minimumContrast(isDark: isDark), "\(preset) dark: \(isDark)")
		}
	}

	@Test
	internal func aPaleAccentDarkensOnLightChromeAndKeepsItsHue() {
		let yellow = ChromeAccent.Preset.yellow.accent.rgb
		let sidebar = ChromePalette(tint: .default, surface: .sidebar, isDark: false)
		let background = sidebar.top.mixed(with: sidebar.bottom)
		#expect(yellow.contrast(with: background) < ChromeAccent.minimumContrast(isDark: false))

		let legible = ChromeAccent.legible(yellow, on: background, isDark: false)
		#expect(legible.contrast(with: background) >= ChromeAccent.minimumContrast(isDark: false))
		#expect(Self.brightness(of: legible) < Self.brightness(of: yellow))
		#expect(Self.hue(of: legible).distance(to: Self.hue(of: yellow)) < 2)
	}

	@Test
	internal func aDarkAccentLightensOnDarkChrome() {
		let deep = ChromeAccent(red: 0.15, green: 0.1, blue: 0.4).rgb
		let sidebar = ChromePalette(tint: .default, surface: .sidebar, isDark: true)
		let background = sidebar.top.mixed(with: sidebar.bottom)
		let legible = ChromeAccent.legible(deep, on: background, isDark: true)
		#expect(legible.contrast(with: background) >= ChromeAccent.minimumContrast(isDark: true))
		#expect(Self.brightness(of: legible) > Self.brightness(of: deep))
	}

	@Test(arguments: [false, true])
	internal func arxsOwnAccentNeedsNoAdjustingOnItsOwnSidebar(isDark: Bool) {
		let sidebar = ChromePalette(tint: .default, surface: .sidebar, isDark: isDark)
		let shipped = ChromeAccent.shipped(isDark: isDark)
		expectNoDifference(
			ChromeAccent.resolve(nil, tint: .default, background: sidebar.top.mixed(with: sidebar.bottom), isDark: isDark),
			shipped
		)
		#expect(ChromeAccent.minimumContrast(isDark: false) == 3)
	}

	@Test(arguments: [0.0, 0.1, 0.2])
	internal func aBlackOrGreyAccentBrightensUntilItReadsOnDarkChrome(level: Double) {
		let grey = ChromePalette.RGB(red: level, green: level, blue: level)
		let sidebar = ChromePalette(tint: .default, surface: .sidebar, isDark: true)
		let background = sidebar.top.mixed(with: sidebar.bottom)
		let legible = ChromeAccent.legible(grey, on: background, isDark: true)
		#expect(legible.contrast(with: background) >= ChromeAccent.minimumContrast(isDark: true))
	}

	@Test
	internal func anAccentThatAlreadyReadsIsLeftAlone() {
		let sidebar = ChromePalette(tint: .default, surface: .sidebar, isDark: false)
		let background = sidebar.top.mixed(with: sidebar.bottom)
		let indigo = ChromeAccent.shipped(isDark: false)
		expectNoDifference(ChromeAccent.legible(indigo, on: background, isDark: false), indigo)
	}

	// MARK: - Saving

	@Test
	internal func preferencesSavedBeforeAccentsAreAutomatic() throws {
		var preferences = BrowserPreferences()
		preferences.chromeAccent = red
		let encoded = try JSONEncoder().encode(preferences)
		var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		expectNoDifference(try JSONDecoder().decode(BrowserPreferences.self, from: encoded).chromeAppearance.accent, red)

		object.removeValue(forKey: "chromeAccent")
		let older = try JSONSerialization.data(withJSONObject: object)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: older).chromeAccent == nil)
	}

	@Test
	internal func anOverrideSavedBeforeAccentsInherits() throws {
		let saved = Data(#"{"tintHue":120}"#.utf8)
		#expect(try JSONDecoder().decode(AppearanceOverride.self, from: saved).accent == nil)
		let chosen = AppearanceOverride(accent: green)
		expectNoDifference(try JSONDecoder().decode(AppearanceOverride.self, from: JSONEncoder().encode(chosen)), chosen)
	}

	@Test
	internal func agentsReadAndChooseTheAppWideAccent() throws {
		var preferences = BrowserPreferences()
		expectNoDifference(AutomationPreferenceKey.accentColor.value(in: preferences), .string("automatic"))

		preferences = try preferences.applying([.init(key: .accentColor, value: .string("red"))])
		expectNoDifference(preferences.chromeAccent, red)
		expectNoDifference(AutomationPreferenceKey.accentColor.value(in: preferences), .string("red"))

		// Automatic clears the color rather than keeping the current one.
		preferences = try preferences.applying([.init(key: .accentColor, value: .string("automatic"))])
		#expect(preferences.chromeAccent == nil)

		// A custom color reads back as itself, so undo can restore it.
		preferences.chromeAccent = .init(red: 0.2, green: 0.4, blue: 0.6)
		expectNoDifference(AutomationPreferenceKey.accentColor.value(in: preferences), .string("#336699"))
		let restored = try BrowserPreferences().applying([.init(key: .accentColor, value: .string("#336699"))])
		expectNoDifference(restored.chromeAccent, .init(red: 0.2, green: 0.4, blue: 0.6))
		for invalid in ["custom", "#12345", "#GGGGGG", "336699"] {
			#expect(throws: AutomationFailure.invalidValue) {
				try preferences.applying([.init(key: .accentColor, value: .string(invalid))])
			}
		}
	}

	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let defaults = try #require(UserDefaults(suiteName: "ChromeAccentTests"))
		defaults.removePersistentDomain(forName: "ChromeAccentTests")

		// On by default (DEV-1143).
		#expect(ChromeAccent.isEnabled(environment: [:], defaults: defaults))
		#expect(!ChromeAccent.isEnabled(environment: [ChromeAccent.featureFlag: "false"], defaults: defaults))
		defaults.set("off", forKey: ChromeAccent.featureFlag)
		#expect(!ChromeAccent.isEnabled(environment: [:], defaults: defaults))
		defaults.removePersistentDomain(forName: "ChromeAccentTests")
	}

	// MARK: - Helpers

	private static func hue(of color: ChromePalette.RGB) -> Double {
		let largest = max(color.red, color.green, color.blue)
		let delta = largest - min(color.red, color.green, color.blue)
		guard delta > 0 else { return 0 }
		let hue: Double = if largest == color.red {
			60 * ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
		} else if largest == color.green {
			60 * ((color.blue - color.red) / delta + 2)
		} else {
			60 * ((color.red - color.green) / delta + 4)
		}
		return hue < 0 ? hue + 360 : hue
	}

	private static func brightness(of color: ChromePalette.RGB) -> Double {
		max(color.red, color.green, color.blue)
	}
}

extension Double {
	/// The shorter way round the color wheel between two hues.
	fileprivate func distance(to other: Double) -> Double {
		let difference = abs(self - other).truncatingRemainder(dividingBy: 360)
		return min(difference, 360 - difference)
	}

	fileprivate func rounded(toPlaces places: Int) -> Double {
		let scale = pow(10, Double(places))
		return (self * scale).rounded() / scale
	}
}
