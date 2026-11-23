import FairPlayProtocol
import Foundation
import OSLog

/// How the bridge reaches Arx's FairPlay helper (DEV-1144). The live one starts the helper app
/// and speaks to it over pipes; tests give their own.
@MainActor
public struct FairPlayHelperConnection {
	/// Starts the helper, unless it runs. `events` hears every event it sends, `exited` its end;
	/// both on the main actor. False when it can't start.
	public var start: (_ events: @escaping @MainActor (FairPlayHelperEvent) -> Void, _ exited: @escaping @MainActor () -> Void) -> Bool
	public var send: (FairPlayHelperCommand) -> Void

	/// Closes the helper's input, which ends it.
	public var stop: () -> Void

	public init(
		start: @escaping (_ events: @escaping @MainActor (FairPlayHelperEvent) -> Void, _ exited: @escaping @MainActor () -> Void) -> Bool,
		send: @escaping (FairPlayHelperCommand) -> Void,
		stop: @escaping () -> Void
	) {
		self.start = start
		self.send = send
		self.stop = stop
	}
}

extension FairPlayHelperConnection {
	/// The helper app inside this app's bundle.
	public static var helperExecutable: URL {
		Bundle.main.bundleURL.appending(path: "Contents/Helpers/ArxFairPlay.app/Contents/MacOS/ArxFairPlay")
	}

	/// Whether the helper app is installed with this app.
	public static var isAvailable: Bool {
		FileManager.default.isExecutableFile(atPath: helperExecutable.path)
	}

	/// The helper app at `executable`, started on demand with `environment` added to this
	/// process's, and ended when the bridge stops it or the app quits (its input closes).
	public static func live(
		executable: URL = helperExecutable,
		environment: [String: String] = [:]
	) -> Self {
		let process = FairPlayHelperProcessHandle(executable: executable, environment: environment)
		return Self(
			start: { events, exited in process.start(events: events, exited: exited) },
			send: { process.send($0) },
			stop: { process.stop() }
		)
	}
}

/// The running helper process and its pipes.
@MainActor
private final class FairPlayHelperProcessHandle {
	private let executable: URL
	private let environment: [String: String]
	private var process: RunningProcess?
	private var input: FileHandle?
	fileprivate private(set) var run: FairPlayHelperRun?
	private let writes: DispatchQueue = DispatchQueue(label: "dev.capturecontext.arx.fairplay.writes")

	init(
		executable: URL,
		environment: [String: String]
	) {
		self.executable = executable
		self.environment = environment
	}

	func start(
		events: @escaping @MainActor (FairPlayHelperEvent) -> Void,
		exited: @escaping @MainActor () -> Void
	) -> Bool {
		if process?.process.isRunning == true { return true }

		let process = Process()
		process.executableURL = executable
		process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
		let input = Pipe()
		let output = Pipe()
		process.standardInput = input
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice

		// The handlers hold only this launch, so a later launch never hears an earlier one.
		let run = FairPlayHelperRun(owner: self, events: events, exited: exited)
		output.fileHandleForReading.readabilityHandler = { handle in
			let data = handle.availableData
			if data.isEmpty { handle.readabilityHandler = nil }

			// In order: the main queue keeps the pipe's lines in sequence.
			DispatchQueue.main.async { MainActor.assumeIsolated { run.received(data) } }
		}
		process.terminationHandler = { process in
			FairPlayLog.logger.notice("The helper app ended (status \(process.terminationStatus), reason \(process.terminationReason.rawValue))")
			DispatchQueue.main.async { MainActor.assumeIsolated { run.ended() } }
		}
		do {
			try process.run()
		} catch {
			FairPlayLog.logger.error("The helper app at \(self.executable.path, privacy: .public) didn't start: \(String(describing: error), privacy: .public)")
			output.fileHandleForReading.readabilityHandler = nil
			process.terminationHandler = nil
			return false
		}
		FairPlayLog.logger.notice("The helper app started (process \(process.processIdentifier))")

		// A helper that died mustn't take the app down with a broken pipe.
		_ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
		self.process = RunningProcess(process)
		self.input = input.fileHandleForWriting
		self.run = run
		return true
	}

	func send(_ command: FairPlayHelperCommand) {
		guard let input else { return }
		let line = FairPlayLineBuffer.line(command.encoded)
		writes.async { try? input.write(contentsOf: line) }
	}

	func stop() {
		guard let running = process else { return }
		let input = self.input
		forget()
		writes.async { try? input?.close() }

		// A helper that doesn't leave once its input closes is ended.
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
			if running.process.isRunning { running.process.terminate() }
		}
	}

	/// Forgets the current launch; its pipe and its end are no longer heard.
	fileprivate func forget() {
		process = nil
		input = nil
		run = nil
	}
}

/// A launched helper, carried to the main queue to be ended if it lingers.
private final class RunningProcess: @unchecked Sendable {
	let process: Process

	init(_ process: Process) {
		self.process = process
	}
}

/// One launch of the helper: its output, split into lines, and its end, both on the main actor.
@MainActor
private final class FairPlayHelperRun {
	private weak var owner: FairPlayHelperProcessHandle?
	private let events: @MainActor (FairPlayHelperEvent) -> Void
	private let exited: @MainActor () -> Void
	private var buffer: FairPlayLineBuffer = FairPlayLineBuffer()

	init(
		owner: FairPlayHelperProcessHandle,
		events: @escaping @MainActor (FairPlayHelperEvent) -> Void,
		exited: @escaping @MainActor () -> Void
	) {
		self.owner = owner
		self.events = events
		self.exited = exited
	}

	func received(_ data: Data) {
		guard let owner, owner.run === self, !data.isEmpty else { return }
		guard let lines = try? buffer.append(data) else {
			// A line too long to be the helper's: it's ended, and its end isn't heard.
			owner.stop()
			exited()
			return
		}
		lines.compactMap(FairPlayHelperEvent.init(decoding:)).forEach(events)
	}

	func ended() {
		guard let owner, owner.run === self else { return }
		owner.forget()
		exited()
	}
}
