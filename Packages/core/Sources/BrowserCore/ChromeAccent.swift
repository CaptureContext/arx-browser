import Foundation

/// The accent color Arx draws its own highlights in (DEV-1117): folder icons first, then selection
/// rings, focused controls and drop targets. Behind `ChromeAccent.featureFlag`.
///
/// The app-wide default is Automatic (nil), the accent the space's tint gives; a profile or space
/// inherits unless it chooses a color. The most specific choice wins, as for the tint.
public struct ChromeAccent: Codable, Equatable, Hashable, Sendable {
	/// Gamma-encoded sRGB, `0 ... 1`.
	public var red: Double
	public var green: Double
	public var blue: Double

	public init(
		red: Double,
		green: Double,
		blue: Double
	) {
		self.red = red
		self.green = green
		self.blue = blue
	}

	public init(_ rgb: ChromePalette.RGB) {
		self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
	}

	public var rgb: ChromePalette.RGB { .init(red: red, green: green, blue: blue) }

	/// Clamped into sRGB, or nil when a component isn't a number.
	public var normalized: Self? {
		guard red.isFinite, green.isFinite, blue.isFinite else { return nil }
		func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
		return .init(red: clamp(red), green: clamp(green), blue: clamp(blue))
	}

	/// The `ARX_ACCENT_COLOR` feature flag (DEV-1117), on by default (DEV-1143).
	public static let featureFlag: String = FeatureFlag.accentColor.name

	/// Read through `FeatureFlag`: `0`, `false`, `no` or `off` turns it off; anything else, or
	/// nothing, leaves it on.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.accentColor.isOn(environment: environment, defaults: defaults)
	}
}

// MARK: - Automation

extension ChromeAccent {
	/// The accent's name for agents: `automatic`, a preset's, or the color as `#RRGGBB`, so undo
	/// and revisions see a custom color itself.
	public static let automaticName: String = "automatic"

	public static func automationName(of accent: Self?) -> String {
		guard let accent else { return automaticName }

		return Preset.allCases.first { $0.accent == accent }?.rawValue ?? accent.hex
	}

	/// `#RRGGBB`, each component rounded to a byte.
	public var hex: String {
		func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
		return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
	}

	/// A color from `#RRGGBB`, or nil for anything else.
	public init?(hex: String) {
		guard
			hex.count == 7,
			hex.first == "#",
			let value = UInt32(hex.dropFirst(), radix: 16)
		else { return nil }

		self.init(
			red: Double((value >> 16) & 0xFF) / 255,
			green: Double((value >> 8) & 0xFF) / 255,
			blue: Double(value & 0xFF) / 255
		)
	}
}

// MARK: - Presets

extension ChromeAccent {
	/// Colors that read on light and dark chrome alike, each a little brighter than a system color
	/// so it holds up on the darker dark sidebar after the contrast check.
	public enum Preset: String, CaseIterable, Sendable {
		case indigo
		case blue
		case purple
		case pink
		case red
		case orange
		case yellow
		case green
		case teal
		case graphite

		public var accent: ChromeAccent {
			switch self {
			case .indigo: .init(red: 0.317647, green: 0.278431, blue: 0.909804)
			case .blue: .init(red: 0.0, green: 0.478431, blue: 1.0)
			case .purple: .init(red: 0.635294, green: 0.345098, blue: 0.890196)
			case .pink: .init(red: 0.937255, green: 0.282353, blue: 0.564706)
			case .red: .init(red: 0.913725, green: 0.258824, blue: 0.247059)
			case .orange: .init(red: 0.960784, green: 0.533333, blue: 0.098039)
			case .yellow: .init(red: 0.952941, green: 0.737255, blue: 0.0)
			case .green: .init(red: 0.180392, green: 0.698039, blue: 0.341176)
			case .teal: .init(red: 0.0, green: 0.647059, blue: 0.682353)
			case .graphite: .init(red: 0.505882, green: 0.513725, blue: 0.552941)
			}
		}
	}
}

// MARK: - Resolution

extension ChromeAccent {
	/// Arx's own accent, which Automatic gives the default tint, in the light and dark appearance.
	public static func shipped(isDark: Bool) -> ChromePalette.RGB {
		isDark
		? .init(red: 0.321569, green: 0.278431, blue: 0.941176)
		: .init(red: 0.317647, green: 0.278431, blue: 0.909804)
	}

	/// Automatic: Arx's accent turned to the tint's hue, with its saturation and brightness, so the
	/// default tint keeps the accent Arx shipped with exactly.
	public static func automatic(
		tint: ChromeTint,
		isDark: Bool
	) -> ChromePalette.RGB {
		let tint = tint.normalized ?? .default
		let shipped = HSB(shipped(isDark: isDark))
		let turn = tint.hue - ChromeTint.default.hue
		guard abs(turn) > 0.000_1 else { return Self.shipped(isDark: isDark) }

		return HSB(hue: shipped.hue + turn, saturation: shipped.saturation, brightness: shipped.brightness).rgb
	}

