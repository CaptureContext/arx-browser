import BrowserAutomationClient
import BrowserCore
import Foundation
import MainFeature
import ViewerFeature
import _ComposableArchitecture

internal struct AutomationCloseRequest: Equatable, Sendable {
	internal let token: UUID
	internal let tab: BrowserCore.Tab
	internal let location: BrowserOrganization.TabLocation
	internal let scope: AutomationTabLocation
	internal let windows: [UUID: TabPresentationReset]
	internal let mainIsOpen: Bool

	internal init(
		token: UUID,
		tab: BrowserCore.Tab,
		state: AppFeature.State
	) throws {
		guard
			let location = state.workspace.location(of: tab.id),
			let scope = AutomationAccess.location(of: tab.id, in: state.workspace)
		else { throw AutomationFailure.staleTarget }

		self.token = token
		self.tab = tab
		self.location = location
		self.scope = scope
		self.windows = Dictionary(
			uniqueKeysWithValues: state.automationOrdinaryHosts.map { host in
				(host.id, TabPresentationReset(tabID: tab.id, window: host))
			}
		)
		self.mainIsOpen = state.windowIsOpen
	}

	internal func matches(_ state: AppFeature.State) -> Bool {
		guard
			state.workspace.tabs[id: tab.id] == tab,
			state.workspace.location(of: tab.id) == location,
			state.windowIsOpen == mainIsOpen,
			Set(state.automationOrdinaryHosts.map(\.id)) == Set(windows.keys)
		else { return false }

		return state.automationOrdinaryHosts.allSatisfy { host in
			let reset = TabPresentationReset(tabID: tab.id, window: host)
			return host.automationCloseRequests[tab.id] == token
			&& windows[host.id]?.generations == reset.generations
		}
	}
}

/// An exact, short-lived acknowledgment of this operation's own removal/reset.
/// It does not grant access to a missing tab or authorize any subsequent command.
internal struct AutomationCloseReceipt: Equatable, Sendable {
	internal let request: AutomationRequest
	internal let grantRevision: UUID
	internal let source: AutomationCloseRequest
	internal let response: AutomationCommandResult
	internal let archived: ArchivedTab?
	internal let retained: BrowserCore.Tab?
	internal let generations: [UUID: [UUID: Int]]

	internal init(
		pending: AutomationState.Pending,
		source: AutomationCloseRequest,
		response: AutomationCommandResult,
		state: AppFeature.State
	) {
		self.request = pending.request
		self.grantRevision = pending.grantRevision
		self.source = source
		self.response = response
		self.archived = state.workspace.archive.first { $0.tab.id == source.tab.id }
		self.retained = state.workspace.tabs[id: source.tab.id]
		self.generations = state.automationPaneGenerations
	}

	internal func validation(
		request: AutomationRequest,
		response: AutomationCommandResult,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		state: AppFeature.State
	) -> AutomationFailure? {
		guard
			self.request == request,
			self.response == response,
			client.grantRevision == grantRevision,
			state.workspace.profiles.ids.contains(source.tab.profileID)
		else { return .denied }

		if case let .space(id) = source.scope {
			guard state.workspace.spaces[id: id]?.profileID == source.tab.profileID
			else { return .denied }
		}

		let exactScope = AutomationScope.tab(
			source.tab.id,
			profileID: source.tab.profileID,
			location: source.scope
		)
		let permitsSpace: Bool

		if case let .space(id) = source.scope {
			permitsSpace = AutomationAccess.permitsSpace(
				id,
				client: client,
				organization: state.workspace
			)
		} else {
			permitsSpace = false
		}
		guard
			client.scopes.contains(exactScope)
			|| permitsSpace
			|| AutomationAccess.permitsProfile(source.tab.profileID, client: client)
		else { return .denied }

		let isPresented = state.automationOrdinaryHosts.contains { host in
			host.viewer.panes.contains { $0.item.tab?.id == source.tab.id }
		}
		guard
			snapshots[source.tab.id] == nil,
			state.workspace.tabs[id: source.tab.id] == retained,
			state.workspace.archive.first(where: { $0.tab.id == source.tab.id }) == archived,
			state.automationPaneGenerations == generations,
			!isPresented,
			!state.peeks.contains(where: { $0.tab.id == source.tab.id })
		else { return .staleTarget }

		return nil
	}
}

