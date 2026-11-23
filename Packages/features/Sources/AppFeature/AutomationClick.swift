import BrowserAutomationClient
import BrowserCore
import Foundation
import _ComposableArchitecture

extension AutomationState {
	internal struct ReleasedInspection: Equatable, Sendable {
		internal var request: AutomationRequest
		internal var grantRevision: UUID
		internal var result: AutomationInspectionResult
		internal var expiresAt: Date

		internal init(
			request: AutomationRequest,
			grantRevision: UUID,
			result: AutomationInspectionResult,
			expiresAt: Date
		) {
			self.request = request
			self.grantRevision = grantRevision
			self.result = result
			self.expiresAt = expiresAt
		}
	}

	internal struct ClickReceipt: Equatable, Sendable {
		internal var request: AutomationRequest
		internal var grantRevision: UUID
		internal var source: PageInspectionSource

		internal init(
			request: AutomationRequest,
			grantRevision: UUID,
			source: PageInspectionSource
		) {
			self.request = request
			self.grantRevision = grantRevision
			self.source = source
		}
	}
}

extension AppFeature.State {
	internal mutating func recordReleasedInspection(
		_ request: AutomationRequest,
		result: AutomationInspectionResult,
		grantRevision: UUID,
		now: Date
	) {
		guard
			automation.sessions[request.sessionID] == request.clientID,
			let scope = automation.inspectionScopes[request.sessionID],
			scope.clientID == request.clientID,
			scope.grantRevision == grantRevision,
			scope.id == result.source.scopeID,
			case let .inspect(inspection) = request.operation,
			inspection == result.request
		else { return }

		automation.releasedInspections.removeAll { released in
			released.expiresAt <= now
			|| (
				released.request.sessionID == request.sessionID
				&& released.result.source.tabID == result.source.tabID

				// Each frame keeps its own latest snapshot, as the engine does.
				&& released.result.snapshot.frameID == result.snapshot.frameID
			)
		}
		automation.releasedInspections.append(.init(
			request: request,
			grantRevision: grantRevision,
			result: result,
			expiresAt: now.addingTimeInterval(30)
		))

		// Mirror the native global snapshot budget. Eviction always invalidates
		// an old reference; it never substitutes another tab's snapshot.
		if automation.releasedInspections.count > 16 {
			automation.releasedInspections.removeFirst(automation.releasedInspections.count - 16)
		}
	}

	internal func releasedInspection(
		for request: AutomationRequest,
		click: AutomationClickRequest,
		now: Date
	) -> AutomationState.ReleasedInspection? {
		automation.releasedInspections.first {
			$0.request.clientID == request.clientID
			&& $0.request.sessionID == request.sessionID
			&& $0.result.request.targetID == click.targetID
			&& $0.result.snapshot.snapshotID == click.snapshotID
			&& $0.expiresAt > now
		}
	}

	internal func automationClickValidation(
		_ request: AutomationClickRequest,
		pending: AutomationState.Pending,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date,
		targetsViewport: Bool = false,
		destinationReference: String? = nil
	) -> AutomationFailure? {
		guard
			client.allowsPageContent,
			client.allowsPageInteraction
		else { return .denied }
		let receiptCount = automation.clickReceipts.count
		+ automation.formReceipts.count
		+ automation.scrollReceipts.count
		let hasReceiptCapacity = receiptCount < 16
		|| automation.clickReceipts[pending.request.id] != nil
		|| automation.formReceipts[pending.request.id] != nil
		|| automation.scrollReceipts[pending.request.id] != nil
		guard hasReceiptCapacity else { return .busy }

		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}

		let inspection = AutomationInspectionRequest(
			targetID: request.targetID,
			expectedRevision: request.expectedRevision
		)
		let inspectionFailure = automationInspectionValidation(
			inspection,
			client: client,
			snapshots: snapshots
		)
		if let inspectionFailure { return inspectionFailure }

		guard
			let released = releasedInspection(for: pending.request, click: request, now: now),
			released.grantRevision == client.grantRevision,
			let scope = automation.inspectionScopes[pending.request.sessionID],
			scope.id == released.result.source.scopeID,
			scope.grantRevision == client.grantRevision,
			let snapshot = snapshots[released.result.source.tabID],
			snapshot.revision == released.result.source.sessionRevision,
			snapshot.documentRevision == released.result.source.documentRevision,
			// A pointer point addresses the viewport through the snapshot's own ID.
			targetsViewport || released.result.snapshot.nodes.contains(where: { $0.reference == request.reference }),
			destinationReference.map({ destination in
				released.result.snapshot.nodes.contains(where: { $0.reference == destination })
			}) ?? true
		else { return .staleReference }
		return nil
	}
}

extension BrowserAutomation {
	internal func click(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .click(request) = pending.request.operation,
			let released = state.releasedInspection(for: pending.request, click: request, now: now)
		else { return finish(id, result: .failure(.staleReference), state: &state) }

		state.automation.pending[id]?.executing = true
		state.automation.pending[id]?.interactionSource = released.result.source
		return .run { [control, pageInteraction] send in
			let result: AutomationClickResult
			if Task.isCancelled {
				result = .init(
					operationID: request.operationID,
					disposition: .notDispatched,
					failure: .cancelled
				)

			} else if await !control.authorize(id) {
				result = .init(
					operationID: request.operationID,
					disposition: .notDispatched,
					failure: .denied
				)

			} else if await !pageInteraction.isAvailable() {
				result = .init(
					operationID: request.operationID,
					disposition: .notDispatched,
					failure: .unsupported
				)

			} else {
				result = await pageInteraction.clickAuthorized(request, released.result) {
					control.authorize(id) && control.beginClick(id)
				}
			}

			// Do not throw on cancellation here: native submission may already have
			// changed the website. The receipt must preserve that uncertainty.
			await send(.automation(.event(.finished(id, .click(result)))))
		}
		.cancellable(id: id)
	}
}
