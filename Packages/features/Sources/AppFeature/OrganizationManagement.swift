import AppUI
import BrowserCore
import BrowserEngineClient
import SettingsFeature
import _ComposableArchitecture

/// Publishes Settings edits once, then reconciles every normal window through its own selection.
@Reducer
internal struct OrganizationManagement {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.date)
	private var date

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.settings.delegate.changeOrganization) { state, change in
			let removedProfileID: Profile.ID? = if case let .removeProfile(id) = change { id } else { nil }
			if let removedProfileID, state.profileRetirement.intents.contains(where: { $0.profileID == removedProfileID }) {
				return failure(String.localized(.appUI.retirement.blocked))
			}
			guard !state.checkingQuit, !state.shouldQuit
			else { return failure(String.localized(.appUI.management.busy)) }

			guard !state.hasPendingProfileTransfers
			else { return failure(String.localized(.appUI.management.transferInProgress)) }

			if let removedProfileID {
				let profileInUse = state.littleWindows.contains(where: { $0.tab.profileID == removedProfileID })
				|| state.peeks.contains(where: { $0.tab.profileID == removedProfileID })

				if profileInUse { return failure(String.localized(.appUI.management.profileInUse)) }
			}

			let previous = state.workspace
			let updated: BrowserOrganization
			do {
				updated = try previous.applying(change, uuid: { uuid() })
			} catch {
				return failure(organizationErrorMessage(error))
			}
			let remaining = Set(updated.tabs.map(\.id))
			let blocked = Set(state.profileRetirement.intents.map(\.profileID))
			let movesBlockedSpace = updated.spaces.contains { space in
				blocked.contains(space.profileID)
				&& previous.spaces[id: space.id]?.profileID != space.profileID
			}
			guard !movesBlockedSpace
			else { return failure(String.localized(.appUI.retirement.blocked)) }

			let removed = previous.tabs.map(\.id).filter { !remaining.contains($0) }
			guard !removed.isEmpty else { return commit(updated, removed: [], state: &state) }

			let changedProfiles = Set(updated.spaces.compactMap { space -> Profile.ID? in
				guard
					let old = previous.spaces[id: space.id],
					old.profileID != space.profileID
				else { return nil }
				return space.profileID
			})

			return .run { [engine] send in
				do {
					for profile in changedProfiles { try await engine.prepareProfile(profile) }
				} catch {
					await send(.settings(.event(.organizationChangeFailed(
						String.localized(.appUI.management.profilePreparationFailed)
					))))
					return
				}

				for id in removed {
					guard await engine.permitsClosing(id), !Task.isCancelled else {
						await send(.settings(.event(.organizationChangeFailed(
							String.localized(.appUI.management.closeCancelled)
						))))
						return
					}
				}
				await send(.event(.organizationChangeApproved(previous, updated, removed)))
			}
		}

		Pullback(\.event.organizationChangeApproved) { state, value in
			let (previous, updated, removed) = value
			guard
				state.workspace == previous,
				!state.checkingQuit,
				!state.shouldQuit,
				!state.hasPendingProfileTransfers
			else {
				return failure(String.localized(.appUI.management.workspaceChanged))
			}
			let removedProfiles = Set(previous.profiles.map(\.id)).subtracting(updated.profiles.map(\.id))
			guard
				!state.littleWindows.contains(where: { removedProfiles.contains($0.tab.profileID) }),
				!state.peeks.contains(where: { removedProfiles.contains($0.tab.profileID) })
			else {
				return failure(String.localized(.appUI.management.profileInUse))
			}
			return commit(updated, removed: removed, state: &state)
		}
	}

	private func failure(_ message: String) -> Effect<Action> {
		.send(.settings(.event(.organizationChangeFailed(message))))
	}

	private func commit(
		_ organization: BrowserOrganization,
		removed: [BrowserCore.Tab.ID],
		state: inout State
	) -> Effect<Action> {
		let previous = state.workspace

		// Read before the owners follow the change: the windows the tabs it removes were in.
		let removedOwners = state.openTabOwners(removedFrom: previous, in: organization)
		let previousProfiles = Set(state.workspace.profiles.map(\.id))
		let createdProfile = organization.profiles.first { !previousProfiles.contains($0.id) }

		// A space moved to another profile gets new tab IDs; its windows keep them (DEV-822).
		state.remapOpenTabOwners(from: state.workspace, to: organization)
		state.workspace = organization
		state.unsavedOrganization = organization
		if let createdProfile {
			state.settings.selectedProfileID = createdProfile.id
		} else if organization.profiles[id: state.settings.selectedProfileID] == nil {
			state.settings.selectedProfileID = organization.profiles.first?.id
		}

		var effects: [Effect<Action>] = [
			.send(.settings(.event(.organizationChanged))),
			.send(.main(.reconcile(organization))),
		]
		for id in state.windows.filter({ !$0.isPrivate }).map(\.id) {
			effects.append(.send(.windows(.element(
				id: id,
				action: .reconcile(organization)
			))))
		}
		effects.append(.run { [engine] _ in
			for id in removed { await engine.close(id) }
		})
		effects.append(.send(.delegate(.save(organization))))
		let removedSpaces = previous.spaces.ids.subtracting(organization.spaces.ids)
		let unrecorded = state.unrecordedSpaceRemovals.intersection(removedSpaces)
		state.unrecordedSpaceRemovals.subtract(unrecorded)
		if state.windowUndo, unrecorded.isEmpty, let step = deletedSpaceStep(from: previous, to: organization, owners: removedOwners) {
			effects.append(state.appendUndo(step))
		}
		return .concatenate(effects)
	}

	/// A deleted space can come back with ⌘Z in any window for the grace period, with its tabs,
	/// folders and their history: a closed tab's history stays on disk until the next launch
	/// (DEV-1030). Other Settings changes aren't steps.
	private func deletedSpaceStep(
		from previous: BrowserOrganization,
		to organization: BrowserOrganization,
		owners: [BrowserCore.Tab.ID: UUID]
	) -> OrganizationUndo? {
		let removed = previous.spaces.ids.subtracting(organization.spaces.ids)
		guard
			!removed.isEmpty,
			previous.profiles.ids == organization.profiles.ids
		else { return nil }

		return .init(
			before: previous,
			after: organization,
			spaceID: removed.count == 1 ? removed.first : nil,
			expiresAt: date.now.addingTimeInterval(OrganizationUndo.deletedSpaceGracePeriod),
			openTabOwners: owners,
			restoresSelection: false
		)
	}
}

extension AppFeature.State {
	internal var hasPendingProfileTransfers: Bool {
		main.transferInProgress
		|| windows.contains(where: \.transferInProgress)
		|| littleWindows.contains { $0.isSwitchingProfile || $0.isPromoting }
	}
}
