import CoreFoundation
import Darwin
import Foundation
import Synchronization

/// Notices when a thread's run loop stops turning (DEV-1010).
///
/// A run-loop observer stamps every pass through the loop. A watchdog thread looks only when the
/// current pass could have reached ``Configuration/threshold``, and parks while the loop waits, so
/// an idle app costs it no wakes and a busy one about one a second. Once a pass has been busy for
/// the threshold, it samples the thread's stack (``ThreadSampler``) and appends the stall to the
/// ``StallLog`` at once, then again with its full length when the loop comes back. A pass that
/// reached the threshold and ended before the watchdog looked is still logged, as the run loop
/// measured it, without a stack.
/// Time is the Mac's uptime, so sleep never counts as a stall, and nothing is logged while a
/// debugger is attached.
///
/// Strict mode (`ARX_STALL_STRICT_MS`, for smokes) ends the process with ``strictExitCode`` once
/// a stall passes its limit, after logging it.
public final class StallWatchdog: @unchecked Sendable {
	public struct Configuration: Equatable, Sendable {
		/// How long one pass may take before it's a stall.
		public var threshold: TimeInterval

		/// How often the watchdog looks while a stall is open, and the least it waits between looks.
		public var pollInterval: TimeInterval

		/// Strict mode: a stall this long ends the process. `nil` only logs.
		public var strictLimit: TimeInterval?

		/// Whether stalls are logged while a debugger is attached, which pauses the app at will.
		public var logsUnderDebugger: Bool

		public init(
			threshold: TimeInterval = 1,
			pollInterval: TimeInterval = 0.05,
			strictLimit: TimeInterval? = nil,
			logsUnderDebugger: Bool = false
		) {
			self.threshold = threshold
			self.pollInterval = pollInterval
			self.strictLimit = strictLimit
			self.logsUnderDebugger = logsUnderDebugger
		}

		/// The default, with strict mode from `ARX_STALL_STRICT_MS` (milliseconds).
		public init(environment: [String: String]) {
			self.init(
				strictLimit: environment[Self.strictFeatureFlag]
					.flatMap(Double.init)
					.flatMap { $0 > 0 ? $0 / 1000 : nil }
			)
		}

		/// The feature flag smokes set to fail a run on a long stall.
		public static let strictFeatureFlag: String = "ARX_STALL_STRICT_MS"
	}

	/// The exit status of a run strict mode ended.
	public static let strictExitCode: Int32 = 86

	private struct State {
		/// Counts passes through the loop.
		var pass: UInt64 = 0
		var passStart: UInt64
		var waiting: Bool = false

		/// The pass the watchdog reported as a stall, and when it ended.
		var reportedPass: UInt64?
		var reportedPassEnd: UInt64?

		/// The longest busy pass past strict mode's limit, measured by the run loop itself, so a
		/// short one between two polls isn't missed.
		var strictlyExceeded: UInt64?

		/// A pass that reached the threshold and ended before the watchdog looked: its length and
		/// when it ended.
		var unseenStall: (length: UInt64, end: UInt64)?

		/// The watchdog thread is waiting for the loop to wake.
		var parked: Bool = false
	}

	private struct Pending {
		var pass: UInt64
		var start: UInt64
		var record: StallRecord
	}

	public let configuration: Configuration
	private let log: StallLog
	private let sampler: ThreadSampler
	private let runLoop: CFRunLoop
	private let environment: DiagnosticsEnvironment?
	private let terminate: @Sendable (Int32) -> Void
	private let state: Mutex<State>

	/// The stall logged as begun and not yet as ended. Its lock covers the end's write, so the
	/// watchdog thread and `stop()` never both write it.
	private let pending: Mutex<Pending?> = .init(nil)

	/// Wakes a parked watchdog thread.
	private let wake: DispatchSemaphore = .init(value: 0)

