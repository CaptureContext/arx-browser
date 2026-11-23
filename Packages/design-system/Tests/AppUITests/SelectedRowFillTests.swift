@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// The selected tab's fill is opaque, so the chrome's grain never shows through it.
@MainActor
internal struct SelectedRowFillTests {
	@Test(arguments: [false, true])
	internal func theSelectedRowIsOpaque(isDark: Bool) {
		let fill = BrowserTheme.selectedRow.resolve(in: Self.environment(isDark: isDark, tint: .default))
		#expect(fill.opacity == 1)
	}

	@Test(arguments: [false, true])
	internal func itReadsAsTheTranslucentSelectionOverTheSidebar(isDark: Bool) {
		let environment = Self.environment(isDark: isDark, tint: .default)
		let fill = BrowserTheme.selectedRow.resolve(in: environment)
		let selection = BrowserTheme.selection.resolve(in: environment)
		let palette = ChromePalette(tint: .default, surface: .sidebar, isDark: isDark)
		let base = (palette.top.red + palette.bottom.red) / 2
		let expected = base * (1 - Double(selection.opacity)) + Double(selection.red) * Double(selection.opacity)
		#expect(abs(Double(fill.red) - expected) < 0.002)
		// Lighter than the sidebar, as the selected row always was.
		#expect(Double(fill.red) > base)
	}

	@Test
	internal func itFollowsTheSpacesTint() {
		let neutral = BrowserTheme.selectedRow.resolve(in: Self.environment(isDark: true, tint: .default))
		let tinted = BrowserTheme.selectedRow.resolve(
			in: Self.environment(isDark: true, tint: .init(hue: 20, intensity: 1))
		)
		#expect(neutral != tinted)
	}

	private static func environment(
		isDark: Bool,
		tint: ChromeTint
	) -> EnvironmentValues {
		var environment = EnvironmentValues()
		environment.colorScheme = isDark ? .dark : .light
		environment.browserChromeTint = tint
		return environment
	}
}
