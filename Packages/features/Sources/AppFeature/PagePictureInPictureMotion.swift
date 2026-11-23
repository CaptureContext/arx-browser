import AppKit
import Foundation

/// Where Page PiP's window comes to rest, and how a throw gets it there (DEV-1105): the rules
/// Media PiP's window follows (DEV-825, DEV-852), which live in the engine's C++
/// (`pip/arx_pip_motion.h`) where Swift can't reach them.
///
/// The window rests at a corner 16 points inside a screen's visible frame. On release the
/// velocity of the last tenth of a second is projected forward with UIKit's normal deceleration
/// rate, no farther on each axis than the release screen's width or height and never past the
/// first other display it crosses, and the window settles on the corner nearest that point, on
/// whichever screen it lands. Units are points and seconds, in AppKit's screen coordinates (y up).
internal enum PagePictureInPictureMotion {
	/// A resting position: one of a screen's four corners.
	internal enum Corner: Int, CaseIterable, Sendable {
		case bottomLeft
		case bottomRight
		case topLeft
		case topRight

		fileprivate var isRight: Bool { self == .bottomRight || self == .topRight }
		fileprivate var isTop: Bool { self == .topLeft || self == .topRight }
	}

	/// Where a window rests: the screen's visible frame, the corner, and the window's frame there.
	internal struct Rest: Equatable, Sendable {
		internal var area: CGRect
		internal var corner: Corner
		internal var frame: CGRect
	}

	/// A position of the window's middle at a time, both from the input events.
	internal struct Sample: Equatable, Sendable {
		internal var position: CGPoint
		internal var time: TimeInterval
	}

	internal static let edgeInset: CGFloat = 16

	/// The share of velocity left after each millisecond of coasting (UIScrollView's normal rate).
	internal static let decelerationRate: Double = 0.998

	/// How far back the release velocity looks.
	internal static let velocityWindow: TimeInterval = 0.1

	/// The velocity at release, `now`, in points per second, from the samples of the last tenth
	/// of a second. When those hold only the newest sample the one before it counts too, so
	/// sparse events still give a velocity; a pointer that rested longer than that has none.
	internal static func velocity(
		of samples: [Sample],
		at now: TimeInterval
	) -> CGVector {
		guard let last = samples.last, now - last.time <= velocityWindow else { return .zero }

		let recent = samples.filter { now - $0.time <= velocityWindow }
		let first: Sample? = if recent.count >= 2 {
			recent.first
		} else {
			samples.dropLast().last
		}
		guard let first, last.time > first.time else { return .zero }

		let elapsed = last.time - first.time
		return .init(
			dx: (last.position.x - first.position.x) / elapsed,
			dy: (last.position.y - first.position.y) / elapsed
		)
	}

	/// The distance a value moving at `velocity` coasts, as UIKit's projection works it out.
	internal static func projectedDistance(_ velocity: CGFloat) -> CGFloat {
		velocity / 1000 * decelerationRate / (1 - decelerationRate)
	}

	/// Where a window whose middle is at `center`, moving at `velocity`, is thrown to: no farther
	/// on each axis than the width or height of the screen it's released over, and never past the
	/// first other display the throw crosses. A hard throw reaches a neighbouring display, never
	/// one beyond it (`arx_pip::BoundedProject`).
	internal static func projection(
		of center: CGPoint,
		velocity: CGVector,
		areas: [CGRect]
	) -> CGPoint {
		guard let source = area(for: center, in: areas) else {
			return .init(x: center.x + projectedDistance(velocity.dx), y: center.y + projectedDistance(velocity.dy))
		}

		let dx = min(max(projectedDistance(velocity.dx), -source.width), source.width)
		let dy = min(max(projectedDistance(velocity.dy), -source.height), source.height)
		let projected = CGPoint(x: center.x + dx, y: center.y + dy)

		// The first other display along the way.
		var first: (area: CGRect, enter: CGFloat, leave: CGFloat)?
		for other in areas where other != source {
			guard
				let (enter, leave) = clip(from: center, to: projected, in: other),
				leave > enter,
				enter < first?.enter ?? .infinity
			else { continue }

			first = (other, enter, leave)
		}
		guard let first, !first.area.contains(projected), !source.contains(projected) else { return projected }

		// It would carry on past that display: it stops inside it, just before it would leave.
		let stop = max(first.enter, first.leave - 1e-6)
		return .init(x: center.x + dx * stop, y: center.y + dy * stop)
	}

