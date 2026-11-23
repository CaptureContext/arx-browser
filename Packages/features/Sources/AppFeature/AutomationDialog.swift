import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

extension AppFeature.State {
	internal func automationDialogValidation(
		_ request: AutomationDialogRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allows([.read, .pageContent, .interact]) else { return .denied }
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}
		return automationPageValidation(
			targetID: request.targetID,
			expectedRevision: request.expectedRevision,
			client: client,
			snapshots: snapshots
		)
	}

	/// A read releases the page's dialog text, so it's checked like any page read.
	/// Answering may navigate the page; that reply holds only the outcome.
	internal func automationDialogResponseValidation(
		_ request: AutomationDialogRequest,
		response: AutomationDialogResult,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allows([.read, .pageContent, .interact]) else { return .denied }
		do {
			try request.validate()
			try response.validate()
		} catch {
			return error as? AutomationFailure ?? .invalidRequest
		}
		guard
			response.targetID == request.targetID,
			response.operationID == request.operationID
		else { return .invalidRequest }

		switch request.action {
		case .read:
			guard !response.answered, response.failure == nil else { return .invalidRequest }
			return automationDialogValidation(request, client: client, snapshots: snapshots)

		case .accept, .dismiss:
			guard response.dialog == nil else { return .invalidRequest }
			guard automationPermitsLiveTab(request.targetID, client: client) else { return .denied }
			return nil
		}
	}
}

extension BrowserAutomation {
	/// Reads the tab's dialog, or answers the exact one `read` returned. Accepting
	/// was approved by the user; the answer itself is checked once more here.
	internal func pageDialog(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .dialog(request) = pending.request.operation,
			let tab = state.workspace.tabs[id: .init(rawValue: request.targetID)]
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		state.automation.pending[requestID]?.executing = true
		return .run { [engine, control] send in
			let current = await engine.pageDialog(tab.id)
			let result: AutomationDialogResult
			switch request.action {
			case .read:
				result = .init(targetID: request.targetID, dialog: current)

			case .accept, .dismiss:
				guard let current, current.token == request.token else {
					result = .init(targetID: request.targetID, operationID: request.operationID, failure: .staleTarget)
					break
				}
				let answer = await engine.answerPageDialog(
					tab.id,
					current,
					request.action == .accept,
					request.action == .accept && current.kind == .prompt ? request.text : nil
				) {
					control.authorize(requestID)
				}
				let failure: AutomationFailure? = switch answer {
				case .answered: nil
				case .stale: .staleTarget
				case .invalid: .invalidValue
				case .denied: .denied
				case .unavailable: .unsupported
				}
				result = .init(
					targetID: request.targetID,
					operationID: request.operationID,
					answered: answer == .answered,
					failure: failure
				)
			}
			await send(.automation(.event(.finished(requestID, .dialog(result)))))
		}
		.cancellable(id: requestID)
	}
}
