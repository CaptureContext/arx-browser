import BrowserCore
import CustomDump
import Foundation
import Testing

/// The theme panel's dots against a recording of a picker (DEV-1299): every tracked frame's
/// main dot is fed through the model, and the other dots must land where the recording has them.
internal struct ThemeDotsTests {
	/// A few pixels of the recording's 337-pixel radius; its tracking is good to about one.
	private static let tolerance: Double = 4 * ArcPickerRecording.pixel

	// MARK: - The recording

	@Test(arguments: ThemeDots.Arrangement.allCases.filter { $0 != .single })
	internal func theOtherDotsLandWhereArcDrewThem(_ arrangement: ThemeDots.Arrangement) throws {
		let frames = ArcPickerRecording.frames.filter { $0.arrangement == arrangement }
		try #require(frames.count >= 10)

		var worst: (error: Double, time: Double) = (0, 0)
		for frame in frames {
			try #require(frame.points.count == arrangement.count)
			let dots = ThemeDots(angle: 0, distance: 0, arrangement: arrangement).moving(to: frame.points[0])
			let error = Self.error(dots.points, frame.points)
			if error > worst.error { worst = (error, frame.time) }
		}
		#expect(
			worst.error <= Self.tolerance,
			"Worst frame at \(worst.time) s is \(worst.error / ArcPickerRecording.pixel) px off"
		)
	}

	@Test
	internal func pressingTheDotAt210MakesItTheMainOneWhereItStands() throws {
		let before = ArcPickerRecording.beforeSwitch
		let after = ArcPickerRecording.afterSwitch
		let dots = ThemeDots(angle: 0, distance: 0, arrangement: .splitComplementary).moving(to: before[0])
		#expect(Self.error(dots.points, before) <= Self.tolerance)

		// The dot pressed is the one the recording's new main dot was before.
		let pressed = try #require(dots.points.indices.dropFirst().min { lhs, rhs in
			Self.distance(dots.points[lhs], after[0]) < Self.distance(dots.points[rhs], after[0])
		})
		expectNoDifference(dots.arrangement.offsets[pressed - 1], 210)

		let (promoted, previous) = dots.promoting(pressed)
		#expect(Self.error(promoted.points, after) <= Self.tolerance)
		#expect(Self.distance(promoted.points[0], dots.points[pressed]) <= Self.tolerance)
		// The old main dot doesn't move; the third one jumps to the place left.
		expectNoDifference(previous, [pressed, 0, 1])
		#expect(Self.distance(promoted.points[1], dots.points[0]) <= Self.tolerance)
		#expect(Self.distance(promoted.points[2], dots.points[1]) > 0.2)
	}

	// MARK: - Plus and minus

	@Test
	internal func plusOpensOppositeThenSplitsAndStopsAtThree() throws {
		let one = ThemeDots(angle: 20, distance: 0.5)
		let two = try #require(one.adding())
		expectNoDifference(two.angles, [20, 200])
		let three = try #require(two.adding())

		// The second dot springs from 180° to 150°, and the new one comes in at 210°.
		expectNoDifference(three.angles, [20, 170, 230])
		#expect(three.adding() == nil)
		#expect(ThemeDots(angle: 0, distance: 0.5, arrangement: .analogous).adding() == nil)
	}

	@Test
	internal func minusGoesBackToOppositeThenOneThenNone() throws {
		let three = ThemeDots(angle: 20, distance: 0.5, arrangement: .splitComplementary)
		let two = try #require(three.removing())

		// The dot at 150° stays and springs to 180°; the one at 210° goes.
		expectNoDifference(two.angles, [20, 200])
		expectNoDifference(try #require(two.removing()).angles, [20])
		#expect(ThemeDots(angle: 20, distance: 0.5).removing() == nil)
		expectNoDifference(
			ThemeDots(angle: 20, distance: 0.5, arrangement: .analogous).removing()?.arrangement,
			.complementary
		)
	}

	// MARK: - The field

	@Test
	internal func aDragPastTheCircleHoldsTheDotOnItsEdge() {
		let dots = ThemeDots(angle: 0, distance: 0.5, arrangement: .complementary).moving(to: .init(x: 0, y: 3))
		expectNoDifference(dots.distance, 1)
		expectNoDifference(dots.angle, 90)
		#expect(dots.points.allSatisfy { abs(Self.distance($0, .zero) - 1) < 1e-9 })
	}

	@Test
	internal func theCentreKeepsTheHue() {
		let dots = ThemeDots(angle: 123, distance: 0.6, arrangement: .complementary).moving(to: .zero)
		expectNoDifference(dots.angle, 123)
		expectNoDifference(dots.distance, 0)
		#expect(dots.points.allSatisfy { $0 == .zero })
	}

	@Test
	internal func angleIsHueClockwiseFromThreeOClockAndTheColorFadesOutward() {
		// Straight down on screen is a quarter turn clockwise.
		let dots = ThemeDots(angle: 0, distance: 0).moving(to: .init(x: 0, y: 0.25))
		expectNoDifference(dots.colors, [.init(hue: 90, intensity: 0.75)])
		expectNoDifference(ThemeDots.intensity(atDistance: 0), 1)
		expectNoDifference(ThemeDots.intensity(atDistance: 1), 0)
	}

	// MARK: - Saving

	@Test(arguments: ThemeDots.Arrangement.allCases)
	internal func dotsRoundTripThroughTheSavedColors(_ arrangement: ThemeDots.Arrangement) {
		let dots = ThemeDots(angle: 300, distance: 0.25, arrangement: arrangement)
		let saved = AppearanceOverride().settingThemeDots(dots, over: .default)
		let read = saved.themeDots(over: .default)
		expectNoDifference(read?.arrangement, arrangement)
		#expect(abs((read?.angle ?? -1) - 300) < 1e-9)
		#expect(abs((read?.distance ?? -1) - 0.25) < 1e-9)
		#expect(saved.settingThemeDots(nil, over: .default).themeDots(over: .default) == nil)
	}

	@Test
	internal func colorsThePanelDidntWriteAreReadBestEffort() {
		// Three colors in no arrangement, as Arc's importer or an agent may set them.
		let dots = ThemeDots(colors: [
			.init(hue: 10, intensity: 0.4),
			.init(hue: 100, intensity: 0.7),
			.init(hue: 300, intensity: 0.1),
		])
		expectNoDifference(dots?.arrangement, .splitComplementary)
		expectNoDifference(dots?.angle, 10)
		#expect(abs((dots?.distance ?? 0) - 0.6) < 1e-9)
	}

	// MARK: - Helpers

	/// The largest distance between each recorded dot and the model's, the main dots paired and the
	/// others matched whichever way fits, as the recording doesn't tell same-sized dots apart.
	private static func error(
		_ model: [ThemeDots.Point],
		_ recorded: [ThemeDots.Point]
	) -> Double {
		guard model.count == recorded.count, let first = model.first else { return .infinity }

		let main = distance(first, recorded[0])
		let rest = Array(model.dropFirst())
		let others = Array(recorded.dropFirst())
		let pairings: [[Int]] = rest.count == 2 ? [[0, 1], [1, 0]] : [Array(rest.indices)]
		let best = pairings.map { pairing in
			pairing.enumerated().map { distance(rest[$0.offset], others[$0.element]) }.max() ?? 0
		}.min() ?? 0
		return max(main, best)
	}

	private static func distance(
		_ lhs: ThemeDots.Point,
		_ rhs: ThemeDots.Point
	) -> Double {
		((lhs.x - rhs.x) * (lhs.x - rhs.x) + (lhs.y - rhs.y) * (lhs.y - rhs.y)).squareRoot()
	}
}