	/// The part of the segment from `from` to `to` inside `rect`, as where it enters and leaves
	/// (0 at `from`, 1 at `to`); `nil` when it misses (Liang–Barsky).
	private static func clip(
		from: CGPoint,
		to: CGPoint,
		in rect: CGRect
	) -> (enter: CGFloat, leave: CGFloat)? {
		var enter: CGFloat = 0
		var leave: CGFloat = 1
		let dx = to.x - from.x
		let dy = to.y - from.y
		let sides: [(p: CGFloat, q: CGFloat)] = [
			(-dx, from.x - rect.minX),
			(dx, rect.maxX - from.x),
			(-dy, from.y - rect.minY),
			(dy, rect.maxY - from.y),
		]
		for side in sides {
			if side.p == 0 {
				if side.q < 0 { return nil }
				continue
			}
			let r = side.q / side.p
			if side.p < 0 {
				enter = max(enter, r)
			} else {
				leave = min(leave, r)
			}
		}
		return enter <= leave ? (enter, leave) : nil
	}

	/// The origin of `corner` for a window of `size` in `area`, 16 points from the two nearest
	/// edges. On an axis where the window doesn't fit between the insets it's centred.
	internal static func origin(
		of corner: Corner,
		size: CGSize,
		in area: CGRect
	) -> CGPoint {
		let x: CGFloat = if size.width + 2 * edgeInset > area.width {
			area.midX - size.width / 2
		} else if corner.isRight {
			area.maxX - size.width - edgeInset
		} else {
			area.minX + edgeInset
		}
		let y: CGFloat = if size.height + 2 * edgeInset > area.height {
			area.midY - size.height / 2
		} else if corner.isTop {
			area.maxY - size.height - edgeInset
		} else {
			area.minY + edgeInset
		}
		return .init(x: x, y: y)
	}

	/// The screen holding `point`, else the nearest one.
	internal static func area(
		for point: CGPoint,
		in areas: [CGRect]
	) -> CGRect? {
		areas.first { $0.contains(point) }
		?? areas.min { distanceSquared(from: point, to: $0) < distanceSquared(from: point, to: $1) }
	}

	/// Where a window released at `frame` and moving at `velocity` comes to rest: its middle is
	/// projected forward, the screen that point lands on (or the nearest) is chosen, and the
	/// corner whose window middle is nearest the projected point wins. `nil` without screens.
	internal static func rest(
		for frame: CGRect,
		velocity: CGVector,
		areas: [CGRect]
	) -> Rest? {
		let center = CGPoint(x: frame.midX, y: frame.midY)
		let target = projection(of: center, velocity: velocity, areas: areas)
		guard let area = area(for: target, in: areas) else { return nil }

		let corner = Corner.allCases.min { first, second in
			distanceSquared(target, middle(of: first, size: frame.size, in: area))
			< distanceSquared(target, middle(of: second, size: frame.size, in: area))
		} ?? .bottomRight
		return .init(
			area: area,
			corner: corner,
			frame: .init(origin: origin(of: corner, size: frame.size, in: area), size: frame.size)
		)
	}

	/// Where a window at `frame` goes to sit at `corner` of the screen it's on, or the nearest one.
	internal static func rest(
		for frame: CGRect,
		at corner: Corner,
		areas: [CGRect]
	) -> Rest? {
		guard let area = area(for: .init(x: frame.midX, y: frame.midY), in: areas) else { return nil }

		return .init(
			area: area,
			corner: corner,
			frame: .init(origin: origin(of: corner, size: frame.size, in: area), size: frame.size)
		)
	}

