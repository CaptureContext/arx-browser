@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// DEV-1117: what `BrowserTheme.accent` resolves to from the appearance in the environment.
@MainActor
internal struct BrowserAccentTests {
	@Test
	internal func withTheFeatureFlagOffArxsOwnAccentStays() {
		var environment = EnvironmentValues()
		environment.browserChromeAccent = ChromeAccent.Preset.red.accent
		expectSame(BrowserAccent().resolve(in: environment), Color.resource(.browser.accent).resolve(in: environment))
	}

	@Test(arguments: [ColorScheme.light, .dark])
	internal func automaticWithTheDefaultTintIsArxsAccent(scheme: ColorScheme) {
		var environment = EnvironmentValues()
		environment.browserAccentIsEnabled = true
		environment.colorScheme = scheme
		expectSame(
			BrowserAccent().resolve(in: environment),
			Color(ChromeAccent.shipped(isDark: scheme == .dark)).resolve(in: environment)
		)
	}

	@Test
	internal func theChosenAccentIsDrawnWhenItReads() {
		var environment = EnvironmentValues()
		environment.browserAccentIsEnabled = true
		environment.browserChromeAccent = ChromeAccent.Preset.red.accent
		expectSame(BrowserAccent().resolve(in: environment), Color(ChromeAccent.Preset.red.accent.rgb).resolve(in: environment))
	}

	@Test
	internal func aPaleAccentIsDarkenedToReadOnTheSidebar() {
		var environment = EnvironmentValues()
		environment.browserAccentIsEnabled = true
		environment.browserChromeAccent = ChromeAccent.Preset.yellow.accent
		let resolved = BrowserAccent().resolve(in: environment)
		let rgb = ChromePalette.RGB(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
		let sidebar = ChromePalette(tint: .default, surface: .sidebar, isDark: false)
		#expect(rgb.contrast(with: sidebar.top.mixed(with: sidebar.bottom)) >= ChromeAccent.minimumContrast(isDark: false) - 0.01)
	}

	private func expectSame(
		_ lhs: Color.Resolved,
		_ rhs: Color.Resolved,
		sourceLocation: SourceLocation = #_sourceLocation
	) {
		for (left, right) in [(lhs.red, rhs.red), (lhs.green, rhs.green), (lhs.blue, rhs.blue), (lhs.opacity, rhs.opacity)] {
			#expect(abs(left - right) < 0.002, "\(lhs) != \(rhs)", sourceLocation: sourceLocation)
		}
	}
}
