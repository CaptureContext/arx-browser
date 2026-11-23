import Foundation
import Observation
import SwiftUI

/// When the footer picker shows its hint, and for which space.
///
/// Only the first hint waits: the pointer has to rest on a space for `delay` without moving.
/// Once a hint shows, moving to another space moves the hint there at once. Leaving every space
/// hides it and starts the wait over.
@MainActor
@Observable
public final class SidebarSpaceHintTimer {
	/// The space whose hint is showing.
	public private(set) var hinted: UUID?

	/// How long the pointer rests on a space before the first hint shows.
	public static let delay: Duration = .seconds(1)

	/// A stand-in id for the Library button's hint, which shares the footer's timer with the spaces.
	public static let libraryHintID: UUID = .init(uuid: (0xA7, 0x11, 0xB2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))

	@ObservationIgnored
	private let clock: any Clock<Duration>

	@ObservationIgnored
	private var waiting: Task<Void, Never>?

	public init(clock: any Clock<Duration> = ContinuousClock()) {
		self.clock = clock
	}

	/// The pointer moved over a space, or off every space for `nil`. Call it on every movement:
	/// before the first hint shows, any movement starts the rest over.
	public func pointerMoved(over id: UUID?) {
		guard let id else {
			hide()
			return
		}
		if hinted != nil {
			// A hint is up: it follows the pointer straight away.
			waiting?.cancel()
			waiting = nil
			if hinted != id { hinted = id }
			return
		}
		waiting?.cancel()
		waiting = Task { [clock] in
			do {
				try await clock.sleep(for: Self.delay)
			} catch {
				return
			}
			guard !Task.isCancelled else { return }
			self.hinted = id
			self.waiting = nil
		}
	}

	/// The pointer left `id` without landing on another item yet. A showing hint stays for `grace`, so
	/// moving across a gap to a neighbouring item (the Library button and the space dots) keeps hints quick.
	/// Before any hint shows, it hides at once, like `pointerMoved(over: nil)`.
	public func pointerLeft(
		_ id: UUID,
		grace: Duration = SidebarSpaceHintTimer.leaveGrace
	) {
		guard hinted == id else {
			if hinted == nil { hide() }
			return
		}
		waiting?.cancel()
		waiting = Task { [clock] in
			do {
				try await clock.sleep(for: grace)
			} catch {
				return
			}
			guard !Task.isCancelled, self.hinted == id else { return }
			self.hinted = nil
			self.waiting = nil
		}
	}

	/// How long a showing hint outlives the pointer leaving its item.
	public static let leaveGrace: Duration = .milliseconds(150)

	/// Hides the hint and forgets any wait, as when the pointer leaves or a drag starts.
	public func hide() {
		waiting?.cancel()
		waiting = nil
		if hinted != nil { hinted = nil }
	}
}

extension EnvironmentValues {
	/// One timer for every hint in the sidebar's footer, so a showing hint follows the pointer
	/// from the Library button to the spaces and back. `nil` gives each picker its own.
	@Entry
	public var sidebarFooterHintTimer: SidebarSpaceHintTimer? = nil
}
