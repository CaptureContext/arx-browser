import Foundation

/// Which way a history swipe goes.
internal enum WebKitSwipeDirection: Equatable, Sendable {
	case back
	case forward
}

/// Who a swipe on a WebKit page belongs to (DEV-1203): the Swift twin of the Chromium pages'
/// `arx::gestures::Ownership` (`Packages/engine/Native/gestures/ownership.h`), with the same
/// thresholds, so a swipe feels the same in both engines.
///
/// The page decides first. Chromium's renderer acknowledges each wheel; on a WebKit page, the
/// swipe script (`WebKitSwipeScript`) answers each wheel with whether something under it scrolls
/// that way and whether its overscroll may leave it. Until a first unconsumed answer that lets
/// the overscroll out, the page keeps the gesture; a later consumed wheel takes it back.
internal struct WebKitSwipeOwnership: Equatable, Sendable {
	internal enum Owner: Equatable, Sendable {
		case pending
		case content
		case history
		case scrubber
		case cancelled
	}

	/// Normalized trackpad travel that commits one step: a fifth of the trackpad's width, as on
	/// Chromium pages.
	internal static let threshold: Double = 0.16

	/// Precise scroll points per normalized unit of finger travel (`kScrollPointsPerUnit`).
	internal static let scrollPointsPerUnit: Double = 800

	internal private(set) var owner: Owner = .cancelled
	internal private(set) var direction: WebKitSwipeDirection?
	private var isActive = false
	private var isInverted = false
	private var canGoBack = false
	private var canGoForward = false
	private var hasAnswer = false
	private var firstUnconsumed = false
	private var overscrollAllowed = false
	private var isAdmitted = false
	private var wasArmed = false
	private var horizontal: Double = 0
	private var vertical: Double = 0
	private var origin: Double = 0

	internal init() {}

	/// Finger travel for a precise scroll's deltas, in normalized, y-up units. Natural scrolling
	/// (`inverted`) moves the content with the fingers: the deltas follow the fingers horizontally
	/// and oppose them vertically, as AppKit's y axis points down.
	internal static func travel(
		deltaX: Double,
		deltaY: Double,
		inverted: Bool
	) -> (x: Double, y: Double) {
		let sign: Double = inverted ? 1 : -1
		return (sign * deltaX / scrollPointsPerUnit, -sign * deltaY / scrollPointsPerUnit)
	}

	internal mutating func begin(
		inverted: Bool,
		canGoBack: Bool,
		canGoForward: Bool
	) {
		self = .init()
		isActive = true
		isInverted = inverted
		self.canGoBack = canGoBack
		self.canGoForward = canGoForward
		owner = .pending
	}

	internal var isCurrent: Bool { isActive }

	/// The page's answer for one wheel of the gesture. `consumed`: something under the pointer
	/// scrolls that way, or the page prevented the wheel. `propagatesX`: the overscroll may leave
	/// the page (nil when the page couldn't tell, which is never permission).
	internal mutating func acknowledge(
		consumed: Bool,
		propagatesX: Bool?
	) {
		guard isActive, owner != .content, owner != .cancelled else { return }

		if !hasAnswer {
			hasAnswer = true
			firstUnconsumed = !consumed
			if consumed { owner = .content }
		}

		// An explicit containment or a later consumer takes precedence over admission.
		if propagatesX == false || consumed { owner = .content }
		if !consumed, propagatesX == true { overscrollAllowed = true }
		isAdmitted = firstUnconsumed && overscrollAllowed && owner != .content
		reconcile()
	}

	/// `horizontal` is the travel since the gesture began; `totalVertical` the vertical travel
	/// summed without sign.
	internal mutating func update(
		horizontal: Double,
		totalVertical: Double
	) {
		guard isActive, owner != .cancelled, owner != .content else { return }
		guard horizontal.isFinite, totalVertical.isFinite, totalVertical >= vertical else {
			cancel()
			return
		}

		self.horizontal = horizontal
		vertical = totalVertical
		let x = abs(horizontal)

		// Once the list has been open, vertical travel is selection, not a reason to give the
		// gesture back to the page.
		if owner != .scrubber, !wasArmed,
			vertical > 2 * x || (vertical * 1.3 > x && vertical > 0.01) || vertical > 0.24
		{
			cancel()
			return
		}
		reconcile()
	}

	/// Opens the history list half a commit distance past the commit itself, so a closed ring can
	/// still be released as a single step. The caller adds the hold delay.
	internal mutating func revealScrubber() -> Bool {
		guard isActive, owner == .history, revealReached else { return false }
		owner = .scrubber
		wasArmed = true
		return true
	}

	/// Whether releasing the open list goes to its selected entry. Ends the gesture.
	internal mutating func releaseScrubber() -> Bool {
		guard isActive, owner == .scrubber else { return false }
		let commits = isAdmitted && displacement >= Self.threshold
		isActive = false
		return commits
	}

	/// Where releasing goes, if anywhere. Ends the gesture: call it before navigating, so a
	/// reentrant navigation can't commit twice.
	internal mutating func release() -> WebKitSwipeDirection? {
		guard isActive else { return nil }
		let result = owner == .history && progress >= 1 ? direction : nil
		isActive = false
		return result
	}

	internal mutating func cancel() {
		guard isActive else { return }
		owner = .cancelled
	}

	internal mutating func invalidate() {
		isActive = false
		owner = .cancelled
	}

	/// Whether the swipe takes the wheel from the page: it owns the gesture and has moved.
	internal var consumesWheel: Bool {
		admitted && abs(horizontal) > 0.01
	}

	internal var admitted: Bool {
		isActive && isAdmitted && (owner == .history || owner == .scrubber)
	}

	internal var revealReached: Bool {
		admitted && direction != nil && displacement >= Self.threshold * 1.5
	}

	/// How far the ring has filled, 0 to 1.
	internal var progress: Double {
		guard direction != nil, admitted else { return 0 }
		return min(max(displacement / Self.threshold, 0), 1)
	}

	/// Measured from where history took the gesture, so travel while the page was still deciding
	/// never pre-fills the indicator or shortens the commit.
	private var displacement: Double {
		guard let direction else { return 0 }
		let value = (horizontal - origin) * (isInverted ? -1 : 1)
		return direction == .back ? -value : value
	}

	private mutating func reconcile() {
		guard isActive, isAdmitted, owner != .cancelled, owner != .content, abs(horizontal) >= 0.001
		else { return }

		if direction == nil {
			let forward = (horizontal > 0) != isInverted
			direction = forward ? .forward : .back
			origin = horizontal
			guard forward ? canGoForward : canGoBack else {
				owner = .content
				return
			}
		}
		if owner == .scrubber {
			// Retreating well under the threshold folds the list back into the indicator;
			// sideways drift while selecting doesn't. Going past the threshold re-arms it.
			if displacement < Self.threshold / 2 { owner = .history }
		} else {
			owner = .history
		}
	}
}
