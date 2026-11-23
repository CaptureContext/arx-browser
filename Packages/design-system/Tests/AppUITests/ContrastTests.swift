@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// WCAG 2 contrast for the shipped colors, read from the asset catalog.
internal struct ContrastTests {
	private static let text: Double = 4.5
	private static let nonText: Double = 3

	// MARK: - Default appearance

	@Test(arguments: [false, true])
	internal func primaryTextReadsOnTheSidebarAtEveryTint(isDark: Bool) throws {
		let text = try Palette.shared.color("text", isDark: isDark)
		let selection = try Palette.shared.color("selection", isDark: isDark)
		let hover = try Palette.shared.color("hover", isDark: isDark)

		for background in Self.sidebarBackgrounds(isDark: isDark) {
			#expect(text.contrast(on: background) >= Self.text, "\(background)")
			#expect(text.contrast(on: selection.over(background)) >= Self.text, "\(background)")
			#expect(text.contrast(on: hover.over(background)) >= Self.text, "\(background)")
		}
	}

	@Test(arguments: [false, true])
	internal func selectedCommandResultsRead(isDark: Bool) throws {
		let accent = try Palette.shared.color("accent", isDark: isDark)
		let onAccent = try Palette.shared.color("onAccent", isDark: isDark)
		let background = try Palette.shared.color("commandBackground", isDark: isDark)
		let text = try Palette.shared.color("text", isDark: isDark)

		#expect(onAccent.contrast(on: accent) >= Self.text)
		#expect(text.opacity(0.76).contrast(on: background) >= Self.text)
	}

	@Test
	internal func secondaryTextMatchesItsOpacityToken() throws {
		for isDark in [false, true] {
			let text = try Palette.shared.color("text", isDark: isDark)
			let secondary = try Palette.shared.color("secondaryText", isDark: isDark)

			#expect(secondary.rgb == text.rgb)
			#expect(abs(secondary.alpha - BrowserMetrics.State.secondaryOpacity) < 0.001)
		}
	}

	// MARK: - Increase Contrast

	@Test(arguments: [false, true])
	internal func secondaryTextReadsUnderIncreasedContrast(isDark: Bool) throws {
		let secondary = try Palette.shared.color("secondaryText", isDark: isDark, highContrast: true)

		let increasedSecondaryOpacity: Double = BrowserMetrics.State.opacity(
			BrowserMetrics.State.secondaryOpacity,
			contrast: .increased
		)
		#expect(abs(secondary.alpha - increasedSecondaryOpacity) < 0.001)
		for background in Self.sidebarBackgrounds(isDark: isDark) {
			#expect(secondary.contrast(on: background) >= Self.text, "\(background)")
		}
	}

	@Test(arguments: [false, true])
	internal func dimmedTextAndIconsReadUnderIncreasedContrast(isDark: Bool) throws {
		let text = try Palette.shared.color("text", isDark: isDark)
		let fill = try Palette.shared.color("fill", isDark: isDark)
		let accent = try Palette.shared.color("accent", isDark: isDark)
		let onAccent = try Palette.shared.color("onAccent", isDark: isDark)
		let command = try Palette.shared.color("commandBackground", isDark: isDark)
		let increased: (Double) -> Double = { BrowserMetrics.State.opacity($0, contrast: .increased) }

		for background in Self.sidebarBackgrounds(isDark: isDark) {
			// The URL bar's placeholder, and an unselected space's icon.
			#expect(text.opacity(increased(0.55)).contrast(on: fill.over(background)) >= Self.text, "\(background)")
			#expect(
				text.opacity(increased(BrowserMetrics.SpaceSwitcher.inactiveOpacity)).contrast(on: background) >= Self.nonText,
				"\(background)"
			)
		}

