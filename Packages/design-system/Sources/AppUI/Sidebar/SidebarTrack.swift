import AppKit
import SwiftUI

/// How far a sideways scroll view inside the Library can still move, so it gets the swipe first.
public struct SidebarNestedScroll: Equatable, Sendable {
	public var canMoveBack: Bool
	public var canMoveForward: Bool

	public init(
		canMoveBack: Bool = false,
		canMoveForward: Bool = false
	) {
		self.canMoveBack = canMoveBack
		self.canMoveForward = canMoveForward
	}
}

internal struct SidebarNestedScrollKey: PreferenceKey {
	internal static let defaultValue: SidebarNestedScroll = .init()

	internal static func reduce(
		value: inout SidebarNestedScroll,
		nextValue: () -> SidebarNestedScroll
	) {
		let next = nextValue()
		value.canMoveBack = value.canMoveBack || next.canMoveBack
		value.canMoveForward = value.canMoveForward || next.canMoveForward
	}
}

/// The sidebar's one horizontal axis, so a swipe runs through the Library and the spaces without a seam.
///
/// A position of `n` shows space `n`. The Library sits one unit below `home`, the space it opened from.
/// Positions are in units rather than points, so the sidebar widening never moves anything.
///
/// A swipe moves the track measured frame by frame (DEV-1310):
/// - Where the track stands is a function of how far the fingers have gone since they came down,
///   and of nothing else: half as far as they go (`follow`), one stop either way from where the
///   swipe set out, and past that, or past either end, a give that grows ever more slowly and
///   never stops dead (`give(past:stiffness:)`).
/// - Let go while still moving, however slowly, and the track goes on the way it was going; let
///   go held still, it goes to whichever stop shows more.
/// - Every landing is on one spring, critically damped, that starts at the speed the track had.
///
/// With `offersCreation`, a swipe pulled past the last space by `creationThreshold` opens the Create
/// a Space page one unit after it (DEV-1109). Until it opens, the page isn't a stop: a short pull
/// rubber-bands back as before. Open, it's the last page, and swiping back leaves it.
public struct SidebarTrack: Equatable, Sendable {
	public enum Stop: Equatable, Sendable {
		case library
		case space(Int)

		/// The Create a Space page after the last space (DEV-1109).
		case creation
	}

	private struct Settling: Equatable, Sendable {
		fileprivate var target: CGFloat
		fileprivate var offset: CGFloat
		fileprivate var slope: CGFloat
		fileprivate var rate: CGFloat
		fileprivate var start: TimeInterval

		fileprivate init(
			target: CGFloat,
			offset: CGFloat,
			slope: CGFloat,
			rate: CGFloat,
			start: TimeInterval
		) {
			self.target = target
			self.offset = offset
			self.slope = slope
			self.rate = rate
			self.start = start
		}

		fileprivate func position(at time: TimeInterval) -> CGFloat {
			let elapsed = CGFloat(max(time - start, 0))
			return target + (offset + slope * elapsed) * exp(-rate * elapsed)
		}

		fileprivate func velocity(at time: TimeInterval) -> CGFloat {
			let elapsed = CGFloat(max(time - start, 0))
			return (slope - rate * (offset + slope * elapsed)) * exp(-rate * elapsed)
		}
	}

	/// One swipe, from the fingers coming down until they lift.
	private struct Swipe: Equatable, Sendable {
		fileprivate struct Move: Equatable, Sendable {
			fileprivate var time: TimeInterval
			fileprivate var travel: CGFloat
			fileprivate var position: CGFloat
		}

		/// The stop the swipe set out from: where the track rested, or the stop it was landing
		/// on when the fingers caught it.
		fileprivate var origin: CGFloat

		/// Which way the slide the fingers caught was going: 1 toward later spaces, -1 toward
		/// earlier ones, 0 when the track was at rest.
		fileprivate var heading: CGFloat

		/// Where the track stood when the fingers came down, before any give: the same as its
		/// position unless they caught it in the give past its reach.
		fileprivate var start: CGFloat

		/// The stops the swipe can reach: one either way from `origin`, within the track.
		fileprivate var reach: ClosedRange<CGFloat>

		/// How stiff the give past `reach.upperBound` is.
		fileprivate var upperStiffness: CGFloat

		/// How far the fingers have gone, in points, positive toward later spaces.
		fileprivate var travel: CGFloat

		/// The travel the track's first stop took none of: fingers that push on against it
		/// move nothing, and move the track again as soon as they turn back.
		fileprivate var spent: CGFloat

		/// The last moves, for the speed the fingers lift at.
		fileprivate var moves: [Move]

		fileprivate mutating func shift(by distance: CGFloat) {
			origin += distance
			start += distance
			reach = (reach.lowerBound + distance)...(reach.upperBound + distance)
			moves = moves.map {
				var move = $0
				move.position += distance
				return move
			}
		}
	}

	/// How far the track gives for `past` units pushed beyond where it may go: nearly all of a
	/// small push's share, less and less of a longer one, and never a whole page.
	public static func give(
		past: CGFloat,
		stiffness: CGFloat = stiffness
	) -> CGFloat {
		guard past > 0 else { return 0 }
		return 1 - 1 / (past * stiffness + 1)
	}

	/// The push that gives `give`: `give(past:stiffness:)` the other way round.
	private static func push(
		giving give: CGFloat,
		stiffness: CGFloat
	) -> CGFloat {
		guard give > 0 else { return 0 }
		return (1 / (1 - min(give, 0.999)) - 1) / stiffness
	}

	/// How far the track goes for each point the fingers go: half.
	public static let follow: CGFloat = 0.5

	/// How stiff the give past a swipe's reach is: 0.15 of a page per page pushed at first, and
	/// less and less after (a reference: 200 points of fingers at the last space moved it 14).
	public static let stiffness: CGFloat = 0.15

	/// The give toward a Create a Space page on offer is softer, so the pull that opens it can be
	/// seen: `creationThreshold` at about 0.4 of the sidebar's width of finger travel.
	private static let creationStiffness: CGFloat = 0.68

	/// Fingers slower than this as they lift, in points a second, are held still.
	private static let stillSpeed: CGFloat = 5

	/// Moves older than this as the fingers lift say nothing of their speed.
	private static let recentMoves: TimeInterval = 0.06

	/// Fingers that made no move for this long before lifting have no speed left to carry.
	private static let restingAge: TimeInterval = 0.045

	/// A swipe has uncovered the next space once the track is this far toward it, in units, so a
	/// touch that drifts a point or two sideways wakes no page.
	private static let revealDistance: CGFloat = 0.02

