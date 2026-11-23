import AppUI
import BrowserAutomationClient
import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

extension AutomationState {
	/// What an asynchronous management command waits to observe before it reports success.
	internal enum Settlement: Equatable, Sendable {
		/// A Settings transaction or sidebar edit that should leave the workspace exactly so.
		case workspace(BrowserOrganization, resultID: UUID?)

		/// The profile should be gone once retirement finishes.
		case profileRemoved(Profile.ID)

		/// The cross-profile move with this request ID should have committed.
		case transfer(UUID)

		/// The window should show this tab in one of its panes.
		case pane(windowID: UUID, tabID: BrowserCore.Tab.ID)

		/// The window's panes should be in this order.
		case panes(windowID: UUID, [UUID])

		/// The window's panes should show exactly these tabs, in this order, in this orientation.
		case split(windowID: UUID, [BrowserCore.Tab.ID], BrowserSpacePresentation.Orientation)

		/// The window should show this space.
		case space(windowID: UUID, Space.ID)

		/// The window should be focused.
		case focused(UUID)

		/// Settings should hold exactly these preferences.
		case preferences(BrowserPreferences)
	}
}

extension AppFeature.State {
	/// Ordinary windows whose current space the grant covers. Only granted tabs are named.
	public func automationWindows(for client: AutomationClient) -> [AutomationWindowItem] {
		guard client.allowsRead else { return [] }

		let hosts = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		return hosts.compactMap { host in
			let spaceID = host.sidebar.spaceID
			guard AutomationAccess.permitsSpace(spaceID, client: client, organization: workspace)
			else { return nil }

			func granted(_ id: BrowserCore.Tab.ID?) -> UUID? {
				guard
					let id,
					AutomationAccess.permitsTab(id, client: client, organization: workspace)
				else { return nil }
				return id.rawValue
			}

			let selected = granted(host.sidebar.selectedTab?.id)
			let panes = host.viewer.panes.count > 1
			? host.viewer.panes.compactMap { granted($0.item.tab?.id) }
			: []
			let isFocused = (focusedWindowID ?? main.id) == host.id
			let fields = [
				"window", host.id.uuidString, spaceID.rawValue.uuidString,
				selected?.uuidString ?? "none", panes.map(\.uuidString).joined(separator: ","),
				isFocused ? "focused" : "background", client.grantRevision.uuidString,
			]
			return .init(
				id: host.id,
				spaceID: spaceID.rawValue,
				selectedTabID: selected,
				paneTabIDs: panes,
				isFocused: isFocused,
				isMain: host.id == main.id,
				revision: AutomationSecurity.digest(Data(fields.joined(separator: "\u{1F}").utf8))
			)
		}
	}

	/// The inventory's open tabs with the window that keeps each, while each window keeps its
	/// own (DEV-1157): an additional window's, or the main window's for the rest.
	internal func automationTabWindows(_ items: [AutomationInventoryItem]) -> [AutomationInventoryItem] {
		guard independentWindows, items.contains(where: { $0.kind == .tab }) else { return items }

		let locations = workspace.tabLocations
		return items.map { item in
			guard
				item.kind == .tab,
				let window = automationWindow(keeping: .init(rawValue: item.id), locations: locations)
			else { return item }

			var item = item
			item.windowID = window
			return item
		}
	}

	/// The window that keeps an open tab while each window keeps its own: an additional
	/// window's, or the main window's (DEV-1157). None for a pinned tab or Favorite.
	internal func automationWindow(
		keeping tab: BrowserCore.Tab.ID,
		locations: [BrowserCore.Tab.ID: BrowserOrganization.TabLocation]
	) -> UUID? {
		guard independentWindows, case .unpinned = locations[tab] else { return nil }
		return windowTabOwners[tab] ?? main.id
	}

	internal func automationWindowValidation(
		_ command: AutomationCommand,
		client: AutomationClient
	) -> AutomationFailure? {
		guard let window = automationWindows(for: client).first(where: { $0.id == command.targetID })
		else { return .denied }
		guard window.revision == command.expectedRevision else { return .staleTarget }
		if command.action == .swapSplit || command.action == .closeSplit {
			guard window.paneTabIDs.count > 1 else { return .invalidRequest }
		}
		return nil
	}

