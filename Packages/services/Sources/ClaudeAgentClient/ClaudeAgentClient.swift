import AgentClient
import BrowserAutomationClient
import Foundation
import _Dependencies

/// What the Claude adapter needs from the Mac. Tests replace every part.
public struct ClaudeCodeRuntime: Sendable {
	public var home: URL

	/// Finds the person's `claude` command, or `nil` when it isn't installed.
	public var executable: @Sendable () -> URL?

	/// Arx's own environment. Only the variables ``ClaudeCode/environment(from:home:executable:)`` keeps reach `claude`.
	public var environment: [String: String]

	public var folders: AgentProfileFolders
	public var process: AgentProcessRunner
	public var makeSessionID: @Sendable () -> UUID

	public init(
		home: URL,
		executable: @escaping @Sendable () -> URL?,
		environment: [String: String],
		folders: AgentProfileFolders,
		process: AgentProcessRunner,
		makeSessionID: @escaping @Sendable () -> UUID
	) {
		self.home = home
		self.executable = executable
		self.environment = environment
		self.folders = folders
		self.process = process
		self.makeSessionID = makeSessionID
	}

	public static var live: Self {
		let home: URL = FileManager.default.homeDirectoryForCurrentUser
		return .init(
			home: home,
			executable: { ClaudeCode.locate(in: ClaudeCode.commandFolders(home: home)) },
			environment: ProcessInfo.processInfo.environment,
			folders: .live(home: home),
			process: .live(),
			makeSessionID: { UUID() }
		)
	}
}

extension AgentProviderClient {
	/// Claude through the person's own Claude Code.
	public static func claudeCode(_ runtime: ClaudeCodeRuntime) -> Self {
		let claude: ClaudeAgent = .init(runtime: runtime)
		return .init(
			provider: .claude,
			account: { await claude.account() },
			models: { ClaudeCode.models },
			send: { request in claude.send(request) },
			discard: { token in try await claude.discard(token) }
		)
	}
}

/// The adapter's work, on top of ``ClaudeCodeRuntime``.
internal struct ClaudeAgent: Sendable {
	internal var runtime: ClaudeCodeRuntime

	internal init(runtime: ClaudeCodeRuntime) {
		self.runtime = runtime
	}

	internal func account() async -> AgentAccount {
		guard let executable = runtime.executable()
		else { return .init(provider: .claude, status: .runtimeMissing) }

		do {
			return ClaudeCode.account(from: try await authStatus(executable))
		} catch {
			return .init(provider: .claude, status: .runtimeMissing)
		}
	}

	internal func send(_ request: AgentTurnRequest) -> AsyncThrowingStream<AgentEvent, any Error> {
		AsyncThrowingStream { continuation in
			let task: Task<Void, Never> = .init {
				do {
					try await run(request) { continuation.yield($0) }
					continuation.finish()
				} catch {
					continuation.finish(throwing: Self.failure(error))
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	internal func discard(_ token: String) async throws {
		guard
			let session = UUID(uuidString: token),
			let executable = runtime.executable()
		else { return }

		let status: AgentProcessOutput = try await authStatus(executable)
		let configuration: URL = ClaudeCode.configurationDirectory(from: status, home: runtime.home)
		for transcript in ClaudeCode.transcripts(of: session, in: configuration) {
			try RealHomeGuard.check(transcript)
			try FileManager.default.removeItem(at: transcript)
		}
	}

	// MARK: - Turns

	private func run(
		_ request: AgentTurnRequest,
		emit: @Sendable (AgentEvent) -> Void
	) async throws {
		guard let executable = runtime.executable()
		else { throw AgentFailure.runtimeMissing }

		// Checked before every turn, so a sign-in that switched to an API key is never used.
		switch ClaudeCode.account(from: try await authStatus(executable)).status {
		case .signedIn:
			break

		case let .unsupportedSignIn(method):
			throw AgentFailure.unsupportedSignIn(method: method)

		case .signedOut:
			throw AgentFailure.signedOut

		case .runtimeMissing, .unavailable:
			throw AgentFailure.runtimeMissing
		}

		let workspace: URL = runtime.folders.workspace(request.profileID)
		try runtime.folders.prepare(workspace)

		let toolConfiguration: URL? = try request.browserAccess.map { connection in
			let file: URL = runtime.folders.turns(request.profileID).appending(path: UUID().uuidString + ".json")
			try runtime.folders.write(try ClaudeCode.toolConfiguration(connection), to: file)
			return file
		}
		defer {
			if let toolConfiguration {
				withErrorReporting { try runtime.folders.remove(toolConfiguration) }
			}
		}

		let session: ClaudeCode.Session = request.resumeToken.map(ClaudeCode.Session.resume)
		?? .new(runtime.makeSessionID())
		let invocation: AgentProcessInvocation = .init(
			executable: executable,
			arguments: ClaudeCode.turnArguments(
				session: session,
				modelID: request.modelID,
				effort: request.effort,
				toolConfiguration: toolConfiguration,
				input: ClaudeCode.inputFormat(for: request.attachments)
			),
			environment: ClaudeCode.environment(from: runtime.environment, home: runtime.home, executable: executable),
			workingDirectory: workspace,
			input: try ClaudeCode.input(prompt: request.prompt, attachments: request.attachments)
		)

		var stream: ClaudeCodeStream = .init(expectsBrowserTools: toolConfiguration != nil)
		do {
			for try await line in runtime.process.lines(invocation) {
				for event in try stream.consume(line) {
					emit(event)
				}
			}
		} catch let failure as AgentProcessFailure {
			// Claude Code exits unsuccessfully after a failed result; the result says why.
			try stream.finish()
			throw failure
		}
		try stream.finish()
	}

	private func authStatus(_ executable: URL) async throws -> AgentProcessOutput {
		try await runtime.process.output(
			.init(
				executable: executable,
				arguments: ClaudeCode.authStatusArguments,
				environment: ClaudeCode.environment(from: runtime.environment, home: runtime.home, executable: executable)
			)
		)
	}

	private static func failure(_ error: any Error) -> any Error {
		switch error {
		case is AgentFailure, is CancellationError:
			error

		case AgentProcessFailure.launchFailed:
			AgentFailure.runtimeMissing

		default:
			AgentFailure.interrupted
		}
	}
}

// MARK: - Dependency

public enum ClaudeAgentKey: DependencyKey {
	public static var liveValue: AgentProviderClient {
		let isEnabled: Bool = AgentProviderClient.isEnabled(
			environment: ProcessInfo.processInfo.environment,
			arguments: CommandLine.arguments
		)
		guard isEnabled
		else { return .unavailable(.claude) }

		return .claudeCode(.live)
	}

	public static var testValue: AgentProviderClient {
		.unimplemented(.claude)
	}
}

extension DependencyValues {
	/// Claude through the person's own Claude Code.
	public var claudeAgent: AgentProviderClient {
		get { self[ClaudeAgentKey.self] }
		set { self[ClaudeAgentKey.self] = newValue }
	}
}
