import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct MatchSiteBackgroundTests {
	private let navy: ChromePalette.RGB = .init(argb: 0xFF10_2040)
	private let paper: ChromePalette.RGB = .init(argb: 0xFFFA_F7F0)

	// MARK: - Picking the color

	@Test
	internal func theDeclaredThemeColorWinsOverTheBackground() {
		let page = navigation("https://example.com", colors: .init(theme: navy, background: paper))
		expectNoDifference(MatchSiteBackground.color(of: page), navy)
	}

	@Test
	internal func withoutAThemeColorTheBackgroundIsUsed() {
		let page = navigation("https://example.com", colors: .init(background: paper))
		expectNoDifference(MatchSiteBackground.color(of: page), paper)
	}

	@Test
	internal func aPageWithNoColorOffersNone() {
		#expect(MatchSiteBackground.color(of: navigation("https://example.com")) == nil)
	}

	/// The engine picks the `theme-color` tag whose `media` matches the page's scheme, so the color
	/// it reports for the dark scheme is the one the chrome takes, and a change follows.
	@Test
	internal func theThemeColorTheEngineChoseForTheSchemeIsTheOneUsed() {
		let light = navigation("https://example.com", colors: .init(theme: paper, background: paper))
		let dark = navigation("https://example.com", colors: .init(theme: navy, background: paper))
		expectNoDifference(MatchSiteBackground.color(of: light), paper)
		expectNoDifference(MatchSiteBackground.color(of: dark), navy)
	}

	@Test(arguments: [
		"about:blank",
		"arx://settings",
		"file:///Users/someone/page.html",
	])
	internal func pagesThatArentOrdinaryWebPagesOfferNone(address: String) {
		let page = navigation(address, colors: .init(theme: navy, background: paper))
		#expect(MatchSiteBackground.color(of: page) == nil)
	}

	@Test
	internal func aFailedOrUnloadedPageOffersNone() {
		var failed = navigation("https://example.com", colors: .init(theme: navy))
		failed.errorCode = -105
		var unloaded = navigation("https://example.com", colors: .init(theme: navy))
		unloaded.isUnloaded = true

		#expect(MatchSiteBackground.color(of: failed) == nil)
		#expect(MatchSiteBackground.color(of: unloaded) == nil)
	}

	@Test
	internal func engineColorsKeepAnOpaqueThemeAndOnlyAnOpaqueBackground() {
		expectNoDifference(
			PageColors(themeARGB: 0x80FF_0000, backgroundARGB: 0x80FF_FFFF),
			.init(theme: .init(red: 1, green: 0, blue: 0), background: nil)
		)
		expectNoDifference(
			PageColors(themeARGB: 0x00FF_0000, backgroundARGB: 0xFF00_00FF),
			.init(theme: nil, background: .init(red: 0, green: 0, blue: 1))
		)
		expectNoDifference(PageColors(themeARGB: nil, backgroundARGB: nil), .none)
	}

	// MARK: - Split views

	@Test
	internal func panesOfOneSiteTakeTheActivePanesColor() {
		let panes = [
			navigation("https://www.example.com/a", colors: .init(theme: navy)),
			navigation("https://example.com/b", colors: .init(theme: paper)),
		]
		expectNoDifference(MatchSiteBackground.color(panes: panes, active: 1), paper)
		expectNoDifference(MatchSiteBackground.color(panes: panes, active: 0), navy)
	}

	@Test
	internal func panesOfDifferentSitesKeepTheSpacesColor() {
		let panes = [
			navigation("https://example.com", colors: .init(theme: navy)),
			navigation("https://example.org", colors: .init(theme: navy)),
		]
		#expect(MatchSiteBackground.color(panes: panes, active: 0) == nil)
	}

	@Test
	internal func anEmptyPaneBesideASiteKeepsTheSpacesColor() {
		let panes = [
			navigation("https://example.com", colors: .init(theme: navy)),
			BrowserNavigation(),
		]
		#expect(MatchSiteBackground.color(panes: panes, active: 0) == nil)
	}

	@Test
	internal func aSinglePaneIsItsOwnSite() {
		let panes = [navigation("https://example.com", colors: .init(background: paper))]
		expectNoDifference(MatchSiteBackground.color(panes: panes, active: 0), paper)
		#expect(MatchSiteBackground.color(panes: panes, active: 3) == nil)
	}

	// MARK: - Legibility

	private static let siteColors: [UInt32] = [
		0xFF00_0000, 0xFFFF_FFFF, 0xFF10_2040, 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF,
		0xFFFF_FF00, 0xFF00_FFFF, 0xFFFF_00FF, 0xFF1D_A1F2, 0xFFE5_0914, 0xFF80_8080,
	]

	@Test(arguments: siteColors)
	internal func everyStopKeepsArxsTextAtSevenToOne(argb: UInt32) {
		for surface in ChromePalette.Surface.allCases {
			for isDark in [false, true] {
				let palette = ChromePalette(site: .init(argb: argb), surface: surface, isDark: isDark)
				for stop in [palette.top, palette.bottom] {
					let text: Double = isDark ? 1 : 0
					#expect(
						Self.contrast(stop, text: text) >= 7,
						"\(String(argb, radix: 16)) \(surface) dark: \(isDark)"
					)
				}
			}
		}
	}

	@Test(arguments: siteColors)
	internal func theTopStopStaysInItsLightnessBand(argb: UInt32) {
		for surface in ChromePalette.Surface.allCases {
			for isDark in [false, true] {
				let palette = ChromePalette(site: .init(argb: argb), surface: surface, isDark: isDark)
				let band = ChromePalette.SiteAdjustment.lightness(surface, isDark: isDark)
				#expect(band.contains(palette.top.luma.rounded(toPlaces: 6)))
			}
		}
	}

	@Test
	internal func aDarkSiteDarkensLightChromeOnlyToItsBand() {
		let palette = ChromePalette(site: .init(argb: 0xFF00_0000), surface: .sidebar, isDark: false)
		expectNoDifference(palette.top.luma.rounded(toPlaces: 6), 0.8)

		// No color in black, so the chrome is grey.
		#expect(abs(palette.top.red - palette.top.blue) < 0.0001)
	}

	@Test
	internal func aSaturatedSiteIsSoftenedButKeepsItsHue() {
		let red = ChromePalette(site: .init(argb: 0xFFE5_0914), surface: .sidebar, isDark: false)
		#expect(red.top.red > red.top.green)
		#expect(red.top.red > red.top.blue)
		// Softened: far from the site's own full red.
		#expect(red.top.red - min(red.top.green, red.top.blue) < 0.3)
	}

	@Test
	internal func increasedContrastKeepsTheShippedLightnessAndLessColor() {
		let site: ChromePalette.RGB = .init(argb: 0xFF1D_A1F2)
		for isDark in [false, true] {
			let shipped = ChromePalette.shipped(.sidebar, isDark: isDark)
			let standard = ChromePalette(site: site, surface: .sidebar, isDark: isDark)
			let increased = ChromePalette(site: site, surface: .sidebar, isDark: isDark, increasedContrast: true)
			expectNoDifference(increased.top.luma.rounded(toPlaces: 6), shipped.top.luma.rounded(toPlaces: 6))
			#expect(Self.chroma(increased.top) < Self.chroma(standard.top))
		}
	}

	@Test
	internal func theStopsKeepTheShippedStepBetweenTopAndBottom() {
		for surface in ChromePalette.Surface.allCases {
			for isDark in [false, true] {
				let shipped = ChromePalette.shipped(surface, isDark: isDark)
				let palette = ChromePalette(site: navy, surface: surface, isDark: isDark)
				expectNoDifference(
					(palette.bottom.luma - palette.top.luma).rounded(toPlaces: 6),
					(shipped.bottom.luma - shipped.top.luma).rounded(toPlaces: 6)
				)
			}
		}
	}

	// MARK: - The space's choice

	@Test
	internal func aSpaceChoosesMatchSiteOverItsProfile() {
		let space = AppearanceOverride(matchesSite: true)
		expectNoDifference(space.over(.init(tintHue: 30)), .init(tintHue: 30, matchesSite: true))
		#expect(AppearanceOverride().over(.init(matchesSite: true)).matchesSite == true)
	}

	@Test
	internal func anOverrideSavedBeforeMatchSiteDecodesWithoutIt() throws {
		let saved = Data(#"{"tintHue":120,"grainEnabled":false}"#.utf8)
		let decoded = try JSONDecoder().decode(AppearanceOverride.self, from: saved)
		expectNoDifference(decoded, .init(tintHue: 120, grainEnabled: false))

		let chosen = AppearanceOverride(tintHue: 120, matchesSite: true)
		let roundTrip = try JSONDecoder().decode(AppearanceOverride.self, from: JSONEncoder().encode(chosen))
		expectNoDifference(roundTrip, chosen)
	}

	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let defaults = try #require(UserDefaults(suiteName: "MatchSiteBackgroundTests"))
		defaults.removePersistentDomain(forName: "MatchSiteBackgroundTests")

		// On by default (DEV-1143).
		#expect(MatchSiteBackground.isEnabled(environment: [:], defaults: defaults))
		#expect(!MatchSiteBackground.isEnabled(environment: [MatchSiteBackground.featureFlag: "0"], defaults: defaults))
		defaults.set("no", forKey: MatchSiteBackground.featureFlag)
		#expect(!MatchSiteBackground.isEnabled(environment: [:], defaults: defaults))
		#expect(MatchSiteBackground.isEnabled(environment: [MatchSiteBackground.featureFlag: "1"], defaults: defaults))
		defaults.removePersistentDomain(forName: "MatchSiteBackgroundTests")
	}

	// MARK: - Helpers

	private func navigation(
		_ address: String,
		colors: PageColors = .none
	) -> BrowserNavigation {
		.init(url: URL(string: address), colors: colors)
	}

	/// WCAG 2 contrast between a stop and black (`0`) or white (`1`) text.
	private static func contrast(
		_ color: ChromePalette.RGB,
		text: Double
	) -> Double {
		func linear(_ component: Double) -> Double {
			component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
		}
		let luminance = 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
		let lighter = max(luminance, text)
		let darker = min(luminance, text)
		return (lighter + 0.05) / (darker + 0.05)
	}

	/// How far a stop is from grey, as its spread of components.
	private static func chroma(_ color: ChromePalette.RGB) -> Double {
		max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
	}
}

extension Double {
	fileprivate func rounded(toPlaces places: Int) -> Double {
		let scale = pow(10, Double(places))
		return (self * scale).rounded() / scale
	}
}