extension BrowserAutomation {
	internal func close(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .command(command) = pending.request.operation,
			let tab = state.workspace.tabs.first(where: { $0.id.rawValue == command.targetID })
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		guard let closeAuthorized = engine.closeAuthorized else {
			return finish(id, result: .failure(.unsupported), state: &state)
		}

		let request: AutomationCloseRequest
		do {
			request = try .init(token: uuid(), tab: tab, state: state)
		} catch {
			return finish(id, result: .failure(.staleTarget), state: &state)
		}
		state.automation.pending[id]?.closeRequest = request
		state.main.automationCloseRequests[tab.id] = request.token
		for index in state.windows.indices where !state.windows[index].isPrivate {
			state.windows[index].automationCloseRequests[tab.id] = request.token
		}

		let revision = pending.snapshots[tab.id]?.revision
		return .run { @MainActor [engine, control] send in
			guard !Task.isCancelled else { return }
			guard control.authorize(id) else {
				send(.automation(.event(.finished(id, .failure(.denied)))))
				return
			}

			do {
				let closed = try await closeAuthorized(tab.id, revision, { control.authorize(id) }) {
					// The adapter invokes this in the same MainActor turn as native token
					// consumption and disposal. A newer reopen cannot interleave with commit.
					guard engine.snapshot(tab.id) == nil else {
						send(.automation(.event(.finished(id, .failure(.engineFailed)))))
						return
					}
					send(.automation(.event(.closed(id, request.token))))
				}
				if !closed {
					send(.automation(.event(.finished(id, .failure(.cancelled)))))
				}
			} catch {
				let failure = error as? AutomationFailure ?? .engineFailed
				send(.automation(.event(.finished(id, .failure(failure)))))
			}
		}
		.cancellable(id: id)
	}

	internal func closed(
		_ id: UUID,
		token: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			let source = pending.closeRequest,
			source.token == token,
			case let .command(command) = pending.request.operation
		else { return .none }

		let failure = state.automationValidation(
			pending,
			snapshots: pending.snapshots,
			now: now
		)
		if let failure { return finish(id, result: .failure(failure), state: &state) }

		do {
			if source.tab.savedDestination == nil {
				try state.main.archiveClosedTab(
					source.tab.id,
					closedAt: now,
					groupID: uuid(),
					recordsUndo: false,
					uuid: { uuid() }
				)
			} else if state.windowUndo {
				// Deleting a saved entry removes it; closing a pin or Favorite resets it. The commit
				// below records it as the agent's step, not the window's own (DEV-1030).
				state.main.sidebar.sealUndo()
				let newest = state.main.sidebar.undo.last?.id
				state.main.sidebar.commitTabClose(source.tab.id, reset: command.action != .removeSavedEntry)

				// Only a step the close itself added: a reset that changed nothing adds none.
				if state.main.sidebar.undo.last?.id != newest { state.main.sidebar.undo.removeLast() }
			} else {
				// Deleting a saved entry removes it; closing a pin or Favorite resets it.
				state.main.sidebar.commitTabClose(source.tab.id, reset: command.action != .removeSavedEntry)
			}
		} catch {
			return finish(id, result: .failure(.engineFailed), state: &state)
		}

		var effects = [commit(state.main.sidebar.organization, for: id, state: &state)]
		for hostID in source.windows.keys {
			let action: Action = hostID == state.main.id
			? .main(.refreshArchive)
			: .windows(.element(id: hostID, action: .refreshArchive))
			effects.append(AppFeature()._reduce(into: &state, action: action))
		}

		if source.tab.savedDestination != nil, command.action != .removeSavedEntry {
			for (hostID, reset) in source.windows {
				if hostID == state.main.id {
					state.main.clearResetTabPlacements(reset)
				} else {
					state.windows[id: hostID]?.clearResetTabPlacements(reset)
				}
				for (paneID, generation) in reset.generations {
					let action = MainFeature.Action.viewer(.unloadIfUnchanged(
						source.tab.id,
						in: paneID,
						generation: generation
					))
					let routed: Action = hostID == state.main.id
					? .main(action)
					: .windows(.element(id: hostID, action: action))
					effects.append(AppFeature()._reduce(into: &state, action: routed))
				}

				let changed = MainFeature.Action.delegate(.presentationChanged)
				let publication: Action = hostID == state.main.id
				? .main(changed)
				: .windows(.element(id: hostID, action: changed))
				effects.append(.send(publication))
			}
		}

		let response = AutomationCommandResult(
			operationID: command.operationID,
			status: .committed,
			targetID: command.targetID
		)
		state.automation.closeReceipts[id] = .init(
			pending: pending,
			source: source,
			response: response,
			state: state
		)
		let reply = finish(id, result: .command(response), state: &state)
		effects.append(.concatenate(reply, .send(.automation(.event(.closeReceiptReleased(id))))))
		return .merge(effects)
	}
}

extension AppFeature.State {
	internal var automationOrdinaryHosts: [MainFeature.State] {
		[main] + windows.filter { !$0.isPrivate }
	}

	internal var automationPaneGenerations: [UUID: [UUID: Int]] {
		Dictionary(
			uniqueKeysWithValues: automationOrdinaryHosts.map { host in
				let generations = Dictionary(
					uniqueKeysWithValues: host.viewer.panes.map { ($0.id, $0.item.generation) }
				)
				return (host.id, generations)
			}
		)
	}

	internal mutating func discardAutomationRequest(_ id: UUID) {
		endAgentPresence(id, now: nil)
		automation.hostCompletions.remove(id)
		automation.hostFailures[id] = nil
		automation.passwordSignIns[id] = nil
		guard let source = automation.pending.removeValue(forKey: id)?.closeRequest
		else { return }

		if main.automationCloseRequests[source.tab.id] == source.token {
			main.automationCloseRequests[source.tab.id] = nil
		}
		for index in windows.indices where windows[index].automationCloseRequests[source.tab.id] == source.token {
			windows[index].automationCloseRequests[source.tab.id] = nil
		}
	}
}