	/// Whether a management command's expected result is now visible.
	internal func automationSettled(_ settlement: AutomationState.Settlement) -> Bool {
		func host(_ id: UUID) -> MainFeature.State? {
			id == main.id ? main : windows[id: id]
		}

		switch settlement {
		case let .workspace(expected, _):
			return workspace == expected

		case let .profileRemoved(id):
			return workspace.profiles[id: id] == nil

		case let .transfer(requestID):
			return automation.completedTransfers.contains(requestID)

		case let .pane(windowID, tabID):
			return host(windowID)?.viewer.panes.contains { $0.item.tab?.id == tabID } == true

		case let .panes(windowID, order):
			return host(windowID)?.viewer.panes.map(\.id) == order

		case let .split(windowID, tabs, orientation):
			guard let viewer = host(windowID)?.viewer else { return false }
			return viewer.panes.map(\.item.tab?.id) == tabs.map(Optional.some) && viewer.orientation == orientation

		case let .space(windowID, spaceID):
			return host(windowID)?.sidebar.spaceID == spaceID

		case let .focused(windowID):
			return focusedWindowID == windowID

		case let .preferences(expected):
			return persistedPreferences == expected
		}
	}
}

extension BrowserAutomation {
	/// Runs profile, space, Favorites, saved-entry, folder, Split View and window commands
	/// through the same transactions and actions the Settings window and sidebar use.
	internal func manage(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		let targetID = command.targetID
		switch command.action {
		case .createProfile:
			let profileID = Profile.ID(rawValue: uuid())
			return change(id, .createProfile(profileID, name: command.name ?? ""), resultID: profileID.rawValue, state: &state)

		case .renameProfile:
			return change(id, .renameProfile(.init(rawValue: targetID), name: command.name ?? ""), state: &state)

		case .deleteProfile:
			let profileID = Profile.ID(rawValue: targetID)
			guard !state.workspace.spaces.contains(where: { $0.profileID == profileID })
			else { return finish(id, result: .failure(.invalidRequest), state: &state) }

			state.automation.pending[id]?.settlement = .profileRemoved(profileID)
			return .send(.profileRetirement(.begin(profileID)))

		case .createSpace:
			let spaceID = Space.ID(rawValue: uuid())
			let icon = command.icon.flatMap(SpaceIcon.init(rawValue:))
			return change(
				id,
				.createSpace(spaceID, profileID: .init(rawValue: targetID), name: command.name ?? "", icon: icon),
				resultID: spaceID.rawValue,
				state: &state
			)

		case .renameSpace:
			guard let space = state.workspace.spaces[id: .init(rawValue: targetID)]
			else { return finish(id, result: .failure(.staleTarget), state: &state) }

			return change(
				id,
				.updateSpace(
					space.id,
					profileID: space.profileID,
					name: command.name ?? space.name,
					icon: command.icon.flatMap(SpaceIcon.init(rawValue:)) ?? space.icon
				),
				state: &state
			)

		case .setSpaceTheme:
			guard let space = state.workspace.spaces[id: .init(rawValue: targetID)]
			else { return finish(id, result: .failure(.staleTarget), state: &state) }

			var appearance = space.appearance ?? .init()
			appearance.theme = command.theme.flatMap(AppearanceOverride.Theme.init(rawValue:))
			return change(id, .setSpaceAppearance(space.id, appearance), state: &state)

		case .setSpaceAppearance:
			guard
				let space = state.workspace.spaces[id: .init(rawValue: targetID)],
				let appearance = command.appearance
			else { return finish(id, result: .failure(.staleTarget), state: &state) }

			return change(id, .setSpaceAppearance(space.id, appearance.applied(to: space.appearance)), state: &state)

		case .setProfileAppearance:
			guard
				let profile = state.workspace.profiles[id: .init(rawValue: targetID)],
				let appearance = command.appearance
			else { return finish(id, result: .failure(.staleTarget), state: &state) }

			return change(id, .setProfileAppearance(profile.id, appearance.applied(to: profile.appearance)), state: &state)

		case .moveSpace:
			return change(
				id,
				.moveSpace(.init(rawValue: targetID), before: command.destinationID.map(Space.ID.init(rawValue:))),
				state: &state
			)

		case .deleteSpace:
			return deleteSpace(id, command: command, state: &state)

		case .selectSpace:
			let spaceID = Space.ID(rawValue: targetID)
			let windowID = state.main.id
			state.automation.pending[id]?.settlement = .space(windowID: windowID, spaceID)
			return settle(id, after: .send(.main(.sidebar(.ui(.spaceSelected(spaceID))))))

		case .addFavorite, .removeFavorite, .updateSavedURL, .ungroupFolder:
			return edit(id, command: command, state: &state)

		case .removeSavedEntry:
			guard state.workspace.tabs[id: .init(rawValue: targetID)]?.savedDestination != nil
			else { return finish(id, result: .failure(.invalidRequest), state: &state) }

			return close(id, state: &state)

		case .deleteFolder:
			return deleteFolder(id, command: command, state: &state)

		case .openSplit:
			let tabID = BrowserCore.Tab.ID(rawValue: targetID)
			guard state.main.sidebar.organization.tabs[id: tabID] != nil, state.windowIsOpen
			else { return finish(id, result: .failure(.notReady), state: &state) }

			let windowID = state.main.id
			if let splitTabs = command.splitTabs {
				let tabs = [tabID] + splitTabs.map { BrowserCore.Tab.ID(rawValue: $0.id) }

				// A tab another window or Peek shows can't be a pane here; refuse before changing anything.
				let elsewhere = Set(state.windows.flatMap { $0.viewer.panes.compactMap { $0.item.tab?.id } })
					.union(state.peeks.map(\.tab.id))
				guard elsewhere.isDisjoint(with: tabs)
				else { return finish(id, result: .failure(.invalidRequest), state: &state) }
				guard tabs.count <= state.main.viewer.capacity.panes(command.orientation ?? .horizontal)
				else { return finish(id, result: .failure(.invalidRequest), state: &state) }

				let orientation = command.orientation ?? .horizontal
				state.automation.pending[id]?.settlement = .split(windowID: windowID, tabs, orientation)
				return settle(id, after: .send(.main(.ui(.openSplit(tabs, orientation)))))
			}
			state.automation.pending[id]?.settlement = .pane(windowID: windowID, tabID: tabID)
			return settle(id, after: .send(.main(.ui(.splitTab(tabID)))))

		case .swapSplit, .closeSplit:
			let windowID = targetID
			guard let host = windowID == state.main.id ? state.main : state.windows[id: windowID]
			else { return finish(id, result: .failure(.staleTarget), state: &state) }

			let action: MainFeature.Action
			if command.action == .swapSplit {
				action = .ui(.swapPanes)
				state.automation.pending[id]?.settlement = .panes(windowID: windowID, host.viewer.panes.map(\.id).reversed())
			} else {
				action = .ui(.closePane)
				let remaining = host.viewer.panes.map(\.id).filter { $0 != host.viewer.activePaneID }
				state.automation.pending[id]?.settlement = .panes(windowID: windowID, remaining)
			}
			let routed: Action = windowID == state.main.id ? .main(action) : .windows(.element(id: windowID, action: action))
			return settle(id, after: .send(routed))

		case .focusWindow:
			// Launch onboarding holds the main window back until it ends (DEV-838).
			if targetID == state.main.id, !state.openMainWindow() {
				return finish(id, result: .failure(.userActionRequired), state: &state)
			}
			state.automation.pending[id]?.settlement = .focused(targetID)
			return settle(id, after: .send(.ui(.focusWindow(targetID))))

		default:
			return finish(id, result: .failure(.unsupported), state: &state)
		}
	}

