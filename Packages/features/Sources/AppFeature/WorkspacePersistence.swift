import BrowserWorkspaceClient
import DiagnosticsClient
import WorkspaceSync
import _ComposableArchitecture

/// The production boundary for atomic workspace writes.
///
/// Ordinary edits are coalesced and written off the main actor. Saves that a pending
/// flow waits on (quit, migration commits, security transitions, profile retirement)
/// are written without delay.
@Reducer
internal struct WorkspacePersistence {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal static let coalescingInterval: Duration = .milliseconds(250)

	private enum Cancellation: Hashable { case coalescedSave }

	private let workspace: BrowserWorkspaceClient

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.workspaceDocument)
	private var document

	@Dependency(\.workspaceSync)
	private var sync

	internal init(workspace: BrowserWorkspaceClient) {
		self.workspace = workspace
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.delegate.save) { state, _ in
			guard !state.discardUnsavedChangesOnQuit else { return .none }

			// The group's change saves what's unsaved once it lands.
			guard !state.isChangingPreferenceGroup else { return .none }
			guard !state.requiresImmediateSave else { return flush(state: state) }

			return .run { [clock] send in
				try await clock.sleep(for: Self.coalescingInterval)
				await send(.flushWorkspaceSave)
			}
			.cancellable(id: Cancellation.coalescedSave, cancelInFlight: true)
		}

		Pullback(\.flushWorkspaceSave) { state in
			guard !state.discardUnsavedChangesOnQuit, !state.isChangingPreferenceGroup else { return .none }

			return flush(state: state)
		}

		// Keeping a Preferences group on this Mac or syncing it again (DEV-982) is a save of the
		// workspace with the new choice, ordered with the others by its ticket.
		Pullback(\.settings.iCloudSync.delegate.setPreferenceGroup) { state, value in
			let (group, syncs, keepingThisMac) = value

			// A flow waiting on its own save (quitting, a migration, a security change) goes first;
			// the toggle shows the choice as it was.
			guard
				!state.discardUnsavedChangesOnQuit,
				!state.isChangingPreferenceGroup,
				!state.requiresImmediateSave
			else {
				return .run { [sync] _ in await sync.refreshStatus() }
			}
			let tookSyncedValues: Bool = syncs && !keepingThisMac

			let organization = state.workspace
			let preferences = state.persistedPreferences
			document.updatePreferences(requestsSave: false) { $0.automation = preferences.automation }
			let ticket = workspace.reserveSaveTicket()
			state.isChangingPreferenceGroup = true

			// Unsaved until it lands, so quitting waits for it as for any save.
			state.unsavedOrganization = organization

			return .merge(
				.cancel(id: Cancellation.coalescedSave),
				.run { [workspace, sync] send in

					// Conflicts that arrived while the group was kept here were never repaired.
					if tookSyncedValues {
						await sync.repairBeforeSyncing(group)
					}
					do {
						let saved = try await workspace.setPreferenceGroup(
							group,
							syncs: syncs,
							keepingThisMac: keepingThisMac,
							organization: organization,
							preferences: preferences,
							ticket: ticket
						)
						await send(.event(.preferenceGroupSaved(group, tookSyncedValues: tookSyncedValues, organization, saved)))
					} catch {
						await send(.event(.preferenceGroupFailed(WorkspaceFailurePresentation.message(for: error))))
					}
					await sync.refreshStatus()
				}
			)
		}
	}

	/// Selects the canonical snapshot at the flush boundary, not when the save was requested,
	/// and reserves its write order before leaving the main actor.
	private func flush(state: State) -> Effect<Action> {
		let organization = state.workspace
		let preferences = state.persistedPreferences

		// Automation preferences are reducer-owned; this is where they reach the document.
		document.updatePreferences(requestsSave: false) { $0.automation = preferences.automation }

		// Clearing Arx before an import retires every old profile once the fresh one is saved
		// (DEV-833), so that save must survive a power loss too.
		let synchronizeSecurityChange = preferences.automation.authenticationLockID != nil
		|| state.automation.signIn.resumingLockID != nil
		|| state.migrationClearing?.step == .saving
		let ticket = workspace.reserveSaveTicket()

		return .merge(
			.cancel(id: Cancellation.coalescedSave),
			.run { [workspace] send in
				do {
					let isCurrent = try await workspace.save(
						organization,
						preferences: preferences,
						synchronizeSecurityChange: synchronizeSecurityChange,
						ticket: ticket
					)
					guard isCurrent else { return }

					// Counts only, for the clean-quit ledger's record of a run that ends badly (DEV-1018).
					CleanQuitLedger.current?.note(tabs: organization.tabs.count, spaces: organization.spaces.count)
					await send(.event(.saveSucceeded(organization, preferences)))
				} catch {
					await send(.event(.saveFailed(WorkspaceFailurePresentation.message(for: error))))
				}
			}
		)
	}
}

extension AppFeature.State {
	/// Flows that wait for `saveSucceeded` or that must reach disk before continuing.
	internal var requiresImmediateSave: Bool {
		quitAfterSaving
		|| migrationCommit != nil
		|| migrationClearing != nil
		|| profileRetirement.isBusy
		|| automationPreferences.authenticationLockID != nil
		|| automation.signIn.resumingLockID != nil
	}
}
