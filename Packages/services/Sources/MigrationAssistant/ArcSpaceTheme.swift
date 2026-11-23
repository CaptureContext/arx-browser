import BrowserCore
import Foundation

/// Reads an Arc space's colors from `customInfo.windowTheme` in `StorableSidebar.json`
/// (DEV-897, DEV-919) and maps them onto an Arx appearance override.
///
/// Arc's theme is undocumented. What's read, as other importers read it: colors are
/// dictionaries with `red`, `green` and `blue`; the space's main color is
/// `primaryColorPalette.midTone`; a gradient is the first `baseColors` list. Anything else
/// is ignored, and a theme without a readable color gives no override, so the space keeps
/// Arx's default look.
///
/// Arx stores colors as hue plus intensity (Max's call on DEV-919), so the mapping is
/// approximate: each color becomes `ChromeTint(approximating:)`, the mid tone the space's
/// tint and up to two more gradient colors its gradient stops, at Arx's default angle
/// because Arc's angle isn't known.
internal enum ArcSpaceTheme {
	/// Bounds on the walk through a theme, which comes from a file Arx didn't write.
	private static let maximumDepth: Int = 12
	private static let maximumNodes: Int = 2048

	internal static func appearance(_ windowTheme: Any?) -> AppearanceOverride? {
		guard let theme = windowTheme as? [String: Any] else { return nil }

		let gradient = gradientColors(theme)
		let midTone = color((theme["primaryColorPalette"] as? [String: Any])?["midTone"])
		?? gradient.first
		?? firstColor(theme)
		guard let midTone else { return nil }

		let tint: ChromeTint = .init(approximating: midTone)

		// The tint stands for the gradient's first color, so the stops are the ones after it.
		let stops = gradient.dropFirst().prefix(ChromeGradient.maximumStops).map(ChromeTint.init(approximating:))
		return .init(
			theme: scheme(theme),
			tintHue: tint.hue,
			tintIntensity: tint.intensity,
			gradient: stops.isEmpty ? nil : ChromeGradient(stops: Array(stops)).normalized
		)
	}

	/// `{"red": …, "green": …, "blue": …}`, each a number. Arc writes extended sRGB, so
	/// components may fall outside `0 … 1`; they're clamped later.
	internal static func color(_ value: Any?) -> ChromePalette.RGB? {
		guard
			let dictionary = value as? [String: Any],
			let red = number(dictionary["red"]),
			let green = number(dictionary["green"]),
			let blue = number(dictionary["blue"]),
			red.isFinite, green.isFinite, blue.isFinite
		else { return nil }

		return .init(red: red, green: green, blue: blue)
	}

	/// The colors of the first `baseColors` list, depth first with keys in order.
	internal static func gradientColors(_ theme: [String: Any]) -> [ChromePalette.RGB] {
		var budget = maximumNodes
		func search(
			_ value: Any,
			depth: Int
		) -> [Any]? {
			budget -= 1
			guard budget > 0, depth < maximumDepth else { return nil }

			if let dictionary = value as? [String: Any] {
				if let colors = dictionary["baseColors"] as? [Any] { return colors }
				for key in dictionary.keys.sorted() {
					if let found = search(dictionary[key]!, depth: depth + 1) { return found }
				}
			} else if let array = value as? [Any] {
				for element in array {
					if let found = search(element, depth: depth + 1) { return found }
				}
			}
			return nil
		}

		return (search(theme, depth: 0) ?? []).compactMap { entry in
			color(entry) ?? (entry as? [String: Any]).flatMap(firstColor)
		}
	}

	/// The first dictionary that reads as a color, depth first with keys in order.
	internal static func firstColor(_ value: [String: Any]) -> ChromePalette.RGB? {
		var budget = maximumNodes
		func search(
			_ value: Any,
			depth: Int
		) -> ChromePalette.RGB? {
			budget -= 1
			guard budget > 0, depth < maximumDepth else { return nil }

			if let found = color(value) { return found }
			if let dictionary = value as? [String: Any] {
				for key in dictionary.keys.sorted() {
					if let found = search(dictionary[key]!, depth: depth + 1) { return found }
				}
			} else if let array = value as? [Any] {
				for element in array {
					if let found = search(element, depth: depth + 1) { return found }
				}
			}
			return nil
		}

		return search(value, depth: 0)
	}

	/// Light or dark when the theme names one: a top-level key such as `colorScheme` or
	/// `appearance` set to "light" or "dark", or `isDark`. Otherwise nil, so the space
	/// follows the app.
	internal static func scheme(_ theme: [String: Any]) -> AppearanceOverride.Theme? {
		for key in ["colorScheme", "appearance", "appearanceMode", "mode"] {
			guard let value = theme[key] as? String else { continue }

			switch value.lowercased() {
			case "light": return .light
			case "dark": return .dark
			default: continue
			}
		}
		if let isDark = theme["isDark"] as? Bool { return isDark ? .dark : .light }
		return nil
	}

	private static func number(_ value: Any?) -> Double? {
		// JSONSerialization gives NSNumber, which also bridges from a JSON true or false.
		guard
			let number = value as? NSNumber,
			CFGetTypeID(number) != CFBooleanGetTypeID()
		else { return nil }

		return number.doubleValue
	}
}
