import BrowserAutomationClient
import BrowserCore
import Foundation
import _ComposableArchitecture

extension AppFeature.State {
	internal func automationScrollResponseValidation(
		_ request: AutomationRequest,
		scroll: AutomationScrollRequest,
		response: AutomationScrollResult,
		client: AutomationClient
	) -> AutomationFailure? {
		guard scroll.operationID == response.operationID
		else { return .invalidRequest }
		guard
			client.allowsPageContent,
			client.allowsPageInteraction
		else { return .denied }

		let key = AutomationState.OperationKey(
			clientID: client.id,
			operationID: scroll.operationID
		)
		let isRejectedBeforeAdmission = response.disposition == .notDispatched
		&& response.failure == .limitExceeded
		&& !automation.usedOperations.contains(key)
		if isRejectedBeforeAdmission { return nil }

		if response.failure == .duplicateOperation {
			let matchesRecordedOutcome = response.disposition == .possiblyDispatched
			|| (
				automation.operationBindings[key] == AutomationSecurity.mutationBinding(request.operation)
				&& automation.scrollOutcomes[key]?.disposition == response.disposition
			)
			guard
				automation.usedOperations.contains(key),
				matchesRecordedOutcome
			else { return .denied }

			return nil
		}
		guard
			automation.scrollOutcomes[key]?.disposition == response.disposition,
			automation.operationBindings[key] == AutomationSecurity.mutationBinding(request.operation)
		else { return .denied }
		if response.disposition == .notDispatched { return nil }

		guard
			let receipt = automation.scrollReceipts[request.id],
			receipt.requestID == request.id,
			receipt.clientID == request.clientID,
			receipt.sessionID == request.sessionID,
			receipt.operationID == scroll.operationID,
			receipt.binding == automation.operationBindings[key],
			receipt.grantRevision == client.grantRevision,
			workspace.profiles.ids.contains(receipt.source.profileID),
			workspace.tabs[id: receipt.source.tabID]?.profileID == receipt.source.profileID,
			AutomationAccess.permitsTab(receipt.source.tabID, client: client, organization: workspace)
		else { return .denied }
		return nil
	}
}

extension BrowserAutomation {
	internal func scroll(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .scroll(request) = pending.request.operation,
			let released = state.releasedInspection(for: pending.request, click: request.target, now: now)
		else { return finish(id, result: .failure(.staleReference), state: &state) }

		state.automation.pending[id]?.executing = true
		state.automation.pending[id]?.interactionSource = released.result.source
		return .run { [control, pageInteraction] send in
			let result: AutomationScrollResult
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

			} else if await !pageInteraction.scrollIsAvailable() {
				result = .init(
					operationID: request.operationID,
					disposition: .notDispatched,
					failure: .unsupported
				)

			} else {
				result = await pageInteraction.scrollAuthorized(request, released.result) {
					control.authorize(id) && control.beginScroll(id)
				}
			}
			await send(.automation(.event(.finished(id, .scroll(result)))))
		}
		.cancellable(id: id)
	}
}
