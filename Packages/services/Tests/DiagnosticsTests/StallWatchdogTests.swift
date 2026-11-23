@testable import DiagnosticsClient
import Foundation
import Synchronization
import Testing
import _TestSupport

/// The main-thread stall watchdog (DEV-1010), on a run loop thread of the test's own.
@Suite(.serialized)
internal struct StallWatchdogTests {
	@Test
	internal func aTwoSecondBlockIsLoggedWithItsSymbolicatedStack() async throws {
		let loop: WatchedRunLoop = try .init()
		defer { loop.finish() }

		loop.perform { StallWatchdogTests.blockTheRunLoopForStallTest(seconds: 2) }
		let stall: StallRecord = try #require(await loop.waitForEndedStall())

		#expect(stall.duration >= 1.9 && stall.duration < 4)
		#expect(stall.frames.contains { $0.symbol?.contains("blockTheRunLoopForStallTest") == true })
		#expect(stall.modules.contains { $0.uuid != nil })
		#expect(!stall.frames.contains { $0.module.contains("/") })
		// Written as it began, then again as it ended.
		let lines: [String] = try String(contentsOf: loop.log.file, encoding: .utf8).split(separator: "\n").map(String.init)
		#expect(lines.count == 2)
	}

	@Test
	internal func shortWorkIsNotAStall() async throws {
		let loop: WatchedRunLoop = try .init()
		defer { loop.finish() }

		// Blocks queued together run in one pass, so each gets a pass of its own.
		for _ in 0 ..< 5 {
			loop.perform { usleep(200_000) }
			try await Task.sleep(for: .milliseconds(300))
		}
		try await Task.sleep(for: .seconds(0.3))

		#expect(loop.log.records().isEmpty)
	}

	@Test
	internal func strictModeEndsTheRunAfterLoggingTheStall() async throws {
		let exitCode: Mutex<Int32?> = .init(nil)
		let loop: WatchedRunLoop = try .init(strictLimit: 1.3) { code in exitCode.withLock { $0 = code } }
		defer { loop.finish() }

		loop.perform { StallWatchdogTests.blockTheRunLoopForStallTest(seconds: 2) }
		try await Task.sleep(for: .seconds(2.5))

		#expect(exitCode.withLock { $0 } == StallWatchdog.strictExitCode)
		let stall: StallRecord? = loop.log.records().first
		#expect(stall?.exceededStrictLimit == true)
		#expect(stall?.duration ?? 0 >= 1.3)
	}

	@Test
	internal func aStrictLimitBelowTheThresholdStillEndsTheRun() async throws {
		let exitCode: Mutex<Int32?> = .init(nil)
		let loop: WatchedRunLoop = try .init(strictLimit: 0.3) { code in exitCode.withLock { $0 = code } }
		defer { loop.finish() }

		loop.perform { StallWatchdogTests.blockTheRunLoopForStallTest(seconds: 0.8) }
		try await Task.sleep(for: .seconds(1.2))

		#expect(exitCode.withLock { $0 } == StallWatchdog.strictExitCode)
	}

	@Test
	internal func aStrictStallBetweenTwoPollsStillEndsTheRun() async throws {
		let exitCode: Mutex<Int32?> = .init(nil)
		let loop: WatchedRunLoop = try .init(strictLimit: 0.2, threshold: 5, pollInterval: 0.5) { code in
			exitCode.withLock { $0 = code }
		}
		defer { loop.finish() }

		loop.perform { StallWatchdogTests.blockTheRunLoopForStallTest(seconds: 0.3) }
		try await Task.sleep(for: .seconds(1.2))

		#expect(exitCode.withLock { $0 } == StallWatchdog.strictExitCode)
		#expect(loop.log.records().first?.exceededStrictLimit == true)
	}

	@Test
	internal func aStrictStallJustBeforeStoppingStillEndsTheRun() async throws {
		let exitCode: Mutex<Int32?> = .init(nil)
		let loop: WatchedRunLoop = try .init(strictLimit: 0.2, threshold: 5, pollInterval: 0.5) { code in
			exitCode.withLock { $0 = code }
		}
		defer { loop.finish() }

		// Like Chromium's loop returning for good right after a long pass.
		let watchdog: StallWatchdog? = loop.watchdog
		loop.perform {
			StallWatchdogTests.blockTheRunLoopForStallTest(seconds: 0.3)

			// The next pass begins first, so the long one is measured, then the run ends.
			DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { watchdog?.stop() }
		}
		try await Task.sleep(for: .seconds(0.45))

		#expect(exitCode.withLock { $0 } == StallWatchdog.strictExitCode)
	}

