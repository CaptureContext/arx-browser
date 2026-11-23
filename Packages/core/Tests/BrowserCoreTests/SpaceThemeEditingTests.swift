import BrowserCore
import CustomDump
import Foundation
import Testing

/// The state behind each control of the space theme editor (DEV-1253).
internal struct SpaceThemeEditingTests {
	private let inherited: ChromeAppearance = .init(
		tint: .init(hue: 30, intensity: 0.5),
		grain: .init(isEnabled: true, intensity: 0.3, size: 2),
		gradient: .init(stops: [.init(hue: 90, intensity: 0.5)], angle: 45)
	)

	// MARK: - Color field

	@Test
	internal func anInheritedTintShowsNoColors() {
		expectNoDifference(AppearanceOverride().themeColors(over: inherited), [])

		// Other choices don't make the tint this level's own.
		expectNoDifference(AppearanceOverride(theme: .dark, grainEnabled: false).themeColors(over: inherited), [])
	}

	@Test
	internal func placingTheFirstColorChoosesTheTintAlone() {
		let placed = AppearanceOverride().settingThemeColors([.init(hue: 200, intensity: 0.4)], over: inherited)
		expectNoDifference(placed.tintHue, 200)
		expectNoDifference(placed.tintIntensity, 0.4)

		// One color is the tint's own gradient, over the profile's two-color one.
		expectNoDifference(placed.gradient?.stops, [])
		expectNoDifference(placed.applied(to: inherited).gradient, nil)
		expectNoDifference(placed.themeColors(over: inherited), [.init(hue: 200, intensity: 0.4)])
	}

	@Test
	internal func moreColorsBecomeTheGradientsStopsAtTheInheritedAngle() {
		let colors: [ChromeTint] = [
			.init(hue: 10, intensity: 0.3),
			.init(hue: 120, intensity: 0.3),
			.init(hue: 250, intensity: 0.3),
		]
		let theme = AppearanceOverride().settingThemeColors(colors, over: inherited)
		expectNoDifference(theme.gradient, .init(stops: Array(colors.dropFirst()), angle: 45))
		expectNoDifference(theme.themeColors(over: inherited), colors)
	}

	@Test
	internal func aFourthColorIsDropped() {
		let colors = (0 ..< 4).map { ChromeTint(hue: Double($0) * 60, intensity: 0.2) }
		let theme = AppearanceOverride().settingThemeColors(colors, over: inherited)
		expectNoDifference(theme.themeColors(over: inherited), Array(colors.prefix(AppearanceOverride.maximumThemeColors)))
	}

	@Test
	internal func removingTheLastColorInheritsTheTintAgain() {
		let theme = AppearanceOverride(theme: .dark)
			.settingThemeColors([.init(hue: 200, intensity: 0.4)], over: inherited)
			.settingThemeColors([], over: inherited)
		expectNoDifference(theme, .init(theme: .dark))
		expectNoDifference(theme.applied(to: inherited).tint, inherited.tint)
	}

	// MARK: - Intensity

	@Test
	internal func theWaveSliderSetsEveryColorsIntensity() {
		let theme = AppearanceOverride()
			.settingThemeColors([.init(hue: 10, intensity: 0.2), .init(hue: 200, intensity: 0.6)], over: inherited)
			.settingThemeIntensity(0.8, over: inherited)
		expectNoDifference(
			theme.themeColors(over: inherited),
			[.init(hue: 10, intensity: 0.8), .init(hue: 200, intensity: 0.8)]
		)
	}

	@Test
	internal func theWaveSliderOverAnInheritedTintAdoptsItsColors() {
		let theme = AppearanceOverride().settingThemeIntensity(1.4, over: inherited)
		expectNoDifference(
			theme.themeColors(over: inherited),
			[.init(hue: 30, intensity: 1), .init(hue: 90, intensity: 1)]
		)
	}

	// MARK: - Texture dial

	@Test
	internal func theInnerCircleCyclesNoiseJeansPaperTextileClear() {
		var texture: ChromeGrain.Texture? = .noise
		var seen: [ChromeGrain.Texture?] = []
		for _ in 0 ..< 5 {
			texture = AppearanceOverride.nextThemeTexture(after: texture)
			seen.append(texture)
		}
		expectNoDifference(seen, [.jeans, .paper, .textile, nil, .noise])
	}

	@Test
	internal func aTextureTurnsTheGrainOnAndClearTurnsItOff() {
		let jeans = AppearanceOverride().settingThemeTexture(.jeans)
		expectNoDifference(jeans.applied(to: inherited).grain, .init(isEnabled: true, intensity: 0.3, size: 2, texture: .jeans))
		expectNoDifference(jeans.themeTexture(over: inherited), .jeans)

		let clear = jeans.settingThemeTexture(nil)
		expectNoDifference(clear.themeTexture(over: inherited), nil)

		// Clear keeps the texture, so the dial comes back to it.
		expectNoDifference(clear.grainTexture, .jeans)
	}

	@Test
	internal func inheritingTheGrainDropsTheTexture() {
		let theme = AppearanceOverride(grainIntensity: 0.9).settingThemeTexture(.paper).inheritingGrain()
		expectNoDifference(theme, .init())
		expectNoDifference(theme.themeTexture(over: inherited), .noise)
	}

	@Test
	internal func aProfilesTextureReachesItsSpaces() {
		let profile = AppearanceOverride(grainTexture: .paper)
		let space = AppearanceOverride(grainIntensity: 0.5)
		expectNoDifference(
			ChromeAppearance.resolve(global: inherited, profile: profile, space: space).grain,
			.init(isEnabled: true, intensity: 0.5, size: 2, texture: .paper)
		)
	}

	// MARK: - Coding

	@Test
	internal func theTextureRoundTripsAndOlderGrainDecodesAsNoise() throws {
		let theme = AppearanceOverride(grainTexture: .jeans)
		let decoded = try JSONDecoder().decode(AppearanceOverride.self, from: JSONEncoder().encode(theme))
		expectNoDifference(decoded, theme)

		let older = Data(#"{"isEnabled":true,"intensity":0.2,"size":1}"#.utf8)
		expectNoDifference(try JSONDecoder().decode(ChromeGrain.self, from: older).texture, .noise)
	}
}
