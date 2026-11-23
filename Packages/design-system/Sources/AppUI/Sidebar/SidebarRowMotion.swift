import BrowserCore
import SwiftUI

/// Rows come and go on a short spring (DEV-1187). A new tab slides in from under the
/// row above it while its height opens, a closed or archived one collapses out, and the rows
/// around them close up on the same spring; moves between sections and reorders do the same.
/// Pinned tabs, folders and Favorites follow the same rules. Nothing moves under Reduce Motion,
/// on a space or profile switch, or while a list fills for the first time.
///
/// On by default, as every flag is for the beta. `ARX_SIDEBAR_ROW_ANIMATIONS` set to `0`,
/// `false`, `no` or `off` brings back the earlier rows, which change at once unless the change
/// brings its own animation.
public enum SidebarRowMotion {
	public static let featureFlag: String = FeatureFlag.sidebarRowAnimations.name

	/// Whether rows animate. Read once, through the `FeatureFlag` registry: the environment, then
	/// Arx's defaults under the flag's name.
	public static let isEnabled: Bool = FeatureFlag.sidebarRowAnimations.isOn()

	/// The feel: short and quick to settle, with a hint of overshoot.
	internal static let spring: Spring = .init(duration: 0.3, bounce: 0.1)

	/// The spring as rows play it: on a clock that a held frame doesn't run ahead of
	/// (`SteadyAnimation`).
	internal static let animation: Animation = .init(SteadyAnimation(base: .spring(spring)))

	/// How long a list is on screen before its changes animate, so the rows a window, a space's
	/// page or a Library column fills in as it opens arrive at once.
	internal static let settleDelay: Duration = .milliseconds(400)

	/// How long a closing folder keeps its folded rows listed: the spring's settling time, with
	/// room to spare (DEV-1249).
	internal static let foldDuration: Duration = .milliseconds(600)

	/// What a list shows, compared before and after a change.
	internal struct Rows: Equatable {
		/// Whose rows these are: nil for a space's own page, which the pager keeps per space, or
		/// the profile whose Favorites they are. A new owner is a switch, which doesn't animate.
		internal var owner: UUID?

		/// The rows on screen, in order, by section: a space's Pinned and folders, then its open
		/// tabs, so a tab moving from the end of one to the start of the other is a change too.
		internal var sections: [[Row]]

		/// Whether the space shows all its rows. Collapsing it has its own animation.
		internal var isExpanded: Bool

		internal init(
			owner: UUID? = nil,
			sections: [[Row]],
			isExpanded: Bool = true
		) {
			self.owner = owner
			self.sections = sections
			self.isExpanded = isExpanded
		}

		/// Rows at the top level, by section.
		internal init(
			owner: UUID? = nil,
			sections: [[SidebarItem.ID]],
			isExpanded: Bool = true
		) {
			self.init(
				owner: owner,
				sections: sections.map { $0.map { Row(id: $0) } },
				isExpanded: isExpanded
			)
		}

		/// One section's rows, at the top level.
		internal init(
			owner: UUID? = nil,
			ids: [SidebarItem.ID],
			isExpanded: Bool = true
		) {
			self.init(owner: owner, sections: [ids], isExpanded: isExpanded)
		}
	}

	/// A row on screen and how deep in folders it sits, so a tab moving into the folder just
	/// above it, which keeps every row's place, is a change too.
	internal struct Row: Hashable {
		internal var id: SidebarItem.ID
		internal var depth: Int

		internal init(
			id: SidebarItem.ID,
			depth: Int = 0
		) {
			self.id = id
			self.depth = depth
		}
	}

	/// How a change to the rows animates.
	internal enum Decision: Equatable {
		/// As it came: the rows didn't change, the flag is off, or the space is collapsing or
		/// expanding, which brings its own animation.
		case inherit

		/// At once: a switch to another owner, the first fill, a drop landing or Reduce Motion.
		case still

		/// On `spring`.
		case spring
	}

	/// How the change from `old` to `new` animates.
	///
	/// - Parameters:
	///   - isSettled: whether the list has been on screen for `settleDelay`.
	///   - isLanding: whether a drop is landing in the list, its preview settling into place.
	internal static func decision(
		from old: Rows,
		to new: Rows,
		isEnabled: Bool,
		reduceMotion: Bool,
		isSettled: Bool,
		isLanding: Bool = false
	) -> Decision {
		guard isEnabled, old != new else { return .inherit }
		guard old.owner == new.owner, isSettled, !isLanding, !reduceMotion else { return .still }
		guard old.isExpanded == new.isExpanded else { return .inherit }
		guard old.sections != new.sections else { return .inherit }
		return .spring
	}

