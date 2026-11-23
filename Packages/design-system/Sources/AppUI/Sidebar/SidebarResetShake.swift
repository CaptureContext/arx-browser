import SwiftUI

extension EnvironmentValues {
	/// How many times each sidebar item was reset to its pinned page (DEV-1225). A row whose count
	/// goes up shakes once; one appearing with a count already there stays still.
	@Entry
	public var sidebarResetPulses: [SidebarItem.ID: Int] = [:]
}

/// A reset pin's row (DEV-1225): a short horizontal shake, a couple of quick swings well under half a
/// second, so the reset reads at a glance. With Reduce Motion on, a brief tint over the row
/// instead, which fades in and out without moving anything. It's drawn over the row rather than
/// behind it, so a selected row's opaque fill, such as a selected Split View's, can't hide it.
public struct SidebarResetShake: ViewModifier {
	/// How far each swing goes, in points, and when it lands.
	public nonisolated static let swings: [(offset: CGFloat, at: TimeInterval)] = [
		(-5, 0.045),
		(5, 0.09),
		(-3.5, 0.08),
		(2, 0.065),
		(0, 0.06),
	]

	/// The whole shake.
	public nonisolated static var duration: TimeInterval { swings.map(\.at).reduce(0, +) }

	/// The tint Reduce Motion shows instead: in, held, out.
	public nonisolated static let highlightTimes: (in: TimeInterval, hold: TimeInterval, out: TimeInterval) = (0.08, 0.16, 0.24)

	/// Each reset count the row shows: its own, or each Split View member's.
	private let pulses: [SidebarItem.ID: Int]

	/// Goes up once per shake.
	@SwiftUI.State
	private var shakes: Int = 0

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion: Bool

	public init(pulses: [SidebarItem.ID: Int]) {
		self.pulses = pulses
	}

	/// Whether a count the row already had went up: a reset. A member joining or leaving a Split
	/// View changes which counts the row has, which isn't one.
	public nonisolated static func isReset(
		from old: [SidebarItem.ID: Int],
		to new: [SidebarItem.ID: Int]
	) -> Bool {
		new.contains { id, count in old[id].map { $0 < count } ?? false }
	}

	private struct Values {
		var offset: CGFloat = 0
		var highlight: Double = 0
	}

	public func body(content: Content) -> some View {
		// Read on the main actor; the animator's content closure is Sendable.
		let reduceMotion: Bool = self.reduceMotion
		return content.keyframeAnimator(initialValue: Values(), trigger: shakes) { content, value in
			content.modifier(SidebarResetFrame(
				offset: value.offset,
				highlight: value.highlight,
				reduceMotion: reduceMotion
			))
		} keyframes: { _ in
			KeyframeTrack(\.offset) {
				CubicKeyframe(Self.swings[0].offset, duration: Self.swings[0].at)
				CubicKeyframe(Self.swings[1].offset, duration: Self.swings[1].at)
				CubicKeyframe(Self.swings[2].offset, duration: Self.swings[2].at)
				CubicKeyframe(Self.swings[3].offset, duration: Self.swings[3].at)
				CubicKeyframe(Self.swings[4].offset, duration: Self.swings[4].at)
			}
			KeyframeTrack(\.highlight) {
				LinearKeyframe(0.22, duration: Self.highlightTimes.in)
				LinearKeyframe(0.22, duration: Self.highlightTimes.hold)
				LinearKeyframe(0, duration: Self.highlightTimes.out)
			}
		}
		.onChange(of: pulses) { old, new in
			if Self.isReset(from: old, to: new) {
				shakes += 1
			}
		}
	}
}

/// One frame of a reset: the row moved by the shake's `offset`, or, with Reduce Motion, still and
/// under a tint of `highlight` opacity.
internal struct SidebarResetFrame: ViewModifier {
	private let offset: CGFloat
	private let highlight: Double
	private let reduceMotion: Bool

	// Built in the keyframe animator's closure, outside the main actor.
	internal nonisolated init(
		offset: CGFloat,
		highlight: Double,
		reduceMotion: Bool
	) {
		self.offset = offset
		self.highlight = highlight
		self.reduceMotion = reduceMotion
	}

	internal func body(content: Content) -> some View {
		content
			.offset(x: reduceMotion ? 0 : offset)
			.overlay {
				RoundedRectangle(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
					.fill(.tint.opacity(reduceMotion ? highlight : 0))
					.allowsHitTesting(false)
			}
	}
}

extension View {
	/// Shakes the row each time one of its reset counts goes up (DEV-1225).
	public func sidebarResetShake(_ pulses: [SidebarItem.ID: Int]) -> some View {
		modifier(SidebarResetShake(pulses: pulses))
	}

	/// Shakes the row as `sidebarResetShake(_:)` does, or leaves it be for nil: a row nothing
	/// can reset.
	@ViewBuilder
	internal func sidebarResetShake(_ pulses: [SidebarItem.ID: Int]?) -> some View {
		if let pulses {
			modifier(SidebarResetShake(pulses: pulses))
		} else {
			self
		}
	}
}