	@Test
	internal func aStallThatEndsJustBeforeStoppingKeepsItsEnd() async throws {
		let loop: WatchedRunLoop = try .init(pollInterval: 0.5)
		defer { loop.finish() }

		let watchdog: StallWatchdog? = loop.watchdog
		loop.perform {
			StallWatchdogTests.blockTheRunLoopForStallTest(seconds: 1.6)
			DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { watchdog?.stop() }
		}
		try await Task.sleep(for: .seconds(2))

		let stall: StallRecord? = loop.log.records().first
		#expect(stall?.ended == true)
		#expect(stall?.duration ?? 0 >= 1.5)
	}

	@Test
	internal func workInALaterBeforeWaitingObserverIsAStall() async throws {
		let loop: WatchedRunLoop = try .init()
		defer { loop.finish() }

		// Like Core Animation's commit: an observer after the watchdog's, as the loop goes idle.
		loop.addBeforeWaitingObserver(order: 0) { StallWatchdogTests.blockTheRunLoopForStallTest(seconds: 1.5) }
		let stall: StallRecord? = await loop.waitForEndedStall()

		#expect(stall != nil)
	}

	@Test
	internal func aCutShortLastLineDoesNotSwallowTheNextRecord() throws {
		let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-stalls-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }

		let log: StallLog = .init(folder: folder)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try Data(#"{"id":"cut","date":"2026-11-1"#.utf8).write(to: log.file)
		log.append(.init(id: "next", date: Date(), duration: 1, frames: [.init(module: "Arx", offset: 1)]))

		#expect(log.records().map(\.id) == ["next"])
		#expect(log.records().first?.frames.count == 1)
	}

	@Test
	internal func theLogKeepsItsLimitAndDropsExpiredStallsFromDisk() throws {
		let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-stalls-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }

		let log: StallLog = .init(folder: folder)
		log.append(.init(id: "expired", date: Date().addingTimeInterval(-40 * 24 * 3600), duration: 1))
		for index in 0 ..< StallLog.limit + 1 {
			log.append(.init(id: "\(index)", date: Date().addingTimeInterval(Double(index)), duration: 1))
		}

		#expect(log.records().count == StallLog.limit)
		let text: String = try String(contentsOf: log.file, encoding: .utf8)
		#expect(text.split(separator: "\n").count == StallLog.limit)
		#expect(!text.contains("expired"))
		#expect(!text.contains(#""id":"0""#))
	}

	@Test
	internal func pruningRemovesExpiredStallsWithoutAnAppend() throws {
		let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-stalls-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }

		let then: Date = Date()
		StallLog(file: StallLog(folder: folder).file, now: { then }).append(.init(id: "old", date: then, duration: 1))
		let later: StallLog = .init(file: StallLog(folder: folder).file, now: { then.addingTimeInterval(31 * 24 * 3600) })
		#expect(try String(contentsOf: later.file, encoding: .utf8).contains("old"))

		later.prune()

		#expect(try String(contentsOf: later.file, encoding: .utf8).isEmpty)
	}

	@Test
	internal func concurrentAppendsAndPrunesLoseNothing() throws {
		let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-stalls-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }

		let log: StallLog = .init(folder: folder)

		// An expired record makes every prune rewrite the file.
		log.append(.init(id: "expired", date: Date().addingTimeInterval(-40 * 24 * 3600), duration: 1))
		DispatchQueue.concurrentPerform(iterations: 60) { index in
			if index.isMultiple(of: 3) {
				log.prune()
			} else {
				log.append(.init(id: "\(index)", date: Date(), duration: 1))
			}
		}

		#expect(log.records().count == 40)
	}

	@Test
	internal func anIdleLoopCostsTheWatchdogNoLooks() async throws {
		let loop: WatchedRunLoop = try .init()
		defer { loop.finish() }

		try await Task.sleep(for: .seconds(0.3))
		let settled: Int = loop.watchdog?.looks ?? 0
		try await Task.sleep(for: .seconds(1.5))

		#expect((loop.watchdog?.looks ?? 0) - settled <= 1)
	}

	@Test
	internal func busyButMovingWorkCostsAboutOneLookASecond() async throws {
		let loop: WatchedRunLoop = try .init()
		defer { loop.finish() }

		for _ in 0 ..< 20 {
			loop.perform { usleep(30_000) }
			try await Task.sleep(for: .milliseconds(100))
		}

		#expect((loop.watchdog?.looks ?? 0) <= 5)
		#expect(loop.log.records().isEmpty)
	}

	@Test
	internal func aStallThatEndedBeforeTheWatchdogLookedIsStillLogged() async throws {
		// The watchdog waits 3 s once the loop wakes, so it looks only after the stall ended.
		let loop: WatchedRunLoop = try .init(pollInterval: 3)
		defer { loop.finish() }

		loop.perform { StallWatchdogTests.blockTheRunLoopForStallTest(seconds: 1.5) }
		try await Task.sleep(for: .seconds(3.6))

		let stall: StallRecord? = loop.log.records().first
		#expect(stall?.ended == true)
		#expect(stall?.frames.isEmpty == true)
		#expect(stall?.duration ?? 0 >= 1.4)
	}

	@Test
	internal func theStrictFeatureFlagIsInMilliseconds() {
		#expect(StallWatchdog.Configuration(environment: [:]).strictLimit == nil)
		#expect(StallWatchdog.Configuration(environment: ["ARX_STALL_STRICT_MS": "1500"]).strictLimit == 1.5)
		#expect(StallWatchdog.Configuration(environment: ["ARX_STALL_STRICT_MS": "0"]).strictLimit == nil)
	}

	@Test
	internal func aStallThatNeverEndedReadsAsUnended() throws {
		let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("arx-stalls-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }

		let log: StallLog = .init(folder: folder)
		let begun: StallRecord = .init(id: "a", date: Date(), duration: 1, frames: [.init(module: "Arx", offset: 16)])
		log.append(begun)
		var ended: StallRecord = .init(id: "b", date: Date().addingTimeInterval(-60), duration: 1)
		log.append(ended)
		ended.duration = 3
		ended.ended = true
		log.append(ended)

		let records: [StallRecord] = log.records()
		#expect(records.map(\.id) == ["a", "b"])
		#expect(records[0].ended == false && records[0].frames.count == 1)
		#expect(records[1].ended && records[1].duration == 3)
		#expect(log.last?.id == "a")
	}

	@inline(never)
	internal static func blockTheRunLoopForStallTest(seconds: Double) {
		usleep(UInt32(seconds * 1_000_000))
	}
}