	#if DEBUG
	/// The decisions lists took for their changes since `startRecording()`, or nil when nothing
	/// records. Debug builds only, for tests.
	@MainActor
	internal private(set) static var recorded: [Decision]?

	@MainActor
	internal static func startRecording() {
		recorded = []
	}

	@MainActor
	internal static func stopRecording() {
		recorded = nil
	}

	@MainActor
	fileprivate static func record(_ decision: Decision) {
		recorded?.append(decision)
	}
	#endif

	/// Where a row is `time` into its spring, from 0 (gone) to 1 (in place): what a new row's
	/// reveal reaches then, and one minus a closing row's.
	internal static func progress(at time: TimeInterval) -> CGFloat {
		CGFloat(spring.value(target: 1.0, initialVelocity: 0.0, time: time))
	}
}

extension EnvironmentValues {
	/// Whether sidebar rows come and go as `SidebarRowMotion` describes. Tests and snapshots set
	/// it; the app leaves it at the flag.
	@Entry
	internal var sidebarRowMotion: Bool = SidebarRowMotion.isEnabled
}

extension View {
	/// Animates the change when `rows` change, as `SidebarRowMotion.decision` says.
	internal func sidebarRowMotion(
		_ rows: SidebarRowMotion.Rows,
		isLanding: Bool = false
	) -> some View {
		modifier(SidebarRowMotionModifier(rows: rows, isLanding: isLanding))
	}
}

private struct SidebarRowMotionModifier: ViewModifier {
	fileprivate let rows: SidebarRowMotion.Rows
	fileprivate let isLanding: Bool

	@Environment(\.sidebarRowMotion)
	private var isEnabled

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	/// The rows as last shown; nil until the list first appears.
	@SwiftUI.State
	private var shown: SidebarRowMotion.Rows?

	/// When the list first appeared.
	@SwiftUI.State
	private var appeared: ContinuousClock.Instant?

	fileprivate func body(content: Content) -> some View {
		// Decided now, while `shown` still holds the rows before this change.
		let decision: SidebarRowMotion.Decision = shown.map {
			SidebarRowMotion.decision(
				from: $0,
				to: rows,
				isEnabled: isEnabled,
				reduceMotion: reduceMotion,
				isSettled: appeared.map { ContinuousClock.now - $0 >= SidebarRowMotion.settleDelay } ?? false,
				isLanding: isLanding
			)
		} ?? .inherit
		content
			.transaction(value: rows) { transaction in
				switch decision {
				case .inherit:
					break

				case .still:
					transaction.animation = nil
					transaction.disablesAnimations = true

				case .spring:
					// A change made without animation on purpose, such as a drop whose preview
					// settles into place, stays that way.
					guard !transaction.disablesAnimations else { return }
					transaction.animation = SidebarRowMotion.animation
				}
			}
			.onChange(of: rows, initial: true) { old, new in
				#if DEBUG
				if shown != nil, old != new { SidebarRowMotion.record(decision) }
				#endif
				if appeared == nil { appeared = .now }
				shown = new
			}
	}
}

// MARK: - Transitions

extension AnyTransition {
	/// A sidebar row coming or going: with `SidebarRowMotion` on, its height opens or closes while
	/// it slides from under the row above it; off, the fade rows always had.
	internal static func sidebarRow(isEnabled: Bool) -> AnyTransition {
		isEnabled ? AnyTransition(SidebarRowTransition()) : .opacity
	}

	/// A Favorite coming or going: with `SidebarRowMotion` on, it grows from its cell's center as
	/// the tiles around it make room; off, the fade tiles always had.
	internal static func favoriteTile(isEnabled: Bool) -> AnyTransition {
		isEnabled ? .scale(scale: 0.6).combined(with: .opacity) : .opacity
	}
}

/// A row coming in or going out: `SidebarRowReveal` at 0 off screen and 1 in place.
internal struct SidebarRowTransition: Transition {
	internal func body(
		content: Content,
		phase: TransitionPhase
	) -> some View {
		content.modifier(SidebarRowReveal(progress: phase.isIdentity ? 1 : 0))
	}
}

