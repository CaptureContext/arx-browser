import Foundation

/// Joins streamed text so a feature receives a few batches a second instead of every token.
///
/// Providers stream text in pieces that can arrive hundreds of times a second. Sending each
/// one to a store would flood it, so text collects here and leaves at most once per
/// ``interval``. Any other event flushes the waiting text first, so order is kept.
public struct AgentEventCoalescer: Sendable {
	public var interval: Duration

	private var pending: String
	private var lastFlush: ContinuousClock.Instant?

	public init(interval: Duration = .milliseconds(100)) {
		self.interval = interval
		self.pending = ""
		self.lastFlush = nil
	}

	/// Takes one event and returns what may be delivered now.
	public mutating func push(
		_ event: AgentEvent,
		at now: ContinuousClock.Instant
	) -> [AgentEvent] {
		guard case let .text(text) = event
		else { return flush(at: now) + [event] }

		pending += text
		let isDue: Bool = lastFlush.map { now - $0 >= interval } ?? true
		return isDue ? flush(at: now) : []
	}

	/// Returns the text still waiting, when the stream ends.
	public mutating func finish() -> [AgentEvent] {
		guard !pending.isEmpty
		else { return [] }

		defer { pending = "" }
		return [.text(pending)]
	}

	private mutating func flush(at now: ContinuousClock.Instant) -> [AgentEvent] {
		guard !pending.isEmpty
		else { return [] }

		defer {
			pending = ""
			lastFlush = now
		}
		return [.text(pending)]
	}
}

extension AsyncThrowingStream where Element == AgentEvent, Failure == any Error {
	/// Groups events into batches with ``AgentEventCoalescer``. Text that arrives during a pause
	/// waits for the next event or the end of the stream.
	public func coalesced(
		interval: Duration = .milliseconds(100),
		clock: ContinuousClock = .init()
	) -> AsyncThrowingStream<[AgentEvent], any Error> {
		AsyncThrowingStream<[AgentEvent], any Error> { continuation in
			let task: Task<Void, Never> = .init {
				var coalescer: AgentEventCoalescer = .init(interval: interval)
				do {
					for try await event in self {
						let batch: [AgentEvent] = coalescer.push(event, at: clock.now)
						if !batch.isEmpty { continuation.yield(batch) }
					}
					let rest: [AgentEvent] = coalescer.finish()
					if !rest.isEmpty { continuation.yield(rest) }
					continuation.finish()
				} catch {
					let rest: [AgentEvent] = coalescer.finish()
					if !rest.isEmpty { continuation.yield(rest) }
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}
