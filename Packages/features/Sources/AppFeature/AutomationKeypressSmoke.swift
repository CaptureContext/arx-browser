#if DEBUG
import Foundation
import _MCP

internal enum AutomationKeypressSmoke {
	internal static func verifyEvidence(
		_ data: Data,
		redirected: Bool
	) throws {
		guard
			data.count <= 16_384,
			case let .object(root) = try JSONDecoder().decode(Value.self, from: data),
			Set(root.keys) == ["events"],
			case let .array(events) = root["events"],
			!events.isEmpty,
			events.count <= 32
		else { throw AutomationSmokeFailure.invalidResponse }

		let kinds = ["keydown", "keypress", "keyup", "beforeinput", "textInput", "input", "settled"]
		var counts: [String: Int] = [:]
		for event in events {
			guard
				case let .object(fields) = event,
				Set(fields.keys) == ["target", "event", "trusted", "activation", "focused", "correct"],
				case let .string(kind) = fields["event"],
				kinds.contains(kind),
				fields["target"] == .string(kind == "settled" ? "fixture" : "target"),
				fields["trusted"] == .bool(kind != "settled"),
				fields["activation"] == .bool(false),
				fields["correct"] == .bool(true),
				case .bool = fields["focused"]
			else { throw AutomationSmokeFailure.invalidResponse }

			if !redirected, fields["focused"] != .bool(true) {
				throw AutomationSmokeFailure.invalidResponse
			}
			counts[kind, default: 0] += 1
		}
		guard
			counts["keydown"] == 1,
			counts["settled"] == 1,
			counts["input", default: 0] == (redirected ? 0 : 1)
		else { throw AutomationSmokeFailure.invalidResponse }
	}

	internal static func evidence(
		at url: URL,
		redirected: Bool
	) async throws -> Data {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 2
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }

		for _ in 0..<50 {
			let (data, response) = try await session.data(from: url)
			guard
				(response as? HTTPURLResponse)?.statusCode == 200,
				response.url == url,
				data.count <= 16_384
			else { throw AutomationSmokeFailure.invalidResponse }

			do {
				try verifyEvidence(data, redirected: redirected)
				return data
			} catch AutomationSmokeFailure.invalidResponse {
				try await Task.sleep(for: .milliseconds(40))
			}
		}
		throw AutomationSmokeFailure.formMismatch
	}
}
#endif
