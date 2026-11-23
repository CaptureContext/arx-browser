import Foundation

/// The window chrome's color: a hue, and how far it moves from neutral grey towards vibrant.
public struct ChromeTint: Codable, Equatable, Hashable, Sendable {
	/// Degrees on the color wheel, `0 ..< 360`. Red is 0, green 120, blue 240.
	public var hue: Double

	/// `0` is neutral grey and `1` is the most color the chrome takes.
	public var intensity: Double

	public init(
		hue: Double = Self.default.hue,
		intensity: Double = Self.default.intensity
	) {
		self.hue = hue
		self.intensity = intensity
	}

	/// The muted lavender Arx ships with.
	public static let `default`: Self = .init(hue: 240, intensity: 0.2)

	/// Wraps the hue onto the wheel and clamps the intensity, or nil when either isn't a number.
	public var normalized: Self? {
		guard hue.isFinite, intensity.isFinite else { return nil }
		let hue = hue.truncatingRemainder(dividingBy: 360)
		return .init(
			hue: hue < 0 ? hue + 360 : hue,
			intensity: min(max(intensity, 0), 1)
		)
	}
}

/// The static texture laid over the chrome: film grain by default, or a woven, paper or textile surface.
public struct ChromeGrain: Codable, Equatable, Hashable, Sendable {
	/// The surface the grain draws (DEV-1253). Turning the grain off is the theme editor's Clear.
	public enum Texture: String, CaseIterable, Codable, Hashable, Sendable {
		/// Fine film grain, as Arx has always drawn.
		case noise

		/// A diagonal twill weave, like denim.
		case jeans

		/// Soft blotches and short fibers, like paper.
		case paper

		/// Fine diagonal stripes, woven, like a shirt's cloth (DEV-1286).
		case textile
	}

	public var isEnabled: Bool

	/// `0 ... 1`.
	public var intensity: Double

	/// Display pixels per grain, `1 ... 3`.
	public var size: Double
	public var texture: Texture

	public init(
		isEnabled: Bool = Self.default.isEnabled,
		intensity: Double = Self.default.intensity,
		size: Double = Self.default.size,
		texture: Texture = .noise
	) {
		self.isEnabled = isEnabled
		self.intensity = intensity
		self.size = size
		self.texture = texture
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			isEnabled: try values.decode(Bool.self, forKey: .isEnabled),
			intensity: try values.decode(Double.self, forKey: .intensity),
			size: try values.decode(Double.self, forKey: .size),
			// Encoded before textures (DEV-1253): film grain.
			texture: try values.decodeIfPresent(Texture.self, forKey: .texture) ?? .noise
		)
	}

	public static let `default`: Self = .init(isEnabled: true, intensity: 0.18, size: 1)

	public static let intensityRange: ClosedRange<Double> = 0 ... 1
	public static let sizeRange: ClosedRange<Double> = 1 ... 3
}

/// A gradient across the chrome (DEV-919): the tint's color and one or two more, at an angle.
public struct ChromeGradient: Codable, Equatable, Hashable, Sendable {
	/// The colors after the tint's own, one or two. None means the tint's own two-tone gradient,
	/// which a space can choose over its profile's gradient.
	public var stops: [ChromeTint]

	/// Degrees, as CSS measures a linear gradient's direction: 0 runs up, 90 to the right and
	/// 180 down. 135 runs from the top leading corner, as the two-tone gradient does.
	public var angle: Double

	public init(
		stops: [ChromeTint],
		angle: Double = Self.defaultAngle
	) {
		self.stops = stops
		self.angle = angle
	}

	public static let defaultAngle: Double = 135

	/// A gradient takes the tint and at most two more colors.
	public static let maximumStops: Int = 2

	/// The tint's own two-tone gradient, which a space can choose over its profile's gradient.
	public static let plain: Self = .init(stops: [])

	/// At most two stops, each a usable tint, and an angle on the circle; nil for one that can't be
	/// drawn.
	public var normalized: Self? {
		guard angle.isFinite else { return nil }
		let angle = angle.truncatingRemainder(dividingBy: 360)
		let stops = stops.prefix(Self.maximumStops).compactMap(\.normalized)
		guard stops.count == min(self.stops.count, Self.maximumStops) else { return nil }
		return .init(stops: stops, angle: angle < 0 ? angle + 360 : angle)
	}
}

/// Everything about the window chrome's background that Settings, a profile or a space can choose.
public struct ChromeAppearance: Codable, Equatable, Hashable, Sendable {
	public var tint: ChromeTint
	public var grain: ChromeGrain

