/// A profile's or space's departures from the app-wide appearance. Nil follows the level above,
/// one setting at a time: a space can choose only its tint and still inherit its profile's grain.
public struct AppearanceOverride: Equatable, Hashable, Codable, Sendable {
	public enum Theme: String, CaseIterable, Codable, Sendable {
		case light
		case dark
	}

	public var theme: Theme?
	public var tintHue: Double?
	public var tintIntensity: Double?
	public var grainEnabled: Bool?
	public var grainIntensity: Double?
	public var grainSize: Double?

	/// The grain's surface (DEV-1253). Nil follows the level above, as the grain's other choices do.
	public var grainTexture: ChromeGrain.Texture?

	/// A gradient of the tint and more colors (DEV-919). `ChromeGradient.plain` chooses the tint's
	/// own two-tone gradient over a broader level's.
	public var gradient: ChromeGradient?

	/// Match site (DEV-1101): the chrome takes the color of the page it shows, and this level's tint
	/// only for pages without one. Behind `MatchSiteBackground.featureFlag`. Nil inherits the level
	/// above, as the accent does (DEV-1170); the app-wide level is off unless Settings turns it on.
	public var matchesSite: Bool?

	/// The accent color (DEV-1117). Nil inherits the level above; the app-wide level's nil is
	/// Automatic.
	public var accent: ChromeAccent?

	public init(
		theme: Theme? = nil,
		tintHue: Double? = nil,
		tintIntensity: Double? = nil,
		grainEnabled: Bool? = nil,
		grainIntensity: Double? = nil,
		grainSize: Double? = nil,
		grainTexture: ChromeGrain.Texture? = nil,
		gradient: ChromeGradient? = nil,
		matchesSite: Bool? = nil,
		accent: ChromeAccent? = nil
	) {
		self.theme = theme
		self.tintHue = tintHue
		self.tintIntensity = tintIntensity
		self.grainEnabled = grainEnabled
		self.grainIntensity = grainIntensity
		self.grainSize = grainSize
		self.grainTexture = grainTexture
		self.gradient = gradient
		self.matchesSite = matchesSite
		self.accent = accent
	}

	/// Every chrome setting chosen, as when editing the app-wide appearance.
	public init(_ appearance: ChromeAppearance) {
		self.init(
			tintHue: appearance.tint.hue,
			tintIntensity: appearance.tint.intensity,
			grainEnabled: appearance.grain.isEnabled,
			grainIntensity: appearance.grain.intensity,
			grainSize: appearance.grain.size,
			grainTexture: appearance.grain.texture,
			gradient: appearance.gradient,
			matchesSite: appearance.matchesSite,
			accent: appearance.accent
		)
	}

	/// Chooses nothing, so it follows the level above entirely.
	public var isEmpty: Bool { self == .init() }

	/// Whether it chooses the tint's hue or intensity, or a gradient.
	public var overridesTint: Bool { tintHue != nil || tintIntensity != nil || gradient != nil }

	/// Whether it chooses any film-grain setting.
	public var overridesGrain: Bool {
		grainEnabled != nil || grainIntensity != nil || grainSize != nil || grainTexture != nil
	}

	/// This override's choices, falling back to a broader one's.
	public func over(_ broader: Self?) -> Self {
		.init(
			theme: theme ?? broader?.theme,
			tintHue: tintHue ?? broader?.tintHue,
			tintIntensity: tintIntensity ?? broader?.tintIntensity,
			grainEnabled: grainEnabled ?? broader?.grainEnabled,
			grainIntensity: grainIntensity ?? broader?.grainIntensity,
			grainSize: grainSize ?? broader?.grainSize,
			grainTexture: grainTexture ?? broader?.grainTexture,
			gradient: gradient ?? broader?.gradient,
			matchesSite: matchesSite ?? broader?.matchesSite,
			accent: accent ?? broader?.accent
		)
	}

	/// The chrome after this override's choices replace the app-wide ones they cover.
	public func applied(to global: ChromeAppearance) -> ChromeAppearance {
		let tint = ChromeTint(
			hue: tintHue ?? global.tint.hue,
			intensity: tintIntensity ?? global.tint.intensity
		)
		let grain = ChromeGrain(
			isEnabled: grainEnabled ?? global.grain.isEnabled,
			intensity: grainIntensity.map(ChromeGrain.intensityRange.clamping) ?? global.grain.intensity,
			size: grainSize.map(ChromeGrain.sizeRange.clamping) ?? global.grain.size,
			texture: grainTexture ?? global.grain.texture
		)
		let gradient: ChromeGradient? = if let chosen = self.gradient?.normalized {
			chosen.stops.isEmpty ? nil : chosen
		} else {
			global.gradient
		}
		return .init(
			tint: tint.normalized ?? global.tint,
			grain: grain,
			gradient: gradient,
			accent: accent?.normalized ?? global.accent,
			matchesSite: matchesSite ?? global.matchesSite
		)
	}

