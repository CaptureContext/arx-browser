import AppUI
import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

extension BrowserAutomation {
	internal func execute(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .command(command) = pending.request.operation
		else { return .none }

		let failure = state.automationValidation(
			pending,
			snapshots: pending.snapshots,
			now: now
		)
		if let failure { return finish(id, result: .failure(failure), state: &state) }

		if command.action.isHostOperation { return executeHost(id, state: &state) }

		state.automation.pending[id]?.executing = true
		if command.action == .openTab, command.focus {
			let context = TabPresentationContext(state)
			state.automation.pending[id]?.focusContext = context
		}

		if let nativeCommand = command.nativeCommand {
			let tabID = BrowserCore.Tab.ID(rawValue: command.targetID)
			guard let snapshot = pending.snapshots[tabID] else {
				return finish(id, result: .failure(.notLoaded), state: &state)
			}

			return .run { [engine, control] send in
				do {
					try await engine.commandAuthorized(tabID, snapshot.revision, nativeCommand) {
						control.authorize(id)
					}
					let result = AutomationCommandResult(
						operationID: command.operationID,
						status: command.action == .stop ? .committed : .acceptedLoading,
						targetID: command.targetID
					)
					await send(.automation(.event(.finished(id, .command(result)))))
				} catch {
					let failure = error as? AutomationFailure ?? .engineFailed
					await send(.automation(.event(.finished(id, .failure(failure)))))
				}
			}
			.cancellable(id: id)
		}

		switch command.action {
		case .closeTab:
			return close(id, state: &state)

		case .moveTab where state.workspace.moveTabCrossesProfiles(command):
			return transfer(id, command: command, state: &state)

		case .createProfile, .renameProfile, .deleteProfile, .createSpace, .renameSpace, .setSpaceTheme,
			.setSpaceAppearance, .setProfileAppearance, .moveSpace,
			.deleteSpace, .selectSpace, .addFavorite, .removeFavorite, .updateSavedURL, .removeSavedEntry,
			.ungroupFolder, .deleteFolder, .openSplit, .swapSplit, .closeSplit, .focusWindow:
			return manage(id, command: command, state: &state)

		case .restoreArchived:
			return restoreArchived(id, command: command, state: &state)

		case .cancelDownload, .revealDownload:
			return downloadCommand(id, command: command, state: &state)

		case .startDownload:
			return startDownload(id, command: command, state: &state)

		case .openTab:
			guard
				let space = state.workspace.spaces.first(where: { $0.id.rawValue == command.targetID }),
				let url = command.url
			else { return finish(id, result: .failure(.invalidRequest), state: &state) }

			// A tab this client left on the same page in an earlier run is taken over rather than
			// opened again beside it (DEV-1022). The person's tabs never are.
			if let reused = state.reusableAgentTab(
				clientID: pending.request.clientID,
				sessionID: pending.request.sessionID,
				url: url,
				spaceID: space.id
			) {
				// Its profile first; the tab is looked at again once that's done (`reuseReady`).
				return .run { [engine] send in
					do {
						try await engine.prepareProfile(space.profileID)
						try Task.checkCancellation()
						await send(.automation(.event(.agentTabReuseReady(id, reused))))
					} catch {
						let failure = error as? AutomationFailure ?? .engineFailed
						await send(.automation(.event(.finished(id, .failure(failure)))))
					}
				}
				.cancellable(id: id)
			}
			return openNewTab(id, url: url, space: space, clientID: pending.request.clientID)

		case .selectTab:
			let tabID = BrowserCore.Tab.ID(rawValue: command.targetID)
			guard pending.snapshots[tabID] != nil else {
				return finish(id, result: .failure(.notLoaded), state: &state)
			}
			guard let tab = state.workspace.tabs[id: tabID] else {
				return finish(id, result: .failure(.staleTarget), state: &state)
			}

			let focus = OrdinaryTabPresentation().focus(tab, state: &state)
			let result = AutomationCommandResult(
				operationID: command.operationID,
				status: .committed,
				targetID: command.targetID
			)
			return .merge(focus, finish(id, result: .command(result), state: &state))

		case .pinTab, .unpinTab, .moveTab, .moveFolder, .createFolder, .renameFolder:
			do {
				var organization = state.workspace
				let resultID = try edit(command, organization: &organization)
				let effects = commit(organization, for: id, state: &state)
				let result = AutomationCommandResult(
					operationID: command.operationID,
					status: .committed,
					targetID: resultID
				)
				return .merge(effects, finish(id, result: .command(result), state: &state))
			} catch {
				let failure = error as? AutomationFailure ?? .invalidRequest
				return finish(id, result: .failure(failure), state: &state)
			}

		default:
			return finish(id, result: .failure(.unsupported), state: &state)
		}
	}

