import AgentClient
import BrowserAutomationClient
import BrowserCore
import ClaudeAgentClient
import Foundation
import Testing
import _TestSupport

internal struct ClaudeAgentTests {
	// MARK: - Account

	@Test
	internal func reportsAClaudeSignIn() async throws {
		let world: World = try .init(authStatus: World.signedIn)

		let account: AgentAccount = await world.client.account()

		#expect(account.status == .signedIn(.init(id: "/fake/.claude", label: "person@example.com", plan: "max")))
	}

	@Test
	internal func refusesSignInsBilledSeparately() async throws {
		for method in ["api_key", "api_key_helper", "third_party", "oauth_token"] {
			let world: World = try .init(authStatus: .init(status: 0, json: ["authMethod": method]))
			#expect(await world.client.account().status == .unsupportedSignIn(method: method))
		}
	}

	@Test
	internal func reportsSignedOutAndMissingClaude() async throws {
		let signedOut: World = try .init(authStatus: .init(status: 1, json: ["authMethod": "none"]))
		#expect(await signedOut.client.account().status == .signedOut(instructions: ClaudeCode.signInInstructions))

		let missing: World = try .init(authStatus: World.signedIn, isInstalled: false)
		#expect(await missing.client.account().status == .runtimeMissing)
	}

	// MARK: - Turns

