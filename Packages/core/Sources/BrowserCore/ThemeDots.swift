import Foundation

/// The colors of a theme as the theme panel's field holds them (DEV-1299):
/// one to three dots on a circle, all the same distance from its centre, at fixed angles from the
/// main dot. A theme's position is the main dot's angle and distance; its arrangement places the
/// others.
///
/// Angle is hue, measured clockwise on screen from 3 o'clock. Distance is how far from the centre,
/// `0 ... 1` of the circle's radius; the color is strongest at the centre and fades to neutral at
/// the edge. Every dot shares the main dot's distance, so all the colors
/// share one intensity.
public struct ThemeDots: Equatable, Hashable, Sendable {
	/// Where the other dots sit, as angles from the main dot, measured from a recording.
	public enum Arrangement: String, CaseIterable, Codable, Hashable, Sendable {
		/// One dot.
		case single

		/// Two dots, opposite each other: plus from one dot.
		case complementary

		/// Three dots at 150° and 210° from the main one: plus from two dots.
		case splitComplementary

		/// Three dots at 40° on either side of the main one: a gradient swatch.
		case analogous

		/// The other dots' angles from the main dot, clockwise, in the order the gradient's stops
		/// take them. Plus from two dots springs the old second dot from 180° to 150° and adds the
		/// new one at 210°, so the first stop is the one at 150°.
		public var offsets: [Double] {
			switch self {
			case .single: []
			case .complementary: [180]
			case .splitComplementary: [150, 210]
			case .analogous: [40, 320]
			}
		}

		/// How many dots it has.
		public var count: Int { offsets.count + 1 }
	}

	/// A point on the field, in units of the circle's radius from its centre: x runs right and y
	/// runs down, as on screen.
	public struct Point: Equatable, Hashable, Sendable {
		public var x: Double
		public var y: Double

		public init(
			x: Double,
			y: Double
		) {
			self.x = x
			self.y = y
		}

		/// The centre.
		public static let zero: Self = .init(x: 0, y: 0)
	}

	/// The main dot's angle in degrees, `0 ..< 360`, clockwise on screen from 3 o'clock: its hue.
	public var angle: Double

	/// How far every dot is from the centre, `0 ... 1` of the circle's radius.
	public var distance: Double
	public var arrangement: Arrangement

	public init(
		angle: Double,
		distance: Double,
		arrangement: Arrangement = .single
	) {
		self.angle = Self.wrapped(angle.isFinite ? angle : 0)
		self.distance = distance.isFinite ? min(max(distance, 0), 1) : 0
		self.arrangement = arrangement
	}

	/// The dots for a main color.
	public init(
		main: ChromeTint,
		arrangement: Arrangement = .single
	) {
		let main = main.normalized ?? .default
		self.init(
			angle: main.hue,
			distance: Self.distance(forIntensity: main.intensity),
			arrangement: arrangement
		)
	}

	/// The dots that best show a theme's colors, or nil for none. Colors the panel wrote come back
	/// exactly; others, such as a theme imported from Arc or set by an agent, take the main color's
	/// place and the arrangement nearest their count, and snap to it on the next edit.
	public init?(colors: [ChromeTint]) {
		guard let main = colors.first else { return nil }

		let arrangement: Arrangement = switch colors.count {
		case 1: .single
		case 2: .complementary
		default: Self.isAnalogous(colors) ? .analogous : .splitComplementary
		}
		self.init(main: main, arrangement: arrangement)
	}

	/// How many dots there are.
	public var count: Int { arrangement.count }

	/// Every dot's angle, the main dot's first.
	public var angles: [Double] {
		[angle] + arrangement.offsets.map { Self.wrapped(angle + $0) }
	}

	/// Every dot's centre, the main dot's first.
	public var points: [Point] {
		angles.map { Self.point(angle: $0, distance: distance) }
	}

	/// Every dot's color, the main dot's first: the tint, then the gradient's stops.
	public var colors: [ChromeTint] {
		let intensity = Self.intensity(atDistance: distance)
		return angles.map { ChromeTint(hue: $0, intensity: intensity) }
	}

	// MARK: - Editing

