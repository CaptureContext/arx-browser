import CustomDump
import Foundation
import Testing

@testable import AppFeature

/// DEV-1105: Page PiP's window rests at corners and is thrown there as Media PiP's is.
@Suite
internal struct PagePictureInPictureMotionTests {
	private typealias Motion = PagePictureInPictureMotion

	private let screen: CGRect = .init(x: 0, y: 0, width: 1440, height: 900)
	private let size: CGSize = .init(width: 480, height: 345)

	@Test
	internal func cornersSitSixteenPointsInsideTheVisibleFrame() async throws {
		expectNoDifference(Motion.origin(of: .bottomLeft, size: size, in: screen), .init(x: 16, y: 16))
		expectNoDifference(Motion.origin(of: .bottomRight, size: size, in: screen), .init(x: 944, y: 16))
		expectNoDifference(Motion.origin(of: .topLeft, size: size, in: screen), .init(x: 16, y: 539))
		expectNoDifference(Motion.origin(of: .topRight, size: size, in: screen), .init(x: 944, y: 539))

		// A window that doesn't fit between the insets is centred on that axis.
		let tall = CGSize(width: 480, height: 880)
		expectNoDifference(Motion.origin(of: .topRight, size: tall, in: screen), .init(x: 944, y: 10))
	}

	@Test
	internal func aReleaseAtRestSettlesAtTheNearestCorner() async throws {
		let frame = CGRect(origin: .init(x: 100, y: 500), size: size)
		let rest = try #require(Motion.rest(for: frame, velocity: .zero, areas: [screen]))
		#expect(rest.corner == .topLeft)
		expectNoDifference(rest.frame.origin, .init(x: 16, y: 539))
	}

	@Test
	internal func aThrowCarriesTheWindowToTheCornerItsHeadedFor() async throws {
		// Released at top left, thrown right and down.
		let frame = CGRect(origin: .init(x: 100, y: 500), size: size)
		let rest = try #require(Motion.rest(for: frame, velocity: .init(dx: 2_000, dy: -1_500), areas: [screen]))
		#expect(rest.corner == .bottomRight)
	}

	@Test
	internal func aHardThrowReachesTheNeighbouringScreenButNotBeyond() async throws {
		let right = CGRect(x: 1440, y: 0, width: 1440, height: 900)
		let farRight = CGRect(x: 2880, y: 0, width: 1440, height: 900)
		let frame = CGRect(origin: .init(x: 900, y: 16), size: size)
		let rest = try #require(Motion.rest(
			for: frame,
			velocity: .init(dx: 100_000, dy: 0),
			areas: [screen, right, farRight]
		))
		expectNoDifference(rest.area, right)
		#expect(rest.corner == .bottomRight)
	}

	@Test
	internal func theReleaseVelocityComesFromTheLastTenthOfASecond() async throws {
		let samples: [Motion.Sample] = [
			.init(position: .init(x: 0, y: 0), time: 0),
			.init(position: .init(x: 500, y: 0), time: 0.5),
			.init(position: .init(x: 520, y: 10), time: 0.55),
			.init(position: .init(x: 540, y: 20), time: 0.6),
		]
		let velocity = Motion.velocity(of: samples, at: 0.6)
		#expect(abs(velocity.dx - 400) < 0.001)
		#expect(abs(velocity.dy - 200) < 0.001)
		// A pointer that rested before the release throws nothing.
		expectNoDifference(Motion.velocity(of: samples, at: 0.8), .zero)

		// One recent sample uses the one before it.
		let sparse = Array(samples.prefix(2))
		#expect(Motion.velocity(of: sparse, at: 0.55).dx == 1_000)
	}

	@Test
	internal func theSpringSettlesAndItsSwingStaysUnderTheInset() async throws {
		// Thrown into the bottom-right corner from up and to the left.
		let start = CGVector(dx: -300, dy: 200)
		var offset = start
		var velocity = CGVector(dx: 2_500, dy: -1_500)
		var widest: CGFloat = 0
		for _ in 0..<240 {
			Motion.Spring.thrown.step(offset: &offset, velocity: &velocity, dt: 1.0 / 120)
			Motion.boundOvershoot(&offset, velocity: &velocity, from: start, at: .bottomRight)
			widest = max(widest, offset.dx, -offset.dy)
		}
		#expect(abs(offset.dx) < 0.5)
		#expect(abs(offset.dy) < 0.5)
		#expect(widest > 0)
		#expect(widest <= Motion.maximumOvershoot)
		#expect(Motion.maximumOvershoot < Motion.edgeInset)
	}

	/// An axis that starts at its corner still can't swing off the screen when the release
	/// velocity points that way.
	@Test
	internal func anAlignedAxisStaysOnScreenToo() async throws {
		let start = CGVector(dx: 0, dy: -300)
		var offset = start
		var velocity = CGVector(dx: 1_500, dy: 2_000)
		var outward: CGFloat = 0
		for _ in 0..<240 {
			Motion.Spring.thrown.step(offset: &offset, velocity: &velocity, dt: 1.0 / 120)
			Motion.boundOvershoot(&offset, velocity: &velocity, from: start, at: .topRight)
			outward = max(outward, offset.dx)
		}
		#expect(outward <= Motion.maximumOvershoot)
		#expect(abs(offset.dx) < 0.5)
	}

	/// A throw stops in the first display it crosses, whatever their sizes.
	@Test
	internal func aThrowStopsInTheFirstDisplayItCrosses() async throws {
		let wide = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
		let second = CGRect(x: 2_560, y: 0, width: 1_024, height: 768)
		let third = CGRect(x: 3_584, y: 0, width: 1_024, height: 768)
		let frame = CGRect(x: 2_200, y: 16, width: 480, height: 345)
		let rest = try #require(Motion.rest(
			for: frame,
			velocity: .init(dx: 100_000, dy: 0),
			areas: [wide, second, third]
		))
		expectNoDifference(rest.area, second)
	}

	@Test
	internal func itOpensWhereItLastRested() async throws {
		let defaults = try #require(UserDefaults(suiteName: "PagePictureInPictureMotionTests"))
		defaults.removePersistentDomain(forName: "PagePictureInPictureMotionTests")
		#expect(Motion.rememberedCorner(defaults: defaults) == .bottomRight)
		Motion.remember(.topLeft, defaults: defaults)
		#expect(Motion.rememberedCorner(defaults: defaults) == .topLeft)
		defaults.removePersistentDomain(forName: "PagePictureInPictureMotionTests")
	}
}