	@Test
	internal func streamsATurnWithBrowserTools() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			#"{"type":"system","subtype":"init","session_id":"s-1","model":"claude-sonnet-5-5","mcp_servers":[{"name":"arx","status":"connected"}]}"#,
			#"{"type":"stream_event","event":{"type":"message_start"}}"#,
			#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Let me "}}}"#,
			#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"look."}}}"#,
			#"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"t1","name":"mcp__arx__browser_tabs","input":{"action":"list"}}]}}"#,
			#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false}]}}"#,
			#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","utilization":0.9,"resetsAt":1800000000}}"#,
			#"{"type":"result","subtype":"success","is_error":false,"session_id":"s-1","usage":{"input_tokens":10,"output_tokens":5}}"#,
		]

		let events: [AgentEvent] = try await world.collect(world.request(withBrowser: true))

		#expect(
			events == [
				.started(resumeToken: "s-1", modelID: "claude-sonnet-5-5"),
				.text("Let me "),
				.text("look."),
				.toolStarted(.init(id: "t1", name: "browser_tabs", input: #"{"action":"list"}"#)),
				.toolFinished(id: "t1", isError: false),
				.usageWarning(.init(resetsAt: Date(timeIntervalSince1970: 1_800_000_000), utilization: 0.9)),
				.completed(.init(resumeToken: "s-1", inputTokens: 10, outputTokens: 5)),
			]
		)
	}

	@Test
	internal func runsTheUnmodifiedCommandWithOnlyArxTools() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = World.success

		_ = try await world.collect(world.request(withBrowser: true, model: "opus"))

		let turn: AgentProcessInvocation = try #require(world.turns.value.first)
		let arguments: [String] = turn.arguments
		#expect(turn.executable == world.executable)
		#expect(arguments.starts(with: ["--print", "--output-format", "stream-json"]))
		#expect(world.value(after: "--tools", in: arguments) == "")
		#expect(world.value(after: "--setting-sources", in: arguments) == "local")
		#expect(world.value(after: "--permission-mode", in: arguments) == "dontAsk")
		#expect(world.value(after: "--session-id", in: arguments) == UUID.make(9).uuidString.lowercased())
		#expect(world.value(after: "--model", in: arguments) == "opus")
		#expect(world.value(after: "--effort", in: arguments) == "low")
		#expect(world.value(after: "--max-turns", in: arguments) == "12")
		#expect(world.value(after: "--allowedTools", in: arguments) == "mcp__arx")
		#expect(arguments.contains("--strict-mcp-config"))
		#expect(world.value(after: "--system-prompt", in: arguments) == AgentPrompt.guidance)
		#expect(!arguments.contains { $0.contains("Summarize") })
		#expect(String(decoding: try #require(turn.input), as: UTF8.self) == "Summarize the page")
		#expect(turn.workingDirectory == world.folders.workspace(.make(1)))
	}

	@Test
	internal func keepsBillingAndArxSecretsOutOfClaudesEnvironment() async throws {
		let world: World = try .init(
			authStatus: World.signedIn,
			environment: [
				"ANTHROPIC_API_KEY": "key",
				"ANTHROPIC_AUTH_TOKEN": "token",
				"CLAUDE_CODE_OAUTH_TOKEN": "oauth",
				"CLAUDE_CODE_USE_BEDROCK": "1",
				"ARX_MCP_CREDENTIAL": "secret",
				"LANG": "en_US.UTF-8",
			]
		)
		world.turnOutput = World.success

		_ = try await world.collect(world.request(withBrowser: true))

		let invocations: [AgentProcessInvocation] = world.turns.value + world.statusChecks.value
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
		let seen: LockIsolated<(data: Data?, permissions: Int)> = .init((nil, 0))
		world.onTurn = { invocation in
			guard let path = world.value(after: "--mcp-config", in: invocation.arguments)
			else { return }

			let permissions: Int = ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
			seen.setValue((FileManager.default.contents(atPath: path), permissions))
		}

		_ = try await world.collect(world.request(withBrowser: true))

		let configuration: ToolConfiguration = try JSONDecoder().decode(ToolConfiguration.self, from: try #require(seen.value.data))
		let arx: ToolConfiguration.Server = try #require(configuration.mcpServers["arx"])
		#expect(arx.command == "/Applications/Arx.app/Contents/Helpers/ArxMCP")
		#expect(arx.env["ARX_MCP_CREDENTIAL"] == "secret")
		#expect(seen.value.permissions == 0o600)

		let remaining: [String] = (try? FileManager.default.contentsOfDirectory(atPath: world.folders.turns(.make(1)).path)) ?? []
		#expect(remaining.isEmpty)
	}

	@Test
	internal func resumesWithoutBrowserTools() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = World.success
		var request: AgentTurnRequest = world.request(withBrowser: false)
		request.resumeToken = "s-1"

		_ = try await world.collect(request)

		let arguments: [String] = try #require(world.turns.value.first).arguments
		#expect(world.value(after: "--resume", in: arguments) == "s-1")
		#expect(!arguments.contains("--session-id"))
		#expect(!arguments.contains("--mcp-config"))
		#expect(!arguments.contains("--allowedTools"))
	}

	@Test
	internal func neverStartsATurnWithAnAPIKey() async throws {
		let world: World = try .init(authStatus: .init(status: 0, json: ["authMethod": "api_key"]))

		await #expect(throws: AgentFailure.unsupportedSignIn(method: "api_key")) {
			try await world.collect(world.request(withBrowser: false))
		}
		#expect(world.turns.value.isEmpty)
	}

	@Test
	internal func signedOutTurnsFailBeforeRunning() async throws {
		let world: World = try .init(authStatus: .init(status: 1, json: ["authMethod": "none"]))

		await #expect(throws: AgentFailure.signedOut) {
			try await world.collect(world.request(withBrowser: false))
		}
		#expect(world.turns.value.isEmpty)
	}

	// MARK: - Failures

	@Test
	internal func reportsUsageLimitsAndCredits() async throws {
		let limited: World = try .init(authStatus: World.signedIn)
		limited.turnOutput = [
			World.initLine,
			#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1800000000000}}"#,
			#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["limit"]}"#,
		]
		await #expect(throws: AgentFailure.usageLimit(.init(resetsAt: Date(timeIntervalSince1970: 1_800_000_000)))) {
			try await limited.collect(limited.request(withBrowser: false))
		}

		let credits: World = try .init(authStatus: World.signedIn)
		credits.turnOutput = [
			World.initLine,
			#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","errorCode":"credits_required"}}"#,
			#"{"type":"result","subtype":"success","is_error":true,"result":"limit"}"#,
		]
		await #expect(throws: AgentFailure.usageCreditsRequired) {
			try await credits.collect(credits.request(withBrowser: false))
		}
	}

	@Test
	internal func mapsLoginAndRetryFailures() async throws {
		let expired: World = try .init(authStatus: World.signedIn)
		expired.turnOutput = [
			World.initLine,
			#"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":3,"error":"billing_error"}"#,
			#"{"type":"result","subtype":"success","is_error":true,"result":"Login expired · Please run /login"}"#,
		]

		let events: LockIsolated<[AgentEvent]> = .init([])
		await #expect(throws: AgentFailure.loginExpired) {
			for try await event in expired.client.send(expired.request(withBrowser: false)) {
				events.withValue { $0.append(event) }
			}
		}
		#expect(events.value.last == .retrying(attempt: 1, maxAttempts: 3, reason: .billing))
	}

	@Test
	internal func passesTheRequestedEffort() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = World.success
		var request: AgentTurnRequest = world.request(withBrowser: false)
		request.effort = .high

		_ = try await world.collect(request)

		#expect(world.value(after: "--effort", in: try #require(world.turns.value.first).arguments) == "high")
	}

	@Test
	internal func reportsTheTurnLimit() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			World.initLine,
			#"{"type":"result","subtype":"error_max_turns","is_error":true,"errors":[]}"#,
		]

		await #expect(throws: AgentFailure.turnLimitReached) {
			try await world.collect(world.request(withBrowser: false))
		}
	}

	@Test
	internal func failsWhenBrowserToolsDidNotStart() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			#"{"type":"system","subtype":"init","session_id":"s-1","mcp_servers":[{"name":"arx","status":"failed"}]}"#,
		]

		await #expect(throws: AgentFailure.browserToolsUnavailable) {
			try await world.collect(world.request(withBrowser: true))
		}
	}

	@Test
	internal func outputWithoutAResultIsAnInterruption() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [World.initLine, "not json", #"{"type":"unknown"}"#]

		await #expect(throws: AgentFailure.interrupted) {
			try await world.collect(world.request(withBrowser: false))
		}
	}

	@Test
	internal func usesWholeMessagesWithoutPartialEvents() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		world.turnOutput = [
			World.initLine,
			#"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#,
			#"{"type":"result","subtype":"success","is_error":false,"session_id":"s-1"}"#,
		]

		let events: [AgentEvent] = try await world.collect(world.request(withBrowser: false))

		#expect(events.contains(.text("Done.")))
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
	internal func discardDeletesOnlyThatSessionsTranscript() async throws {
		let world: World = try .init(authStatus: World.signedIn)
		let configuration: URL = world.home.appending(path: "claude-config", directoryHint: .isDirectory)
		world.authStatus = .init(status: 0, json: ["authMethod": "claude.ai", "configDirectory": configuration.path])

		let session: UUID = .make(7)
		let project: URL = configuration.appending(path: "projects/-arx-profile", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: project.appending(path: session.uuidString.lowercased()), withIntermediateDirectories: true)
		let transcript: URL = project.appending(path: session.uuidString.lowercased() + ".jsonl")
		let other: URL = project.appending(path: UUID.make(8).uuidString.lowercased() + ".jsonl")
		FileManager.default.createFile(atPath: transcript.path, contents: Data("{}".utf8))
		FileManager.default.createFile(atPath: other.path, contents: Data("{}".utf8))

		try await world.client.discard(session.uuidString.lowercased())
		try await world.client.discard("../../etc")

		#expect(!FileManager.default.fileExists(atPath: transcript.path))
		#expect(!FileManager.default.fileExists(atPath: project.appending(path: session.uuidString.lowercased()).path))
		#expect(FileManager.default.fileExists(atPath: other.path))
	}

	@Test
	internal func liveValueIsInertInTests() async throws {
		#expect(!AgentProviderClient.isEnabled(environment: [:], arguments: ["Arx"]))
	}
}

