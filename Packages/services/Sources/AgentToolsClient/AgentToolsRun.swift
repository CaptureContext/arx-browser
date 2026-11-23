import Darwin
import Foundation

/// When the agent tools may touch the system, and the few processes they run.
internal enum AgentToolsRun {
	/// Automated runs never install the command or write another app's configuration:
	/// anything outside an app bundle (which includes every `swift test` run, Swift Testing
	/// sets no XCTest keys), test runs (XCTest keys), smoke fixtures (`ARX_ENGINE_PROFILE`
	/// or `--arx-…` options), headless runs, and runs with `ARX_SKIP_AGENT_TOOLS`.
	internal static func isAllowed(
		environment: [String: String],
		arguments: [String],
		bundlePath: String
	) -> Bool {
		guard bundlePath.hasSuffix(".app")
		else { return false }

		let automationKeys: [String] = [
			"ARX_SKIP_AGENT_TOOLS",
			"ARX_ENGINE_PROFILE",
			"XCTestConfigurationFilePath",
			"XCTestBundlePath",
			"XCTestSessionIdentifier",
		]
		guard automationKeys.allSatisfy({ environment[$0] == nil })
		else { return false }

		return !arguments.dropFirst().contains { argument in
			argument == "--headless" || argument.hasPrefix("--arx-")
		}
	}

	/// The person's login shell from the user database, which an app opened from the Dock
	/// doesn't get through `SHELL`.
	internal static func loginShell() -> String? {
		guard
			let entry = getpwuid(getuid()),
			let shell = entry.pointee.pw_shell
		else { return ProcessInfo.processInfo.environment["SHELL"] }

		return String(cString: shell)
	}

	/// The PATH a new terminal window gets. Apps opened from the Dock only get launchd's
	/// short PATH, so the login shell is asked, between markers so profile output is ignored.
	internal static func loginPath(shell: String?) async -> String? {
		guard let shell
		else { return nil }

		let marker: String = "__ARX_PATH__"
		let output: String? = await run(
			URL(fileURLWithPath: shell),
			arguments: ["-l", "-i", "-c", #"printf '%s%s%s' "\#(marker)" "$PATH" "\#(marker)""#],
			timeout: .seconds(3)
		)?.output
		guard
			let output,
			let start = output.range(of: marker),
			let end = output.range(of: marker, range: start.upperBound..<output.endIndex)
		else { return nil }

		return String(output[start.upperBound..<end.lowerBound])
	}

	internal struct Result: Equatable, Sendable {
		internal var status: Int32
		internal var output: String
	}

	/// Runs a program with no input and waits for it, stopping it after `timeout`.
	/// Returns `nil` when it couldn't start or ran out of time.
	internal static func run(
		_ executable: URL,
		arguments: [String],
		timeout: Duration
	) async -> Result? {
		let process: Process = .init()
		process.executableURL = executable
		process.arguments = arguments
		process.standardInput = FileHandle.nullDevice
		let pipe: Pipe = .init()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		let finished: AsyncStream<Void> = .init { continuation in
			process.terminationHandler = { _ in continuation.finish() }
		}
		do {
			try process.run()
		} catch {
			return nil
		}

		// Read as output arrives rather than to the end: a child the shell started can keep the
		// pipe open long after the shell itself has gone.
		let output: OutputBuffer = .init()
		pipe.fileHandleForReading.readabilityHandler = { handle in
			let chunk: Data = handle.availableData
			if chunk.isEmpty {
				handle.readabilityHandler = nil
				output.finish()
			} else {
				output.append(chunk)
			}
		}
		let watchdog: Task<Void, Never> = .detached {
			try? await Task.sleep(for: timeout)
			guard !Task.isCancelled
			else { return }

			await stop(process)
		}

		// Waits for the process itself, not for this task: a cancelled task would stop waiting
		// while the process still runs, and reading its termination reason then throws.
		await withTaskCancellationHandler {
			await Task.detached { for await _ in finished {} }.value
		} onCancel: {
			Task.detached { await stop(process) }
		}
		watchdog.cancel()
		let data: Data = await output.collect(grace: .milliseconds(300))
		pipe.fileHandleForReading.readabilityHandler = nil

		guard
			!process.isRunning,
			process.terminationReason == .exit,
			!Task.isCancelled
		else { return nil }

		return .init(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
	}

	/// Asks the process to stop, then kills it if it's still running a moment later: an
	/// interactive shell ignores the polite signal.
	private static func stop(_ process: Process) async {
		guard process.isRunning
		else { return }

		process.terminate()
		try? await Task.sleep(for: .milliseconds(500))
		if process.isRunning {
			kill(process.processIdentifier, SIGKILL)
		}
	}
}

/// Output read from a pipe as it arrives, collected once the pipe ends or a moment after the
/// process exits, whichever comes first.
private final class OutputBuffer: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var data: Data = .init()
	private var isFinished: Bool = false

	internal func append(_ chunk: Data) {
		lock.withLock { data.append(chunk) }
	}

	internal func finish() {
		lock.withLock { isFinished = true }
	}

	internal func collect(grace: Duration) async -> Data {
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now + grace
		while clock.now < deadline, !lock.withLock({ isFinished }) {
			try? await Task.sleep(for: .milliseconds(10))
		}
		return lock.withLock { data }
	}
}
