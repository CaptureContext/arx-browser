import AgentClient
import Foundation

/// Turns `codex exec --json` output into ``AgentEvent``s.
///
/// Event shapes follow Codex's own definitions
/// (https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/exec/src/exec_events.rs):
/// `thread.started`, `turn.started`, `item.started` and `item.completed` with `agent_message`
/// and `mcp_tool_call` items, `turn.completed`, `turn.failed` and top-level `error`. Lines it
/// doesn't recognize are skipped, so newer Codex versions keep working.
public struct CodexStream: Sendable {
	/// Whether the turn needs Arx's browser tools to have started.
	public var expectsBrowserTools: Bool

	/// Makes tool activity identifiers unique across the turns of one thread.
	public var turnID: String

	/// The model the turn asked for, reported back in ``AgentEvent/started(resumeToken:modelID:)``.
	public var modelID: String?

	private var threadID: String?
	private var hasText: Bool
	private var toolCalls: Set<String>
	private var lastError: String?
	private var isFinished: Bool

	public init(
		expectsBrowserTools: Bool,
		turnID: String,
		modelID: String?
	) {
		self.expectsBrowserTools = expectsBrowserTools
		self.turnID = turnID
		self.modelID = modelID
		self.threadID = nil
		self.hasText = false
		self.toolCalls = []
		self.lastError = nil
		self.isFinished = false
	}

	/// Reads one line. Throws when the turn ended with a failure or used every step it may take.
	public mutating func consume(_ line: String) throws -> [AgentEvent] {
		guard
			let data = line.data(using: .utf8),
			let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let type = event["type"] as? String
		else { return [] }

		switch type {
		case "thread.started":
			guard let threadID = event["thread_id"] as? String
			else { return [] }

			self.threadID = threadID
			return [.started(resumeToken: threadID, modelID: modelID)]

		case "item.started":
			return try itemStarted(event["item"] as? [String: Any] ?? [:])

		case "item.completed":
			return try itemCompleted(event["item"] as? [String: Any] ?? [:])

		case "error":
			return error(event["message"] as? String ?? "")

		case "turn.completed":
			isFinished = true
			let usage: [String: Any] = event["usage"] as? [String: Any] ?? [:]
			return [
				.completed(
					.init(
						resumeToken: threadID ?? "",
						inputTokens: usage["input_tokens"] as? Int,
						outputTokens: usage["output_tokens"] as? Int
					)
				),
			]

		case "turn.failed":
			isFinished = true
			let error: [String: Any] = event["error"] as? [String: Any] ?? [:]
			throw Self.failure(message: error["message"] as? String ?? lastError ?? "")

		default:
			return []
		}
	}

	/// Called when the output ends. A turn that ended without finishing was interrupted.
	///
	/// When Arx's browser tools can't start, Codex stops before it starts a thread and says
	/// why only on standard error, which Arx never reads.
	public func finish() throws {
		guard !isFinished else { return }

		if threadID == nil, expectsBrowserTools {
			throw AgentFailure.browserToolsUnavailable
		}
		if let lastError {
			throw Self.failure(message: lastError)
		}
		throw AgentFailure.interrupted
	}

	// MARK: - Items

	private mutating func itemStarted(_ item: [String: Any]) throws -> [AgentEvent] {
		guard item["type"] as? String == "mcp_tool_call"
		else { return [] }

		return try toolStarted(item)
	}

