#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture
import _MCP

/// Checks the public acknowledgment without treating dispatch as website success.
internal enum AutomationClickSmoke {
	internal static func decode(
		_ result: CallTool.Result,
		operationID: UUID
	) throws -> AutomationClickResult {
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
			payload["kind"] == .string("click"),
			payload["operationID"] == .string(operationID.uuidString),
			payload["navigationCompleted"] == .bool(false),
			case let .string(rawDisposition) = payload["disposition"],
			let disposition = AutomationClickDisposition(rawValue: rawDisposition)
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

	/// Navigation can retire the source before its renderer acknowledgment arrives.
	/// The caller must independently verify the owned destination; this proves no site success.
	internal static func verifyNavigationReceipt(_ result: AutomationClickResult) throws {
		switch (result.disposition, result.failure) {
		case (.dispatched, nil), (.possiblyDispatched, .staleReference):
			return
		default:
			throw AutomationSmokeFailure.clickMismatch
		}
	}

	internal static func request(
		for snapshot: AutomationInspectionSmoke.Snapshot,
		name: String
	) throws -> AutomationClickRequest {
		let matches = snapshot.content.nodes.filter { $0.name == name && $0.reference != nil }
		guard matches.count == 1, let reference = matches.first?.reference
		else { throw AutomationSmokeFailure.clickMismatch }
		return .init(
			operationID: UUID(),
			targetID: snapshot.targetID,
			expectedRevision: snapshot.expectedRevision,
			snapshotID: snapshot.content.snapshotID,
			reference: reference
		)
	}

	@MainActor
	internal static func approvedClick(
		_ request: AutomationClickRequest,
		session: AutomationSmokeSession,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		approve: Bool
	) async throws -> AutomationClickResult {
		let sourceID = BrowserCore.Tab.ID(rawValue: request.targetID)
		let before = engine.client.snapshot(sourceID)
		let operation = Task { try await session.click(request) }
		do {
			var pendingID: UUID?
			for _ in 0..<100 {
				pendingID = store.automation.pending.values.first {
					guard case let .click(click) = $0.request.operation else { return false }
					return click.operationID == request.operationID && $0.awaitingApproval
				}?.request.id
				if pendingID != nil { break }
				try await Task.sleep(for: .milliseconds(20))
			}
			print("""
			ARX_MCP_CLICK_APPROVAL pending=\(pendingID != nil) \
			sourceUnchanged=\(engine.client.snapshot(sourceID) == before)
			""")
			guard let pendingID, engine.client.snapshot(sourceID) == before
			else { throw AutomationSmokeFailure.clickMismatch }
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