	/// How many times the watchdog thread has looked, for tests of what it costs.
	private let lookCount: Mutex<Int> = .init(0)
	private let thresholdNanoseconds: UInt64
	private let running: Mutex<Bool> = .init(false)
	private var observers: [CFRunLoopObserver] = []
	private let strictLimitNanoseconds: UInt64?

	/// Watches the calling thread's run loop. Call it on the thread to watch, then ``start()``.
	///
	/// - Parameters:
	///   - terminate: ends the process for strict mode; `_exit` unless a test replaces it.
	public init(
		log: StallLog,
		configuration: Configuration = .init(),
		environment: DiagnosticsEnvironment? = nil,
		terminate: @escaping @Sendable (Int32) -> Void = { _exit($0) }
	) {
		self.log = log
		self.configuration = configuration
		self.environment = environment
		self.terminate = terminate
		self.sampler = .init(thread: pthread_mach_thread_np(pthread_self()))
		self.runLoop = CFRunLoopGetCurrent()
		self.state = .init(.init(passStart: Self.uptime()))
		self.strictLimitNanoseconds = configuration.strictLimit.map(Self.nanoseconds)
		self.thresholdNanoseconds = Self.nanoseconds(configuration.threshold)
	}

	deinit {
		stop()
	}

	/// Starts observing the run loop it was made on and starts the watchdog thread.
	public func start() {
		let started: Bool = running.withLock { running in
			defer { running = true }
			return !running
		}
		guard started else { return }

		// First among observers, every activity starts a busy pass, `.beforeWaiting` included: the
		// work other observers do then, such as Core Animation's commits, can stall too. Last among
		// observers, `.beforeWaiting` marks the loop idle once that work is done.
		let busy: CFRunLoopActivity = [.entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit]
		let observers: [CFRunLoopObserver?] = [
			CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, busy.rawValue, true, CFIndex.min) { [weak self] _, _ in
				self?.markPass(waiting: false)
			},
			CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
				self?.markPass(waiting: true)
			},
		]
		self.observers = observers.compactMap { $0 }
		for observer in self.observers {
			CFRunLoopAddObserver(runLoop, observer, .commonModes)
		}

		let thread: Thread = .init { [self] in watch() }
		thread.name = "Arx stall watchdog"
		thread.qualityOfService = .userInteractive
		thread.start()
	}

	/// Stops the watchdog thread and removes the observer.
	public func stop() {
		// A pass past the strict limit that ended since the last poll, as the run loop returned
		// for good, still ends the run, so a smoke can't pass by quitting quickly.
		if
			running.withLock({ $0 }),
			let exceeded = state.withLock({ $0.strictlyExceeded }),
			configuration.logsUnderDebugger || !Self.isDebuggerAttached()
		{
			endForStrictMode(
				.init(
					id: UUID().uuidString,
					date: Date().addingTimeInterval(-Self.seconds(exceeded)),
					duration: Self.seconds(exceeded),
					ended: true,
					appVersion: environment?.appVersion,
					appBuild: environment?.appBuild,
					processID: getpid()
				),
				duration: exceeded
			)
		}
		running.withLock { $0 = false }
		wake.signal()

		// A stall that ended since the last poll keeps its full length.
		flushEndedStall(state.withLock { $0 })
		for observer in observers {
			CFRunLoopRemoveObserver(runLoop, observer, .commonModes)
			CFRunLoopObserverInvalidate(observer)
		}
		observers = []
	}

	/// The run loop's side: a new pass begins, and a reported stall ends.
	private func markPass(waiting: Bool) {
		let now: UInt64 = Self.uptime()
		let strictLimit: UInt64? = strictLimitNanoseconds
		let threshold: UInt64 = thresholdNanoseconds
		let unparks: Bool = state.withLock { state in
			if state.reportedPass == state.pass, state.reportedPassEnd == nil {
				state.reportedPassEnd = now
			}
			let length: UInt64 = Self.elapsed(from: state.passStart, to: now)
			if let strictLimit, !state.waiting, length >= strictLimit {
				state.strictlyExceeded = max(state.strictlyExceeded ?? 0, length)
			}
			if !state.waiting, length >= threshold, state.reportedPass != state.pass,
			   length > state.unseenStall?.length ?? 0 {
				state.unseenStall = (length, now)
			}
			state.pass &+= 1
			state.passStart = now
			state.waiting = waiting
			guard !waiting, state.parked else { return false }

			state.parked = false
			return true
		}

		// Once per wake from idle at most: the watchdog doesn't park again before it has looked.
		if unparks { wake.signal() }
	}

	// MARK: - Watching

	private func watch() {
		let strictLimit: UInt64? = configuration.strictLimit.map(Self.nanoseconds)

		// A strict limit below the threshold is a stall of its own.
		let threshold: UInt64 = min(Self.nanoseconds(configuration.threshold), strictLimit ?? .max)
		while running.withLock({ $0 }) {
			// Idle with nothing open: park until the loop wakes, rather than look at a sleeping loop.
			let hasPending: Bool = pending.withLock { $0 != nil }
			if !hasPending {
				let parked: Bool = state.withLock { state in
					guard state.waiting, state.strictlyExceeded == nil, state.unseenStall == nil else { return false }

					state.parked = true
					return true
				}
				if parked {
					wake.wait()
					continue
				}
			}

			// Then look when the current pass could have reached the threshold, or every poll while a
			// stall is open.
			let passStart: UInt64 = state.withLock { $0.passStart }
			let untilThreshold: TimeInterval = Self.seconds(threshold - min(threshold, Self.elapsed(from: passStart, to: Self.uptime())))
			Thread.sleep(forTimeInterval: hasPending ? configuration.pollInterval : max(configuration.pollInterval, untilThreshold))

			// `stop()` may have run while it slept.
			guard running.withLock({ $0 }) else { break }

			lookCount.withLock { $0 += 1 }
			let snapshot: State = state.withLock { $0 }

			// Read after the snapshot, so no pass in it starts later than `now`.
			let now: UInt64 = Self.uptime()

			if let unseen = snapshot.unseenStall {
				state.withLock { $0.unseenStall = nil }
				if configuration.logsUnderDebugger || !Self.isDebuggerAttached() {
					let ended: Date = Date().addingTimeInterval(-Self.seconds(Self.elapsed(from: unseen.end, to: now)))
					log.append(
						.init(
							id: UUID().uuidString,
							date: ended.addingTimeInterval(-Self.seconds(unseen.length)),
							duration: Self.seconds(unseen.length),
							ended: true,
							appVersion: environment?.appVersion,
							appBuild: environment?.appBuild,
							processID: getpid()
						)
					)
				}
			}

			// A pass past the strict limit that ended between two polls, as the run loop measured it.
			if let exceeded = snapshot.strictlyExceeded,
			   configuration.logsUnderDebugger || !Self.isDebuggerAttached() {
				let record: StallRecord = pending.withLock { $0?.record } ?? .init(
					id: UUID().uuidString,
					date: Date().addingTimeInterval(-Self.seconds(exceeded)),
					duration: Self.seconds(exceeded),
					ended: true,
					appVersion: environment?.appVersion,
					appBuild: environment?.appBuild,
					processID: getpid()
				)
				endForStrictMode(record, duration: exceeded)
				continue
			}

			if let current = pending.withLock({ $0 }) {
				if !flushEndedStall(snapshot),
				   let strictLimit,
				   let length = stillStalled(current.pass, since: current.start),
				   length >= strictLimit {
					endForStrictMode(current.record, duration: length)
				}
				continue
			}

			guard !snapshot.waiting, Self.elapsed(from: snapshot.passStart, to: now) >= threshold else { continue }
			guard configuration.logsUnderDebugger || !Self.isDebuggerAttached() else { continue }

			// The begin is written under `pending`'s lock, so `stop()` waits for it and then writes
			// the end; if `stop()` already ran, the end is written here.
			pending.withLock { pending in
				beginStall(snapshot, now: now, pending: &pending)
				if !running.withLock({ $0 }) {
					flushEndedStall(state.withLock { $0 }, pending: &pending)
				}
			}
		}
	}

	/// Claims the stalled pass, samples the stack and logs the stall as begun.
	private func beginStall(
		_ snapshot: State,
		now: UInt64,
		pending: inout Pending?
	) {
		// Claim the pass, unless the loop moved on since the snapshot.
		let claimed: Bool = state.withLock { state in
			guard state.pass == snapshot.pass else { return false }

			state.reportedPass = snapshot.pass
			state.reportedPassEnd = nil
			return true
		}
		guard claimed else { return }

		let (frames, modules) = sampler.frames()
		let record: StallRecord = .init(
			id: UUID().uuidString,
			date: Date().addingTimeInterval(-Self.seconds(Self.elapsed(from: snapshot.passStart, to: now))),
			duration: Self.seconds(Self.elapsed(from: snapshot.passStart, to: Self.uptime())),
			appVersion: environment?.appVersion,
			appBuild: environment?.appBuild,
			processID: getpid(),
			frames: frames,
			modules: modules
		)
		log.append(record)

		// Strict mode decides on a later poll, from the pass's own length, never from how long
		// sampling and logging took.
		pending = .init(pass: snapshot.pass, start: snapshot.passStart, record: record)
	}

	private func endForStrictMode(
		_ record: StallRecord,
		duration: UInt64
	) {
		guard running.withLock({ $0 }) else { return }

		var record: StallRecord = record
		record.duration = max(record.duration, Self.seconds(duration))
		record.exceededStrictLimit = true
		record.frames = []
		record.modules = []
		log.append(record)
		FileHandle.standardError.write(
			Data("Arx stall watchdog: the main thread stalled \(Int(record.duration * 1000)) ms (strict mode)\n".utf8)
		)
		running.withLock { $0 = false }
		terminate(Self.strictExitCode)
	}

	/// Logs the pending stall's end once the run loop recorded it. Returns whether it did.
	@discardableResult
	private func flushEndedStall(_ snapshot: State) -> Bool {
		pending.withLock { flushEndedStall(snapshot, pending: &$0) }
	}

	/// The same, with `pending`'s lock already held.
	@discardableResult
	private func flushEndedStall(
		_ snapshot: State,
		pending: inout Pending?
	) -> Bool {
		guard
			let current = pending,
			let end = snapshot.reportedPassEnd,
			snapshot.reportedPass == current.pass
		else { return false }

		var record: StallRecord = current.record
		record.duration = Self.seconds(Self.elapsed(from: current.start, to: end))
		record.ended = true
		record.frames = []
		record.modules = []
		log.append(record)
		pending = nil
		return true
	}

	/// How long `pass` has run, or `nil` once the run loop ended it.
	private func stillStalled(
		_ pass: UInt64,
		since start: UInt64
	) -> UInt64? {
		state.withLock { state in
			guard state.reportedPass != pass || state.reportedPassEnd == nil else { return nil }

			return Self.elapsed(from: start, to: Self.uptime())
		}
	}

	/// How many times the watchdog thread has looked at the loop.
	internal var looks: Int {
		lookCount.withLock { $0 }
	}

	// MARK: - Time

	private static func uptime() -> UInt64 {
		clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
	}

	/// Never negative: a pass the run loop started after `end` was read counts as no time.
	private static func elapsed(
		from start: UInt64,
		to end: UInt64
	) -> UInt64 {
		end > start ? end - start : 0
	}

	private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
		UInt64(max(seconds, 0) * 1_000_000_000)
	}

	private static func seconds(_ nanoseconds: UInt64) -> TimeInterval {
		TimeInterval(nanoseconds) / 1_000_000_000
	}

	private static func isDebuggerAttached() -> Bool {
		var info: kinfo_proc = .init()
		var size: Int = MemoryLayout<kinfo_proc>.stride
		var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
		guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return false }

		return info.kp_proc.p_flag & P_TRACED != 0
	}
}
