import AppUI
import BrowserCore
import SettingsFeature
import WorkspaceSync
import _ComposableArchitecture

/// A starter profile this Mac made that turning on iCloud Sync found a copy of from another Mac
/// (DEV-989). The first merge removes its spaces, copies of the kept profile's, and leaves the
/// profile and its website data to the person: Settings opens on removing it, with erasing its
/// data on, and nothing is erased until they confirm by typing its name, as for any profile.
///
/// Each profile is offered once, after a sync change is shown, at launch or once erasing is
/// available, and only while it has no spaces; one the person keeps stays an ordinary profile
/// they can remove later.
@Reducer
internal struct DuplicateStarterProfiles {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.workspaceSync)
	private var sync

	internal var body: some ReducerOf<Self> {
		Pullback(\.main.ui.task) { _ in
			find()
		}

		Pullback(\.event.workspaceSyncApplied) { _ in
			find()
		}

		// Erasing is offered only once the engine says it can; until then the offer waits.
		Pullback(\.profileRetirement.refreshed) { _, _ in
			find()
		}

		Pullback(\.event.duplicateStarterProfilesFound) { state, ids in

			// One that's gone is settled. One that has spaces here may not have been reloaded yet, or
			// the person filled it again: it stays listed, and is offered only once it's empty.
			let gone: [Profile.ID] = ids.filter { state.workspace.profiles[id: $0] == nil }
			let workspace: BrowserOrganization = state.workspace
			let offered: Profile? = ids
				.compactMap { id in workspace.profiles[id: id] }
				.first { profile in !workspace.spaces.contains { $0.profileID == profile.id } }
			guard
				let offered,
				state.settings.retirementAvailable,
				!state.syncReloadPending,
				!state.profileRetirement.isBusy,
				!state.settings.isManagingOrganization,
				!state.settings.organizationEditorIsPresented
			else { return forget(gone) }

			let editor: OrganizationEditor = .init(
				kind: .removeProfile(offered.id),
				name: offered.name,
				eraseWebsiteData: true,
				note: String.localized(.appUI.management.duplicateStarterProfile)
			)
			return .concatenate(
				forget(gone + [offered.id]),
				.send(.ui(.openSettings)),
				.send(.settings(.ui(.editOrganization(editor))))
			)
		}
	}

	private func find() -> Effect<Action> {
		guard sync.isAvailable() else { return .none }

		return .run { [sync] send in
			let ids: [Profile.ID] = await sync.duplicateStarterProfiles().map(Profile.ID.init(rawValue:))
			guard !ids.isEmpty else { return }

			await send(.event(.duplicateStarterProfilesFound(ids)))
		}
	}

	private func forget(_ ids: [Profile.ID]) -> Effect<Action> {
		guard !ids.isEmpty else { return .none }

		return .run { [sync] _ in
			for id in ids { await sync.forgetDuplicateStarterProfile(id.rawValue) }
		}
	}
}
