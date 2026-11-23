import AgentClient
import BrowserAutomationClient
import BrowserCore
import CodexAgentClient
import Foundation
import Testing
import _TestSupport

internal struct CodexAgentTests {
	// MARK: - Account

	@Test
	internal func reportsAChatGPTSignIn() async throws {
		let world: World = try .init(authStatus: World.signedIn)

		let account: AgentAccount = await world.client.account()

		#expect(account.status == .signedIn(.init(id: world.home.appending(path: ".codex").path)))
		let check: AgentProcessInvocation = try #require(world.statusChecks.value.first)
		#expect(check.executable.path == "/bin/sh")
		#expect(check.arguments == ["-c", #"exec "$0" login status 2>&1"#, world.executable.path])
	}

	@Test
	internal func refusesSignInsBilledSeparately() async throws {
		let cases: [(output: String, method: String)] = [
			("API key configured - sk-***\nAuthentication is checked when you send a request.", "api_key"),
			("Logged in using access token", "access_token"),
			("Logged in using personal access token", "personal_access_token"),
			("Logged in using Amazon Bedrock API key", "bedrock"),
			("Logged in using workload identity", "workload_identity"),
		]
		for (output, method) in cases {
			let world: World = try .init(authStatus: .init(status: 0, text: output))
			#expect(await world.client.account().status == .unsupportedSignIn(method: method))
		}
	}

	@Test
	internal func reportsSignedOutAndMissingCodex() async throws {
		let signedOut: World = try .init(authStatus: .init(status: 1, text: "Not logged in"))
		#expect(await signedOut.client.account().status == .signedOut(instructions: CodexCLI.signInInstructions))

		let missing: World = try .init(authStatus: World.signedIn, isInstalled: false)
		#expect(await missing.client.account().status == .runtimeMissing)
	}

	// MARK: - Models

