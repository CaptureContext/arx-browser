import Foundation
import WorkspaceDatabase
import WorkspaceSync
import _ComposableArchitecture

/// Settings › iCloud Sync (DEV-560, phase 2a): the overall toggle, a toggle per sync category,
/// status and the account review. Shown only when the `ARX_ICLOUD_SYNC` feature flag gave this run a
/// ``WorkspaceSyncClient``.
///
/// Deletions stay on the Mac that made them unless "sync deletions after" is on (ADR 0001, decision
/// 1, DEV-980). History (DEV-984) is off by default and has a window, 30 days unless the person
/// picks another. Tab Archive (DEV-983) is off by default too. Preferences has a toggle per group
/// (DEV-982): one turned off keeps this Mac's values, and turning it on again asks whether to keep
/// this Mac's or use iCloud's. Every toggle is ``SyncToggle``, a per-Mac choice that never syncs. A
/// profile's own "Sync with iCloud" toggle, in its settings, makes it "this Mac only" (DEV-981).
/// Delete from iCloud isn't offered: "Stop syncing this Mac" replaces it (DEV-979), and under each
/// category Settings lists the Macs syncing it, from the device directory. Turning Profiles and
/// spaces or Tab Archive off is a leave (DEV-1148); turning Preferences or History off still pauses
/// it.
@Reducer
public struct ICloudSyncSettingsFeature {
	@ObservableState
	public struct State: Equatable {
		/// Whether this run has iCloud sync; `false` until the section first appears.
		public var isAvailable: Bool
		public var status: WorkspaceSyncStatus

		/// A Preferences group being turned on again, while the person picks whose values it keeps.
		public var syncingPreferenceGroup: PreferenceGroup?

		/// Why the last change of a Preferences group failed; the group keeps its choice.
		public var preferenceGroupError: String?

		/// "Stop syncing this Mac" waits for the person's confirmation.
		public var isConfirmingStop: Bool = false

		/// A Preferences group's change is being saved. The app sets it, and drops another change
		/// meanwhile, so the group toggles wait for it.
		public var isChangingPreferenceGroup: Bool = false

		/// The matches of ``WorkspaceSyncStatus/mergePreview`` the person keeps separate (DEV-1216).
		public var keepingSeparate: Set<UUID> = []

		public init(
			isAvailable: Bool = false,
			status: WorkspaceSyncStatus = .init(),
			syncingPreferenceGroup: PreferenceGroup? = nil
		) {
			self.isAvailable = isAvailable
			self.status = status
			self.syncingPreferenceGroup = syncingPreferenceGroup
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)

		@CasePathable
		public enum UI: Sendable {
			case appeared
			case setEnabled(Bool)
			case setToggle(SyncToggle, Bool)

			/// The answer when a Preferences group syncs again: this Mac's values, or iCloud's.
			case syncPreferenceGroup(keepingThisMac: Bool)
			case cancelSyncingPreferenceGroup

			/// "Stop syncing this Mac" (DEV-979): asks first.
			case stopSyncingThisMac
			case confirmStopSyncingThisMac
			case cancelStopSyncingThisMac

			/// "Sync deletions after" (DEV-980).
			case setSyncsDeletions(Bool)
			case setHistoryWindow(Int)
			case resolve(AccountDecision)

			/// "Merge 'Default' and 'Default'…" (DEV-1216).
			case previewProfileMerge([UUID])
			case setKeepingSeparate(UUID, Bool)
			case confirmMerge
			case cancelMerge
		}

		@CasePathable
		public enum Event: Sendable {
			case statusChanged(WorkspaceSyncStatus)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// AppFeature saves the change with the workspace, so no save under the old choice follows it.
			case setPreferenceGroup(PreferenceGroup, syncs: Bool, keepingThisMac: Bool)
		}
	}