	/// A gradient of the tint and more colors (DEV-919), or nil for the tint's two-tone one.
	public var gradient: ChromeGradient?

	/// The accent color (DEV-1117), or nil for Automatic, the one the tint gives.
	public var accent: ChromeAccent?

	/// Match site (DEV-1101, DEV-1170): the chrome takes the color of the page it shows, and the
	/// tint stays for pages without one. Off by default.
	public var matchesSite: Bool

	public init(
		tint: ChromeTint = .default,
		grain: ChromeGrain = .default,
		gradient: ChromeGradient? = nil,
		accent: ChromeAccent? = nil,
		matchesSite: Bool = false
	) {
		self.tint = tint
		self.grain = grain
		self.gradient = gradient
		self.accent = accent
		self.matchesSite = matchesSite
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			tint: try values.decode(ChromeTint.self, forKey: .tint),
			grain: try values.decode(ChromeGrain.self, forKey: .grain),
			gradient: try values.decodeIfPresent(ChromeGradient.self, forKey: .gradient),
			accent: try values.decodeIfPresent(ChromeAccent.self, forKey: .accent),
			// Encoded before Match site had a browser default: off.
			matchesSite: try values.decodeIfPresent(Bool.self, forKey: .matchesSite) ?? false
		)
	}

	public static let `default`: Self = .init()

	/// The most specific choice wins for each setting on its own: the space's, then its profile's, then the app's.
	public static func resolve(
		global: Self,
		profile: AppearanceOverride?,
		space: AppearanceOverride?
	) -> Self {
		(space ?? .init()).over(profile).applied(to: global)
	}
}

// MARK: - Palette

/// Gradient stops derived from a tint, in gamma-encoded sRGB.
///
/// Each stop keeps the lightness of the colors Arx shipped with, so rows, hover and selection fills,
/// and the page hairline keep their contrast at every hue and intensity. Only the color around that
/// lightness turns with the hue and grows with the intensity.
public struct ChromePalette: Equatable, Sendable {
	public struct RGB: Equatable, Sendable {
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

		/// Rec. 709 luma of the encoded components; the lightness every tint of a stop keeps.
		public var luma: Double {
			Self.lumaWeights.red * red + Self.lumaWeights.green * green + Self.lumaWeights.blue * blue
		}

		fileprivate static let lumaWeights: RGB = .init(red: 0.2126, green: 0.7152, blue: 0.0722)
	}

	public enum Surface: CaseIterable, Sendable {
		/// Behind the sidebar and around the page card.
		case sidebar

		/// The page card itself, behind web content.
		case page
	}

	public var top: RGB
	public var bottom: RGB

	public init(
		top: RGB,
		bottom: RGB
	) {
		self.top = top
		self.bottom = bottom
	}

	public init(
		tint: ChromeTint,
		surface: Surface,
		isDark: Bool
	) {
		let tint = tint.normalized ?? .default
		let stops = Self.shipped(surface, isDark: isDark)
		self.init(
			top: Self.derive(stops.top, tint: tint, isDark: isDark),
			bottom: Self.derive(stops.bottom, tint: tint, isDark: isDark)
		)
	}

	/// The colors from before tints were configurable, which the default tint reproduces.
	public static func shipped(
		_ surface: Surface,
		isDark: Bool
	) -> Self {
		switch (surface, isDark) {
		case (.sidebar, false):
			.init(
				top: .init(red: 0.917647, green: 0.917647, blue: 0.937255),
				bottom: .init(red: 0.941176, green: 0.929412, blue: 0.937255)
			)
		case (.sidebar, true):
			.init(
				top: .init(red: 0.152941, green: 0.152941, blue: 0.180392),
				bottom: .init(red: 0.172549, green: 0.156863, blue: 0.180392)
			)
		case (.page, false):
			.init(
				top: .init(red: 0.988235, green: 0.984314, blue: 0.996078),
				bottom: .init(red: 0.976471, green: 0.960784, blue: 0.972549)
			)
		case (.page, true):
			.init(
				top: .init(red: 0.215686, green: 0.207843, blue: 0.239216),
				bottom: .init(red: 0.235294, green: 0.215686, blue: 0.235294)
			)
		}
	}

	/// How far light stops darken at full intensity, so a vibrant tint has room for color.
	private static let lightDarkening: Double = 0.04

