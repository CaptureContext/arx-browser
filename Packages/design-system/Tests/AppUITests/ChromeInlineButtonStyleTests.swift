@testable import AppUI
import SwiftUI
import Testing

/// The inline button style for buttons inside a control or a row (URL bar, tab rows).
internal struct ChromeInlineButtonStyleTests {
	/// The flag is on unless it says off, as Arx's other feature flags.
	@Test
	internal func featureFlagIsOnUnlessItSaysOff() {
		func isOn(_ value: String?) -> Bool {
			ChromeInlineButtons.isOn { $0 == ChromeInlineButtons.featureFlag ? value : nil }
		}

		#expect(ChromeInlineButtons.featureFlag == "ARX_INLINE_BUTTONS")
		#expect(isOn(nil))
		#expect(isOn("1"))
		#expect(isOn("on"))
		for off in ["0", "false", "no", "off", "OFF"] {
			#expect(!isOn(off))
		}
	}

	/// No shape at rest; hovered, black over the field or row, more in dark; pressed and under
	/// Increase Contrast add to it, so it's always a darker shade of what's under it.
	@Test
	internal func shapeIsADarkerShadeOfWhatsUnderIt() {
		func opacity(
			hovered: Bool = true,
			pressed: Bool = false,
			_ scheme: ColorScheme,
			_ contrast: ColorSchemeContrast = .standard
		) -> Double {
			ChromeInlineButtons.fillOpacity(hovered: hovered, pressed: pressed, colorScheme: scheme, contrast: contrast)
		}

		#expect(opacity(hovered: false, .light) == 0)
		#expect(opacity(hovered: false, .dark) == 0)
		#expect(opacity(.light) == 0.08)
		#expect(opacity(.dark) == 0.24)
		#expect(abs(opacity(pressed: true, .light) - 0.14) < 0.0001)
		#expect(abs(opacity(pressed: true, .dark) - 0.42) < 0.0001)
		#expect(abs(opacity(.light, .increased) - 0.12) < 0.0001)
		#expect(abs(opacity(hovered: false, pressed: true, .dark, .increased) - 0.54) < 0.0001)
	}
}