	/// A tab moving into another profile reopens its URL and saved metadata there, through
	/// the sidebar's transfer. The live session and its cookies stay behind, and the source
	/// is kept until the destination exists.
	internal func transfer(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		guard
			let destinationID = command.destinationID,
			let space = state.workspace.spaces[id: .init(rawValue: destinationID)],
			state.windowIsOpen
		else { return finish(id, result: .failure(.invalidRequest), state: &state) }

		let requestID = uuid()
		state.automation.pending[id]?.settlement = .transfer(requestID)
		return .send(.main(.transferConfirmedTabs(requestID, [.tab(command.targetID)], nil, space.id)))
	}

	/// Settles a pending management command once its awaited change is visible, or fails it.
	internal func settled(
		_ id: UUID,
		failure: AutomationFailure? = nil,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			let settlement = pending.settlement
		else { return .none }

		if let failure { return finish(id, result: .failure(failure), state: &state) }
		guard state.automationSettled(settlement) else {
			// The change travels through other features' effects; look again shortly.
			guard pending.settleAttempts < 50
			else { return finish(id, result: .failure(.staleTarget), state: &state) }

			state.automation.pending[id]?.settleAttempts += 1
			return .run { [clock] send in
				try await clock.sleep(for: .milliseconds(100))
				await send(.automation(.event(.managementSettled(id))))
			}
			.cancellable(id: id)
		}

		if case let .settings(request) = pending.request.operation {
			return settingsSettled(id, request: request, state: &state)
		}
		guard case let .command(command) = pending.request.operation else { return .none }

		var resultID: UUID? = command.targetID
		switch settlement {
		case let .workspace(_, created): resultID = created ?? command.targetID
		case .profileRemoved, .transfer: resultID = nil
		default: break
		}

		// Removed or newly reopened targets aren't in this client's current inventory.
		if command.action.removesTarget { resultID = nil }
		return finish(
			id,
			result: .command(.init(operationID: command.operationID, status: .committed, targetID: resultID)),
			state: &state
		)
	}