	private static func derive(
		_ stop: RGB,
		tint: ChromeTint,
		isDark: Bool
	) -> RGB {
		let luma = stop.luma
		let chroma = ChromaPlane.coordinates(of: stop, luma: luma)
		let turn = ChromaPlane.angle(ofHue: tint.hue) - ChromaPlane.angle(ofHue: ChromeTint.default.hue)
		let scale = tint.intensity / ChromeTint.default.intensity
		let a = scale * (chroma.a * cos(turn) - chroma.b * sin(turn))
		let b = scale * (chroma.a * sin(turn) + chroma.b * cos(turn))

		let excess = max(tint.intensity - ChromeTint.default.intensity, 0) / (1 - ChromeTint.default.intensity)
		let lightness = isDark ? luma : luma - lightDarkening * excess
		return ChromaPlane.color(a: a, b: b, luma: lightness)
	}
}

// MARK: - Match site

extension ChromePalette {
	/// The chrome in a site's color (DEV-1101), adjusted so Arx's text and icons keep their contrast.
	///
	/// The site's lightness is clamped into a band around the surface's shipped lightness, so a black
	/// site darkens light chrome only a little and a white one lifts dark chrome only a little; its
	/// color is softened and capped, so a vivid brand color reads as a tint rather than a fill. The
	/// stops keep the shipped gradient's step between top and bottom. Increased Contrast keeps the
	/// shipped lightness itself and halves the color.
	public init(
		site color: RGB,
		surface: Surface,
		isDark: Bool,
		increasedContrast: Bool = false
	) {
		let shipped = Self.shipped(surface, isDark: isDark)
		let clamped = RGB(
			red: min(max(color.red, 0), 1),
			green: min(max(color.green, 0), 1),
			blue: min(max(color.blue, 0), 1)
		)
		let luma = clamped.luma
		let band = increasedContrast
		? shipped.top.luma ... shipped.top.luma
		: SiteAdjustment.lightness(surface, isDark: isDark)
		let top = min(max(luma, band.lowerBound), band.upperBound)
		let bottom = min(max(top + shipped.bottom.luma - shipped.top.luma, 0), 1)

		let chroma = ChromaPlane.coordinates(of: clamped, luma: luma)
		let magnitude = (chroma.a * chroma.a + chroma.b * chroma.b).squareRoot()
		let cap = isDark ? SiteAdjustment.darkChroma : SiteAdjustment.lightChroma
		var scale = magnitude > 0 ? min(SiteAdjustment.softening, cap / magnitude) : 0
		if increasedContrast { scale /= 2 }
		self.init(
			top: ChromaPlane.color(a: scale * chroma.a, b: scale * chroma.b, luma: top),
			bottom: ChromaPlane.color(a: scale * chroma.a, b: scale * chroma.b, luma: bottom)
		)
	}

	/// How far a site's color may move the chrome (DEV-1101).
	public enum SiteAdjustment {
		/// The share of a site's color the chrome keeps, before the cap.
		public static let softening: Double = 0.6

		/// The most color, as a distance from grey in the luma-free plane, on light chrome.
		public static let lightChroma: Double = 0.12

		/// Dark chrome takes less, so a dark sidebar never glows.
		public static let darkChroma: Double = 0.1

		/// The lightness a surface's top stop may take, as Rec. 709 luma of encoded sRGB. Each band
		/// holds the shipped stop, and keeps Arx's black or white text above 7:1 contrast.
		public static func lightness(
			_ surface: Surface,
			isDark: Bool
		) -> ClosedRange<Double> {
			switch (surface, isDark) {
			case (.sidebar, false): 0.8 ... 0.95
			case (.page, false): 0.86 ... 0.99
			case (.sidebar, true): 0.1 ... 0.24
			case (.page, true): 0.15 ... 0.3
			}
		}
	}
}

extension ChromeTint {
	/// The tint closest to a color from another browser, such as an Arc space's (DEV-897).
	///
	/// The hue is the color's direction in the plane `ChromePalette` turns tints in, so a tint
	/// derived from it points the same way; the intensity is the color's saturation, `0` for
	/// grey and `1` for a pure color. Arx's tints are softer than the color itself, so this is
	/// an approximation, not a round trip. Components are clamped to sRGB first.
	public init(approximating color: ChromePalette.RGB) {
		let clamped = ChromePalette.RGB(
			red: min(max(color.red, 0), 1),
			green: min(max(color.green, 0), 1),
			blue: min(max(color.blue, 0), 1)
		)
		let largest = max(clamped.red, clamped.green, clamped.blue)
		let smallest = min(clamped.red, clamped.green, clamped.blue)
		let saturation = largest > 0 ? (largest - smallest) / largest : 0
		self.init(
			hue: largest - smallest > 0.0001 ? ChromaPlane.hue(of: clamped) : Self.default.hue,
			intensity: saturation
		)
	}
}

