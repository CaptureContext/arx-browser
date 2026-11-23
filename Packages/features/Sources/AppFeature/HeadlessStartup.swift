import Foundation
import Synchronization

/// Where a headless run is on its way to `ready`. Each phase is logged to stderr with the time
/// since launch, and a run still not ready after `slow` (then after `slower`) reports a
/// `diagnostic` `startupSlow` naming the phase, so a run that seems silent says what it waits on.
internal final class HeadlessStartup: Sendable {
	internal enum Phase: String, Sendable {
		/// Before Chromium is ready: the engine, its helpers and the profile start.
		case engine

		/// Chromium is ready and Arx is opening its host window.
		case window

		/// The local MCP endpoint and the run's own client are being set up.
		case automation
		case ready
		case stopping
	}

	internal static let slow: Duration = .seconds(30)
	internal static let slower: Duration = .seconds(90)

	private let started: ContinuousClock.Instant
	private let phase: Mutex<Phase> = .init(.engine)
	private let log: @Sendable (String) -> Void
	private let report: @Sendable ([String: Any]) -> Void

	internal init(
		log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
		report: @escaping @Sendable ([String: Any]) -> Void = { HeadlessOutput.emit("diagnostic", $0) }
	) {
		self.started = .now
		self.log = log
		self.report = report
	}

	internal var current: Phase { phase.withLock { $0 } }

	/// Moves forward only: a late report of an earlier phase changes nothing.
	internal func enter(_ next: Phase) {
		let order: [Phase] = [.engine, .window, .automation, .ready, .stopping]
		let moved = phase.withLock { phase in
			guard
				let from = order.firstIndex(of: phase),
				let to = order.firstIndex(of: next),
				to > from
			else { return false }

			phase = next
			return true
		}
		guard moved else { return }

		let elapsed = ContinuousClock.now - started
		let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
		log("ARX_HEADLESS_PHASE \(next.rawValue) \(milliseconds)ms")
	}

	/// Arms the two checks. They report only while the run is still starting.
	internal func watch(
		slow: Duration = HeadlessStartup.slow,
		slower: Duration = HeadlessStartup.slower,
		schedule: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void = HeadlessStartup.afterDelay
	) {
		for limit in [slow, slower] {
			schedule(limit) { [self] in check(after: limit) }
		}
	}

	/// The check `watch` schedules: a report while the run is still starting.
	private func check(after limit: Duration) {
		let phase = current
		guard [.engine, .window, .automation].contains(phase) else { return }

		let seconds = limit.components.seconds
		log("ARX_HEADLESS_STARTUP_SLOW phase=\(phase.rawValue) seconds=\(seconds)")
		report(["code": "startupSlow", "phase": phase.rawValue, "seconds": Int(seconds)])
	}

	/// On a dispatch timer, so a busy main thread or cooperative pool can't hold a report back.
	internal static func afterDelay(
		_ delay: Duration,
		_ work: @escaping @Sendable () -> Void
	) {
		let (seconds, attoseconds) = delay.components
		let interval = TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
		DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: work)
	}
}