// MARK: - World

private struct ToolConfiguration: Decodable {
	internal struct Server: Decodable {
		internal var command: String
		internal var env: [String: String]
	}

	internal var mcpServers: [String: Server]
}

/// A fake Mac: a temporary home folder, a stand-in `claude` and recorded processes.
private final class World: @unchecked Sendable {
	internal static let signedIn: AuthStatus = .init(
		status: 0,
		json: [
			"authMethod": "claude.ai",
			"configDirectory": "/fake/.claude",
			"email": "person@example.com",
			"subscriptionType": "max",
		]
	)

	internal static let initLine: String = #"{"type":"system","subtype":"init","session_id":"s-1","mcp_servers":[]}"#

	internal static let success: [String] = [
		#"{"type":"system","subtype":"init","session_id":"s-1","mcp_servers":[{"name":"arx","status":"connected"}]}"#,
		#"{"type":"result","subtype":"success","is_error":false,"session_id":"s-1"}"#,
	]

	internal struct AuthStatus: @unchecked Sendable {
		internal var status: Int32
		internal var json: [String: Any]
	}

	internal let home: URL
	internal let executable: URL
	internal let folders: AgentProfileFolders
	internal let turns: LockIsolated<[AgentProcessInvocation]> = .init([])
	internal let statusChecks: LockIsolated<[AgentProcessInvocation]> = .init([])
	internal let isTurnRunning: LockIsolated<Bool> = .init(false)
	internal let wasTurnStopped: LockIsolated<Bool> = .init(false)

