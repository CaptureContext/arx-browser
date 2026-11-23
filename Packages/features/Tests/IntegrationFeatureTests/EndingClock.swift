import Foundation

/// A clock whose sleeps end at once, as cancelled, so a timer never fires.
///
/// For tests that run a live `Store` and wait for its effects to finish: a waiting timer
/// such as a chat turn's silence watch (DEV-643) would otherwise keep them waiting.
internal struct EndingClock: Clock {
	internal typealias Duration = Swift.Duration
	internal typealias Instant = ContinuousClock.Instant

	internal var now: Instant {
		ContinuousClock.now
	}

	internal var minimumResolution: Duration {
		.zero
	}

	internal func sleep(
		until deadline: Instant,
		tolerance: Duration?
	) async throws {
		throw CancellationError()
	}
}
