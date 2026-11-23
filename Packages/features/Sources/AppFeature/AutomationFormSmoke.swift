#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture
import _MCP

/// Decodes only value-free acknowledgments; website effects need separate owned evidence.
internal enum AutomationFormSmoke {
	internal static func decode(
		_ result: CallTool.Result,
		operationID: UUID
	) throws -> AutomationFormResult {
		guard
			try JSONEncoder().encode(result).count <= 262_144,
			result.content.count == 1,
			case let .text(text, _, _) = result.content[0],
			let structured = result.structuredContent,
			try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == structured,
			case let .object(envelope) = structured,
			Set(envelope.keys) == ["untrustedData", "result"],
			envelope["untrustedData"] == .bool(true),
			case let .object(payload) = envelope["result"],
			Set(payload.keys) == ["kind", "operationID", "disposition", "failure", "navigationCompleted"],
			payload["kind"] == .string("form"),
			payload["operationID"] == .string(operationID.uuidString),
			payload["navigationCompleted"] == .bool(false),
			case let .string(rawDisposition) = payload["disposition"],
			let disposition = AutomationFormDisposition(rawValue: rawDisposition)
		else { throw AutomationSmokeFailure.invalidResponse }

		let failure: AutomationFailure?
		switch payload["failure"] {
		case .null:
			failure = nil

		case let .string(rawFailure):
			guard let value = AutomationFailure(rawValue: rawFailure)
			else { throw AutomationSmokeFailure.invalidResponse }
			failure = value

		default:
			throw AutomationSmokeFailure.invalidResponse
		}
		guard result.isError == (failure != nil)
		else { throw AutomationSmokeFailure.invalidResponse }
		return .init(operationID: operationID, disposition: disposition, failure: failure)
	}

	/// Counts actual owned input/change events without exporting the field values.
	internal static func verifyEvidence(
		_ data: Data,
		targets: [String]
	) throws {
		guard
			data.count <= 16_384,
			case let .object(root) = try JSONDecoder().decode(Value.self, from: data),
			Set(root.keys) == ["events"],
			case let .array(events) = root["events"],
			events.count == targets.count * 2,
			Set(targets).count == targets.count
		else { throw AutomationSmokeFailure.invalidResponse }

		var observed: [String: Set<String>] = [:]
		for event in events {
			guard
				case let .object(fields) = event,
				Set(fields.keys) == ["target", "event", "trusted", "activation", "focused", "correct"],
				case let .string(target) = fields["target"],
				targets.contains(target),
				case let .string(kind) = fields["event"],
				["input", "change"].contains(kind),
				fields["trusted"] == .bool(true),
				fields["activation"] == .bool(false),
				fields["focused"] == .bool(false),
				fields["correct"] == .bool(true),
				observed[target, default: []].insert(kind).inserted
			else { throw AutomationSmokeFailure.invalidResponse }
		}
		guard targets.allSatisfy({ observed[$0] == ["input", "change"] })
		else { throw AutomationSmokeFailure.invalidResponse }
	}

	internal static func evidence(
		at url: URL,
		targets: [String]
	) async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 2
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }

		for _ in 0..<50 {
			let (data, response) = try await session.data(from: url)
			guard (response as? HTTPURLResponse)?.statusCode == 200
			else { throw AutomationSmokeFailure.formMismatch }
			do {
				try verifyEvidence(data, targets: targets)
				return
			} catch AutomationSmokeFailure.invalidResponse {
				// The renderer's input/change fetches can finish after its native receipt.
				try await Task.sleep(for: .milliseconds(40))
			}
		}
		throw AutomationSmokeFailure.formMismatch
	}

	@MainActor
	internal static func approvedForm(
		_ request: AutomationFormRequest,
		session: AutomationSmokeSession,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		approve: Bool
	) async throws -> AutomationFormResult {
		let sourceID = BrowserCore.Tab.ID(rawValue: request.target.targetID)
		let before = engine.client.snapshot(sourceID)
		let operation = Task { try await session.form(request) }
		do {
			var pendingID: UUID?
			for _ in 0..<100 {
				pendingID = store.automation.pending.values.first {
					guard case let .form(form) = $0.request.operation else { return false }
					return form.operationID == request.operationID && $0.awaitingApproval
				}?.request.id
				if pendingID != nil { break }
				try await Task.sleep(for: .milliseconds(20))
			}
			guard let pendingID, engine.client.snapshot(sourceID) == before
			else { throw AutomationSmokeFailure.formMismatch }

			store.send(.automation(approve ? .ui(.approve(pendingID)) : .ui(.decline(pendingID))))
			return try await operation.value
		} catch {
			operation.cancel()
			_ = await operation.result
			throw error
		}
	}
}
#endif
