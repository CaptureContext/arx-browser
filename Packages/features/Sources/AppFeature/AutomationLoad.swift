import BrowserAutomationClient
import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

extension BrowserAutomation {
	/// Opens a background page for a saved tab. Nothing is selected, focused or
	/// attached: the page loads detached until a window shows the tab.
	internal func loadPage(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .load(request) = pending.request.operation,
			let tab = state.workspace.tabs[id: .init(rawValue: request.targetID)]
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		// DEV-873: a tab Arx unloaded to free memory has a page, but loads again here.
		if let snapshot = pending.snapshots[tab.id], !snapshot.navigation.isUnloaded {
			let result = AutomationLoadResult(targetID: request.targetID, status: .alreadyLoaded)
			return finish(requestID, result: .load(result), state: &state)
		}

		state.automation.pending[requestID]?.executing = true
		return .run { [engine, control] send in
			do {
				try await engine.prepareProfile(tab.profileID)
				try Task.checkCancellation()
				try await engine.openAuthorized(tab) { control.authorize(requestID) }
				let result = AutomationLoadResult(targetID: request.targetID, status: .loading)
				await send(.automation(.event(.finished(requestID, .load(result)))))

			} catch is CancellationError {
				await send(.automation(.event(.finished(requestID, .failure(.cancelled)))))

			} catch {
				let failure = error as? AutomationFailure ?? .engineFailed
				await send(.automation(.event(.finished(requestID, .failure(failure)))))
			}
		}
		.cancellable(id: requestID)
	}
}

extension AppFeature.State {
	internal func automationLoadValidation(
		_ request: AutomationLoadRequest,
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
			automationPermitsLiveTab(request.targetID, client: client),
			let tab = workspace.tabs[id: tabID]
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
			!windows.contains(where: isBusy)
		else { return .busy }

		let item = AutomationInventoryBuilder.item(
			request.targetID,
			client: client,
			organization: workspace,
			snapshots: snapshots
		)
		guard item?.revision == request.expectedRevision
		else { return .staleTarget }

		// A saved tab reopens its restoration URL; only ordinary web pages are loaded.
		let url = tab.reopeningURL
		guard
			url.hasWebScheme,
			url.host != nil
		else { return .unsupported }
		return nil
	}

	/// Opening the page creates its session, which moves the tab's revision. The
	/// reply holds only the load's status, so the tab only has to still be reachable.
	internal func automationLoadResponseValidation(
		_ request: AutomationLoadRequest,
		response: AutomationLoadResult,
		client: AutomationClient
	) -> AutomationFailure? {
		guard client.allowsRead, client.allowsPageContent else { return .denied }
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}
		guard response.targetID == request.targetID else { return .invalidRequest }
		guard automationPermitsLiveTab(request.targetID, client: client) else { return .denied }

		return nil
	}
}
