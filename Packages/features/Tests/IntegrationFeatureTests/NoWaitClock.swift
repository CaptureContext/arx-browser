import _ComposableArchitecture

/// A clock whose sleeps end at once, without yielding, and move its time on to their deadline,
/// so a wait measured on it takes as long on it as it would on a real clock.
internal struct NoWaitClock: Clock {
	private let start: ContinuousClock.Instant = .now
	private let elapsed = LockIsolated(Duration.zero)

	internal var now: ContinuousClock.Instant { start.advanced(by: elapsed.value) }
	internal var minimumResolution: Duration { .zero }

	/// The time that has passed on this clock.
	internal var timePassed: Duration { elapsed.value }

	internal func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
		try Task.checkCancellation()
		elapsed.withValue { $0 = max($0, start.duration(to: deadline)) }
	}
}
