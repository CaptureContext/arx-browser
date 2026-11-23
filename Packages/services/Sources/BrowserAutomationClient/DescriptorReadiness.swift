import Dispatch
import Foundation

/// Suspends until a non-blocking descriptor can make progress, instead of polling it on a timer.
///
/// Each wait installs a one-shot dispatch source. The wait returns only after that source's
/// cancellation handler has run, so a caller that awaited every wait may close the descriptor.
public enum DescriptorReadiness {
	public enum Event: Sendable {
		case readable
		case writable
	}

	private static let queue: DispatchQueue = .init(label: "dev.capturecontext.arx.descriptor-readiness")

	/// - Parameters:
	///   - event: The condition to wait for.
	///   - descriptor: An open, non-blocking descriptor.
	///   - deadline: When to stop waiting and throw `timeout`; `nil` waits until ready or cancelled.
	///   - timeout: The error thrown at the deadline.
	public static func wait(
		for event: Event,
		on descriptor: Int32,
		until deadline: ContinuousClock.Instant? = nil,
		timeout: @autoclosure () -> any Error = CancellationError()
	) async throws {
		try Task.checkCancellation()
		let waiter = Waiter()
		let timeoutError = timeout()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
				let source: any DispatchSourceProtocol = switch event {
				case .readable: DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
				case .writable: DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
				}
				source.setEventHandler { waiter.resolve(.success(())) }
				source.setCancelHandler { waiter.finish() }
				waiter.install(source: source, continuation: continuation)

				if let deadline {
					let remaining = ContinuousClock.now.duration(to: deadline).timeInterval
					queue.asyncAfter(deadline: .now() + remaining) {
						waiter.resolve(.failure(timeoutError))
					}
				}
				source.resume()
			}
		} onCancel: {
			waiter.resolve(.failure(CancellationError()))
		}
	}

	private final class Waiter: @unchecked Sendable {
		private let lock: NSLock = .init()
		private var source: (any DispatchSourceProtocol)?
		private var continuation: CheckedContinuation<Void, any Error>?
		private var result: Result<Void, any Error>?

		internal init() {}

		internal func install(
			source: any DispatchSourceProtocol,
			continuation: CheckedContinuation<Void, any Error>
		) {
			let isResolved = lock.withLock {
				self.source = source
				self.continuation = continuation
				return result != nil
			}

			// Cancelled or timed out before installation; the cancel handler finishes the wait.
			if isResolved { source.cancel() }
		}

		/// Records the first outcome and cancels the source; the cancel handler delivers it.
		internal func resolve(_ outcome: Result<Void, any Error>) {
			let source: (any DispatchSourceProtocol)? = lock.withLock {
				guard result == nil else { return nil }

				result = outcome
				return self.source
			}
			source?.cancel()
		}

		internal func finish() {
			let delivery: (CheckedContinuation<Void, any Error>, Result<Void, any Error>)? = lock.withLock {
				guard let continuation, let result else { return nil }

				self.continuation = nil
				self.source = nil
				return (continuation, result)
			}
			guard let (continuation, result) = delivery else { return }

			continuation.resume(with: result)
		}
	}
}

extension Duration {
	fileprivate var timeInterval: TimeInterval {
		let (seconds, attoseconds) = components
		return max(0, TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
	}
}