	/// The spring between spaces, in seconds: critically damped (DEV-1310).
	/// Opening and closing the Library keeps `BrowserMetrics.Library.transitionDuration`.
	private static let spaceResponse: Double = 0.2

	/// Closer to its stop than this, in points, the spring has landed: half a point is a pixel,
	/// and waiting out the rest of its tail held the selection back another 80 ms (DEV-1310).
	private static let settledPoints: CGFloat = 0.5

	/// A mouse wheel has no gesture to follow, so this much of it steps one stop.
	private static let wheelDistance: CGFloat = 30
	private static let wheelPause: TimeInterval = 0.3
	private static let wheelRepeat: TimeInterval = 0.4

	/// How far past the last space, in units, a swipe must pull to open the Create a Space page:
	/// about 0.4 of the sidebar's width of finger travel, through the give toward it.
	public static let creationThreshold: CGFloat = 0.12

	/// How much of a release's speed counts toward the pull, in seconds of it, so a quick pull that
	/// stops short of the threshold but is still heading past it opens the page.
	private static let creationProjection: CGFloat = 0.15

	public var libraryWidth: CGFloat
	public var pageWidth: CGFloat
	public var pageCount: Int
	public var hasLibrary: Bool
	public var nestedScroll: SidebarNestedScroll

	/// Whether a swipe past the last space offers the Create a Space page.
	public var offersCreation: Bool

	/// Whether the Create a Space page is a stop: from when a pull opens it until the track comes
	/// to rest on a space again, so it stays in place while the track leaves it.
	public private(set) var isCreationOpen: Bool
	public private(set) var position: CGFloat
	private var home: CGFloat
	private var swipe: Swipe?
	private var settling: Settling?
	private var wheelTotal: CGFloat
	private var lastWheelTime: TimeInterval?
	private var lastWheelStep: TimeInterval?
	public init(
		spaceIndex: Int,
		libraryProgress: CGFloat = 0,
		pageCount: Int,
		pageWidth: CGFloat,
		libraryWidth: CGFloat,
		hasLibrary: Bool = true,
		offersCreation: Bool = false
	) {
		self.libraryWidth = libraryWidth
		self.pageWidth = pageWidth
		self.pageCount = pageCount
		self.hasLibrary = hasLibrary
		self.nestedScroll = .init()
		self.offersCreation = offersCreation
		self.isCreationOpen = false
		self.position = CGFloat(spaceIndex) - libraryProgress
		self.home = CGFloat(spaceIndex)
		self.swipe = nil
		self.settling = nil
		self.wheelTotal = 0
		self.lastWheelTime = nil
		self.lastWheelStep = nil
	}

	public var libraryProgress: CGFloat { min(max(home - position, 0), 1) }

	/// The space under the Library stays put while the Library covers it.
	public var spacesPosition: CGFloat { max(position, home) }

	public var isSettling: Bool { settling != nil }

	/// The space the spaces have moved toward from `selected`, while the Library is shut.
	public func revealedSpace(from selected: Int) -> Int? {
		guard libraryProgress == 0 else { return nil }
		let current = CGFloat(selected)
		let revealed: Int
		if spacesPosition >= current + Self.revealDistance {
			revealed = Int(spacesPosition.rounded(.up))
		} else if spacesPosition <= current - Self.revealDistance {
			revealed = Int(spacesPosition.rounded(.down))
		} else {
			return nil
		}
		return (0..<pageCount).contains(revealed) ? revealed : nil
	}

	private var lowerBound: CGFloat { hasLibrary ? home - 1 : home }

	private var lastSpace: CGFloat { CGFloat(max(pageCount - 1, 0)) }

	/// Where the Create a Space page sits: one unit after the last space.
	public var creationPosition: CGFloat { CGFloat(pageCount) }

	/// The last stop a swipe pages to, past which it only rubber-bands.
	private var end: CGFloat { isCreationOpen ? creationPosition : lastSpace }

	/// How far a swipe has pulled past the last space toward opening the Create a Space page: 0 at
	/// the last space, 1 at `creationThreshold`, and on past it. Zero while it isn't offered or is open.
	public var creationPull: CGFloat {
		guard offersCreation, !isCreationOpen else { return 0 }

		// Only a swipe that set out from the last space pulls toward the page: one from the
		// space before it stops at the last space.
		if let swipe, swipe.origin < lastSpace { return 0 }
		return max(spacesPosition - lastSpace, 0) / Self.creationThreshold
	}

	/// The spaces changed. One made from the open Create a Space page takes the page's place;
	/// one added or removed elsewhere meanwhile, such as from another window, leaves the page on
	/// screen after the spaces, draft and all.
	public mutating func setPageCount(
		_ count: Int,
		submittedCreation: Bool = false
	) {
		guard count != pageCount else { return }
		if isCreationOpen {
			if submittedCreation, count > pageCount {
				isCreationOpen = false
			} else if position > lastSpace {
				let distance = CGFloat(count - pageCount)
				position += distance
				swipe?.shift(by: distance)
				settling = settling.map {
					var settling = $0
					settling.target += distance
					return settling
				}
			}
		}
		pageCount = count
	}

	/// Inside the open Library, a sideways scroll view spends the swipe before the track moves.
	public func nestedConsumes(
		deltaX: CGFloat,
		deltaY: CGFloat
	) -> Bool {
		guard libraryProgress == 1, abs(deltaX) > abs(deltaY) else { return false }
		return deltaX < 0 ? nestedScroll.canMoveForward : nestedScroll.canMoveBack
	}

	/// Whether a sideways move has somewhere to go, and if so, where the Library sits for it:
	/// away from a visible Library, the track leads back to the first space and the Library
	/// before it.
	private mutating func claim(
		deltaX: CGFloat,
		deltaY: CGFloat
	) -> Bool {
		guard abs(deltaX) > abs(deltaY) else { return false }
		let home = position < self.home ? self.home : 0
		let bound = hasLibrary ? home - 1 : home
		let canMove = deltaX > 0 ? position > bound : position < home || pageCount > 1 || offersCreation
		guard canMove else { return false }
		self.home = home
		return true
	}