/// A thread running its own run loop with a watchdog on it, logging into a temporary folder.
private final class WatchedRunLoop: @unchecked Sendable {
	let log: StallLog
	private let folder: URL
	private var runLoop: CFRunLoop?
	private(set) var watchdog: StallWatchdog?

	init(
		strictLimit: TimeInterval? = nil,
		threshold: TimeInterval = 1,
		pollInterval: TimeInterval = 0.05,
		terminate: @escaping @Sendable (Int32) -> Void = { _ in }
	) throws {
		self.folder = FileManager.default.temporaryDirectory.appendingPathComponent("arx-stalls-\(UUID().uuidString)")
		self.log = .init(folder: folder)
		let ready: DispatchSemaphore = .init(value: 0)
		let log: StallLog = self.log
		let thread: Thread = .init { [self] in
			let watchdog: StallWatchdog = .init(
				log: log,
				configuration: .init(threshold: threshold, pollInterval: pollInterval, strictLimit: strictLimit, logsUnderDebugger: true),
				terminate: terminate
			)
			watchdog.start()

			// A far-off timer keeps the run loop from returning while it has nothing to do.
			let timer: Timer = .init(timeInterval: 3600, repeats: true) { _ in }
			RunLoop.current.add(timer, forMode: .default)
			self.watchdog = watchdog
			self.runLoop = CFRunLoopGetCurrent()
			ready.signal()
			CFRunLoopRun()
			watchdog.stop()
		}
		thread.start()
		ready.wait()
	}

	func perform(_ work: @escaping @Sendable () -> Void) {
		guard let runLoop else { return }

		CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
		CFRunLoopWakeUp(runLoop)
	}

	/// Runs `work` once, from an observer ordered after the watchdog's first one, the next time
	/// the loop is about to wait.
	func addBeforeWaitingObserver(
		order: CFIndex,
		_ work: @escaping @Sendable () -> Void
	) {
		guard let runLoop else { return }

		let observer: CFRunLoopObserver? = CFRunLoopObserverCreateWithHandler(
			kCFAllocatorDefault,
			CFRunLoopActivity.beforeWaiting.rawValue,
			false,
			order
		) { _, _ in work() }
		CFRunLoopAddObserver(runLoop, observer, .commonModes)
		CFRunLoopWakeUp(runLoop)
	}

	/// The first stall, once the log says it ended.
	func waitForEndedStall() async -> StallRecord? {
		for _ in 0 ..< 100 {
			if let stall = log.records().first(where: \.ended) { return stall }

			try? await Task.sleep(for: .milliseconds(50))
		}
		return nil
	}

	func finish() {
		watchdog?.stop()
		if let runLoop { CFRunLoopStop(runLoop) }
		try? FileManager.default.removeItem(at: folder)
	}
}
