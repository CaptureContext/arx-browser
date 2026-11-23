import BrowserAutomationClient
import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

extension BrowserAutomation {
	internal func waitForPage(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .wait(request) = pending.request.operation,
			let tab = state.workspace.tabs.first(where: { $0.id.rawValue == request.targetID }),
			let snapshot = pending.snapshots[tab.id],
			let documentRevision = snapshot.documentRevision
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		let target = PageWaitTarget(
			tabID: tab.id,
			profileID: tab.profileID,
			sessionRevision: snapshot.revision,
			documentRevision: documentRevision
		)
		state.automation.pending[requestID]?.waitTarget = target
		state.automation.pending[requestID]?.executing = true

		return .run { [control, pageWait, engine] send in
			do {
				try Task.checkCancellation()

				guard await control.authorize(requestID)
				else { throw AutomationFailure.denied }
				guard await pageWait.isAvailable()
				else { throw AutomationFailure.unsupported }

				let observation = try await pageWait.waitAuthorized(request, target) {
					control.authorize(requestID)
				}

				try Task.checkCancellation()

				guard await pageWait.sourceIsCurrent(observation.source)
				else { throw AutomationFailure.staleTarget }
				guard await control.authorize(requestID)
				else { throw AutomationFailure.denied }

				await send(.automation(.event(.waited(requestID, observation))))

			} catch is CancellationError {
				await send(.automation(.event(.finished(requestID, .failure(.cancelled)))))

			} catch {
				var failure = error as? AutomationFailure ?? .engineFailed

				// A challenge or sign-in prompt refused mid-wait revokes authorization
				// for the same document; report why instead of a plain denial.
				let requiresUserAction = await MainActor.run {
					engine.snapshot(target.tabID).map { snapshot in
						snapshot.documentRevision == target.documentRevision
						&& snapshot.navigation.requiresUserAction
					} ?? false
				}
				if failure == .denied, requiresUserAction { failure = .userActionRequired }
				await send(.automation(.event(.finished(requestID, .failure(failure)))))
			}
		}
		.cancellable(id: requestID)
	}

	internal func waited(
		_ requestID: UUID,
		observation: PageWaitObservation,
		state: inout State
	) -> Effect<Action> {
		let clients = state.automationPreferences.clients
		guard
			let pending = state.automation.pending[requestID],
			case let .wait(request) = pending.request.operation,
			pending.waitTarget == observation.source.target,
			let client = clients.first(where: { $0.id == pending.request.clientID })
		else { return .none }

		let snapshots = [observation.source.target.tabID: observation.snapshot]
		let failure = state.automationValidation(pending, snapshots: snapshots, now: now)
		if let failure { return finish(requestID, result: .failure(failure), state: &state) }

		let item = AutomationInventoryBuilder.item(
			request.targetID,
			client: client,
			organization: state.workspace,
			snapshots: snapshots
		)
		guard
			!observation.snapshot.navigation.isLoading,
			observation.snapshot.documentRevision == observation.source.target.documentRevision,
			let item
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		let result = AutomationWaitResult(
			request: request,
			source: observation.source,
			observedRevision: item.revision,
			sessionRevision: observation.snapshot.revision,
			errorCode: observation.snapshot.navigation.errorCode
		)
		do {
			try result.validate()
			return finish(requestID, result: .wait(result), state: &state)
		} catch {
			return finish(requestID, result: .failure(.invalidRequest), state: &state)
		}
	}
}

extension AppFeature.State {
	internal func automationWaitValidation(
		_ request: AutomationWaitRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		target: PageWaitTarget? = nil
	) -> AutomationFailure? {
		guard client.allowsRead else { return .denied }

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

		if let target {
			guard
				target.tabID == tabID,
				target.profileID == tab.profileID
			else { return .staleTarget }

		} else {
			let item = AutomationInventoryBuilder.item(
				request.targetID,
				client: client,
				organization: workspace,
				snapshots: snapshots
			)
			guard item?.revision == request.expectedRevision
			else { return .staleTarget }
		}

		guard let snapshot = snapshots[tabID] else { return .notLoaded }

		// DEV-873: Arx unloaded its page to free memory; `load` brings it back.
		guard !snapshot.navigation.isUnloaded else { return .notLoaded }
		guard let epoch = snapshot.documentRevision, epoch > 0
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

		return nil
	}
}
