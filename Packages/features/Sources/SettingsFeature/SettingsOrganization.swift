import AppUI
import BrowserCore
import BrowserWorkspaceClient
import WorkspaceSync
import _ComposableArchitecture

@Reducer
internal struct SettingsOrganization {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.workspaceDocument)
	private var document

	@Dependency(\.workspaceSync)
	private var sync

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.editOrganization) { state, editor in
			guard !state.isManagingOrganization else { return .none }
			state.organizationEditor = editor
			state.organizationEditorIsPresented = true
			state.organizationError = nil
			return .none
		}

		Pullback(\.ui.organizationEditorChanged) { state, editor in
			guard !state.isManagingOrganization else { return .none }
			state.organizationEditor = editor
			state.organizationError = nil
			return .none
		}

		Pullback(\.ui.organizationEditorPresented) { state, presented in
			guard !state.isManagingOrganization else { return .none }
			state.organizationEditorIsPresented = presented
			return .none
		}

		Pullback(\.ui.dismissOrganizationEditor) { state in
			guard !state.isManagingOrganization else { return .none }
			state.organizationEditorIsPresented = false
			state.organizationError = nil
			return .none
		}

		Pullback(\.ui.submitOrganizationEditor) { state in

			// A change commits at once and closes the editor, keeping its name: a second Return
			// for the same sheet (DEV-774) finds it closed and creates nothing.
			guard
				state.organizationEditorIsPresented,
				!state.isManagingOrganization
			else { return .none }
			let editor = state.organizationEditor

			// "Delete from This Mac Only" (DEV-1336) reaches the store before the save that removes it,
			// when the sheet asked: another Mac syncs Profiles and spaces, and none removed it already.
			@SharedReader(.iCloudRemoval)
			var iCloudRemoval

			let keep: Effect<Action> = if
				iCloudRemoval.asksWhere,
				editor.keepsElsewhere,
				let id = editor.removedID,
				iCloudRemoval.marked[id] == nil
			{
				.run { [document] _ in document.keepRemovalOnThisMac([id]) }
			} else {
				.none
			}
			if case let .removeProfile(id) = editor.kind, editor.eraseWebsiteData {
				let isErasureConfirmed = state.retirementAvailable
				&& editor.eraseConfirmation == editor.name

				guard isErasureConfirmed else { return .none }

				state.isManagingOrganization = true
				state.organizationError = nil
				return .concatenate(keep, .send(.delegate(.retireProfile(id))))
			}
			do {
				let change = try state.organizationEditor.change(uuid: { uuid() })
				return .concatenate(keep, .send(.ui(.changeOrganization(change))))

			} catch {
				state.organizationError = organizationErrorMessage(error)
				return .none
			}
		}

		Pullback(\.ui.keepMarked) { _, ids in
			.run { [sync] _ in await sync.keep(ids) }
		}

		Pullback(\.ui.changeOrganization) { state, change in
			guard !state.isManagingOrganization else { return .none }
			state.isManagingOrganization = true
			state.organizationError = nil
			return .send(.delegate(.changeOrganization(change)))
		}

		Pullback(\.event.organizationChanged) { state in
			state.isManagingOrganization = false
			state.organizationEditorIsPresented = false
			state.organizationError = nil
			return .none
		}

		Pullback(\.event.organizationChangeFailed) { state, message in
			state.isManagingOrganization = false
			state.organizationError = message
			return .none
		}
	}
}

public func organizationErrorMessage(_ error: Error) -> String {
	switch error as? OrganizationChangeError {
	case .emptyName: String.localized(.appUI.management.emptyName)
	case .lastProfile: String.localized(.appUI.management.lastProfile)
	case .profileHasSpaces: String.localized(.appUI.management.profileHasSpaces)
	case .lastSpace: String.localized(.appUI.management.lastSpace)
	case .invalidSite: String.localized(.appUI.management.invalidSite)
	case .missingItem, nil: String.localized(.appUI.management.invalidChange)
	}
}