	/// The main dot dragged to a point: the set turns and scales about the centre. A point past the
	/// circle holds the dot on its edge; the centre keeps the angle, so the hue survives it.
	public func moving(to point: Point) -> Self {
		guard point.x.isFinite, point.y.isFinite else { return self }

		let length = (point.x * point.x + point.y * point.y).squareRoot()
		var copy = self
		copy.distance = min(length, 1)
		if length > 0 { copy.angle = Self.wrapped(atan2(point.y, point.x) * 180 / .pi) }
		return copy
	}

	/// Pressing a dot that isn't the main one makes it the main one where it stands, and the others
	/// take the arrangement's places around it. The old main dot is already on one of them, so it
	/// stays; the third dot moves to the one left (41.3 to 41.7 s of the recording).
	///
	/// - Returns: The new dots, and for each of their indices the index the dot had before, so a
	///   view can move each dot from where it was.
	public func promoting(_ index: Int) -> (dots: Self, previous: [Int]) {
		let offsets = arrangement.offsets
		guard index > 0, index < count else { return (self, Array(0 ..< count)) }

		let pressed = offsets[index - 1]
		var copy = self
		copy.angle = Self.wrapped(angle + pressed)

		// The old main dot sits at −pressed from the new one; the others fill the places left, in order.
		var previous = [index] + Array(repeating: -1, count: offsets.count)
		let mainSlot = offsets.firstIndex { Self.separation($0, -pressed) < 0.5 } ?? 0
		previous[mainSlot + 1] = 0
		var rest = (1 ..< count).filter { $0 != index }.makeIterator()
		for slot in previous.indices where previous[slot] == -1 {
			previous[slot] = rest.next() ?? 0
		}
		return (copy, previous)
	}

	/// Plus: one dot gains its opposite, two become three at 150° and 210°. Nil at three.
	public func adding() -> Self? {
		var copy = self
		switch arrangement {
		case .single: copy.arrangement = .complementary
		case .complementary: copy.arrangement = .splitComplementary
		case .splitComplementary, .analogous: return nil
		}
		return copy
	}

	/// Minus: three become two opposite each other, two become one. Nil for one, which leaves the
	/// field empty.
	public func removing() -> Self? {
		var copy = self
		switch arrangement {
		case .single: return nil
		case .complementary: copy.arrangement = .single
		case .splitComplementary, .analogous: copy.arrangement = .complementary
		}
		return copy
	}

	// MARK: - Mapping

	/// The intensity a dot at this distance gives: full at the centre, none at the edge. The recording's dots
	/// fade from a saturation of 0.31 at the centre to 0.03 at the edge; tune here.
	public static func intensity(atDistance distance: Double) -> Double {
		1 - min(max(distance, 0), 1)
	}

	/// Where a color of this intensity sits, the inverse of `intensity(atDistance:)`.
	public static func distance(forIntensity intensity: Double) -> Double {
		1 - min(max(intensity, 0), 1)
	}

	public static func point(
		angle: Double,
		distance: Double
	) -> Point {
		let radians = angle * .pi / 180
		return .init(x: cos(radians) * distance, y: sin(radians) * distance)
	}

	// MARK: - Helpers

	private static func isAnalogous(_ colors: [ChromeTint]) -> Bool {
		guard colors.count == 3 else { return false }

		let main = colors[0].hue
		let offsets = colors.dropFirst().map { wrapped($0.hue - main) }
		return Arrangement.analogous.offsets.allSatisfy { expected in
			offsets.contains { separation($0, expected) < 1 }
		}
	}

	private static func wrapped(_ degrees: Double) -> Double {
		let value = degrees.truncatingRemainder(dividingBy: 360)
		return value < 0 ? value + 360 : value
	}

	private static func separation(
		_ lhs: Double,
		_ rhs: Double
	) -> Double {
		let difference = wrapped(lhs - rhs)
		return min(difference, 360 - difference)
	}
}

extension AppearanceOverride {
	/// This level's own colors as the field's dots, or nil when it inherits its tint.
	public func themeDots(over inherited: ChromeAppearance) -> ThemeDots? {
		ThemeDots(colors: themeColors(over: inherited))
	}

	/// The dots as this level's own colors, or the tint inherited again for nil.
	public func settingThemeDots(
		_ dots: ThemeDots?,
		over inherited: ChromeAppearance
	) -> Self {
		settingThemeColors(dots?.colors ?? [], over: inherited)
	}
}