	private static func middle(
		of corner: Corner,
		size: CGSize,
		in area: CGRect
	) -> CGPoint {
		let origin = origin(of: corner, size: size, in: area)
		return .init(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
	}

	private static func distanceSquared(
		_ first: CGPoint,
		_ second: CGPoint
	) -> CGFloat {
		let dx = first.x - second.x
		let dy = first.y - second.y
		return dx * dx + dy * dy
	}

	/// The squared distance from `point` to the nearest point of `rect`; zero inside it.
	private static func distanceSquared(
		from point: CGPoint,
		to rect: CGRect
	) -> CGFloat {
		let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
		let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
		return dx * dx + dy * dy
	}
}

// MARK: - Spring

extension PagePictureInPictureMotion {
	/// A spring by its response (the period of the undamped oscillation) and damping ratio
	/// (1 settles without overshoot, less bounces).
	internal struct Spring: Equatable, Sendable {
		internal var response: Double
		internal var damping: Double

		/// A thrown window settles with a little bounce, as Media PiP's does.
		internal static let thrown: Self = .init(response: 0.42, damping: 0.78)

		/// With Reduce Motion it glides in without bounce or carried velocity.
		internal static let reducedMotion: Self = .init(response: 0.3, damping: 1)

		/// One step of `dt` seconds for an offset from rest and its velocity, in small enough
		/// sub-steps to stay stable at any frame rate.
		internal func step(
			offset: inout CGVector,
			velocity: inout CGVector,
			dt: Double
		) {
			let stiffness = pow(2 * .pi / response, 2)
			let friction = 4 * .pi * damping / response
			let steps = max(1, Int((dt / (1.0 / 240)).rounded(.up)))
			let h = dt / Double(steps)
			for _ in 0..<steps {
				velocity.dx += (-stiffness * offset.dx - friction * velocity.dx) * h
				velocity.dy += (-stiffness * offset.dy - friction * velocity.dy) * h
				offset.dx += velocity.dx * h
				offset.dy += velocity.dy * h
			}
		}
	}

	/// How far a settle may swing past its corner: under the inset, so the window never leaves the
	/// screen's visible frame.
	internal static let maximumOvershoot: CGFloat = edgeInset * 0.75

	/// Keeps the swing toward the screen's edges within ``maximumOvershoot``, or where the window
	/// started if that was farther out, whatever the release velocity. A swing that reaches the
	/// bound loses its outward velocity there.
	internal static func boundOvershoot(
		_ offset: inout CGVector,
		velocity: inout CGVector,
		from start: CGVector,
		at corner: Corner
	) {
		func bound(
			_ value: inout CGFloat,
			_ speed: inout CGFloat,
			start: CGFloat,
			outward: CGFloat
		) {
			let limit = max(maximumOvershoot, start * outward)
			guard value * outward > limit else { return }

			value = limit * outward
			if speed * outward > 0 { speed = 0 }
		}
		bound(&offset.dx, &velocity.dx, start: start.dx, outward: corner.isRight ? 1 : -1)
		bound(&offset.dy, &velocity.dy, start: start.dy, outward: corner.isTop ? 1 : -1)
	}
}

// MARK: - Remembered corner

extension PagePictureInPictureMotion {
	private static let cornerKey: String = "ArxPagePictureInPictureCorner"

	/// The corner Page PiP last came to rest at, on this Mac: where it opens next. Bottom right,
	/// as video PiP, until it has rested somewhere.
	internal static func rememberedCorner(defaults: UserDefaults = .standard) -> Corner {
		guard defaults.object(forKey: cornerKey) != nil else { return .bottomRight }

		return Corner(rawValue: defaults.integer(forKey: cornerKey)) ?? .bottomRight
	}

	internal static func remember(
		_ corner: Corner,
		defaults: UserDefaults = .standard
	) {
		defaults.set(corner.rawValue, forKey: cornerKey)
	}
}
