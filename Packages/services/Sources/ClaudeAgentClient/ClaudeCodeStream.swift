import AgentClient
import Foundation

/// Turns Claude Code's `stream-json` output into ``AgentEvent``s.
///
/// Message shapes follow the Agent SDK reference
/// (https://code.claude.com/docs/en/agent-sdk/typescript): `system` `init` and `api_retry`,
/// `stream_event` partial messages, `assistant` and `user` messages, `rate_limit_event` and
/// the final `result`. Lines it doesn't recognize are skipped, so newer Claude Code versions
/// keep working.
public struct ClaudeCodeStream: Sendable {
	/// Whether the turn needs Arx's browser tools to have started.
	public var expectsBrowserTools: Bool

	private var sessionID: String?
	private var hasStreamedText: Bool
	private var rejection: AgentFailure?
	private var isFinished: Bool

	public init(expectsBrowserTools: Bool) {
		self.expectsBrowserTools = expectsBrowserTools
		self.sessionID = nil
		self.hasStreamedText = false
		self.rejection = nil
		self.isFinished = false
	}

	/// Reads one line. Throws when the turn ended with a failure.
	public mutating func consume(_ line: String) throws -> [AgentEvent] {
		guard
			let data = line.data(using: .utf8),
			let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let type = message["type"] as? String
		else { return [] }

		switch type {
		case "system":
			return try system(message)

		case "stream_event":
			return streamEvent(message["event"] as? [String: Any] ?? [:])

		case "assistant":
			return assistant(message["message"] as? [String: Any] ?? [:])

		case "user":
			return toolResults(message["message"] as? [String: Any] ?? [:])

		case "rate_limit_event":
			return rateLimit(message["rate_limit_info"] as? [String: Any] ?? [:])

		case "result":
			return try result(message)

		default:
			return []
		}
	}

	/// Called when the output ends. A turn that ended without a result was interrupted.
	public func finish() throws {
		guard isFinished
		else { throw rejection ?? AgentFailure.interrupted }
	}

	// MARK: - Messages

	private mutating func system(_ message: [String: Any]) throws -> [AgentEvent] {
		switch message["subtype"] as? String {
		case "init":
			let servers: [[String: Any]] = message["mcp_servers"] as? [[String: Any]] ?? []
			let arx: [String: Any]? = servers.first { $0["name"] as? String == AgentBrowserAccess.Connection.serverName }
			if expectsBrowserTools, arx == nil || arx?["status"] as? String == "failed" {
				throw AgentFailure.browserToolsUnavailable
			}

			guard let sessionID = message["session_id"] as? String
			else { return [] }

			self.sessionID = sessionID
			return [.started(resumeToken: sessionID, modelID: message["model"] as? String)]

		case "api_retry":
			return [
				.retrying(
					attempt: message["attempt"] as? Int ?? 1,
					maxAttempts: message["max_retries"] as? Int ?? 1,
					reason: Self.failure(category: message["error"] as? String)
				),
			]

		case "permission_denied":
			return [.toolDenied(name: Self.toolName(message["tool_name"] as? String ?? "tool"))]

		default:
			return []
		}
	}

	private mutating func streamEvent(_ event: [String: Any]) -> [AgentEvent] {
		switch event["type"] as? String {
		case "message_start":
			hasStreamedText = false
			return []

		case "content_block_delta":
			guard
				let delta = event["delta"] as? [String: Any],
				delta["type"] as? String == "text_delta",
				let text = delta["text"] as? String,
				!text.isEmpty
			else { return [] }

			hasStreamedText = true
			return [.text(text)]

		default:
			return []
		}
	}

	private func assistant(_ message: [String: Any]) -> [AgentEvent] {
		let blocks: [[String: Any]] = message["content"] as? [[String: Any]] ?? []
		return blocks.compactMap { block in
			switch block["type"] as? String {
			case "text":
				// Without partial messages, the whole text only arrives here.
				guard !hasStreamedText, let text = block["text"] as? String, !text.isEmpty
				else { return nil }

				return .text(text)

			case "tool_use":
				guard let id = block["id"] as? String
				else { return nil }

				return .toolStarted(
					.init(
						id: id,
						name: Self.toolName(block["name"] as? String ?? ""),
						input: Self.json(block["input"] ?? [String: Any]())
					)
				)

			default:
				return nil
			}
		}
	}

