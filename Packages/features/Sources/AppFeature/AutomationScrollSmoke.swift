#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture
import _MCP

/// Decodes only value-free acknowledgments; website effects need separate owned evidence.
internal enum AutomationScrollSmoke {
	internal static func decode(
		_ result: CallTool.Result,
		operationID: UUID
	) throws -> AutomationScrollResult {
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
			payload["kind"] == .string("scroll"),
			payload["operationID"] == .string(operationID.uuidString),
			payload["navigationCompleted"] == .bool(false),
			case let .string(rawDisposition) = payload["disposition"],
			let disposition = AutomationScrollDisposition(rawValue: rawDisposition)
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

	@MainActor
	internal static func approvedScroll(
		_ request: AutomationScrollRequest,
		session: AutomationSmokeSession,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		approve: Bool
	) async throws -> AutomationScrollResult {
		let sourceID = BrowserCore.Tab.ID(rawValue: request.target.targetID)
		let before = engine.client.snapshot(sourceID)
		let operation = Task { try await session.scroll(request) }
		do {
			var pendingID: UUID?
			for _ in 0..<100 {
				pendingID = store.automation.pending.values.first {
					guard case let .scroll(scroll) = $0.request.operation else { return false }
					return scroll.operationID == request.operationID && $0.awaitingApproval
				}?.request.id
				if pendingID != nil { break }
				try await Task.sleep(for: .milliseconds(20))
			}
			guard let pendingID, engine.client.snapshot(sourceID) == before
			else { throw AutomationSmokeFailure.scrollMismatch }

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
