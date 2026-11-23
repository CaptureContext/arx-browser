import BrowserAutomationClient
import BrowserCore
import Foundation
import _ComposableArchitecture

extension AutomationState {
	/// Contains no payload or original request. The canonical binding is a SHA256 digest.
	internal struct InteractionReceipt: Equatable, Sendable {
		internal var requestID: UUID
		internal var clientID: UUID
		internal var sessionID: UUID
		internal var operationID: UUID
		internal var binding: String
		internal var grantRevision: UUID
		internal var source: PageInspectionSource

		internal init(
			requestID: UUID,
			clientID: UUID,
			sessionID: UUID,
			operationID: UUID,
			binding: String,
			grantRevision: UUID,
			source: PageInspectionSource
		) {
			self.requestID = requestID
			self.clientID = clientID
			self.sessionID = sessionID
			self.operationID = operationID
			self.binding = binding
			self.grantRevision = grantRevision
			self.source = source
		}
	}
}

extension AppFeature.State {
	internal func automationFormResponseValidation(
		_ request: AutomationRequest,
		form: AutomationFormRequest,
		response: AutomationFormResult,
		client: AutomationClient
	) -> AutomationFailure? {
		guard form.operationID == response.operationID
		else { return .invalidRequest }
		guard
			client.allowsPageContent,
			client.allowsPageInteraction
		else { return .denied }

		let key = AutomationState.OperationKey(
			clientID: client.id,
			operationID: form.operationID
		)
		let isRejectedBeforeAdmission = response.disposition == .notDispatched
		&& response.failure == .limitExceeded
		&& !automation.usedOperations.contains(key)
		if isRejectedBeforeAdmission { return nil }

		if response.failure == .duplicateOperation {
			let matchesRecordedOutcome = response.disposition == .possiblyDispatched
			|| (
				automation.operationBindings[key] == AutomationSecurity.mutationBinding(request.operation)
				&& automation.formOutcomes[key]?.disposition == response.disposition
			)
			guard
				automation.usedOperations.contains(key),
				matchesRecordedOutcome
			else { return .denied }

			return nil
		}
		guard
			automation.formOutcomes[key]?.disposition == response.disposition,
			automation.operationBindings[key] == AutomationSecurity.mutationBinding(request.operation)
		else { return .denied }
		if response.disposition == .notDispatched { return nil }

		guard
			let receipt = automation.formReceipts[request.id],
			receipt.requestID == request.id,
			receipt.clientID == request.clientID,
			receipt.sessionID == request.sessionID,
			receipt.operationID == form.operationID,
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
	internal func form(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .form(request) = pending.request.operation,
			let released = state.releasedInspection(for: pending.request, click: request.target, now: now)
		else { return finish(id, result: .failure(.staleReference), state: &state) }

		state.automation.pending[id]?.executing = true
		state.automation.pending[id]?.interactionSource = released.result.source
		return .run { [control, pageInteraction] send in
			let result: AutomationFormResult
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

			} else if await !pageInteraction.formIsAvailable() {
				result = .init(
					operationID: request.operationID,
					disposition: .notDispatched,
					failure: .unsupported
				)

			} else if request.kind == .keyPress, await !pageInteraction.keypressIsAvailable() {
				result = .init(
					operationID: request.operationID,
					disposition: .notDispatched,
					failure: .unsupported
				)

			} else {
				result = await pageInteraction.formAuthorized(request, released.result) {
					control.authorize(id) && control.beginForm(id)
				}
			}
			await send(.automation(.event(.finished(id, .form(result)))))
		}
		.cancellable(id: id)
	}
}