	internal var authStatus: AuthStatus
	internal var turnOutput: [String] = []
	internal var isTurnEndless: Bool = false
	internal var onTurn: @Sendable (AgentProcessInvocation) -> Void = { _ in }

	private let environment: [String: String]
	private let isInstalled: Bool

	internal init(
		authStatus: AuthStatus,
		isInstalled: Bool = true,
		environment: [String: String] = [:]
	) throws {
		self.home = FileManager.default.temporaryDirectory
			.appending(path: "ClaudeAgentTests-" + UUID().uuidString, directoryHint: .isDirectory)
		self.executable = home.appending(path: ".local/bin/claude")
		self.folders = .init(root: home.appending(path: "Profiles", directoryHint: .isDirectory))
		self.authStatus = authStatus
		self.isInstalled = isInstalled
		self.environment = environment
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
	}

	internal var client: AgentProviderClient {
		.claudeCode(
			.init(
				home: home,
				executable: { [isInstalled, executable] in isInstalled ? executable : nil },
				environment: environment,
				folders: folders,
				process: process,
				makeSessionID: { .make(9) }
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
		guard
			let index = arguments.firstIndex(of: flag),
			arguments.indices.contains(index + 1)
		else { return nil }

		return arguments[index + 1]
	}

	private var process: AgentProcessRunner {
		.init(
			lines: { [self] invocation in
				turns.withValue { $0.append(invocation) }
				onTurn(invocation)
				let output: [String] = turnOutput
				let isEndless: Bool = isTurnEndless
				return AsyncThrowingStream { continuation in
					output.forEach { continuation.yield($0) }
					if isEndless {
						isTurnRunning.setValue(true)
						continuation.onTermination = { [wasTurnStopped] _ in wasTurnStopped.setValue(true) }
					} else {
						continuation.finish()
					}
				}
			},
			output: { [self] invocation in
				statusChecks.withValue { $0.append(invocation) }
				let status: AuthStatus = authStatus
				return .init(
					status: status.status,
					standardOutput: try JSONSerialization.data(withJSONObject: status.json)
				)
			}
		)
	}
}