	/// Takes over a sideways swipe with somewhere to go, from wherever a settling track has reached.
	public mutating func begin(
		deltaX: CGFloat,
		deltaY: CGFloat
	) -> Bool {
		// Where the swipe sets out from, before the Library's place moves under it.
		let landing: CGFloat? = settling?.target
		guard claim(deltaX: deltaX, deltaY: deltaY) else { return false }
		settling = nil

		let origin: CGFloat = landing ?? nearestStop

		// One stop either way, and no further than the track goes. A slide caught far from
		// where it was landing can still be taken back to the stop behind it.
		let lowest: CGFloat = min(origin - 1, position.rounded(.down))
		let highest: CGFloat = max(origin + 1, position.rounded(.up))
		let reach: ClosedRange<CGFloat> = max(lowest, lowerBound)...max(min(highest, end), lowerBound)

		// Toward a Create a Space page on offer the track gives more, so the pull shows.
		let towardCreation: Bool = offersCreation && !isCreationOpen && origin >= lastSpace
		let upperStiffness: CGFloat = towardCreation ? Self.creationStiffness : Self.stiffness

		// Caught in the give, the swipe starts as far out as the push that gave that much.
		var start: CGFloat = position
		if position > reach.upperBound {
			start = reach.upperBound + Self.push(giving: position - reach.upperBound, stiffness: upperStiffness)
		} else if position < reach.lowerBound {
			start = reach.lowerBound - Self.push(giving: reach.lowerBound - position, stiffness: Self.stiffness)
		}
		swipe = .init(
			origin: origin,
			heading: landing.map { $0 == position ? 0 : ($0 > position ? 1 : -1) } ?? 0,
			start: start,
			reach: reach,
			upperStiffness: upperStiffness,
			travel: 0,
			spent: 0,
			moves: []
		)
		return true
	}

	/// The stop nearest where the track stands.
	private var nearestStop: CGFloat {
		stops.min { abs($0 - position) < abs($1 - position) } ?? position
	}

	public mutating func move(
		by deltaX: CGFloat,
		at time: TimeInterval
	) {
		guard var swipe else { return }
		swipe.travel -= deltaX

		// Nothing shows past the track's first stop, the open Library or the first space
		// without one, so there it stops dead and no travel is owed on the way back. Everywhere
		// else the track gives, and where it stands follows the travel alone.
		if swipe.reach.lowerBound <= lowerBound {
			let raw: CGFloat = advanced(from: swipe.start, by: (swipe.travel - swipe.spent) * Self.follow)
			if raw < lowerBound {
				swipe.spent -= (lowerBound - raw) * max(libraryWidth, 1) / Self.follow
			}
		}
		position = position(of: swipe)
		swipe.moves.append(.init(time: time, travel: swipe.travel, position: position))

		// Timed by the trackpad, not as the moves arrive: ones held up behind a busy frame come
		// in a bunch, and would read as a flick.
		swipe.moves.removeAll { time - $0.time > Self.recentMoves }
		self.swipe = swipe
	}

	/// Where the track stands for how far the fingers have gone: half as far, from where the
	/// swipe started, and past its reach only what the track gives.
	private func position(of swipe: Swipe) -> CGFloat {
		let raw: CGFloat = advanced(from: swipe.start, by: (swipe.travel - swipe.spent) * Self.follow)
		if raw > swipe.reach.upperBound {
			let past: CGFloat = raw - swipe.reach.upperBound
			return swipe.reach.upperBound + Self.give(past: past, stiffness: swipe.upperStiffness)
		}
		if raw < swipe.reach.lowerBound {
			let given: CGFloat = swipe.reach.lowerBound - Self.give(past: swipe.reach.lowerBound - raw)
			return max(given, lowerBound)
		}
		return raw
	}

	/// `position` moved by `distance` points. Crossing `home` changes the scale, the Library's
	/// width on one side and a page's on the other, so each side takes its own share.
	private func advanced(
		from position: CGFloat,
		by distance: CGFloat
	) -> CGFloat {
		let page: CGFloat = max(pageWidth, 1)
		let library: CGFloat = max(libraryWidth, 1)
		if distance < 0 {
			guard position > home else { return position + distance / library }
			let step: CGFloat = min(-distance / page, position - home)
			return position - step + (distance + step * page) / library
		}
		guard position < home else { return position + distance / page }
		let step: CGFloat = min(distance / library, home - position)
		return position + step + (distance - step * library) / page
	}

	/// How fast the fingers were going as they lifted, in points a second and positive toward
	/// later spaces, and how fast the track was, in units a second.
	private func speeds(
		of swipe: Swipe,
		liftedAt time: TimeInterval
	) -> (fingers: CGFloat, track: CGFloat) {
		let moves: [Swipe.Move] = swipe.moves.filter { time - $0.time <= Self.recentMoves }
		guard
			let first = moves.first,
			let last = moves.last,
			moves.count > 1,
			// Resting a moment before lifting: no speed at all.
			time - last.time <= Self.restingAge
		else { return (0, 0) }
		let span: CGFloat = CGFloat(max(last.time - first.time, 1.0 / 120))
		return ((last.travel - first.travel) / span, (last.position - first.position) / span)
	}

	/// Lands where the swipe was going: on the way the fingers were still moving, however
	/// slowly, or held still, on whichever stop shows more.
	@discardableResult
	public mutating func release(at time: TimeInterval) -> Stop {
		guard let swipe else {
			let target: CGFloat = nearestStop
			settle(to: target, velocity: 0, at: time)
			return stop(at: target)
		}
		let speeds = speeds(of: swipe, liftedAt: time)
		if opensCreation(velocity: speeds.track) {
			isCreationOpen = true
			settle(to: creationPosition, velocity: speeds.track, at: time)
			return .creation
		}

		// The stops the swipe can land on, the one it set out from among them.
		let reachable: [CGFloat] = stops.filter { swipe.reach.contains($0) }
		var target: CGFloat = swipe.origin

		// A swipe that catches a slide and goes the same way means one stop further than the
		// slide was going: a second quick swipe goes to the space after the first one's, even
		// though the track hasn't reached the first yet.
		if speeds.fingers >= Self.stillSpeed {
			let onward: CGFloat = swipe.heading > 0 ? swipe.origin + 1 : position
			target = reachable.first { $0 >= onward } ?? reachable.last ?? swipe.origin
		} else if speeds.fingers <= -Self.stillSpeed {
			let onward: CGFloat = swipe.heading < 0 ? swipe.origin - 1 : position
			target = reachable.last { $0 <= onward } ?? reachable.first ?? swipe.origin
		} else {
			// A tie goes back to where it set out.
			let nearest: CGFloat = reachable.min { abs($0 - position) < abs($1 - position) } ?? swipe.origin
			let isCloser: Bool = abs(nearest - position) < abs(swipe.origin - position)
			target = isCloser || !reachable.contains(swipe.origin) ? nearest : swipe.origin
		}
		settle(to: target, velocity: speeds.track, at: time)
		return stop(at: target)
	}

