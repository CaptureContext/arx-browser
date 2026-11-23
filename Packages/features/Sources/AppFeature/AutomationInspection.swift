import BrowserAutomationClient
import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

extension BrowserAutomation {
	internal func inspectPage(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .inspect(request) = pending.request.operation,
			let tab = state.workspace.tabs.first(where: { $0.id.rawValue == request.targetID }),
			let snapshot = pending.snapshots[tab.id],
			let documentRevision = snapshot.documentRevision
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		let sessionID = pending.request.sessionID
		let scope: AutomationState.InspectionScope = state.automation.inspectionScopes[sessionID]
		?? .init(
			id: uuid(),
			clientID: pending.request.clientID,
			grantRevision: pending.grantRevision
		)
		guard
			scope.clientID == pending.request.clientID,
			scope.grantRevision == pending.grantRevision
		else { return finish(requestID, result: .failure(.denied), state: &state) }

		state.automation.inspectionScopes[sessionID] = scope
		state.automation.pending[requestID]?.executing = true
		let source = PageInspectionSource(
			tabID: tab.id,
			profileID: tab.profileID,
			sessionRevision: snapshot.revision,
			documentRevision: documentRevision,
			scopeID: scope.id
		)

		return .run { [control, pageInspection] send in
			do {
				try Task.checkCancellation()
				guard await control.authorize(requestID)
				else { throw AutomationFailure.denied }
				guard await pageInspection.isAvailable()
				else { throw AutomationFailure.unsupported }

				let snapshot = try await pageInspection.inspectAuthorized(request, source) {
					control.authorize(requestID)
				}
				let result = AutomationInspectionResult(
					request: request,
					source: source,
					snapshot: snapshot
				)
				try result.validate()
				let encoded = try JSONEncoder().encode(AutomationIPC.Reply.result(.inspection(result)))
				guard encoded.count <= AutomationIPC.maximumResponseBytes
				else { throw AutomationFailure.limitExceeded }

				try Task.checkCancellation()
				guard await control.authorize(requestID)
				else { throw AutomationFailure.denied }
				guard await pageInspection.documentIsCurrent(result)
				else { throw AutomationFailure.staleTarget }
				await send(.automation(.event(.finished(requestID, .inspection(result)))))

			} catch is CancellationError {
				await send(.automation(.event(.finished(requestID, .failure(.cancelled)))))

			} catch {
				let failure = error as? AutomationFailure ?? .engineFailed
				await send(.automation(.event(.finished(requestID, .failure(failure)))))
			}
		}
		.cancellable(id: requestID)
	}

	internal func revokeInspectionScopes(_ scopes: [UUID]) -> Effect<Action> {
		guard !scopes.isEmpty else { return .none }
		return .run { [pageInspection] _ in
			await MainActor.run {
				for scope in scopes { pageInspection.revokeScope(scope) }
			}
		}
	}
}

extension AppFeature.State {
	internal func automationInspectionValidation(
		_ request: AutomationInspectionRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allowsRead, client.allowsPageContent else { return .denied }
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}

		let tabID = Tab.ID(rawValue: request.targetID)
		guard
			AutomationAccess.permitsTab(tabID, client: client, organization: workspace),
			let tab = workspace.tabs[id: tabID],
			workspace.profiles.ids.contains(tab.profileID)
		else { return .denied }

		func isBusy(_ host: MainFeature.State) -> Bool {
			host.transferInProgress
			|| host.isClosing
			|| host.pendingTabCloses.contains(tabID)
			|| host.pendingFolderDeletion != nil
			|| host.archive.isWorking
		}
		guard
			!settings.isManagingOrganization,
			!isBusy(main),
			!windows.contains(where: isBusy),
			!peeks.contains(where: { $0.tab.id == tabID })
		else { return .busy }

		let item = AutomationInventoryBuilder.item(
			request.targetID,
			client: client,
			organization: workspace,
			snapshots: snapshots
		)
		guard item?.revision == request.expectedRevision
		else { return .staleTarget }
		guard let snapshot = snapshots[tabID] else { return .notLoaded }

		// DEV-873: Arx unloaded its page to free memory; `load` brings it back.
		guard !snapshot.navigation.isUnloaded else { return .notLoaded }
		guard let documentRevision = snapshot.documentRevision, documentRevision > 0
		else { return .unsupported }
		guard
			let url = snapshot.navigation.url,
			url.hasWebScheme,
			url.host != nil
		else { return .unsupported }

		// An unattended run refused an HTTP authentication or sign-in prompt
		// nobody could answer.
		guard !snapshot.navigation.requiresUserAction
		else { return .userActionRequired }
		guard snapshot.navigation.errorCode == nil, !snapshot.navigation.isLoading
		else { return .notReady }
		return nil
	}
}