	@Dependency(\.workspaceSync)
	private var sync

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.appeared) { state in
			state.isAvailable = sync.isAvailable()
			guard state.isAvailable else { return .none }

			return .run { [sync] send in
				for await status in await sync.statusUpdates() {
					await send(.event(.statusChanged(status)))
				}
			}
			.cancellable(id: Cancellation.status, cancelInFlight: true)
		}

		Pullback(\.event.statusChanged) { state, status in

			// A preview that ended, or another one, starts with nothing kept separate.
			if status.mergePreview?.plan.mergeIDs != state.status.mergePreview?.plan.mergeIDs {
				state.keepingSeparate = []
			}
			state.status = status
			return .none
		}

		Pullback(\.ui.previewProfileMerge) { state, profileIDs in
			guard state.isAvailable, state.status.mergePreview == nil, !state.status.isMerging else { return .none }

			return .run { [sync] _ in
				await sync.previewProfileMerge(profileIDs)
			}
		}

		Pullback(\.ui.setKeepingSeparate) { state, value in
			let (id, isSeparate) = value
			guard state.status.mergePreview?.plan.mergeIDs.contains(id) == true else { return .none }

			if isSeparate {
				state.keepingSeparate.insert(id)
			} else {
				state.keepingSeparate.remove(id)
			}
			return .none
		}

		Pullback(\.ui.confirmMerge) { state in
			guard state.status.mergePreview != nil, !state.status.isMerging else { return .none }

			let keepingSeparate: Set<UUID> = state.keepingSeparate
			return .run { [sync] _ in
				await sync.confirmMerge(keepingSeparate)
			}
		}

		Pullback(\.ui.cancelMerge) { state in
			guard state.status.mergePreview != nil, !state.status.isMerging else { return .none }

			state.keepingSeparate = []
			return .run { [sync] _ in
				await sync.cancelMerge()
			}
		}

		Pullback(\.ui.setEnabled) { state, isEnabled in
			guard state.isAvailable else { return .none }

			state.status.isEnabled = isEnabled
			return .run { [sync] _ in
				await sync.setEnabled(isEnabled)
			}
		}

		Pullback(\.ui.setToggle) { state, value in
			guard state.isAvailable else { return .none }

			let (toggle, isOn) = value
			switch toggle {
			case let .category(category):
				return .run { [sync] _ in
					await sync.setCategory(category, isOn)
				}

			case let .preferenceGroup(group):
				guard !state.isChangingPreferenceGroup else { return .none }

				state.preferenceGroupError = nil
				guard isOn else {
					guard state.status.localPreferenceGroups.insert(group).inserted else { return .none }

					return .send(.delegate(.setPreferenceGroup(group, syncs: false, keepingThisMac: true)))
				}
				guard state.status.localPreferenceGroups.contains(group) else { return .none }

				state.syncingPreferenceGroup = group
				return .none
			}
		}

		Pullback(\.ui.syncPreferenceGroup) { state, keepingThisMac in
			guard let group = state.syncingPreferenceGroup else { return .none }

			state.syncingPreferenceGroup = nil

			// Another group's change started while the dialog was open: the app would drop this one.
			guard !state.isChangingPreferenceGroup else { return .none }

			state.status.localPreferenceGroups.remove(group)
			return .send(.delegate(.setPreferenceGroup(group, syncs: true, keepingThisMac: keepingThisMac)))
		}

		Pullback(\.ui.cancelSyncingPreferenceGroup) { state in
			state.syncingPreferenceGroup = nil
			return .none
		}

		Pullback(\.ui.stopSyncingThisMac) { state in
			guard
				state.isAvailable,
				state.status.canStopSyncing,
				!state.status.isStopping,
				!state.status.isResolving
			else { return .none }

			state.isConfirmingStop = true
			return .none
		}

		Pullback(\.ui.confirmStopSyncingThisMac) { state in
			guard state.isConfirmingStop else { return .none }

			state.isConfirmingStop = false

			// An account decision started while the dialog was open: sync would drop the stop.
			guard state.status.canStopSyncing, !state.status.isResolving else { return .none }

			state.status.isStopping = true
			return .run { [sync] _ in
				await sync.stopSyncingThisMac()
			}
		}

		Pullback(\.ui.cancelStopSyncingThisMac) { state in
			state.isConfirmingStop = false
			return .none
		}

		Pullback(\.ui.setSyncsDeletions) { state, isOn in
			guard state.isAvailable else { return .none }

			state.status.syncDeletionsAfterDays = isOn ? SyncSettings.defaultSyncDeletionsAfterDays : nil
			return .run { [sync] _ in
				await sync.setSyncsDeletions(isOn)
			}
		}

		Pullback(\.ui.setHistoryWindow) { state, days in
			guard state.isAvailable, days > 0 else { return .none }

			state.status.historyWindowDays = days
			return .run { [sync] _ in
				await sync.setHistoryWindow(days)
			}
		}

		Pullback(\.ui.resolve) { state, decision in
			guard state.isAvailable, !state.status.isResolving else { return .none }

			// The status that follows clears it; WorkspaceSync also runs one decision at a time.
			state.status.isResolving = true

			return .run { [sync] _ in
				await sync.resolve(decision)
			}
		}
	}

	private enum Cancellation: Hashable {
		case status
	}
}
