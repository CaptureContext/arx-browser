import Darwin
import Foundation
import Synchronization

/// Ends a headless run's protocol exactly once. A normal shutdown reports
/// `stopped` after the runtime returns. A slow one reports a `diagnostic` first,
/// and a hung one reports `error` (`shutdownHung`) and `stopped` before the
/// process is forced to exit: by Chromium's shutdown watchdog after `deadline`,
/// or by this watchdog after `deadline` plus `grace`, whichever comes first.
internal final class HeadlessShutdown: Sendable {
	/// Chromium's own watchdog gives up on a teardown after this long.
	internal static let deadline: Duration = .seconds(60)

	/// How long a stop waits for pending workspace and history writes, well inside the
	/// 10 seconds after which a stop reports `shutdownSlow`.
	internal static let saveDeadline: Duration = .seconds(5)

	private let deadline: Duration
	private let grace: Duration
	private let slow: Duration
	private let exit: @Sendable (Int32) -> Void
	private let state: Mutex<State> = .init(State())

	private struct State {
		internal var phase: Phase
		internal var suppressedDialogs: Int

		internal init(
			phase: Phase = .running,
			suppressedDialogs: Int = 0
		) {
			self.phase = phase
			self.suppressedDialogs = suppressedDialogs
		}
	}

	private enum Phase {
		case running
		case stopping(DispatchSemaphore)
		case reported
	}

	internal init(
		deadline: Duration = HeadlessShutdown.deadline,
		grace: Duration = .seconds(15),
		slow: Duration = .seconds(10),
		exit: @escaping @Sendable (Int32) -> Void = { Darwin._exit($0) }
	) {
		self.deadline = deadline
		self.grace = grace
		self.slow = slow
		self.exit = exit
	}

	/// The run started stopping. Arms the watchdog once.
	internal func begin(suppressedDialogs: UInt64) {
		let finished = DispatchSemaphore(value: 0)
		let armed = state.withLock { state in
			guard case .running = state.phase else { return false }
			state.phase = .stopping(finished)
			state.suppressedDialogs = Int(clamping: suppressedDialogs)
			return true
		}
		guard armed else { return }

		let slow = slow
		let limit = deadline + grace
		Thread.detachNewThread { [self] in
			guard finished.wait(timeout: .now() + slow.timeInterval) == .timedOut else { return }

			// Still stopping: say so while the run can still be diagnosed.
			guard isStopping else { return }
			HeadlessOutput.emit("diagnostic", ["code": "shutdownSlow", "seconds": Int(slow.components.seconds)])
			guard finished.wait(timeout: .now() + (limit - slow).timeInterval) == .timedOut
			else { return }

			expired(exitCode: HeadlessFailure.shutdownHung.exitCode)
		}
	}

	/// Reports `stopped` after a normal shutdown. False if the run was already
	/// reported as hung.
	@discardableResult
	internal func finish(
		exitCode: Int32,
		suppressedDialogs: UInt64
	) -> Bool {
		let finished: DispatchSemaphore? = state.withLock { state in
			switch state.phase {
			case .reported:
				return nil

			case let .stopping(semaphore):
				state.phase = .reported
				return semaphore

			case .running:
				state.phase = .reported
				return DispatchSemaphore(value: 0)
			}
		}
		guard let finished else { return false }

		finished.signal()
		HeadlessOutput.emit(
			"stopped",
			["exitCode": Int(exitCode), "suppressedDialogs": Int(clamping: suppressedDialogs)]
		)
		return true
	}

	/// A shutdown that will not finish. Called on a watchdog thread, by Chromium
	/// just before it exits with `exitCode`, or by this run's own watchdog, which
	/// then exits itself.
	internal func expired(
		exitCode: Int32,
		exitsItself: Bool = false
	) {
		let suppressedDialogs: Int? = state.withLock { state in
			if case .reported = state.phase { return nil }
			state.phase = .reported
			return state.suppressedDialogs
		}
		guard let suppressedDialogs else { return }

		HeadlessOutput.emit(.shutdownHung)
		HeadlessOutput.emit("stopped", ["exitCode": Int(exitCode), "suppressedDialogs": suppressedDialogs])
		if !exitsItself { exit(exitCode) }
	}

	private var isStopping: Bool {
		state.withLock { state in
			if case .stopping = state.phase { return true }
			return false
		}
	}
}

extension Duration {
	fileprivate var timeInterval: TimeInterval {
		let (seconds, attoseconds) = components
		return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
	}
}

extension HeadlessShutdown {
	/// Runs `work` and waits for it, but for no longer than `limit`: true when it finished in
	/// time. Work that doesn't finish keeps running; the stop just doesn't wait for it.
	internal static func finish(
		within limit: Duration,
		_ work: @escaping @Sendable () async -> Void
	) async -> Bool {
		await finish(work) { expire in

			// On a dispatch timer, not a task: a busy cooperative pool must not stretch the limit.
			DispatchQueue.global().asyncAfter(deadline: .now() + limit.timeInterval, execute: expire)
		}
	}

	/// Runs `work` and waits until it finishes or `timeout` calls the function it's given,
	/// whichever comes first: true when the work came first. Tests decide when time is up.
	internal static func finish(
		_ work: @escaping @Sendable () async -> Void,
		timeout: @Sendable (@escaping @Sendable () -> Void) -> Void
	) async -> Bool {
		let once = Once()
		return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
			let resume: @Sendable (Bool) -> Void = { finished in
				if once.claim() { continuation.resume(returning: finished) }
			}
			Task {
				await work()
				resume(true)
			}
			timeout { resume(false) }
		}
	}
}

/// True for the first caller only.
private final class Once: Sendable {
	private let claimed: Mutex<Bool> = .init(false)

	internal func claim() -> Bool {
		claimed.withLock { claimed in
			defer { claimed = true }
			return !claimed
		}
	}
}