	/// Drops the tint choices, so the tint follows the level above again.
	public func inheritingTint() -> Self {
		var copy = self
		copy.tintHue = nil
		copy.tintIntensity = nil
		copy.gradient = nil
		return copy
	}

	/// Drops the accent choice, so the accent follows the level above again (DEV-1117).
	public func inheritingAccent() -> Self {
		var copy = self
		copy.accent = nil
		return copy
	}

	/// Drops the Match site choice, so it follows the level above again (DEV-1170).
	public func inheritingMatchSite() -> Self {
		var copy = self
		copy.matchesSite = nil
		return copy
	}

	/// Drops the film-grain choices, so the grain follows the level above again.
	public func inheritingGrain() -> Self {
		var copy = self
		copy.grainEnabled = nil
		copy.grainIntensity = nil
		copy.grainSize = nil
		copy.grainTexture = nil
		return copy
	}
}

// MARK: - Coding

extension AppearanceOverride {
	/// Set to `true` in the `userInfo` of the coders that save the workspace (its file and its
	/// database columns), which need to tell an override saved before Match site had levels from
	/// one saved since (DEV-1170). Everything else, such as agents and the automation helper,
	/// reads and writes `matchesSite` as it is: on, off or absent to inherit.
	public static let storageCoding: CodingUserInfoKey = .init(rawValue: "arx.appearanceOverride.storage")!

	private enum CodingKeys: String, CodingKey {
		case theme
		case tintHue
		case tintIntensity
		case grainEnabled
		case grainIntensity
		case grainSize
		case grainTexture
		case gradient

		/// Saved: Match site as chosen since it has three levels: on, off or absent to inherit.
		case matchSite

		/// Match site: on, off or absent to inherit. Saved, it's Match site as a space chose it
		/// before (DEV-1101), when only on was a choice and anything else was off, and it's still
		/// written for on, so a Mac on an earlier build keeps showing it.
		case matchesSite
		case accent
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		let isSaved = decoder.userInfo[Self.storageCoding] as? Bool == true
		let matchesSite: Bool? = if values.contains(.matchSite) {
			try values.decodeIfPresent(Bool.self, forKey: .matchSite)
		} else if isSaved {
			// Saved before Match site had a browser default: a space that had it on keeps it, and
			// one that had it off, which was the only default there was, inherits.
			try values.decodeIfPresent(Bool.self, forKey: .matchesSite) == true ? true : nil
		} else {
			try values.decodeIfPresent(Bool.self, forKey: .matchesSite)
		}
		self.init(
			theme: try values.decodeIfPresent(Theme.self, forKey: .theme),
			tintHue: try values.decodeIfPresent(Double.self, forKey: .tintHue),
			tintIntensity: try values.decodeIfPresent(Double.self, forKey: .tintIntensity),
			grainEnabled: try values.decodeIfPresent(Bool.self, forKey: .grainEnabled),
			grainIntensity: try values.decodeIfPresent(Double.self, forKey: .grainIntensity),
			grainSize: try values.decodeIfPresent(Double.self, forKey: .grainSize),
			grainTexture: try values.decodeIfPresent(ChromeGrain.Texture.self, forKey: .grainTexture),
			gradient: try values.decodeIfPresent(ChromeGradient.self, forKey: .gradient),
			matchesSite: matchesSite,
			accent: try values.decodeIfPresent(ChromeAccent.self, forKey: .accent)
		)
	}

	public func encode(to encoder: any Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encodeIfPresent(theme, forKey: .theme)
		try values.encodeIfPresent(tintHue, forKey: .tintHue)
		try values.encodeIfPresent(tintIntensity, forKey: .tintIntensity)
		try values.encodeIfPresent(grainEnabled, forKey: .grainEnabled)
		try values.encodeIfPresent(grainIntensity, forKey: .grainIntensity)
		try values.encodeIfPresent(grainSize, forKey: .grainSize)
		try values.encodeIfPresent(grainTexture, forKey: .grainTexture)
		try values.encodeIfPresent(gradient, forKey: .gradient)
		if encoder.userInfo[Self.storageCoding] as? Bool == true {
			try values.encodeIfPresent(matchesSite, forKey: .matchSite)
			if matchesSite == true { try values.encode(true, forKey: .matchesSite) }
		} else {
			try values.encodeIfPresent(matchesSite, forKey: .matchesSite)
		}
		try values.encodeIfPresent(accent, forKey: .accent)
	}
}

extension ClosedRange<Double> {
	fileprivate func clamping(_ value: Double) -> Double {
		guard value.isFinite else { return lowerBound }
		return Swift.min(Swift.max(value, lowerBound), upperBound)
	}
}

extension BrowserOrganization {
	/// A space's choices win over its profile's.
	public func appearance(ofSpace id: Space.ID) -> AppearanceOverride {
		guard let space = spaces[id: id] else { return .init() }
		let profile = profiles[id: space.profileID]?.appearance
		return (space.appearance ?? .init()).over(profile)
	}
}