	internal func opened(
		_ id: UUID,
		tab: BrowserCore.Tab,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .command(command) = pending.request.operation
		else { return .run { [engine] _ in await engine.close(tab.id) } }

		let failure = state.automationValidation(
			pending,
			snapshots: pending.snapshots,
			now: now
		)
		if let failure {
			return .merge(
				.run { [engine] _ in await engine.close(tab.id) },
				finish(id, result: .failure(failure), state: &state)
			)
		}
		var organization = state.workspace
		do {
			try organization.update { candidate in
				let index = candidate.spaces.firstIndex { space in
					space.id.rawValue == command.targetID
					&& space.profileID == tab.profileID
				}
				guard let index else { throw AutomationFailure.staleTarget }

				candidate.tabs.append(tab)
				candidate.spaces[index].unpinnedTabs.append(tab.id)
			}
		} catch {
			return .merge(
				.run { [engine] _ in await engine.close(tab.id) },
				finish(id, result: .failure(.staleTarget), state: &state)
			)
		}

		// Native creation may finish after a newer user choice or host closure. The tab
		// still belongs to its authorized destination, but must then remain in the background.
		let shouldFocus = command.focus && pending.focusContext == TabPresentationContext(state)
		let committed = commit(organization, for: id, state: &state)

		// The window the request named keeps it; the main window does otherwise (DEV-1157).
		if let windowID = command.windowID { state.giveOpenTabs([tab.id], to: windowID) }

		// The tab is the agent's until the person picks or keeps it (DEV-1022).
		state.recordAgentTab(tab.id, clientID: pending.request.clientID, sessionID: pending.request.sessionID)
		let focused: Effect<Action> = shouldFocus
		? OrdinaryTabPresentation().focus(tab, state: &state)
		: .none
		let events: Effect<Action> = .run { [engine] send in
			for await navigation in await engine.events(tab.id) {
				await send(.main(.viewer(.item(.delegate(.navigation(tab.id, navigation))))))
			}
		}
		.cancellable(id: AutomationObservationID(tabID: tab.id), cancelInFlight: true)
		let result = AutomationCommandResult(
			operationID: command.operationID,
			status: .acceptedLoading,
			targetID: tab.id.rawValue
		)
		return .merge(
			committed,
			focused,
			events,
			finish(id, result: .command(result), state: &state)
		)
	}

	private func edit(
		_ command: AutomationCommand,
		organization: inout BrowserOrganization
	) throws -> UUID {
		switch command.action {
		case .moveFolder:
			return try moveFolder(command, organization: &organization)

		case .createFolder:
			let id = Folder.ID(rawValue: uuid())
			try organization.update { candidate in
				guard
					let index = candidate.spaces.firstIndex(where: { $0.id.rawValue == command.targetID }),
					let name = command.name
				else { throw AutomationFailure.invalidRequest }

				candidate.folders.append(.init(id: id, spaceID: candidate.spaces[index].id, name: name))
				candidate.spaces[index].savedItems.append(.folder(id))
			}
			return id.rawValue

		case .renameFolder:
			try organization.update { candidate in
				guard
					let index = candidate.folders.firstIndex(where: { $0.id.rawValue == command.targetID }),
					let name = command.name
				else { throw AutomationFailure.invalidRequest }

				candidate.folders[index].name = name
			}

		case .pinTab, .unpinTab, .moveTab:
			guard let destination = command.destinationID
			else { throw AutomationFailure.invalidRequest }

			let space: Space?
			let target: SidebarDropTarget
			if let folder = organization.folders.first(where: { $0.id.rawValue == destination }) {
				guard command.action != .unpinTab else { throw AutomationFailure.invalidRequest }
				space = organization.spaces[id: folder.spaceID]
				target = .inside(.folder(folder.id.rawValue))

			} else {
				space = organization.spaces.first(where: { $0.id.rawValue == destination })
				let tab = organization.tabs.first(where: { $0.id.rawValue == command.targetID })
				let pinned = tab?.savedDestination != nil
				let unpins = command.action == .unpinTab || (command.action == .moveTab && !pinned)
				target = unpins ? .unpinnedRoot : .savedRoot
			}

			guard let space else { throw AutomationFailure.unsupported }

			let tab = organization.tabs.first(where: { $0.id.rawValue == command.targetID })
			guard tab?.profileID == space.profileID
			else { throw AutomationFailure.crossProfileTransferUnsupported }

			try organization.move(.tab(command.targetID), to: target, in: space.id)

		default:
			throw AutomationFailure.unsupported
		}
		return command.targetID
	}
}

private struct AutomationObservationID: Hashable {
	private let tabID: BrowserCore.Tab.ID

	fileprivate init(tabID: BrowserCore.Tab.ID) {
		self.tabID = tabID
	}
}