	/// A pull past the last space opens the Create a Space page once it reaches the threshold, or
	/// is still heading there fast enough to, as momentum would carry it.
	private func opensCreation(velocity: CGFloat) -> Bool {
		guard offersCreation, !isCreationOpen, spacesPosition > lastSpace else { return false }
		if let swipe, swipe.origin < lastSpace { return false }

		// Armed, as the bubble shows, it opens however the fingers lifted.
		let pull = spacesPosition - lastSpace
		if pull >= Self.creationThreshold { return true }
		return velocity > 0 && pull + velocity * Self.creationProjection >= Self.creationThreshold
	}

	private func stop(at target: CGFloat) -> Stop {
		if isCreationOpen, target == creationPosition { return .creation }
		return target < home ? .library : .space(Int(target))
	}

	/// Steps one stop once enough of a mouse wheel has turned, and returns the stop it set out for.
	public mutating func wheel(
		by deltaX: CGFloat,
		at time: TimeInterval
	) -> Stop? {
		if let lastWheelTime, time - lastWheelTime > Self.wheelPause { wheelTotal = 0 }
		lastWheelTime = time
		wheelTotal += deltaX
		guard
			abs(wheelTotal) >= Self.wheelDistance,
			lastWheelStep.map({ time - $0 > Self.wheelRepeat }) ?? true,
			claim(deltaX: wheelTotal, deltaY: 0)
		else { return nil }
		var target = nextStop(movingForward: wheelTotal < 0)

		// A wheel turned on past the last space steps on to the Create a Space page.
		if wheelTotal < 0, offersCreation, !isCreationOpen, target == lastSpace, position >= lastSpace {
			isCreationOpen = true
			target = creationPosition
		}
		wheelTotal = 0
		lastWheelStep = time
		settle(to: target, velocity: 0, at: time)
		return stop(at: target)
	}

	private var stops: [CGFloat] {
		var spaces = stride(from: Int(home), to: max(pageCount, Int(home) + 1), by: 1).map(CGFloat.init)
		if isCreationOpen { spaces.append(creationPosition) }
		return hasLibrary ? [home - 1] + spaces : spaces
	}

	/// Leaves the Create a Space page for the last space, as Cancel and Esc do.
	public mutating func closeCreation(at time: TimeInterval) {
		guard isCreationOpen else { return }
		let velocity = settling?.velocity(at: time) ?? 0
		settle(to: lastSpace, velocity: velocity, at: time)
	}

	private func nextStop(movingForward: Bool) -> CGFloat {
		let stops = stops
		return movingForward
		? stops.first { $0 > position } ?? stops[stops.count - 1]
		: stops.last { $0 < position } ?? stops[0]
	}

	/// Follows a selection made elsewhere. Reaching a stop the track is already heading for changes nothing.
	public mutating func present(
		spaceIndex: Int,
		isLibraryOpen: Bool,
		at time: TimeInterval
	) {
		let index = CGFloat(spaceIndex)
		let target = isLibraryOpen ? index - 1 : index
		if settling?.target == target { return }
		if settling == nil, position == target { return }

		let velocity = settling?.velocity(at: time) ?? 0
		if position < home {
			position += index - home
			home = index

		} else if isLibraryOpen {
			position = index
			home = index

		} else {
			// Sliding back to an earlier space must not pass through a Library left behind at `home`.
			home = 0
		}
		settle(to: target, velocity: velocity, at: time)
	}

	/// Spaces were added or removed around the selected one, which should look untouched.
	public mutating func shift(by distance: Int) {
		// The Create a Space page stays after the spaces, however they're ordered (DEV-1109).
		guard !isCreationOpen || position <= lastSpace else {
			home += CGFloat(distance)
			return
		}
		position += CGFloat(distance)
		home += CGFloat(distance)
		swipe?.shift(by: CGFloat(distance))
		settling = settling.map {
			var settling = $0
			settling.target += CGFloat(distance)
			return settling
		}
	}

	/// Returns whether the track still has further to go.
	public mutating func advance(to time: TimeInterval) -> Bool {
		guard let settling else { return false }
		position = settling.position(at: time)
		let settledDistance: CGFloat = Self.settledPoints / max(pageWidth, 1)
		guard
			abs(position - settling.target) < settledDistance,
			abs(settling.velocity(at: time)) < settledDistance * settling.rate
		else { return true }
		finish()
		return false
	}

	/// Where the spring takes the spaces from `time` until it lands, one position every
	/// `interval` seconds: the landing as the render server plays it (`SidebarTrackSurface`).
	public func landing(
		from time: TimeInterval,
		every interval: TimeInterval,
		limit: Int = 480
	) -> [CGFloat] {
		var track: SidebarTrack = self
		var positions: [CGFloat] = []
		var time: TimeInterval = time
		while positions.count < limit {
			let isMoving: Bool = track.advance(to: time)
			positions.append(track.spacesPosition)
			if !isMoving { break }
			time += interval
		}
		return positions
	}

	/// When the spring the track is on set out, or nil at rest.
	public var settlingStart: TimeInterval? { settling?.start }

	/// Starts the spring's clock over at `time`, from where the track stands.
	///
	/// A selection made elsewhere starts its spring inside the update that selects the space,
	/// which holds the main thread for several frames. Timed from there, the first frame drawn
	/// was already most of the way along, so the slide read as a jump (DEV-1310).
	public mutating func restartSettling(at time: TimeInterval) {
		guard let settling, time > settling.start else { return }
		self.settling?.start = time
	}

	public mutating func finish() {
		if let settling { position = settling.target }
		settling = nil
		closesCreationAtRest()
	}

	/// Once the track rests on a space, the Create a Space page it left is no stop anymore.
	private mutating func closesCreationAtRest() {
		if isCreationOpen, position < creationPosition { isCreationOpen = false }
	}

	/// One critically damped spring for every landing, starting at the speed the track had,
	/// whichever way it was going: toward the stop it carries on, away from it it turns round
	/// without a jolt. Only a speed that would carry it past the stop is held to the fastest
	/// that doesn't, so the spring never shows what lies beyond.
	private mutating func settle(
		to target: CGFloat,
		velocity: CGFloat,
		at time: TimeInterval
	) {
		swipe = nil
		let offset = position - target
		guard offset != 0 else {
			settling = nil
			closesCreationAtRest()
			return
		}
		let crossesLibrary: Bool = position < home || target < home
		let response: Double = crossesLibrary ? BrowserMetrics.Library.transitionDuration : Self.spaceResponse
		let rate: CGFloat = 2 * .pi / response
		var slope: CGFloat = velocity + rate * offset

		// Past this the track would cross its stop before it came to rest.
		if slope * offset < 0 { slope = 0 }
		settling = .init(
			target: target,
			offset: offset,
			slope: slope,
			rate: rate,
			start: time
		)
	}
}