	private func committedResult(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		let targetID: UUID? = command.action.removesTarget ? nil : command.targetID
		return finish(
			id,
			result: .command(.init(operationID: command.operationID, status: .committed, targetID: targetID)),
			state: &state
		)
	}

	private func settle(
		_ id: UUID,
		after effect: Effect<Action>
	) -> Effect<Action> {
		.concatenate(effect, .send(.automation(.event(.managementSettled(id)))))
	}

	/// Applies a Settings transaction: removed sessions must allow closing first, and the
	/// commit goes through the same approval event Settings uses.
	private func change(
		_ id: UUID,
		_ change: OrganizationChange,
		resultID: UUID? = nil,
		state: inout State
	) -> Effect<Action> {
		let previous = state.workspace
		do {
			let updated = try previous.applying(change, uuid: { uuid() })
			return transaction(id, previous: previous, updated: updated, resultID: resultID, state: &state)
		} catch {
			return finish(id, result: .failure(.invalidRequest), state: &state)
		}
	}

	private func transaction(
		_ id: UUID,
		previous: BrowserOrganization,
		updated: BrowserOrganization,
		resultID: UUID?,
		state: inout State
	) -> Effect<Action> {
		guard !state.hasPendingProfileTransfers, !state.profileRetirement.isBusy
		else { return finish(id, result: .failure(.busy), state: &state) }

		let remaining = Set(updated.tabs.map(\.id))
		let removed = previous.tabs.map(\.id).filter { !remaining.contains($0) }
		state.automation.pending[id]?.executing = true
		state.automation.pending[id]?.settlement = .workspace(updated, resultID: resultID)
		return .run { [engine] send in
			for tab in removed {
				guard await engine.permitsClosing(tab), !Task.isCancelled else {
					await send(.automation(.event(.managementFailed(id, .cancelled))))
					return
				}
			}
			await send(.automation(.event(.managementApproved(id, previous, updated, removed))))
		}
		.cancellable(id: id)
	}

	internal func approved(
		_ id: UUID,
		previous: BrowserOrganization,
		updated: BrowserOrganization,
		removed: [BrowserCore.Tab.ID],
		state: inout State
	) -> Effect<Action> {
		guard let pending = state.automation.pending[id] else {
			return .none
		}
		if let failure = state.automationValidation(pending, snapshots: pending.snapshots, now: now) {
			return finish(id, result: .failure(failure), state: &state)
		}
		guard state.workspace == previous
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		guard state.windowUndo else {
			return settle(id, after: .send(.event(.organizationChangeApproved(previous, updated, removed))))
		}

		// The agent's step, saying whose it is, in place of the one Settings would record
		// (DEV-1030).
		state.unrecordedSpaceRemovals.formUnion(previous.spaces.ids.subtracting(updated.spaces.ids))
		let step = undoStep(from: previous, to: updated, for: id, state: state)
		return settle(id, after: .concatenate(
			.send(.event(.organizationChangeApproved(previous, updated, removed))),
			step.map { state.appendUndo($0) } ?? .none
		))
	}