	/// The color the accent is drawn in: the chosen one, or Automatic's, made legible on `background`.
	public static func resolve(
		_ chosen: Self?,
		tint: ChromeTint,
		background: ChromePalette.RGB,
		isDark: Bool
	) -> ChromePalette.RGB {
		let color = chosen?.normalized?.rgb ?? automatic(tint: tint, isDark: isDark)
		return legible(color, on: background, isDark: isDark)
	}

	/// The contrast an accent needs against the sidebar: WCAG's 3:1 for interface parts, or, where
	/// Arx's own accent on its own sidebar has less, that, so the default look stays as it shipped.
	/// Dark folders and rings keep a pale outline, which carries their edge there.
	public static func minimumContrast(isDark: Bool) -> Double {
		let sidebar = ChromePalette.shipped(.sidebar, isDark: isDark)
		let shipped = shipped(isDark: isDark).contrast(with: sidebar.top.mixed(with: sidebar.bottom))
		return min(3, shipped)
	}

	/// The color kept at its hue and moved just far enough in brightness (and, in the dark, toward
	/// white) to reach `minimumContrast(isDark:)` on `background`: darker on light chrome, lighter on
	/// dark.
	public static func legible(
		_ color: ChromePalette.RGB,
		on background: ChromePalette.RGB,
		isDark: Bool
	) -> ChromePalette.RGB {
		let minimum = minimumContrast(isDark: isDark)

		// A hundredth of slack: the default tint's sidebar matches the shipped one only to rounding.
		guard color.contrast(with: background) < minimum - 0.01 else { return color }

		var hsb = HSB(color)
		for _ in 0 ..< 100 {
			if isDark {
				// Brighter first; at full brightness, paler.
				if hsb.brightness < 1 {
					hsb.brightness = min(hsb.brightness + 0.02, 1)
				} else {
					hsb.saturation = max(hsb.saturation - 0.02, 0)
				}
			} else {
				hsb.brightness = max(hsb.brightness - 0.02, 0)
			}
			let candidate = hsb.rgb
			if candidate.contrast(with: background) >= minimum { return candidate }

			// Out of room: white in the dark, black in the light.
			if isDark ? hsb.brightness == 1 && hsb.saturation == 0 : hsb.brightness == 0 { return candidate }
		}
		return hsb.rgb
	}
}

extension ChromePalette.RGB {
	/// WCAG 2 relative luminance of the gamma-encoded sRGB color.
	public var relativeLuminance: Double {
		func linear(_ component: Double) -> Double {
			let component = min(max(component, 0), 1)
			return component <= 0.040_45 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
	}

	/// WCAG 2 contrast ratio with another color, `1 ... 21`.
	public func contrast(with other: Self) -> Double {
		let lighter = max(relativeLuminance, other.relativeLuminance)
		let darker = min(relativeLuminance, other.relativeLuminance)
		return (lighter + 0.05) / (darker + 0.05)
	}

	/// The color halfway between two, as the middle of a two-stop gradient reads.
	public func mixed(with other: Self) -> Self {
		.init(red: (red + other.red) / 2, green: (green + other.green) / 2, blue: (blue + other.blue) / 2)
	}
}

/// Hue (degrees), saturation and brightness of a gamma-encoded sRGB color.
private struct HSB {
	fileprivate var hue: Double
	fileprivate var saturation: Double
	fileprivate var brightness: Double

	fileprivate init(
		hue: Double,
		saturation: Double,
		brightness: Double
	) {
		let hue = hue.truncatingRemainder(dividingBy: 360)
		self.hue = hue < 0 ? hue + 360 : hue
		self.saturation = min(max(saturation, 0), 1)
		self.brightness = min(max(brightness, 0), 1)
	}

	fileprivate init(_ rgb: ChromePalette.RGB) {
		let largest = max(rgb.red, rgb.green, rgb.blue)
		let smallest = min(rgb.red, rgb.green, rgb.blue)
		let delta = largest - smallest
		var hue: Double = 0
		if delta > 0 {
			if largest == rgb.red {
				hue = 60 * ((rgb.green - rgb.blue) / delta).truncatingRemainder(dividingBy: 6)
			} else if largest == rgb.green {
				hue = 60 * ((rgb.blue - rgb.red) / delta + 2)
			} else {
				hue = 60 * ((rgb.red - rgb.green) / delta + 4)
			}
		}
		self.init(hue: hue, saturation: largest > 0 ? delta / largest : 0, brightness: largest)
	}

	fileprivate var rgb: ChromePalette.RGB {
		let chroma = brightness * saturation
		let sector = hue / 60
		let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
		let match = brightness - chroma
		let (red, green, blue): (Double, Double, Double) = switch Int(sector) % 6 {
		case 0: (chroma, second, 0)
		case 1: (second, chroma, 0)
		case 2: (0, chroma, second)
		case 3: (0, second, chroma)
		case 4: (second, 0, chroma)
		default: (chroma, 0, second)
		}
		return .init(red: red + match, green: green + match, blue: blue + match)
	}
}
