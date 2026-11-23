import BrowserCore
import BrowserPageWaitClient
import Foundation
import _Dependencies

internal enum ChromiumWaitAdapter {
	/// A captured page owner. Reads and subscription setup run without an actor suspension.
	internal struct Session: Sendable {
		internal var source: PageWaitSource
		internal var read: @MainActor @Sendable () throws -> BrowserSessionSnapshot
		internal var subscribe: @MainActor @Sendable () -> Subscription

		internal init(
			source: PageWaitSource,
			read: @escaping @MainActor @Sendable () throws -> BrowserSessionSnapshot,
			subscribe: @escaping @MainActor @Sendable () -> Subscription
		) {
			self.source = source
			self.read = read
			self.subscribe = subscribe
		}
	}

	internal struct Subscription: Sendable {
		internal var events: AsyncStream<BrowserNavigation>
		internal var cancel: @MainActor @Sendable () -> Void

		internal init(
			events: AsyncStream<BrowserNavigation>,
			cancel: @escaping @MainActor @Sendable () -> Void
		) {
			self.events = events
			self.cancel = cancel
		}
	}

	@MainActor
	internal static func client(
		clock: AnyClock<Duration> = AnyClock(ContinuousClock()),
		isAvailable: @escaping @MainActor @Sendable () -> Bool,
		capture: @escaping @MainActor @Sendable (PageWaitTarget) throws -> Session,
		sourceIsCurrent: @escaping @MainActor @Sendable (PageWaitSource) -> Bool
	) -> BrowserPageWaitClient {
		let active = ActiveWaits()

		return .init(
			isAvailable: isAvailable,
			waitAuthorized: { request, target, authorize in
				try request.validate()
				try Task.checkCancellation()

				guard isAvailable() else { throw AutomationFailure.notReady }
				guard authorize() else { throw AutomationFailure.denied }
				guard request.targetID == target.tabID.rawValue
				else { throw AutomationFailure.invalidRequest }
				guard active.count < 16 else { throw AutomationFailure.busy }

				active.count += 1
				defer { active.count -= 1 }

				let deadline = clock.now.advanced(by: .milliseconds(request.timeoutMilliseconds))
				let session = try capture(target)
				let initial = try session.read()

				guard initial.revision == target.sessionRevision
				else { throw AutomationFailure.staleTarget }

				if !initial.navigation.isLoading {
					guard authorize() else { throw AutomationFailure.denied }

					return .init(source: session.source, snapshot: initial)
				}

				let subscription = session.subscribe()
				defer { subscription.cancel() }

				return try await withThrowingTaskGroup(of: PageWaitObservation.self) { group in
					group.addTask {
						try await observe(
							session,
							events: subscription.events,
							clock: clock,
							deadline: deadline,
							authorize: authorize
						)
					}

					group.addTask {
						try await clock.sleep(until: deadline)
						throw AutomationFailure.timedOut
					}
					defer { group.cancelAll() }

					guard let observation = try await group.next()
					else { throw AutomationFailure.staleTarget }

					try Task.checkCancellation()
					guard sourceIsCurrent(observation.source)
					else { throw AutomationFailure.staleTarget }
					guard authorize() else { throw AutomationFailure.denied }

					return observation
				}
			},
			sourceIsCurrent: sourceIsCurrent
		)
	}

	@MainActor
	private static func observe(
		_ session: Session,
		events: AsyncStream<BrowserNavigation>,
		clock: AnyClock<Duration>,
		deadline: AnyClock<Duration>.Instant,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async throws -> PageWaitObservation {
		// Events are wake-ups only. Never combine a buffered navigation value
		// with the epoch or identity of a replacement page.
		for await _ in events {
			try Task.checkCancellation()
			guard clock.now < deadline else { throw AutomationFailure.timedOut }

			let current = try session.read()
			guard authorize() else { throw AutomationFailure.denied }

			if !current.navigation.isLoading {
				return .init(source: session.source, snapshot: current)
			}
		}

		try Task.checkCancellation()
		throw AutomationFailure.staleTarget
	}

	@MainActor
	private final class ActiveWaits {
		internal var count: Int = 0
	}
}
