import Foundation

/// The edits the space theme editor makes (DEV-1253), kept apart from its views so each control's
/// state can be tested on its own.
///
/// The editor shows a theme as a list of one to three colors: the tint, then the gradient's stops.
/// An empty list is the tint inherited from the level above.
extension AppearanceOverride {
	/// The most colors a theme takes: the tint and the gradient's stops.
	public static let maximumThemeColors: Int = ChromeGradient.maximumStops + 1

	/// This level's own colors, or none when it inherits its tint.
	public func themeColors(over inherited: ChromeAppearance) -> [ChromeTint] {
		guard overridesTint else { return [] }

		let tint = ChromeTint(
			hue: tintHue ?? inherited.tint.hue,
			intensity: tintIntensity ?? inherited.tint.intensity
		)
		let stops = (gradient ?? inherited.gradient)?.stops ?? []
		return [tint] + stops.prefix(ChromeGradient.maximumStops)
	}

	/// The colors as this level's own, or the tint inherited again for none. One color chooses the
	/// tint's own gradient over the level above's; more keep this level's angle, or the one inherited.
	public func settingThemeColors(
		_ colors: [ChromeTint],
		over inherited: ChromeAppearance
	) -> Self {
		guard let first = colors.first else { return inheritingTint() }

		var copy = self
		copy.tintHue = first.hue
		copy.tintIntensity = first.intensity
		let angle = (gradient ?? inherited.gradient)?.angle ?? ChromeGradient.defaultAngle
		copy.gradient = .init(
			stops: Array(colors.dropFirst().prefix(ChromeGradient.maximumStops)),
			angle: angle
		)
		return copy
	}

	/// The intensity every color shares, as the wave slider sets it. Over an inherited tint, the
	/// inherited colors become this level's own with the new intensity.
	public func settingThemeIntensity(
		_ intensity: Double,
		over inherited: ChromeAppearance
	) -> Self {
		let intensity = min(max(intensity, 0), 1)
		var colors = themeColors(over: inherited)
		if colors.isEmpty {
			colors = [inherited.tint] + (inherited.gradient?.stops ?? [])
		}
		return settingThemeColors(
			colors.map { .init(hue: $0.hue, intensity: intensity) },
			over: inherited
		)
	}

	/// The texture in effect, or nil for Clear: the grain turned off.
	public func themeTexture(over inherited: ChromeAppearance) -> ChromeGrain.Texture? {
		let grain = applied(to: inherited).grain
		return grain.isEnabled ? grain.texture : nil
	}

	/// A texture as this level's own, or Clear for nil.
	public func settingThemeTexture(_ texture: ChromeGrain.Texture?) -> Self {
		var copy = self
		copy.grainEnabled = texture != nil
		if let texture { copy.grainTexture = texture }
		return copy
	}

	/// The texture after this one, as tapping the dial's inner circle moves on: Noise, Jeans, Paper,
	/// Textile, Clear, then Noise again.
	public static func nextThemeTexture(after texture: ChromeGrain.Texture?) -> ChromeGrain.Texture? {
		switch texture {
		case .noise: .jeans
		case .jeans: .paper
		case .paper: .textile
		case .textile: nil
		case nil: .noise
		}
	}
}