extension AutomationCommand {
	fileprivate var nativeCommand: BrowserEngineClient.Command? {
		switch action {
		case .navigate: url.map { .navigate($0) }
		case .reload: .reload
		case .back: .back
		case .forward: .forward
		case .stop: .stop
		default: nil
		}
	}
}

extension BrowserOrganization {
	/// Whether `moveTab` reopens the tab in another profile. A folder destination belongs to
	/// its space's profile, so moving a tab into a folder of its own profile stays a move.
	fileprivate func moveTabCrossesProfiles(_ command: AutomationCommand) -> Bool {
		let destination = command.destinationID.flatMap { id in
			spaces[id: .init(rawValue: id)]?.id ?? folders[id: .init(rawValue: id)]?.spaceID
		}
		return tabs[id: .init(rawValue: command.targetID)]?.profileID
		!= destination.flatMap { spaces[id: $0]?.profileID }
	}
}

extension BrowserAutomation {
	/// A new tab for `openTab`, opened by the engine for the request before the app adds it.
	private func openNewTab(
		_ id: UUID,
		url: URL,
		space: Space,
		clientID: UUID
	) -> Effect<Action> {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: uuid()),
			profileID: space.profileID,
			restoration: .init(title: url.host() ?? "", url: url),
			automationClientID: clientID
		)
		return .run { [engine, control] send in
			do {
				try await engine.prepareProfile(space.profileID)
				try Task.checkCancellation()
				try await engine.openAuthorized(tab) { control.authorize(id) }
				try Task.checkCancellation()
				await send(.automation(.event(.opened(id, tab))))
			} catch {
				await engine.close(tab.id)
				let failure = error as? AutomationFailure ?? .engineFailed
				await send(.automation(.event(.finished(id, .failure(failure)))))
			}
		}
		.cancellable(id: id)
	}

	/// The tab `openTab` takes over, looked at again right before its page opens (DEV-1022):
	/// still the client's and still an open tab of the space the request names, with the request
	/// still valid. A tab that went meanwhile gives way to a new one.
	internal func reuseReady(
		_ id: UUID,
		tabID: BrowserCore.Tab.ID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .command(command) = pending.request.operation,
			command.action == .openTab,
			let url = command.url,
			let space = state.workspace.spaces.first(where: { $0.id.rawValue == command.targetID })
		else { return .none }

		if let failure = state.automationValidation(pending, snapshots: pending.snapshots, now: now) {
			return finish(id, result: .failure(failure), state: &state)
		}

		// Still what `reusableAgentTab` chose: on the requested page, as the client left it in a
		// connection that has ended, and nothing using it. One that navigated, was picked, kept or
		// shown meanwhile, or that another open took over first (DEV-1097), isn't taken.
		guard
			let tab = state.workspace.tabs[id: tabID],
			space.unpinnedTabs.contains(tabID),
			state.isReusableAgentTab(
				tabID,
				clientID: pending.request.clientID,
				sessionID: pending.request.sessionID,
				url: url
			)
		else { return openNewTab(id, url: url, space: space, clientID: pending.request.clientID) }

		state.recordAgentTab(tabID, clientID: pending.request.clientID, sessionID: pending.request.sessionID)
		let context = state.automation.pending[id]?.focusContext
		let shouldFocus = command.focus && context == TabPresentationContext(state)

		// The window the request names, else the main window, takes the tab from whichever window
		// had it, as a new tab would go there (DEV-1157).
		let taken = state.takeOpenTabs([tabID], into: command.windowID ?? state.main.id)
		let focused: Effect<Action> = shouldFocus ? OrdinaryTabPresentation().focus(tab, state: &state) : .none
		let opened: Effect<Action> = .run { [engine, control] send in

			// A page still loaded is ready; one unloaded, or from an earlier launch, loads again.
			let wasLoaded = await engine.snapshot(tabID).map { !$0.navigation.isUnloaded } ?? false
			do {
				try await engine.openAuthorized(tab) { control.authorize(id) }
				let result = AutomationCommandResult(
					operationID: command.operationID,
					status: wasLoaded ? .committed : .acceptedLoading,
					targetID: tabID.rawValue
				)
				await send(.automation(.event(.finished(id, .command(result)))))
			} catch {
				let failure = error as? AutomationFailure ?? .engineFailed
				await send(.automation(.event(.finished(id, .failure(failure)))))
			}
		}
		.cancellable(id: id)
		let events: Effect<Action> = .run { [engine] send in
			for await navigation in await engine.events(tabID) {
				await send(.main(.viewer(.item(.delegate(.navigation(tabID, navigation))))))
			}
		}
		.cancellable(id: AutomationObservationID(tabID: tabID), cancelInFlight: true)
		return .merge(taken, focused, opened, events)
	}
}