/// Runs the track: fingers while they are down, then the spring, frame by frame so it can be caught.
@MainActor
@Observable
internal final class SidebarTrackDriver: NSObject {
	internal struct Handlers {
		internal var isEnabled: Bool
		internal var reduceMotion: Bool
		internal var progressChanged: (CGFloat) -> Void

		/// Where the track came to rest, once the spring has settled there.
		internal var committed: (_ isLibraryOpen: Bool, _ spaceIndex: Int) -> Void

		/// The track while fingers move it.
		internal var tracked: (SidebarTrack) -> Void

		/// Where the track is settling before it's committed; `nil` once it is, or never will be.
		internal var landing: (SidebarTrack.Stop?) -> Void

		/// The track landed on the Create a Space page after this last space: whether that selects
		/// it or shuts the Library, which the window then presents back (DEV-1109).
		internal var creationLanded: (_ lastSpace: Int) -> Bool

		/// A key or a menu chose the space at this index: its page has to be built before the
		/// track slides there.
		internal var willSlide: (_ spaceIndex: Int) -> Void

		internal init(
			isEnabled: Bool,
			reduceMotion: Bool,
			progressChanged: @escaping (CGFloat) -> Void,
			committed: @escaping (_ isLibraryOpen: Bool, _ spaceIndex: Int) -> Void,
			tracked: @escaping (SidebarTrack) -> Void = { _ in },
			landing: @escaping (SidebarTrack.Stop?) -> Void = { _ in },
			creationLanded: @escaping (_ lastSpace: Int) -> Bool = { _ in false },
			willSlide: @escaping (_ spaceIndex: Int) -> Void = { _ in }
		) {
			self.isEnabled = isEnabled
			self.reduceMotion = reduceMotion
			self.progressChanged = progressChanged
			self.committed = committed
			self.tracked = tracked
			self.landing = landing
			self.creationLanded = creationLanded
			self.willSlide = willSlide
		}
	}

	internal private(set) var track: SidebarTrack {
		didSet {
			spacesPosition = track.spacesPosition
			showReveal()
			let visible: ClosedRange<Int> = Self.visibleSpaces(of: track)
			if visibleSpaces != visible { visibleSpaces = visible }
			if isCreationOpen != track.isCreationOpen { isCreationOpen = track.isCreationOpen }
			let pull = track.creationPull
			if creationPull != pull { creationPull = pull }
		}
	}

	/// Whether the Create a Space page is mounted (DEV-1109). It changes only as the page opens
	/// and once the track rests on a space again.
	internal private(set) var isCreationOpen: Bool = false

	/// How far a swipe has pulled toward the Create a Space page, for the + bubble alone: it
	/// changes every frame of the pull, and is zero otherwise.
	internal private(set) var creationPull: CGFloat = 0

	/// The spaces the track shows any part of. It changes only as the track crosses a space, so
	/// what reads it doesn't follow every frame.
	internal private(set) var visibleSpaces: ClosedRange<Int>

	/// Whether the track is sliding to a selection made elsewhere, such as a footer button's or a
	/// shortcut's, which can pass any number of spaces. Those it passes aren't built for the
	/// instant they're in view; fingers moving the track uncover each space at their own pace,
	/// and those are (DEV-1235).
	internal private(set) var isPassingSpaces: Bool = false

	@ObservationIgnored
	internal var handlers: Handlers?

	@ObservationIgnored
	internal weak var view: NSView?

	/// `track.spacesPosition`, for what must read it without following every frame of the track.
	@ObservationIgnored
	internal private(set) var spacesPosition: CGFloat = 0

	/// The layers that ride the track, which the render server slides: the pages, and each
	/// profile's Favorites.
	@ObservationIgnored
	private let surfaces: NSHashTable<AnyObject> = .weakObjects()

	private func eachSurface(_ body: (any SidebarTrackSurface) -> Void) {
		for object in surfaces.allObjects {
			if let surface = object as? any SidebarTrackSurface { body(surface) }
		}
	}

	/// Takes on a layer, and puts it where the track is.
	internal func attach(_ surface: any SidebarTrackSurface) {
		guard !surfaces.contains(surface) else { return }
		surfaces.add(surface)
		if isTracking {
			surface.show(position: spacesPosition)
		} else if link != nil {
			playLanding()
		} else {
			surface.rest(at: spacesPosition)
		}
	}

	/// How often a landing handed to the render server is sampled.
	private static let landingInterval: TimeInterval = 1.0 / 120

	/// Hands the landing the track is on to the render server, from where the spring set out.
	private func playLanding() {
		guard surfaces.count > 0 else { return }
		let start: TimeInterval = track.settlingStart ?? CACurrentMediaTime()
		let positions: [CGFloat] = track.landing(from: start, every: Self.landingInterval)
		awaitsLandingStart = true
		eachSurface { $0.play(positions: positions, every: Self.landingInterval) }
	}

	/// Whether a landing has been handed over and the render server hasn't taken it yet.
	@ObservationIgnored
	private var awaitsLandingStart: Bool = false

	/// The render server has taken the landing: the track's own clock starts from here too, so
	/// it stands where the layers are drawn when fingers catch it or it comes to rest.
	internal func landingBegan() {
		guard awaitsLandingStart else { return }
		awaitsLandingStart = false
		track.restartSettling(at: CACurrentMediaTime())
	}

	@ObservationIgnored
	private var link: CADisplayLink?

	@ObservationIgnored
	private var isTracking: Bool

	/// A stop reached by the fingers or a wheel, committed once the spring settles on it.
	///
	/// Committing selects a space, which rebuilds much of the window on the main thread; doing
	/// that mid-spring froze the sidebar for several frames.
	@ObservationIgnored
	private var pendingStop: SidebarTrack.Stop?

	/// Whether fingers caught the spring on its way to a stop, whose page stays shown until they
	/// choose again.
	///
	/// Catching used to say the landing was off, which put the selected space's page back for
	/// the length of the swipe: chaining swipes showed the first page, the second, the first
	/// again and then the third (DEV-1310).
	@ObservationIgnored
	private var holdsLanding: Bool = false

	/// Whether the spring's clock starts at the next frame drawn, for a slide to a selection
	/// made elsewhere (`SidebarTrack.restartSettling`).
	@ObservationIgnored
	private var restartsClock: Bool = false

	/// The Create a Space page asked for its space, which then takes the page's place.
	@ObservationIgnored
	private var submittedCreation: Bool = false