/// The plane of colors with zero luma, spanned by two orthonormal axes. A stop is its luma plus a
/// point in this plane; turning that point changes the hue without changing the lightness.
private enum ChromaPlane {
	private static let u: ChromePalette.RGB = normalized(cross(weights, .init(red: 0, green: 0, blue: 1)))
	private static let v: ChromePalette.RGB = normalized(cross(weights, u))
	private static let weights: ChromePalette.RGB = ChromePalette.RGB.lumaWeights

	fileprivate static func coordinates(
		of color: ChromePalette.RGB,
		luma: Double
	) -> (a: Double, b: Double) {
		let residual = ChromePalette.RGB(red: color.red - luma, green: color.green - luma, blue: color.blue - luma)
		return (dot(residual, u), dot(residual, v))
	}

	/// Pulls the color back towards grey just enough to stay inside sRGB, keeping hue and lightness.
	fileprivate static func color(
		a: Double,
		b: Double,
		luma: Double
	) -> ChromePalette.RGB {
		let offsets = [
			a * u.red + b * v.red,
			a * u.green + b * v.green,
			a * u.blue + b * v.blue,
		]
		var fit: Double = 1
		for offset in offsets {
			if offset > 0 {
				fit = min(fit, (1 - luma) / offset)
			} else if offset < 0 {
				fit = min(fit, luma / -offset)
			}
		}
		fit = max(fit, 0)
		return .init(
			red: luma + fit * offsets[0],
			green: luma + fit * offsets[1],
			blue: luma + fit * offsets[2]
		)
	}

	/// The hue whose fully saturated color points where `color` does in the plane, to a
	/// hundredth of a degree: a coarse pass over the wheel, then a fine one around the best.
	fileprivate static func hue(of color: ChromePalette.RGB) -> Double {
		let chroma = coordinates(of: color, luma: color.luma)
		let target = atan2(chroma.b, chroma.a)
		func distance(_ hue: Double) -> Double {
			let difference = abs(angle(ofHue: hue) - target).truncatingRemainder(dividingBy: 2 * .pi)
			return min(difference, 2 * .pi - difference)
		}

		let coarse = stride(from: 0.0, to: 360, by: 1).min { distance($0) < distance($1) } ?? 0
		let fine = stride(from: coarse - 1, through: coarse + 1, by: 0.01).min { distance($0) < distance($1) } ?? coarse
		let hue = fine.truncatingRemainder(dividingBy: 360)
		return ((hue < 0 ? hue + 360 : hue) * 100).rounded() / 100
	}

	/// Where a fully saturated color of this hue points in the plane, in radians.
	fileprivate static func angle(ofHue hue: Double) -> Double {
		let pure = pureColor(hue: hue)
		let chroma = coordinates(of: pure, luma: pure.luma)
		return atan2(chroma.b, chroma.a)
	}

	private static func pureColor(hue: Double) -> ChromePalette.RGB {
		let sector = (hue / 60).truncatingRemainder(dividingBy: 6)
		let rising = sector - sector.rounded(.down)
		let falling = 1 - rising
		return switch Int(sector) {
		case 0: .init(red: 1, green: rising, blue: 0)
		case 1: .init(red: falling, green: 1, blue: 0)
		case 2: .init(red: 0, green: 1, blue: rising)
		case 3: .init(red: 0, green: falling, blue: 1)
		case 4: .init(red: rising, green: 0, blue: 1)
		default: .init(red: 1, green: 0, blue: falling)
		}
	}

	private static func dot(
		_ lhs: ChromePalette.RGB,
		_ rhs: ChromePalette.RGB
	) -> Double {
		lhs.red * rhs.red + lhs.green * rhs.green + lhs.blue * rhs.blue
	}

	private static func cross(
		_ lhs: ChromePalette.RGB,
		_ rhs: ChromePalette.RGB
	) -> ChromePalette.RGB {
		.init(
			red: lhs.green * rhs.blue - lhs.blue * rhs.green,
			green: lhs.blue * rhs.red - lhs.red * rhs.blue,
			blue: lhs.red * rhs.green - lhs.green * rhs.red
		)
	}

	private static func normalized(_ vector: ChromePalette.RGB) -> ChromePalette.RGB {
		let length = dot(vector, vector).squareRoot()
		return .init(red: vector.red / length, green: vector.green / length, blue: vector.blue / length)
	}
}