	private mutating func itemCompleted(_ item: [String: Any]) throws -> [AgentEvent] {
		switch item["type"] as? String {
		case "agent_message":
			guard let text = item["text"] as? String, !text.isEmpty
			else { return [] }

			// Messages between tool calls arrive whole; keep them apart like paragraphs.
			let separator: String = hasText ? "\n\n" : ""
			hasText = true
			return [.text(separator + text)]

		case "mcp_tool_call":
			let id: String = activityID(item)
			let started: [AgentEvent] = toolCalls.contains(id) ? [] : try toolStarted(item)
			let isError: Bool = item["status"] as? String != "completed"
			let error: [String: Any]? = item["error"] as? [String: Any]
			let message: String = (error?["message"] as? String ?? "").lowercased()
			let denied: [AgentEvent] = message.contains("requires approval")
			? [.toolDenied(name: item["tool"] as? String ?? "tool")]
			: []
			return started + [.toolFinished(id: id, isError: isError)] + denied

		case "file_change":
			// Codex's own file tool can't be removed, but the read-only sandbox refuses it.
			return [.toolDenied(name: "apply_patch")]

		case "command_execution":
			return [.toolDenied(name: "shell")]

		case "web_search":
			return [.toolDenied(name: "web_search")]

		default:
			return []
		}
	}

	private mutating func toolStarted(_ item: [String: Any]) throws -> [AgentEvent] {
		let id: String = activityID(item)
		guard !toolCalls.contains(id)
		else { return [] }

		guard toolCalls.count < CodexCLI.maxTurns
		else { throw AgentFailure.turnLimitReached }

		toolCalls.insert(id)
		return [
			.toolStarted(
				.init(
					id: id,
					name: item["tool"] as? String ?? "",
					input: Self.json(item["arguments"] ?? [String: Any]())
				)
			),
		]
	}

	private func activityID(_ item: [String: Any]) -> String {
		turnID + "/" + (item["id"] as? String ?? "")
	}

	/// Top-level errors are either a retry notice, `Reconnecting... 2/5 (reason)`, or the
	/// reason a failure that follows will give.
	private mutating func error(_ message: String) -> [AgentEvent] {
		guard let retry = Self.retry(message) else {
			lastError = message
			return []
		}

		return [.retrying(attempt: retry.attempt, maxAttempts: retry.maxAttempts, reason: Self.failure(message: retry.reason))]
	}

	// MARK: - Helpers

	private static func retry(_ message: String) -> (attempt: Int, maxAttempts: Int, reason: String)? {
		let prefix: String = "Reconnecting... "
		guard message.hasPrefix(prefix)
		else { return nil }

		let rest: Substring = message.dropFirst(prefix.count)
		let counts: [Substring] = rest.prefix { $0 != " " }.split(separator: "/")
		guard
			counts.count == 2,
			let attempt = Int(counts[0]),
			let maxAttempts = Int(counts[1])
		else { return nil }

		var reason: Substring = rest.drop { $0 != "(" }.dropFirst()
		if reason.hasSuffix(")") { reason = reason.dropLast() }
		return (attempt, maxAttempts, String(reason))
	}

	/// A failure Codex reports as text. The messages are matched loosely, so a change in
	/// wording falls back to ``AgentFailure/runtimeFailed(_:)`` with the text.
	public static func failure(message: String) -> AgentFailure {
		let lowercased: String = message.lowercased()

		if lowercased.contains("usage limit") {
			return .usageLimit(.init())
		}
		if
			lowercased.contains("out of credits")
			|| lowercased.contains("spend cap")
			|| lowercased.contains("quota exceeded")
			|| lowercased.contains("billing")
		{
			return .billing
		}

		let isUnauthorized: Bool = lowercased.contains("401") || lowercased.contains("unauthorized")
		if lowercased.contains("not logged in") || lowercased.contains("missing bearer") {
			return .signedOut
		}
		if
			isUnauthorized
			|| lowercased.contains("sign in again")
			|| lowercased.contains("log in again")
			|| lowercased.contains("token has expired")
			|| lowercased.contains("refresh token")
		{
			return .loginExpired
		}

		let isModelMissing: Bool = lowercased.contains("does not exist")
		|| lowercased.contains("not found")
		|| lowercased.contains("not supported")
		|| lowercased.contains("not available")
		if lowercased.contains("model"), isModelMissing {
			return .modelUnavailable(nil)
		}

		return .runtimeFailed(String(message.prefix(300)))
	}

	private static func json(_ value: Any) -> String {
		guard
			JSONSerialization.isValidJSONObject(value),
			let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
		else { return "{}" }

		return String(decoding: data, as: UTF8.self)
	}
}