/// A row `progress` of the way in: that share of its height tall, its content's bottom at the
/// bottom, so it slides down from under the row above as it opens and up under it as it closes.
/// The rows below follow its height, so they make room and close up on the same spring.
internal struct SidebarRowReveal: ViewModifier, Animatable {
	internal var progress: CGFloat

	internal nonisolated var animatableData: CGFloat {
		get { progress }
		set { progress = newValue }
	}

	internal init(progress: CGFloat) {
		self.progress = progress
	}

	internal func body(content: Content) -> some View {
		SidebarRowRevealLayout(progress: progress) { content }

			// The content above the row's top while it opens is hidden; in place, nothing is
			// clipped, so a selected row's shadow and a focus ring still show.
			.clipShape(SidebarRowRevealClip(isClipping: progress < 1))
			.opacity(min(max(progress * 2, 0), 1))
	}
}

/// Lays its one subview out at full height and reports `progress` of that height.
private struct SidebarRowRevealLayout: Layout {
	fileprivate var progress: CGFloat

	fileprivate func sizeThatFits(
		proposal: ProposedViewSize,
		subviews: Subviews,
		cache: inout Void
	) -> CGSize {
		guard let subview = subviews.first else { return .zero }

		let size: CGSize = subview.sizeThatFits(proposal)
		return .init(width: size.width, height: size.height * min(max(progress, 0), 1))
	}

	fileprivate func placeSubviews(
		in bounds: CGRect,
		proposal: ProposedViewSize,
		subviews: Subviews,
		cache: inout Void
	) {
		guard let subview = subviews.first else { return }

		let size: CGSize = subview.sizeThatFits(.init(width: bounds.width, height: proposal.height))
		subview.place(
			at: .init(x: bounds.minX, y: bounds.maxY - size.height),
			anchor: .topLeading,
			proposal: .init(width: bounds.width, height: size.height)
		)
	}
}

/// The row's own bounds while it opens or closes, and no clip at all once it's in place.
private struct SidebarRowRevealClip: Shape {
	fileprivate let isClipping: Bool

	fileprivate func path(in rect: CGRect) -> Path {
		let reach: CGFloat = 10_000
		return Path(
			CGRect(
				x: rect.minX - reach,
				y: isClipping ? rect.minY : rect.minY - reach,
				width: rect.width + reach * 2,
				height: rect.height + reach * 2
			)
		)
	}
}

// MARK: - A clock that a held frame doesn't run ahead of

/// An animation's time with the frames the main thread held taken out: each step counts for no
/// more than `longestStep`, so after a long frame the animation goes on from where it was
/// drawn last instead of from where it would have been.
///
/// Opening or closing a tab holds the main thread for a tenth of a second or more while the
/// page opens and the window updates, in the same update that starts the row's 0.3 s spring
/// (DEV-1310). Timed by the wall clock, the first frame drawn after that was a third or more
/// of the way through, so the row jumped most of the way and crept the rest.
internal struct SteadyClock: Equatable, Sendable {
	/// About two frames at 60 a second: longer than a frame that was only late, shorter than
	/// one that was held.
	internal static let longestStep: TimeInterval = 1.0 / 30

	private var lastTime: TimeInterval?
	internal private(set) var elapsed: TimeInterval

	internal init() {
		self.lastTime = nil
		self.elapsed = 0
	}

	/// The animation's own time at the wall clock's `time`.
	internal mutating func advance(to time: TimeInterval) -> TimeInterval {
		if let lastTime { elapsed += min(max(time - lastTime, 0), Self.longestStep) }
		lastTime = time
		return elapsed
	}
}

/// `base`, played on a `SteadyClock`.
internal struct SteadyAnimation: CustomAnimation {
	internal let base: Animation

	internal init(base: Animation) {
		self.base = base
	}

	internal func animate<V: VectorArithmetic>(
		value: V,
		time: TimeInterval,
		context: inout AnimationContext<V>
	) -> V? {
		var clock: SteadyClock = context.state[SteadyClockKey<V>.self]
		let steady: TimeInterval = clock.advance(to: time)
		context.state[SteadyClockKey<V>.self] = clock
		return base.animate(value: value, time: steady, context: &context)
	}

	internal func velocity<V: VectorArithmetic>(
		value: V,
		time: TimeInterval,
		context: AnimationContext<V>
	) -> V? {
		base.velocity(value: value, time: context.state[SteadyClockKey<V>.self].elapsed, context: context)
	}
}

private struct SteadyClockKey<V: VectorArithmetic>: AnimationStateKey {
	fileprivate static var defaultValue: SteadyClock { .init() }
}