	/// Deleting a space either moves its contents into another space of the same profile
	/// first, or closes them after each page allows it. The last space can't be deleted.
	private func deleteSpace(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		let previous = state.workspace
		let spaceID = Space.ID(rawValue: command.targetID)
		guard let space = previous.spaces[id: spaceID]
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		do {
			var source = previous
			if let destinationID = command.destinationID {
				let destination = Space.ID(rawValue: destinationID)
				guard
					destination != spaceID,
					previous.spaces[id: destination]?.profileID == space.profileID
				else { return finish(id, result: .failure(.invalidRequest), state: &state) }

				let roots = space.savedItems + space.unpinnedTabs.map(SavedItem.tab)
				if !roots.isEmpty {
					source = try previous.moving(
						roots,
						to: .spaceRoot,
						in: destination,
						newTabID: { .init(rawValue: uuid()) }
					).updated
				}
			}
			let updated = try source.applying(.removeSpace(spaceID), uuid: { uuid() })
			return transaction(id, previous: previous, updated: updated, resultID: nil, state: &state)
		} catch {
			return finish(id, result: .failure(.invalidRequest), state: &state)
		}
	}

	/// Folder deletion closes every contained session only after each page allows it.
	private func deleteFolder(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		let folderID = Folder.ID(rawValue: command.targetID)
		var updated = state.workspace
		do {
			try updated.deleteFolder(folderID)
		} catch {
			return finish(id, result: .failure(.invalidRequest), state: &state)
		}
		guard state.main.pendingFolderDeletion == nil
		else { return finish(id, result: .failure(.busy), state: &state) }

		let previous = state.workspace
		let removed = state.workspace.tabs(in: folderID, includingDescendants: true)
		state.automation.pending[id]?.executing = true
		state.automation.pending[id]?.settlement = .workspace(updated, resultID: nil)
		return .run { [engine, updated] send in
			for tab in removed {
				guard await engine.permitsClosing(tab), !Task.isCancelled else {
					await send(.automation(.event(.managementFailed(id, .cancelled))))
					return
				}
			}
			await send(.automation(.event(.folderDeletionApproved(id, previous, updated, removed))))
		}
		.cancellable(id: id)
	}

	internal func folderDeleted(
		_ id: UUID,
		previous: BrowserOrganization,
		updated: BrowserOrganization,
		removed: [BrowserCore.Tab.ID],
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .command(command) = pending.request.operation
		else { return .none }

		if let failure = state.automationValidation(pending, snapshots: pending.snapshots, now: now) {
			return finish(id, result: .failure(failure), state: &state)
		}
		guard state.workspace == previous
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		let committed = commit(updated, for: id, state: &state)
		return .merge(
			committed,
			.run { [engine] _ in for tab in removed { await engine.close(tab) } },
			committedResult(id, command: command, state: &state)
		)
	}

	/// Organization edits the sidebar makes, committed with the main window's Undo.
	private func edit(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		let tabID = BrowserCore.Tab.ID(rawValue: command.targetID)
		var organization = state.workspace
		do {
			switch command.action {
			case .addFavorite:
				guard let tab = organization.tabs[id: tabID]
				else { throw AutomationFailure.staleTarget }
				guard let space = organization.spaces.first(where: { $0.profileID == tab.profileID })
				else { throw AutomationFailure.invalidRequest }

				let target: SidebarDropTarget = command.destinationID.map { .before(.tab($0)) } ?? .favoritesRoot
				if let destination = command.destinationID {
					guard
						case .favorite = organization.location(of: .init(rawValue: destination)),
						organization.tabs[id: .init(rawValue: destination)]?.profileID == tab.profileID
					else { throw AutomationFailure.invalidRequest }
				}
				try organization.move(.tab(command.targetID), to: target, in: space.id)

			case .removeFavorite:
				guard
					case .favorite = organization.location(of: tabID),
					let destination = command.destinationID,
					let space = organization.spaces[id: .init(rawValue: destination)],
					space.profileID == organization.tabs[id: tabID]?.profileID
				else { throw AutomationFailure.invalidRequest }

				try organization.move(.tab(command.targetID), to: .unpinnedRoot, in: space.id)

			case .updateSavedURL:
				try organization.updateSavedURL(tabID)

			case .ungroupFolder:
				try organization.ungroupFolder(.init(rawValue: command.targetID))

			default:
				throw AutomationFailure.unsupported
			}
		} catch {
			return finish(id, result: .failure(error as? AutomationFailure ?? .invalidRequest), state: &state)
		}

		let committed = commit(organization, for: id, state: &state)
		return .merge(committed, committedResult(id, command: command, state: &state))
	}
}
