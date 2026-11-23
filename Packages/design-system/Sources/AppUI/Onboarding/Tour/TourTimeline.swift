import SwiftUI

/// Keyframe helpers for the tour demos: every value is computed from the time alone,
/// so a frame never depends on the frames before it.
internal enum TourTimeline {
	/// Goes from 0 at `start` to 1 at `end` with an ease in and out, clamped outside.
	internal static func ease(
		_ time: TimeInterval,
		from start: TimeInterval,
		to end: TimeInterval
	) -> CGFloat {
		let progress: CGFloat = linear(time, from: start, to: end)
		return progress * progress * (3 - 2 * progress)
	}

	/// Like `ease`, but overshoots a little before settling, as a spring would.
	internal static func spring(
		_ time: TimeInterval,
		from start: TimeInterval,
		to end: TimeInterval
	) -> CGFloat {
		let progress: CGFloat = linear(time, from: start, to: end)
		let overshoot: CGFloat = 1.4
		let shifted: CGFloat = progress - 1
		return 1 + (overshoot + 1) * pow(shifted, 3) + overshoot * pow(shifted, 2)
	}

	/// Goes from 0 at `start` to 1 at `end` at a steady rate, clamped outside.
	internal static func linear(
		_ time: TimeInterval,
		from start: TimeInterval,
		to end: TimeInterval
	) -> CGFloat {
		guard end > start else { return time >= end ? 1 : 0 }

		return CGFloat(min(1, max(0, (time - start) / (end - start))))
	}

	/// Rises over `fadeIn`, holds, and falls over `fadeOut`: for things that appear and leave.
	internal static func window(
		_ time: TimeInterval,
		in range: ClosedRange<TimeInterval>,
		fade: TimeInterval = 0.2
	) -> CGFloat {
		min(
			ease(time, from: range.lowerBound, to: range.lowerBound + fade),
			1 - ease(time, from: range.upperBound - fade, to: range.upperBound)
		)
	}

	/// The first `count` characters of `text` while it's typed between `start` and `end`.
	internal static func typed(
		_ text: String,
		_ time: TimeInterval,
		from start: TimeInterval,
		to end: TimeInterval
	) -> String {
		let count: Int = Int((linear(time, from: start, to: end) * CGFloat(text.count)).rounded(.down))
		return String(text.prefix(count))
	}

	internal static func mix(
		_ from: CGFloat,
		_ to: CGFloat,
		_ progress: CGFloat
	) -> CGFloat {
		from + (to - from) * progress
	}

	internal static func mix(
		_ from: CGPoint,
		_ to: CGPoint,
		_ progress: CGFloat
	) -> CGPoint {
		.init(x: mix(from.x, to.x, progress), y: mix(from.y, to.y, progress))
	}

	internal static func mix(
		_ from: CGRect,
		_ to: CGRect,
		_ progress: CGFloat
	) -> CGRect {
		.init(
			x: mix(from.minX, to.minX, progress),
			y: mix(from.minY, to.minY, progress),
			width: mix(from.width, to.width, progress),
			height: mix(from.height, to.height, progress)
		)
	}
}