	@Test
	internal func listsVisibleModelsInCodexsOrder() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.modelsOutput = .init(
			status: 0,
			standardOutput: Data(
				#"""
				{"models":[
					{"slug":"b","display_name":"Model B","visibility":"list","priority":2},
					{"slug":"hidden","display_name":"Hidden","visibility":"hide","priority":0},
					{"slug":"a","display_name":"Model A","visibility":"list","priority":1}
				]}
				"""#.utf8
			)
		)

		let models: [AgentModel] = await world.client.models()

		#expect(models.map(\.id) == ["a", "b"])
		#expect(models.first?.title == "Model A")
		#expect(models.first?.capabilities == [.browserTools, .attachments])
		#expect(try #require(world.modelChecks.value.first).arguments == ["debug", "models"])
	}

	@Test
	internal func modelListFailuresLeaveTheDefault() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.modelsOutput = .init(status: 1, standardOutput: Data("error".utf8))

		#expect(await world.client.models().isEmpty)
	}

	// MARK: - Turns

	@Test
	internal func runsATurnWithBrowserTools() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			#"{"type":"thread.started","thread_id":"t-1"}"#,
			#"{"type":"turn.started"}"#,
			#"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata not found"}}"#,
			#"{"type":"item.completed","item":{"id":"item_1","type":"reasoning","text":"thinking"}}"#,
			#"{"type":"item.started","item":{"id":"item_2","type":"mcp_tool_call","server":"arx","tool":"browser_tabs","arguments":{"action":"list"},"result":null,"error":null,"status":"in_progress"}}"#,
			#"{"type":"item.completed","item":{"id":"item_2","type":"mcp_tool_call","server":"arx","tool":"browser_tabs","arguments":{"action":"list"},"result":{"content":[]},"error":null,"status":"completed"}}"#,
			#"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"One tab."}}"#,
			#"{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"Anything else?"}}"#,
			#"{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}"#,
		]

		let events: [AgentEvent] = try await world.collect(world.request(withBrowser: true, model: "gpt-6.1-sol"))

		let tool: String = World.turnID + "/item_2"
		#expect(
			events == [
				.started(resumeToken: "t-1", modelID: "gpt-6.1-sol"),
				.toolStarted(.init(id: tool, name: "browser_tabs", input: #"{"action":"list"}"#)),
				.toolFinished(id: tool, isError: false),
				.text("One tab."),
				.text("\n\nAnything else?"),
				.completed(.init(resumeToken: "t-1", inputTokens: 10, outputTokens: 5)),
			]
		)
	}

	@Test
	internal func runsTheUnmodifiedCommandWithOnlyArxTools() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = World.success

		_ = try await world.collect(world.request(withBrowser: true, model: "gpt-6.1-sol"))

		let turn: AgentProcessInvocation = try #require(world.turns.value.first)
		let arguments: [String] = turn.arguments
		let folder: URL = world.folders.turns(.make(1)).appending(path: UUID.make(9).uuidString, directoryHint: .isDirectory)
		#expect(turn.executable == world.executable)
		#expect(arguments.first == "exec")
		#expect(arguments.last == "-")
		#expect(arguments.contains("--json"))
		#expect(arguments.contains("--ignore-user-config"))
		#expect(arguments.contains("--ignore-rules"))
		#expect(world.values(after: "--disable", in: arguments) == CodexCLI.disabledFeatures)
		for feature in ["shell_tool", "unified_exec", "view_image", "multi_agent", "plugins", "hooks"] {
			#expect(CodexCLI.disabledFeatures.contains(feature))
		}

		let settings: [String] = world.values(after: "-c", in: arguments)
		#expect(settings.contains(#"sandbox_mode="read-only""#))
		#expect(settings.contains(#"approval_policy="never""#))
		#expect(settings.contains(#"web_search="disabled""#))
		#expect(settings.contains("tools.experimental_request_user_input.enabled=false"))
		#expect(settings.contains("skills.include_instructions=false"))
		#expect(settings.contains("project_root_markers=[]"))
		#expect(settings.contains(#"model_reasoning_effort="low""#))
		#expect(settings.contains("developer_instructions=" + CodexCLI.tomlString(AgentPrompt.guidance)))
		// The turn's folder is gone by now; its parent isn't.
		let trusted: String = CodexCLI.canonicalPath(world.folders.turns(.make(1))) + "/" + UUID.make(9).uuidString
		#expect(settings.contains("projects={" + CodexCLI.tomlString(trusted) + #"={trust_level="trusted"}}"#))
		#expect(world.value(after: "--model", in: arguments) == "gpt-6.1-sol")
		#expect(!arguments.contains { $0.contains("Summarize") })

		#expect(String(decoding: try #require(turn.input), as: UTF8.self) == "Summarize the page")
		#expect(turn.workingDirectory == folder)
	}

	@Test
	internal func keepsBillingAndArxSecretsOutOfCodexsEnvironment() async throws {
		let world: World = try .init(
			authStatus: World.signedIn,
			environment: [
				"OPENAI_API_KEY": "key",
				"CODEX_API_KEY": "key",
				"CODEX_ACCESS_TOKEN": "token",
				"CODEX_HOME": "/elsewhere",
				"OPENAI_ORGANIZATION": "org",
				"ARX_MCP_CREDENTIAL": "secret",
				"LANG": "en_US.UTF-8",
			]
		)
		world.turnOutput = World.success

		_ = try await world.collect(world.request(withBrowser: true))

		let invocations: [AgentProcessInvocation] = world.turns.value + world.statusChecks.value
		#expect(invocations.count == 2)
		for invocation in invocations {
			#expect(Set(invocation.environment.keys) == ["HOME", "PATH", "LANG"])
			#expect(invocation.environment["HOME"] == world.home.path)
			#expect(!invocation.arguments.contains { $0.contains("secret") })
		}
	}

	@Test
	internal func writesTheCredentialOnlyForTheTurn() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = World.success
		let seen: LockIsolated<(text: String?, permissions: Int)> = .init((nil, 0))
		world.onTurn = { invocation in
			guard let folder = invocation.workingDirectory
			else { return }

			let file: URL = CodexCLI.toolConfigurationFile(in: folder)
			let attributes: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: file.path)
			let permissions: Int = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
			let text: String? = FileManager.default.contents(atPath: file.path).map { String(decoding: $0, as: UTF8.self) }
			seen.setValue((text, permissions))
		}

		_ = try await world.collect(world.request(withBrowser: true))

		#expect(
			seen.value.text == """
			[mcp_servers.arx]
			command = "/Applications/Arx.app/Contents/Helpers/ArxMCP"
			args = []
			required = true
			omit_tools_from = ["deferred", "code_mode"]
			default_tools_approval_mode = "approve"

			[mcp_servers.arx.env]
			"ARX_MCP_CLIENT_ID" = "\(UUID.make(3).uuidString)"
			"ARX_MCP_CREDENTIAL" = "secret"
			"ARX_MCP_SOCKET" = "/tmp/arx.sock"

			"""
		)
		#expect(seen.value.permissions == 0o600)

		let remaining: [String] = (try? FileManager.default.contentsOfDirectory(atPath: world.folders.turns(.make(1)).path)) ?? []
		#expect(remaining.isEmpty)
	}

	@Test
	internal func resumesWithoutBrowserTools() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = World.success
		var request: AgentTurnRequest = world.request(withBrowser: false)
		request.resumeToken = "t-1"

		_ = try await world.collect(request)

		let turn: AgentProcessInvocation = try #require(world.turns.value.first)
		#expect(turn.arguments.starts(with: ["exec", "resume"]))
		#expect(turn.arguments.suffix(2) == ["t-1", "-"])
		#expect(!world.values(after: "-c", in: turn.arguments).contains { $0.hasPrefix("projects=") })

		let folder: URL = try #require(turn.workingDirectory)
		#expect(!FileManager.default.fileExists(atPath: CodexCLI.toolConfigurationFile(in: folder).path))
	}

	@Test
	internal func passesTheRequestedEffort() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = World.success
		var request: AgentTurnRequest = world.request(withBrowser: false)
		request.effort = .high

		_ = try await world.collect(request)

		let settings: [String] = world.values(after: "-c", in: try #require(world.turns.value.first).arguments)
		#expect(settings.contains(#"model_reasoning_effort="high""#))
	}

	@Test
	internal func neverStartsATurnWithAnAPIKey() async throws {
		let world: World = try .init(authStatus: .init(status: 0, text: "API key configured - sk-***"))

		await #expect(throws: AgentFailure.unsupportedSignIn(method: "api_key")) {
			try await world.collect(world.request(withBrowser: false))
		}
		#expect(world.turns.value.isEmpty)
	}

	@Test
	internal func signedOutTurnsFailBeforeRunning() async throws {
		let world: World = try .init(authStatus: .init(status: 1, text: "Not logged in"))

		await #expect(throws: AgentFailure.signedOut) {
			try await world.collect(world.request(withBrowser: false))
		}
		#expect(world.turns.value.isEmpty)
	}

	// MARK: - Failures

	@Test
	internal func mapsCodexFailureMessages() async throws {
		let cases: [(message: String, failure: AgentFailure)] = [
			("You’ve hit your usage limit. Upgrade to Pro or try again at 3:53 PM.", .usageLimit(.init())),
			("Your workspace is out of credits.", .billing),
			("Quota exceeded. Check your plan and billing details.", .billing),
			("unexpected status 401 Unauthorized: Missing bearer or basic authentication in header", .signedOut),
			("unexpected status 401 Unauthorized: Provided authentication token is expired. Please try signing in again.", .loginExpired),
			("The model does not exist", .modelUnavailable(nil)),
			("something else", .runtimeFailed("something else")),
		]
		for (message, failure) in cases {
			#expect(CodexStream.failure(message: message) == failure)
		}
	}

	@Test
	internal func reportsAFailedTurnAndRetries() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			#"{"type":"thread.started","thread_id":"t-1"}"#,
			#"{"type":"turn.started"}"#,
			#"{"type":"error","message":"Reconnecting... 2/5 (unexpected status 503 Service Unavailable: overloaded)"}"#,
			#"{"type":"error","message":"You’ve hit your usage limit."}"#,
			#"{"type":"turn.failed","error":{"message":"You’ve hit your usage limit."}}"#,
		]

		let events: LockIsolated<[AgentEvent]> = .init([])
		await #expect(throws: AgentFailure.usageLimit(.init())) {
			for try await event in world.client.send(world.request(withBrowser: false)) {
				events.withValue { $0.append(event) }
			}
		}
		#expect(
			events.value.last == .retrying(
				attempt: 2,
				maxAttempts: 5,
				reason: .runtimeFailed("unexpected status 503 Service Unavailable: overloaded")
			)
		)
	}

	@Test
	internal func stopsAfterTheToolCallLimit() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [#"{"type":"thread.started","thread_id":"t-1"}"#]
			+ (0...CodexCLI.maxTurns).map { index in
				#"{"type":"item.started","item":{"id":"item_\#(index)","type":"mcp_tool_call","server":"arx","tool":"browser_tabs","arguments":{},"status":"in_progress"}}"#
			}
		world.isTurnEndless = true

		let started: LockIsolated<Int> = .init(0)
		await #expect(throws: AgentFailure.turnLimitReached) {
			for try await event in world.client.send(world.request(withBrowser: true)) {
				if case .toolStarted = event { started.withValue { $0 += 1 } }
			}
		}
		#expect(started.value == CodexCLI.maxTurns)

		while !world.wasTurnStopped.value {
			await Task.yield()
		}
		#expect(world.wasTurnStopped.value)
	}

	@Test
	internal func reportsDeniedAndFailedToolCalls() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			#"{"type":"thread.started","thread_id":"t-1"}"#,
			#"{"type":"item.completed","item":{"id":"item_0","type":"mcp_tool_call","server":"arx","tool":"browser_click","arguments":{},"error":{"message":"MCP tool call requires approval, but approval policy is never"},"status":"failed"}}"#,
			#"{"type":"item.completed","item":{"id":"item_1","type":"file_change","changes":[],"status":"failed"}}"#,
			#"{"type":"turn.completed","usage":{}}"#,
		]

		let events: [AgentEvent] = try await world.collect(world.request(withBrowser: true))

		let tool: String = World.turnID + "/item_0"
		#expect(
			events == [
				.started(resumeToken: "t-1", modelID: nil),
				.toolStarted(.init(id: tool, name: "browser_click", input: "{}")),
				.toolFinished(id: tool, isError: true),
				.toolDenied(name: "browser_click"),
				.toolDenied(name: "apply_patch"),
				.completed(.init(resumeToken: "t-1")),
			]
		)
	}

	@Test
	internal func failsWhenBrowserToolsDidNotStart() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = []
		world.turnExitStatus = 1

		await #expect(throws: AgentFailure.browserToolsUnavailable) {
			try await world.collect(world.request(withBrowser: true))
		}
	}

	@Test
	internal func outputWithoutACompletedTurnIsAnInterruption() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [#"{"type":"thread.started","thread_id":"t-1"}"#, "not json", #"{"type":"unknown"}"#]

		await #expect(throws: AgentFailure.interrupted) {
			try await world.collect(world.request(withBrowser: false))
		}
	}

	// MARK: - Each step failing (DEV-643)

	@Test
	internal func aSignInCheckThatCannotStartReportsCodexMissing() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.isStatusLaunchable = false

		await #expect(throws: AgentFailure.runtimeMissing) {
			try await world.collect(world.request(withBrowser: false))
		}
		#expect(world.turns.value.isEmpty)
	}

	@Test(arguments: [false, true])
	internal func aTurnThatCannotStartReportsCodexMissing(withBrowser: Bool) async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.isTurnLaunchable = false

		await #expect(throws: AgentFailure.runtimeMissing) {
			try await world.collect(world.request(withBrowser: withBrowser))
		}
	}

	@Test
	internal func codexExitingBeforeAThreadIsAnInterruption() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnExitStatus = 2

		await #expect(throws: AgentFailure.interrupted) {
			try await world.collect(world.request(withBrowser: false))
		}
	}

	// MARK: - Recorded Codex 0.167.1 output (DEV-643)

	/// `codex exec --json` 0.167.1 with Arx's arguments, against a local Responses server.
	@Test
	internal func replaysARecordedAnswer() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			#"{"type":"thread.started","thread_id":"01a1c9f9-b816-7602-a3a4-0d9a18cfb93c"}"#,
			#"{"type":"turn.started"}"#,
			#"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Hello from mock"}}"#,
			#"{"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":3,"reasoning_output_tokens":0}}"#,
		]

		let events: [AgentEvent] = try await world.collect(world.request(withBrowser: false, model: "gpt-6.1-sol"))

		let thread: String = "01a1c9f9-b816-7602-a3a4-0d9a18cfb93c"
		#expect(
			events == [
				.started(resumeToken: thread, modelID: "gpt-6.1-sol"),
				.text("Hello from mock"),
				.completed(.init(resumeToken: thread, inputTokens: 5, outputTokens: 3)),
			]
		)

		// Codex's thread identifiers are UUIDs, so discarding them reaches `codex delete`.
		try await world.client.discard(thread)
		#expect(world.deletions.value.count == 1)
	}

	/// `codex exec --json` 0.167.1 with no sign-in: WebSocket retries, the HTTPS fallback
	/// notice, HTTPS retries, then the failed turn. Codex exits with 1.
	@Test
	internal func replaysARecordedSignedOutTurn() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		let unauthorized: String = "unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses"
		world.turnOutput = [
			#"{"type":"thread.started","thread_id":"01a1c9f7-56d9-7013-8188-a859a3c21451"}"#,
			#"{"type":"turn.started"}"#,
			#"{"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: wss://api.openai.com/v1/responses)"}"#,
			#"{"type":"error","message":"Reconnecting... 5/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: wss://api.openai.com/v1/responses)"}"#,
			#"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Falling back from WebSockets to HTTPS transport. unexpected status 401 Unauthorized"}}"#,
			#"{"type":"error","message":"Reconnecting... 1/5 (\#(unauthorized))"}"#,
			#"{"type":"error","message":"\#(unauthorized)"}"#,
			#"{"type":"turn.failed","error":{"message":"\#(unauthorized)"}}"#,
		]
		world.turnExitStatus = 1

		let events: LockIsolated<[AgentEvent]> = .init([])
		await #expect(throws: AgentFailure.signedOut) {
			for try await event in world.client.send(world.request(withBrowser: false)) {
				events.withValue { $0.append(event) }
			}
		}
		let retries: [Int] = events.value.compactMap { event in
			guard case let .retrying(attempt, _, reason) = event
			else { return nil }

			#expect(reason == .signedOut)
			return attempt
		}
		#expect(retries == [2, 5, 1])
	}

	/// Codex 0.167.1 waits for the network without a limit, printing a notice that has no
	/// attempt count. When it's stopped, the notice is the reason.
	@Test
	internal func waitingForTheNetworkIsNotAnAnswer() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			#"{"type":"thread.started","thread_id":"t-1"}"#,
			#"{"type":"turn.started"}"#,
			#"{"type":"error","message":"Reconnecting... waiting for network (Connection failed: error sending request)"}"#,
		]
		world.turnExitStatus = 1

		await #expect(throws: AgentFailure.runtimeFailed("Reconnecting... waiting for network (Connection failed: error sending request)")) {
			try await world.collect(world.request(withBrowser: false))
		}
	}

	@Test
	internal func cancellingStopsTheProcess() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.isTurnEndless = true

		let task: Task<Void, any Error> = .init {
			for try await _ in world.client.send(world.request(withBrowser: false)) {}
		}
		while !world.isTurnRunning.value {
			await Task.yield()
		}
		task.cancel()
		_ = await task.result

		while !world.wasTurnStopped.value {
			await Task.yield()
		}
		#expect(world.wasTurnStopped.value)
	}

	// MARK: - Discarding

	@Test
	internal func discardDeletesOnlyThatThread() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.deleteOutput = .init(status: 0, standardOutput: Data("Deleted session.".utf8))
		let thread: String = "01a1bc6c-9c77-7861-b380-51deddf1c24c"

		try await world.client.discard(thread)
		try await world.client.discard("--all")

		let deletions: [AgentProcessInvocation] = world.deletions.value
		#expect(deletions.count == 1)
		#expect(deletions.first?.arguments == ["-c", #"exec "$0" delete --force "$1" 2>&1"#, world.executable.path, thread])
	}

	@Test
	internal func discardAcceptsAThreadThatIsAlreadyGone() async throws {
		let missing: World = try .init(authStatus: World.signedIn)
		missing.deleteOutput = .init(status: 1, standardOutput: Data("Error: No active or archived session found matching 'x'.".utf8))
		try await missing.client.discard("01a1bc6c-9c77-7861-b380-51deddf1c24c")

		let failing: World = try .init(authStatus: World.signedIn)
		failing.deleteOutput = .init(status: 1, standardOutput: Data("Error: database is locked".utf8))
		await #expect(throws: AgentFailure.self) {
			try await failing.client.discard("01a1bc6c-9c77-7861-b380-51deddf1c24c")
		}
	}

	@Test
	internal func escapesTOMLStrings() async throws {
		#expect(CodexCLI.tomlString("a\"b\\c\nd\u{1}") == #""a\"b\\c\nd\u0001""#)
	}
}

// MARK: - World

/// A fake Mac: a temporary home folder, a stand-in `codex` and recorded processes.
private final class World: @unchecked Sendable {
	internal static let signedIn: AuthStatus = .init(status: 0, text: "Logged in using ChatGPT")

	internal static let turnID: String = UUID.make(9).uuidString.lowercased()

	internal static let success: [String] = [
		#"{"type":"thread.started","thread_id":"t-1"}"#,
		#"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#,
	]

	internal struct AuthStatus: Sendable {
		internal var status: Int32
		internal var text: String
	}

	internal let home: URL
	internal let executable: URL
	internal let folders: AgentProfileFolders
	internal let turns: LockIsolated<[AgentProcessInvocation]> = .init([])
	internal let statusChecks: LockIsolated<[AgentProcessInvocation]> = .init([])
	internal let modelChecks: LockIsolated<[AgentProcessInvocation]> = .init([])
	internal let deletions: LockIsolated<[AgentProcessInvocation]> = .init([])
	internal let isTurnRunning: LockIsolated<Bool> = .init(false)
	internal let wasTurnStopped: LockIsolated<Bool> = .init(false)

	internal var authStatus: AuthStatus
	internal var modelsOutput: AgentProcessOutput = .init(status: 1, standardOutput: Data())
	internal var deleteOutput: AgentProcessOutput = .init(status: 0, standardOutput: Data())
	internal var turnOutput: [String] = []
	internal var turnExitStatus: Int32 = 0
	internal var isTurnEndless: Bool = false
	internal var isTurnLaunchable: Bool = true
	internal var isStatusLaunchable: Bool = true
	internal var onTurn: @Sendable (AgentProcessInvocation) -> Void = { _ in }

	private let environment: [String: String]
	private let isInstalled: Bool

	internal init(
		authStatus: AuthStatus,
		isInstalled: Bool = true,
		environment: [String: String] = [:]
	) throws {
		self.home = FileManager.default.temporaryDirectory
			.appending(path: "CodexAgentTests-" + UUID().uuidString, directoryHint: .isDirectory)
		self.executable = home.appending(path: ".local/bin/codex")
		self.folders = .init(root: home.appending(path: "Profiles", directoryHint: .isDirectory))
		self.authStatus = authStatus
		self.isInstalled = isInstalled
		self.environment = environment
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
	}

	internal var client: AgentProviderClient {
		.codex(
			.init(
				home: home,
				executable: { [isInstalled, executable] in isInstalled ? executable : nil },
				environment: environment,
				folders: folders,
				process: process,
				makeTurnID: { .make(9) }
			)
		)
	}

	internal func request(
		withBrowser: Bool,
		model: String? = nil
	) -> AgentTurnRequest {
		.init(
			profileID: .make(1),
			conversationID: .init(rawValue: .make(1)),
			prompt: "Summarize the page",
			modelID: model,
			browserAccess: withBrowser
			? .init(
				helper: URL(fileURLWithPath: "/Applications/Arx.app/Contents/Helpers/ArxMCP"),
				credential: .init(socket: "/tmp/arx.sock", clientID: .make(3), token: "secret")
			)
			: nil
		)
	}

	@discardableResult
	internal func collect(_ request: AgentTurnRequest) async throws -> [AgentEvent] {
		var events: [AgentEvent] = []
		for try await event in client.send(request) {
			events.append(event)
		}
		return events
	}

	internal func value(
		after flag: String,
		in arguments: [String]
	) -> String? {
		values(after: flag, in: arguments).first
	}

	/// Every value that follows `flag`, in order.
	internal func values(
		after flag: String,
		in arguments: [String]
	) -> [String] {
		arguments.indices.compactMap { index in
			guard arguments[index] == flag, arguments.indices.contains(index + 1)
			else { return nil }

			return arguments[index + 1]
		}
	}

	private var process: AgentProcessRunner {
		.init(
			lines: { [self] invocation in
				turns.withValue { $0.append(invocation) }
				onTurn(invocation)
				let output: [String] = turnOutput
				let isEndless: Bool = isTurnEndless
				let exitStatus: Int32 = turnExitStatus
				let isLaunchable: Bool = isTurnLaunchable
				return AsyncThrowingStream { continuation in
					guard isLaunchable else {
						continuation.finish(throwing: AgentProcessFailure.launchFailed)
						return
					}

					output.forEach { continuation.yield($0) }
					if isEndless {
						isTurnRunning.setValue(true)
						continuation.onTermination = { [wasTurnStopped] _ in wasTurnStopped.setValue(true) }
					} else if exitStatus == 0 {
						continuation.finish()
					} else {
						continuation.finish(throwing: AgentProcessFailure.exited(status: exitStatus))
					}
				}
			},
			output: { [self] invocation in
				if invocation.arguments.first == "debug" {
					modelChecks.withValue { $0.append(invocation) }
					return modelsOutput
				}
				if invocation.arguments.contains(where: { $0.contains("delete") }) {
					deletions.withValue { $0.append(invocation) }
					return deleteOutput
				}

				statusChecks.withValue { $0.append(invocation) }
				guard isStatusLaunchable
				else { throw AgentProcessFailure.launchFailed }

				return .init(status: authStatus.status, standardOutput: Data(authStatus.text.utf8))
			}
		)
	}
}
