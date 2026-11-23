import BrowserCore
import BrowserPageInteractionClient
import ChromiumEngine
import Foundation

internal enum ChromiumScrollAdapter {
	@MainActor
	internal static func action(
		isAvailable: @escaping @MainActor @Sendable () -> Bool,
		sourceIsCurrent: @escaping @MainActor @Sendable (PageInspectionSource) -> Bool,
		perform: @escaping @MainActor @Sendable (
			ChromiumReferenceScrollRequest,
			PageInspectionSource,
			@escaping @MainActor @Sendable () -> Bool
		) async -> ChromiumReferenceScrollResult
	) -> BrowserPageInteractionClient.Scroll {
		{ request, inspection, authorize in
			func rejected(_ failure: AutomationFailure) -> AutomationScrollResult {
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
				return rejected(error as? AutomationFailure ?? .invalidRequest)
			}

			guard !Task.isCancelled else { return rejected(.cancelled) }
			guard isAvailable() else { return rejected(.unsupported) }
			guard
				request.target.targetID == inspection.request.targetID,
				request.target.snapshotID == inspection.snapshot.snapshotID,
				inspection.snapshot.nodes.contains(where: { $0.reference == request.target.reference }),
				sourceIsCurrent(inspection.source)
			else { return rejected(.staleReference) }

			let result = await perform(
				.init(
					operationID: request.operationID,
					snapshot: .init(inspection.snapshot),
					reference: request.target.reference,
					axis: request.axis == .horizontal ? .horizontal : .vertical,
					deltaCSSPixels: request.canonicalDelta
				),
				inspection.source
			) {
				isAvailable()
				&& sourceIsCurrent(inspection.source)
				&& authorize()
			}
			guard result.operationID == request.operationID else {
				return .init(
					operationID: request.operationID,
					disposition: .possiblyDispatched,
					failure: .engineFailed
				)
			}
			return .init(
				operationID: result.operationID,
				disposition: disposition(result.disposition),
				failure: result.failure.map(failure)
			)
		}
	}

	private static func disposition(
		_ value: ChromiumReferenceScrollDisposition
	) -> AutomationScrollDisposition {
		switch value {
		case .notDispatched: .notDispatched
		case .dispatched: .dispatched
		case .possiblyDispatched: .possiblyDispatched
		case .unchanged: .unchanged
		}
	}

	private static func failure(_ value: ChromiumReferenceScrollFailure) -> AutomationFailure {
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
		case .noScrollableContainer: .noScrollableContainer
		case .invalidDelta: .invalidDelta
		}
	}
}