	private func toolResults(_ message: [String: Any]) -> [AgentEvent] {
		let blocks: [[String: Any]] = message["content"] as? [[String: Any]] ?? []
		return blocks.compactMap { block in
			guard
				block["type"] as? String == "tool_result",
				let id = block["tool_use_id"] as? String
			else { return nil }

			return .toolFinished(id: id, isError: block["is_error"] as? Bool ?? false)
		}
	}

	private mutating func rateLimit(_ info: [String: Any]) -> [AgentEvent] {
		let limit: AgentUsageLimit = .init(
			resetsAt: Self.date(info["resetsAt"]),
			utilization: info["utilization"] as? Double
		)

		switch info["status"] as? String {
		case "allowed_warning":
			return [.usageWarning(limit)]

		case "rejected":
			rejection = info["errorCode"] as? String == "credits_required"
			? .usageCreditsRequired
			: .usageLimit(limit)
			return []

		default:
			return []
		}
	}

	private mutating func result(_ message: [String: Any]) throws -> [AgentEvent] {
		isFinished = true
		let isError: Bool = message["is_error"] as? Bool ?? false
		let subtype: String? = message["subtype"] as? String
		guard subtype == "success", !isError else {
			if let rejection { throw rejection }
			if subtype == "error_max_turns" { throw AgentFailure.turnLimitReached }
			throw Self.failure(result: message)
		}

		let usage: [String: Any] = message["usage"] as? [String: Any] ?? [:]
		let token: String = message["session_id"] as? String ?? sessionID ?? ""
		return [
			.completed(
				.init(
					resumeToken: token,
					inputTokens: usage["input_tokens"] as? Int,
					outputTokens: usage["output_tokens"] as? Int
				)
			),
		]
	}

	// MARK: - Helpers

	/// Strips Claude Code's `mcp__arx__` prefix from Arx's tools.
	private static func toolName(_ name: String) -> String {
		let prefix: String = "mcp__" + AgentBrowserAccess.Connection.serverName + "__"
		return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
	}

	private static func json(_ value: Any) -> String {
		guard
			JSONSerialization.isValidJSONObject(value),
			let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
		else { return "{}" }

		return String(decoding: data, as: UTF8.self)
	}

	/// `resetsAt` is a Unix time; milliseconds are recognized by their size.
	private static func date(_ value: Any?) -> Date? {
		guard let seconds = (value as? NSNumber)?.doubleValue
		else { return nil }

		return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
	}

	/// The categories of `system` `api_retry` events (https://code.claude.com/docs/en/headless).
	private static func failure(category: String?) -> AgentFailure {
		switch category {
		case "authentication_failed", "oauth_org_not_allowed":
			.loginExpired

		case "billing_error", "account_on_hold":
			.billing

		case "rate_limit":
			.usageLimit(.init())

		case "model_not_found":
			.modelUnavailable(nil)

		default:
			.runtimeFailed(category ?? "unknown")
		}
	}

	/// A failed `result`. Claude Code reports missing or expired sign-ins as text, so the
	/// documented messages are matched loosely.
	private static func failure(result message: [String: Any]) -> AgentFailure {
		let errors: [String] = message["errors"] as? [String] ?? []
		let text: String = ([message["result"] as? String ?? ""] + errors).joined(separator: "\n")
		let lowercased: String = text.lowercased()

		let isExpired: Bool = lowercased.contains("login expired")
		|| lowercased.contains("oauth token has expired")
		let isSignedOut: Bool = lowercased.contains("not logged in")
		|| lowercased.contains("please run /login")

		if isExpired { return .loginExpired }
		if isSignedOut { return .signedOut }
		if lowercased.contains("credit balance") || lowercased.contains("billing") {
			return .billing
		}
		if lowercased.contains("model") && (lowercased.contains("not found") || lowercased.contains("not available")) {
			return .modelUnavailable(nil)
		}
		return .runtimeFailed(String(text.prefix(300)))
	}
}
