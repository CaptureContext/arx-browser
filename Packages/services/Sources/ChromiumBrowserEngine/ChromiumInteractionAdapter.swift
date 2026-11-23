import BrowserCore
import BrowserPageInteractionClient
import ChromiumEngine
import Foundation

internal enum ChromiumInteractionAdapter {
	@MainActor
	internal static func client(
		isAvailable: @escaping @MainActor @Sendable () -> Bool,
		sourceIsCurrent: @escaping @MainActor @Sendable (PageInspectionSource) -> Bool,
		click: @escaping @MainActor @Sendable (
			ChromiumReferenceClickRequest,
			PageInspectionSource,
			@escaping @MainActor @Sendable () -> Bool
		) async -> ChromiumReferenceClickResult
	) -> BrowserPageInteractionClient {
		.init(
			isAvailable: isAvailable,
			clickAuthorized: { request, inspection, authorize in
				func rejected(_ failure: AutomationFailure) -> AutomationClickResult {
					.init(
						operationID: request.operationID,
						disposition: .notDispatched,
						failure: failure
					)
				}

				do {
					try request.validate()
					try inspection.validate()
				} catch {
					return rejected(.invalidRequest)
				}
				guard !Task.isCancelled else { return rejected(.cancelled) }
				guard isAvailable() else { return rejected(.unsupported) }
				guard
					request.targetID == inspection.request.targetID,
					request.snapshotID == inspection.snapshot.snapshotID,
					inspection.snapshot.nodes.contains(where: { $0.reference == request.reference }),
					sourceIsCurrent(inspection.source)
				else { return rejected(.staleReference) }

				let result = await click(
					.init(
						operationID: request.operationID,
						snapshot: .init(inspection.snapshot),
						reference: request.reference
					),
					inspection.source
				) {
					isAvailable() && sourceIsCurrent(inspection.source) && authorize()
				}
				guard result.operationID == request.operationID else {
					return .init(
						operationID: request.operationID,
						disposition: .possiblyDispatched,
						failure: .engineFailed
					)
				}

				// A click may itself navigate, detach its source or revoke a permission.
				// Preserve the native outcome instead of reclassifying it as no effect.
				return .init(
					operationID: result.operationID,
					disposition: disposition(result.disposition),
					failure: result.failure.map(failure)
				)
			}
		)
	}

	private static func disposition(
		_ value: ChromiumReferenceClickDisposition
	) -> AutomationClickDisposition {
		switch value {
		case .notDispatched: .notDispatched
		case .dispatched: .dispatched
		case .possiblyDispatched: .possiblyDispatched
		}
	}

	private static func failure(_ value: ChromiumReferenceClickFailure) -> AutomationFailure {
		switch value {
		case .unavailable, .unsupportedDocument: .unsupported
		case .notReady: .notReady
		case .staleReference: .staleReference
		case .notInteractable: .notInteractable
		case .notAuthorized: .denied
		case .busy: .busy
		case .limitExceeded: .limitExceeded
		case .duplicateOperation: .duplicateOperation
		case .cancelled: .cancelled
		case .timedOut: .timedOut
		case .invalidResponse: .engineFailed
		}
	}
}