	/// Landing on the Create a Space page selected its last space or shut the Library, which the
	/// window presents back once: that presentation leaves the page where it is. Any other is a
	/// choice made elsewhere, which goes to the space it names.
	@ObservationIgnored
	private var awaitsCreationPresentation: Bool = false

	/// The selected space's place among the spaces, which `stepSpace(by:)` counts from at rest.
	@ObservationIgnored
	internal var selectedIndex: Int = 0

	/// Where the window's background reads which spaces the track stands between.
	@ObservationIgnored
	internal var reveal: SidebarSpaceReveal? {
		didSet { showReveal() }
	}

	/// The spaces in the track's order, for `reveal`.
	@ObservationIgnored
	internal var spaceIDs: [UUID] = [] {
		didSet { if spaceIDs != oldValue { showReveal() } }
	}

	private func showReveal() {
		reveal?.show(position: track.spacesPosition, among: spaceIDs)
	}

	/// Whether neither fingers nor the spring are moving the track.
	internal var isAtRest: Bool { !isTracking && link == nil }

	internal init(track: SidebarTrack) {
		self.track = track
		self.spacesPosition = track.spacesPosition
		self.visibleSpaces = Self.visibleSpaces(of: track)
		self.isCreationOpen = track.isCreationOpen
		self.creationPull = track.creationPull
		self.isTracking = false
		self.pendingStop = nil
	}

	private static func visibleSpaces(of track: SidebarTrack) -> ClosedRange<Int> {
		let last: CGFloat = CGFloat(max(track.pageCount - 1, 0))
		let position: CGFloat = min(max(track.spacesPosition, 0), last)
		return Int(position.rounded(.down))...Int(position.rounded(.up))
	}

	internal func configure(
		pageCount: Int,
		libraryWidth: CGFloat,
		hasLibrary: Bool,
		offersCreation: Bool
	) {
		if track.pageCount != pageCount {
			track.setPageCount(pageCount, submittedCreation: submittedCreation)
			submittedCreation = false
		}
		if track.libraryWidth != libraryWidth { track.libraryWidth = libraryWidth }
		if track.hasLibrary != hasLibrary { track.hasLibrary = hasLibrary }
		if track.offersCreation != offersCreation { track.offersCreation = offersCreation }
	}

	internal func pageWidthChanged(_ width: CGFloat) {
		guard track.pageWidth != width else { return }
		track.pageWidth = width
		if !isTracking, link == nil { eachSurface { $0.rest(at: track.spacesPosition) } }
	}

	internal func nestedScrollChanged(_ scroll: SidebarNestedScroll) {
		if track.nestedScroll != scroll { track.nestedScroll = scroll }
	}

	internal func nestedConsumes(
		deltaX: CGFloat,
		deltaY: CGFloat
	) -> Bool {
		track.nestedConsumes(deltaX: deltaX, deltaY: deltaY)
	}

	internal func begin(
		deltaX: CGFloat,
		deltaY: CGFloat
	) -> Bool {
		// The layer is where the render server has played the landing to, which this thread's
		// frames may be behind: the fingers take the track from there.
		var caught: SidebarTrack = track
		if link != nil, caught.advance(to: CACurrentMediaTime()) { track = caught }
		guard
			handlers?.isEnabled == true,
			track.begin(deltaX: deltaX, deltaY: deltaY)
		else { return false }
		isTracking = true
		awaitsLandingStart = false
		eachSurface { $0.show(position: track.spacesPosition) }
		stopLink()
		if isPassingSpaces { isPassingSpaces = false }
		restartsClock = false

		// Caught before it settled: the fingers choose again, and until they have, the page of
		// the stop it was landing on stays.
		if pendingStop != nil {
			pendingStop = nil
			holdsLanding = true
		}
		return true
	}

	internal func move(
		by deltaX: CGFloat,
		at time: TimeInterval
	) {
		let wasArmed = track.creationPull >= 1
		track.move(by: deltaX, at: time)

		// A detent as the pull crosses the point where letting go opens Create a Space, either way.
		if (track.creationPull >= 1) != wasArmed {
			NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
		}
		eachSurface { $0.show(position: track.spacesPosition) }
		publish()
		if !holdsLanding { handlers?.tracked(track) }
	}

	internal func release(at time: TimeInterval) {
		isTracking = false
		commit(track.release(at: time))
	}

	internal func wheel(
		by deltaX: CGFloat,
		at time: TimeInterval
	) {
		guard
			handlers?.isEnabled == true,
			let stop = track.wheel(by: deltaX, at: time)
		else { return }
		commit(stop)
	}

	private func commit(_ stop: SidebarTrack.Stop) {
		holdsLanding = false
		pendingStop = stop
		handlers?.landing(stop)
		startSettling()
	}

	private func flushPendingStop() {
		guard let stop = pendingStop else { return }
		pendingStop = nil
		switch stop {
		case .library:
			handlers?.committed(true, Int(track.spacesPosition))
		case let .space(index):
			handlers?.committed(false, index)
		case .creation:
			// The page sits after the last space with the Library shut, which a swipe from the
			// Library or another space has to say, so the last space is the one shown under it.
			awaitsCreationPresentation = handlers?.creationLanded(max(track.pageCount - 1, 0)) == true
		}
	}

	internal func present(
		spaceIndex: Int,
		isLibraryOpen: Bool
	) {
		guard !isTracking else { return }

		// The window presenting what landing on the Create a Space page selected leaves the page.
		if awaitsCreationPresentation {
			awaitsCreationPresentation = false
			if track.isCreationOpen, !isLibraryOpen, spaceIndex == track.pageCount - 1 { return }
		}

		// A selection made elsewhere wins over a stop the spring hasn't reached yet.
		if pendingStop != nil || holdsLanding {
			pendingStop = nil
			holdsLanding = false
			handlers?.landing(nil)
		}
		let resting: SidebarTrack = track
		track.present(
			spaceIndex: spaceIndex,
			isLibraryOpen: isLibraryOpen,
			at: CACurrentMediaTime()
		)

		// Presenting where the fingers already brought the track moves nothing.
		if track != resting {
			if !isPassingSpaces { isPassingSpaces = true }
			restartsClock = true
		}
		startSettling()
	}

	/// Slides to the space `step` places after the one the track is landing on, or else the
	/// selected one, going round past either end, as Next Space and Previous Space do.
	/// Returns whether it did; see `slide(toSpace:)`.
	internal func stepSpace(by step: Int) -> Bool {
		let count: Int = track.pageCount
		guard count > 1 else { return false }
		var landing: Int = selectedIndex
		if case let .space(index) = pendingStop { landing = index }
		return slide(toSpace: ((landing + step) % count + count) % count)
	}