		// A command result's subtitle, unselected and selected.
		#expect(text.opacity(increased(0.76) * increased(0.5)).contrast(on: command) >= Self.text)
		#expect(onAccent.opacity(increased(0.8)).contrast(on: accent) >= Self.text)
	}

	@Test
	internal func increasedContrastKeepsDimmedStatesApart() {
		let inactive = BrowserMetrics.State.opacity(BrowserMetrics.SpaceSwitcher.inactiveOpacity, contrast: .increased)

		#expect(BrowserMetrics.State.opacity(0.5, contrast: .standard) == 0.5)
		#expect(BrowserMetrics.State.opacity(1, contrast: .increased) == 1)
		#expect(inactive > BrowserMetrics.SpaceSwitcher.inactiveOpacity)
		#expect(inactive < 0.9)
	}

	// MARK: - Backgrounds

	/// Both gradient stops of the sidebar for hues around the wheel, from grey to the most vibrant.
	private static func sidebarBackgrounds(isDark: Bool) -> [RGBA] {
		let tints = stride(from: 0.0, to: 360, by: 30).flatMap { hue in
			[0, ChromeTint.default.intensity, 0.6, 1].map { ChromeTint(hue: hue, intensity: $0) }
		}
		return tints.flatMap { tint in
			let palette = ChromePalette(tint: tint, surface: .sidebar, isDark: isDark)
			return [palette.top, palette.bottom].map { RGBA(red: $0.red, green: $0.green, blue: $0.blue) }
		}
	}
}

// MARK: - Colors

private struct RGBA: CustomStringConvertible {
	internal var red: Double
	internal var green: Double
	internal var blue: Double
	internal var alpha: Double

	internal init(
		red: Double,
		green: Double,
		blue: Double,
		alpha: Double = 1
	) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}

	internal var rgb: [Double] { [red, green, blue] }

	internal var description: String {
		String(format: "rgb(%.3f, %.3f, %.3f)", red, green, blue)
	}

	internal func opacity(_ value: Double) -> Self {
		.init(red: red, green: green, blue: blue, alpha: alpha * value)
	}

	/// This color composited over an opaque background.
	internal func over(_ background: Self) -> Self {
		.init(
			red: red * alpha + background.red * (1 - alpha),
			green: green * alpha + background.green * (1 - alpha),
			blue: blue * alpha + background.blue * (1 - alpha)
		)
	}

	internal func contrast(on background: Self) -> Double {
		let foreground = over(background).luminance
		let background = background.luminance
		return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
	}

	private var luminance: Double {
		let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
		return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
	}
}

/// The `browser.*` color sets, by name and appearance.
private struct Palette: Sendable {
	internal static let shared: Palette = .init()

	private struct Key: Hashable {
		internal var name: String
		internal var isDark: Bool
		internal var highContrast: Bool
	}

	private let colors: [Key: [Double]]

	private init() {
		let catalog = URL(filePath: #filePath)
			.deletingLastPathComponent()
			.appending(path: "../../Sources/AppUI/Resources/Colors.xcassets")
			.standardizedFileURL
		let sets = (try? FileManager.default.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil)) ?? []
		var colors: [Key: [Double]] = [:]
		for set in sets where set.pathExtension == "colorset" {
			let name = set.deletingPathExtension().lastPathComponent.replacing("browser.", with: "")
			guard
				let data = try? Data(contentsOf: set.appending(path: "Contents.json")),
				let file = try? JSONDecoder().decode(ColorSet.self, from: data)
			else { continue }

			for entry in file.colors {
				let appearances = entry.appearances ?? []
				let key = Key(
					name: name,
					isDark: appearances.contains { $0.appearance == "luminosity" && $0.value == "dark" },
					highContrast: appearances.contains { $0.appearance == "contrast" && $0.value == "high" }
				)
				let components = entry.color.components
				colors[key] = [components.red, components.green, components.blue, components.alpha].map(Self.component)
			}
		}
		self.colors = colors
	}

	/// Falls back from the high-contrast variant to the standard one, as the asset catalog does.
	internal func color(
		_ name: String,
		isDark: Bool,
		highContrast: Bool = false
	) throws -> RGBA {
		let value = colors[.init(name: name, isDark: isDark, highContrast: highContrast)]
			?? colors[.init(name: name, isDark: isDark, highContrast: false)]
		let components = try #require(value, "No browser.\(name) color")
		return .init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
	}

	private static func component(_ value: String) -> Double {
		if value.hasPrefix("0x"), let byte = Int(value.dropFirst(2), radix: 16) { return Double(byte) / 255 }
		return Double(value) ?? 0
	}

	private struct ColorSet: Decodable {
		internal var colors: [Entry]
	}

	private struct Entry: Decodable {
		internal var appearances: [Appearance]?
		internal var color: Color
	}

	private struct Appearance: Decodable {
		internal var appearance: String
		internal var value: String
	}

	private struct Color: Decodable {
		internal var components: Components
	}

	private struct Components: Decodable {
		internal var red: String
		internal var green: String
		internal var blue: String
		internal var alpha: String
	}
}
