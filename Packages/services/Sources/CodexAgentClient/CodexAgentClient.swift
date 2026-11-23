import AgentClient
import BrowserAutomationClient
import Foundation
import _Dependencies

/// What the Codex adapter needs from the Mac. Tests replace every part.
public struct CodexRuntime: Sendable {
	public var home: URL

	/// Finds the person's `codex` command, or `nil` when it isn't installed.
	public var executable: @Sendable () -> URL?

	/// Arx's own environment. Only the variables ``CodexCLI/environment(from:home:executable:)`` keeps reach `codex`.
	public var environment: [String: String]

	public var folders: AgentProfileFolders
	public var process: AgentProcessRunner

	/// Names each turn's private folder.
	public var makeTurnID: @Sendable () -> UUID

	public init(
		home: URL,
		executable: @escaping @Sendable () -> URL?,
		environment: [String: String],
		folders: AgentProfileFolders,
		process: AgentProcessRunner,
		makeTurnID: @escaping @Sendable () -> UUID
	) {
		self.home = home
		self.executable = executable
		self.environment = environment
		self.folders = folders
		self.process = process
		self.makeTurnID = makeTurnID
	}

	public static var live: Self {
		let home: URL = FileManager.default.homeDirectoryForCurrentUser
		return .init(
			home: home,
			executable: { CodexCLI.locate(in: CodexCLI.commandFolders(home: home)) },
			environment: ProcessInfo.processInfo.environment,
			folders: .live(home: home),
			process: .live(),
			makeTurnID: { UUID() }
		)
	}
}

extension AgentProviderClient {
	/// ChatGPT through the person's own Codex CLI.
	public static func codex(_ runtime: CodexRuntime) -> Self {
		let codex: CodexAgent = .init(runtime: runtime)
		return .init(
			provider: .openAI,
			account: { await codex.account() },
			models: { await codex.models() },
			send: { request in codex.send(request) },
			discard: { token in try await codex.discard(token) }
		)
	}
}

/// The adapter's work, on top of ``CodexRuntime``.
internal struct CodexAgent: Sendable {
	internal var runtime: CodexRuntime

	internal init(runtime: CodexRuntime) {
		self.runtime = runtime
	}

	internal func account() async -> AgentAccount {
		guard let executable = runtime.executable()
		else { return .init(provider: .openAI, status: .runtimeMissing) }

		do {
			return CodexCLI.account(from: try await authStatus(executable), home: runtime.home)
		} catch {
			return .init(provider: .openAI, status: .runtimeMissing)
		}
	}

	internal func models() async -> [AgentModel] {
		guard let executable = runtime.executable()
		else { return [] }

		let invocation: AgentProcessInvocation = .init(
			executable: executable,
			arguments: CodexCLI.modelsArguments,
			environment: environment(executable)
		)
		guard let output = try? await runtime.process.output(invocation)
		else { return [] }

		return CodexCLI.models(from: output)
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

	/// Deletes a thread's transcript with `codex delete`. Tokens that aren't thread
	/// identifiers are ignored, so nothing else can be passed to the command.
	internal func discard(_ token: String) async throws {
		guard
			let threadID = UUID(uuidString: token),
			let executable = runtime.executable()
		else { return }

		let output: AgentProcessOutput = try await runtime.process.output(
			CodexCLI.deleteInvocation(threadID: threadID, executable: executable, environment: environment(executable))
		)
		guard CodexCLI.isDeleted(output)
		else { throw AgentFailure.runtimeFailed("codex delete failed") }
	}

	// MARK: - Turns

	private func run(
		_ request: AgentTurnRequest,
		emit: @Sendable (AgentEvent) -> Void
	) async throws {
		guard let executable = runtime.executable()
		else { throw AgentFailure.runtimeMissing }

		// Checked before every turn, so a sign-in that switched to an API key is never used.
		switch CodexCLI.account(from: try await authStatus(executable), home: runtime.home).status {
		case .signedIn:
			break

		case let .unsupportedSignIn(method):
			throw AgentFailure.unsupportedSignIn(method: method)

		case .signedOut:
			throw AgentFailure.signedOut

		case .runtimeMissing, .unavailable:
			throw AgentFailure.runtimeMissing
		}

		// Every turn gets its own empty folder in the profile. With browser access it holds
		// the tool configuration, which only this turn's `codex` reads.
		let turnID: UUID = runtime.makeTurnID()
		let folder: URL = runtime.folders.turns(request.profileID)
			.appending(path: turnID.uuidString, directoryHint: .isDirectory)
		try runtime.folders.prepare(folder)
		defer {
			withErrorReporting { try runtime.folders.remove(folder) }
		}

		if let connection = request.browserAccess {
			try runtime.folders.write(
				CodexCLI.toolConfiguration(connection),
				to: CodexCLI.toolConfigurationFile(in: folder)
			)
		}

		let attachments: [AgentContextAttachment] = CodexCLI.readable(request.attachments)
		var images: [URL] = []
		for image in AgentPrompt.images(in: attachments) {
			let file: URL = CodexCLI.imageFile(image, in: folder)
			try runtime.folders.write(image.data, to: file)
			images.append(file)
		}

		let session: CodexCLI.Session = request.resumeToken.map(CodexCLI.Session.resume) ?? .new
		let invocation: AgentProcessInvocation = .init(
			executable: executable,
			arguments: CodexCLI.turnArguments(
				session: session,
				modelID: request.modelID,
				effort: request.effort,
				trustedFolder: request.browserAccess == nil ? nil : folder,
				images: images
			),
			environment: environment(executable),
			workingDirectory: folder,
			input: Data(AgentPrompt.render(request.prompt, attachments: attachments).utf8)
		)

		var stream: CodexStream = .init(
			expectsBrowserTools: request.browserAccess != nil,
			turnID: turnID.uuidString.lowercased(),
			modelID: request.modelID
		)
		do {
			for try await line in runtime.process.lines(invocation) {
				for event in try stream.consume(line) {
					emit(event)
				}
			}
		} catch AgentProcessFailure.launchFailed {
			throw AgentFailure.runtimeMissing
		} catch let failure as AgentProcessFailure {
			// Codex exits unsuccessfully after a failed turn; the turn says why.
			try stream.finish()
			throw failure
		}
		try stream.finish()
	}

	private func authStatus(_ executable: URL) async throws -> AgentProcessOutput {
		try await runtime.process.output(
			CodexCLI.authStatusInvocation(executable: executable, environment: environment(executable))
		)
	}

	private func environment(_ executable: URL) -> [String: String] {
		CodexCLI.environment(from: runtime.environment, home: runtime.home, executable: executable)
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

public enum CodexAgentKey: DependencyKey {
	public static var liveValue: AgentProviderClient {
		let isEnabled: Bool = AgentProviderClient.isEnabled(
			environment: ProcessInfo.processInfo.environment,
			arguments: CommandLine.arguments
		)
		guard isEnabled
		else { return .unavailable(.openAI) }

		return .codex(.live)
	}

	public static var testValue: AgentProviderClient {
		.unimplemented(.openAI)
	}
}

extension DependencyValues {
	/// ChatGPT through the person's own Codex CLI.
	public var codexAgent: AgentProviderClient {
		get { self[CodexAgentKey.self] }
		set { self[CodexAgentKey.self] = newValue }
	}
}