	/// Slides to a space chosen by a key or a menu as a swipe would: its page is shown at once
	/// and it's selected only once the spring lands there (DEV-1310).
	///
	/// Selecting first, as these did, ran the selection's whole update before the slide began,
	/// and again for every press: in a recording of ⌥⌘→ pressed quickly that was nine tenths of
	/// the main thread, with frames held up to 800 ms. Now each press only turns the spring
	/// toward the next space, and the presses together cost one selection.
	///
	/// Returns `false`, changing nothing, where the selection has to come first: the space
	/// already shown, fingers on the track, the Create a Space page, Reduce Motion, or a sidebar
	/// that isn't in a window.
	internal func slide(toSpace index: Int) -> Bool {
		guard
			let handlers,
			handlers.isEnabled,
			!handlers.reduceMotion,
			!isTracking,
			!holdsLanding,
			!track.isCreationOpen,
			(0..<track.pageCount).contains(index),
			view?.window != nil
		else { return false }

		// Choosing the space already shown is the window's to answer (DEV-1126).
		if pendingStop == nil, index == selectedIndex { return false }

		let stop: SidebarTrack.Stop = .space(index)
		handlers.willSlide(index)
		track.present(
			spaceIndex: index,
			isLibraryOpen: false,
			at: CACurrentMediaTime()
		)
		if !isPassingSpaces { isPassingSpaces = true }

		// A click or the command bar may be in the middle of an update of its own.
		restartsClock = true
		pendingStop = stop
		handlers.landing(stop)
		startSettling()
		return true
	}

	/// Leaves the Create a Space page for the last space, as Cancel and Esc do (DEV-1109).
	internal func closeCreation() {
		guard !isTracking, track.isCreationOpen else { return }

		// The last space is committed once the spring lands, whatever the page was reached from.
		let last: SidebarTrack.Stop = .space(max(track.pageCount - 1, 0))
		pendingStop = last
		handlers?.landing(last)
		track.closeCreation(at: CACurrentMediaTime())
		startSettling()
	}

	/// The page asked for its space: the next space added takes the page's place.
	internal func creationSubmitted() {
		submittedCreation = true
	}

	internal func shift(by distance: Int) {
		track.shift(by: distance)
		if isTracking {
			eachSurface { $0.show(position: track.spacesPosition) }
		} else if link != nil {
			playLanding()
		} else {
			eachSurface { $0.rest(at: track.spacesPosition) }
		}
		publish()
	}

	internal func viewLeftWindow() {
		if holdsLanding {
			holdsLanding = false
			handlers?.landing(nil)
		}
		stopLink()
		track.finish()
		rested()
		publish()
		flushPendingStop()
	}

	private func startSettling() {
		guard track.isSettling else {
			stopLink()
			rested()
			publish()
			flushPendingStop()
			return
		}
		guard
			handlers?.reduceMotion != true,
			let view,
			view.window != nil
		else {
			stopLink()
			track.finish()
			rested()
			publish()
			flushPendingStop()
			return
		}
		playLanding()
		guard link == nil else { return }
		let link = view.displayLink(target: self, selector: #selector(step))
		link.add(to: .main, forMode: .common)
		self.link = link
	}

	@objc
	private func step(_ link: CADisplayLink) {
		// With layers the render server starts the landing when it takes it (`landingBegan`);
		// starting the clock over here as well would play its first frames twice.
		if restartsClock {
			restartsClock = false
			if surfaces.count == 0 { track.restartSettling(at: link.timestamp) }
		}
		let isMoving = track.advance(to: link.targetTimestamp)
		publish()
		guard !isMoving else { return }
		stopLink()
		rested()

		// After the landed frame is drawn, which the commit's work would otherwise hold back.
		RunLoop.main.perform { [weak self] in
			MainActor.assumeIsolated { self?.flushPendingStop() }
		}
	}

	private func stopLink() {
		link?.invalidate()
		link = nil
		restartsClock = false
	}

	/// The track is at rest, where only what it shows there is in view.
	private func rested() {
		if isPassingSpaces { isPassingSpaces = false }
		awaitsLandingStart = false
		eachSurface { $0.rest(at: track.spacesPosition) }
	}

	private func publish() {
		handlers?.progressChanged(track.libraryProgress)
	}
}

/// Catches a trackpad swipe before anything under the sidebar can act on it.
internal struct SidebarTrackMonitor: NSViewRepresentable {
	private let driver: SidebarTrackDriver
	private let handlers: SidebarTrackDriver.Handlers
	private let pageCount: Int
	private let selectedIndex: Int
	private let spaceIDs: [UUID]
	private let reveal: SidebarSpaceReveal?
	private let libraryWidth: CGFloat
	private let hasLibrary: Bool
	private let offersCreation: Bool

	internal init(
		driver: SidebarTrackDriver,
		handlers: SidebarTrackDriver.Handlers,
		pageCount: Int,
		selectedIndex: Int = 0,
		spaceIDs: [UUID] = [],
		reveal: SidebarSpaceReveal? = nil,
		libraryWidth: CGFloat,
		hasLibrary: Bool,
		offersCreation: Bool = false
	) {
		self.driver = driver
		self.handlers = handlers
		self.pageCount = pageCount
		self.selectedIndex = selectedIndex
		self.spaceIDs = spaceIDs
		self.reveal = reveal
		self.libraryWidth = libraryWidth
		self.hasLibrary = hasLibrary
		self.offersCreation = offersCreation
	}

	internal func makeNSView(context: Context) -> SidebarTrackView {
		let view = SidebarTrackView()
		view.driver = driver
		driver.view = view
		return view
	}

	internal func updateNSView(
		_ view: SidebarTrackView,
		context: Context
	) {
		driver.handlers = handlers
		driver.selectedIndex = selectedIndex
		driver.configure(
			pageCount: pageCount,
			libraryWidth: libraryWidth,
			hasLibrary: hasLibrary,
			offersCreation: offersCreation
		)
		driver.spaceIDs = spaceIDs
		if driver.reveal !== reveal { driver.reveal = reveal }
	}
}

internal final class SidebarTrackView: NSView {
	private enum Gesture {
		case idle
		case passedOn
		case nested
		case tracking
		case settling
	}

	private static let all: NSHashTable<SidebarTrackView> = .weakObjects()

	/// The sidebar's track in a window, for a key or a menu to slide.
	internal static func driver(in window: NSWindow) -> SidebarTrackDriver? {
		all.allObjects.first { $0.window === window && $0.driver != nil }?.driver
	}

	internal var driver: SidebarTrackDriver?
	private var monitor: Any?
	private var gesture: Gesture = .idle

