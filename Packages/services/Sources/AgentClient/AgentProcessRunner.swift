import Foundation
import _Dependencies

/// Runs a provider's own command-line app. Adapters build on it, and tests replace it.
public struct AgentProcessRunner: Sendable {
	/// Streams standard output line by line. Cancelling the consuming task interrupts the
	/// process. Throws ``AgentProcessFailure`` when it can't start or exits unsuccessfully.
	public var lines: @Sendable (AgentProcessInvocation) -> AsyncThrowingStream<String, any Error>

	/// Runs a short command to completion.
	public var output: @Sendable (AgentProcessInvocation) async throws -> AgentProcessOutput

	public init(
		lines: @escaping @Sendable (AgentProcessInvocation) -> AsyncThrowingStream<String, any Error>,
		output: @escaping @Sendable (AgentProcessInvocation) async throws -> AgentProcessOutput
	) {
		self.lines = lines
		self.output = output
	}
}

public struct AgentProcessInvocation: Equatable, Sendable {
	public var executable: URL
	public var arguments: [String]

	/// The whole environment. Nothing is inherited from Arx's own.
	public var environment: [String: String]

	public var workingDirectory: URL?

	/// Written to standard input, which is then closed. Prompts go here so they never show
	/// up in process listings.
	public var input: Data?

	public init(
		executable: URL,
		arguments: [String],
		environment: [String: String],
		workingDirectory: URL? = nil,
		input: Data? = nil
	) {
		self.executable = executable
		self.arguments = arguments
		self.environment = environment
		self.workingDirectory = workingDirectory
		self.input = input
	}
}

public struct AgentProcessOutput: Equatable, Sendable {
	public var status: Int32
	public var standardOutput: Data

	public init(
		status: Int32,
		standardOutput: Data
	) {
		self.status = status
		self.standardOutput = standardOutput
	}
}

public enum AgentProcessFailure: Error, Equatable, Sendable {
	case launchFailed
	case exited(status: Int32)
}

extension AgentProcessRunner {
	/// Foundation's `Process`. A cancelled run gets an interrupt, which lets the provider end
	/// its turn cleanly, and a termination signal if it's still running after `grace`.
	public static func live(grace: Duration = .seconds(3)) -> Self {
		.init(
			lines: { invocation in
				AsyncThrowingStream { continuation in
					let process: RunningProcess
					do {
						process = try .init(invocation)
					} catch {
						continuation.finish(throwing: AgentProcessFailure.launchFailed)
						return
					}

					let task: Task<Void, Never> = .init {
						do {
							for try await line in process.standardOutput.bytes.lines {
								continuation.yield(line)
							}
						} catch {
							// The pipe closes when the process exits; its status decides the result.
						}

						let status: Int32 = await process.status()
						if status == 0 {
							continuation.finish()
						} else {
							continuation.finish(throwing: AgentProcessFailure.exited(status: status))
						}
					}
					continuation.onTermination = { termination in
						guard case .cancelled = termination
						else { return }

						process.stop(grace: grace)
						task.cancel()
					}
				}
			},
			output: { invocation in
				let process: RunningProcess = try .init(invocation)
				let data: Data = try await Task.detached {
					try process.standardOutput.readToEnd() ?? Data()
				}.value
				return .init(status: await process.status(), standardOutput: data)
			}
		)
	}
}

/// A started process, its standard output and its exit status.
private final class RunningProcess: @unchecked Sendable {
	internal let standardOutput: FileHandle

	private let process: Process
	private let lock: NSLock = .init()
	private var exitStatus: Int32?
	private var waiters: [CheckedContinuation<Int32, Never>] = []

	internal init(_ invocation: AgentProcessInvocation) throws {
		let process: Process = .init()
		process.executableURL = invocation.executable
		process.arguments = invocation.arguments
		process.environment = invocation.environment
		process.currentDirectoryURL = invocation.workingDirectory

		let output: Pipe = .init()
		let input: Pipe = .init()
		process.standardOutput = output
		process.standardInput = input

		// Standard error can hold anything the provider prints; Arx never reads or logs it.
		process.standardError = FileHandle.nullDevice

		self.process = process
		self.standardOutput = output.fileHandleForReading

		process.terminationHandler = { [weak self] process in
			self?.finish(process.terminationStatus)
		}

		do {
			try process.run()
		} catch {
			throw AgentProcessFailure.launchFailed
		}

		let data: Data = invocation.input ?? Data()
		let writer: FileHandle = input.fileHandleForWriting

		// A process that exits before reading its input must not take Arx down with SIGPIPE.
		_ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
		Task.detached {
			withErrorReporting {
				try writer.write(contentsOf: data)
				try writer.close()
			}
		}
	}

	internal func status() async -> Int32 {
		await withCheckedContinuation { continuation in
			lock.lock()
			if let exitStatus {
				lock.unlock()
				continuation.resume(returning: exitStatus)
			} else {
				waiters.append(continuation)
				lock.unlock()
			}
		}
	}

	internal func stop(grace: Duration) {
		guard process.isRunning
		else { return }

		process.interrupt()
		Task.detached { [self] in
			try? await Task.sleep(for: grace)
			if self.process.isRunning { self.process.terminate() }
		}
	}

	private func finish(_ status: Int32) {
		lock.lock()
		exitStatus = status
		let waiters: [CheckedContinuation<Int32, Never>] = self.waiters
		self.waiters = []
		lock.unlock()
		waiters.forEach { $0.resume(returning: status) }
	}
}