	/// How far the fingers have gone while the swipe's axis is still undecided.
	private var undecided: CGSize = .zero

	/// The fingers have to have gone this far, in points, before their swipe is read as across
	/// or along the sidebar: the first move alone can be a point of drift either way.
	private static let axisDistance: CGFloat = 3

	internal override func hitTest(_ point: NSPoint) -> NSView? { nil }

	internal override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
		guard window != nil else {
			driver?.viewLeftWindow()
			return
		}
		Self.all.add(self)
		monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
			self?.handle(event) ?? event
		}
	}

	private func handle(_ event: NSEvent) -> NSEvent? {
		guard event.window === window else { return event }

		// The spring already carries the fingers' speed, so momentum has nothing to add.
		if !event.momentumPhase.isEmpty {
			return gesture == .settling ? nil : event
		}

		if event.phase.isEmpty {
			return handleWheel(event)
		}

		// Began and ended still reach the lists below, so they never wait on a gesture they saw start.
		if event.phase.contains(.began) {
			gesture = isInside(event) ? .idle : .passedOn
			undecided = .zero
			return event
		}

		if event.phase.contains(.changed) {
			if gesture == .idle {
				undecided.width += event.scrollingDeltaX
				undecided.height += event.scrollingDeltaY
				guard hypot(undecided.width, undecided.height) >= Self.axisDistance else { return event }
				gesture = nextGesture(deltaX: undecided.width, deltaY: undecided.height)
				guard gesture == .tracking else { return event }

				// All of it so far, so the track starts where the fingers are.
				driver?.move(by: undecided.width, at: event.timestamp)
				return nil
			}
			if gesture == .nested, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
				gesture = nextGesture(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
			}
			guard gesture == .tracking else { return event }
			driver?.move(by: event.scrollingDeltaX, at: event.timestamp)
			return nil
		}

		if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
			if gesture == .tracking {
				driver?.release(at: event.timestamp)
				gesture = .settling
			}
		}
		return event
	}

	/// A nested scroll view that runs out of room hands the same swipe on to the track.
	private func nextGesture(
		deltaX: CGFloat,
		deltaY: CGFloat
	) -> Gesture {
		if driver?.nestedConsumes(deltaX: deltaX, deltaY: deltaY) == true { return .nested }
		if driver?.begin(deltaX: deltaX, deltaY: deltaY) == true { return .tracking }
		return gesture == .nested ? .nested : .passedOn
	}

	private func handleWheel(_ event: NSEvent) -> NSEvent? {
		// Line-based wheels report a few units where a trackpad would report points.
		let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
		let deltaX = event.scrollingDeltaX * scale
		guard
			isInside(event),
			abs(deltaX) > abs(event.scrollingDeltaY * scale),
			driver?.nestedConsumes(deltaX: deltaX, deltaY: event.scrollingDeltaY * scale) != true
		else { return event }
		driver?.wheel(by: deltaX, at: event.timestamp)
		return nil
	}

	private func isInside(_ event: NSEvent) -> Bool {
		bounds.contains(convert(event.locationInWindow, from: nil))
		&& !SidebarTrackExclusionView.contains(event.locationInWindow, in: window)
	}

	deinit {
		MainActor.assumeIsolated {
			if let monitor { NSEvent.removeMonitor(monitor) }
		}
	}
}

/// Switches a window's sidebar to another space the way a swipe does, for the keys and menu
/// items that choose one (DEV-1310): the sidebar slides at once, the space's page shows, and
/// `onSelectSpace` reports the space only once the slide lands, so presses made in quick
/// succession select once, where the last of them lands.
///
/// Each returns whether the sidebar took it. When it returns `false` nothing has changed and
/// the caller selects the space itself.
@MainActor
public enum SidebarSpaceSwitch {
	/// To the space `step` places after the one shown, or the one the sidebar is already
	/// sliding to, going round past either end.
	public static func step(
		by step: Int,
		in window: NSWindow
	) -> Bool {
		SidebarTrackView.driver(in: window)?.stepSpace(by: step) ?? false
	}

	/// To the space at `index`, counting from 0.
	public static func select(
		spaceAt index: Int,
		in window: NSWindow
	) -> Bool {
		SidebarTrackView.driver(in: window)?.slide(toSpace: index) ?? false
	}
}

/// Slides the pager's track to one of its spaces, for the switcher's buttons in its footer.
internal struct SidebarSpaceSlide: Equatable {
	private let driver: SidebarTrackDriver
	private let spaces: [UUID]

	internal init(
		driver: SidebarTrackDriver,
		spaces: [UUID]
	) {
		self.driver = driver
		self.spaces = spaces
	}

	/// Whether the sidebar took it; see `SidebarTrackDriver.slide(toSpace:)`.
	@MainActor
	internal func callAsFunction(_ spaceID: UUID) -> Bool {
		guard let index = spaces.firstIndex(of: spaceID) else { return false }
		return driver.slide(toSpace: index)
	}

	internal nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.driver === rhs.driver && lhs.spaces == rhs.spaces
	}
}

extension EnvironmentValues {
	/// Set by the pager on its footer, so a space's button there slides the sidebar to it and
	/// the space is selected once the slide lands (DEV-1310).
	@Entry
	internal var sidebarSpaceSlide: SidebarSpaceSlide? = nil
}

/// An area of the sidebar, such as the footer's space picker, whose sideways scrolling is its own
/// and never moves the track between spaces.
internal final class SidebarTrackExclusionView: NSView {
	private static let all: NSHashTable<SidebarTrackExclusionView> = .weakObjects()

	internal override init(frame: NSRect) {
		super.init(frame: frame)
		Self.all.add(self)
	}

	internal required init?(coder: NSCoder) {
		super.init(coder: coder)
		Self.all.add(self)
	}

	internal override func hitTest(_ point: NSPoint) -> NSView? { nil }

	/// Whether a point in a window's coordinates falls inside an exclusion in that window.
	internal static func contains(
		_ location: NSPoint,
		in window: NSWindow?
	) -> Bool {
		guard let window else { return false }
		return all.allObjects.contains { view in
			view.window === window && view.bounds.contains(view.convert(location, from: nil))
		}
	}
}

private struct SidebarTrackExclusion: NSViewRepresentable {
	internal func makeNSView(context: Context) -> SidebarTrackExclusionView { .init(frame: .zero) }

	internal func updateNSView(
		_ view: SidebarTrackExclusionView,
		context: Context
	) {}
}

extension View {
	/// Keeps sideways scrolling over this view from moving the sidebar between spaces.
	public func sidebarTrackExclusion() -> some View {
		background { SidebarTrackExclusion() }
	}
}
