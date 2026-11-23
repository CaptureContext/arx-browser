import Foundation
import SettingsFeature
import Testing
import WorkspaceDatabase
import WorkspaceSync
import _ComposableArchitecture

/// Settings › iCloud Sync's "sync deletions after" toggle (DEV-980), Preferences groups (DEV-982) and
/// the merge preview (DEV-1216).
@Suite(.dependencies)
@MainActor
internal struct ICloudSyncSettingsTests {
	@Test
	internal func theToggleTurnsSyncDeletionsOnForThirtyDays() async {
		let requests: LockIsolated<[Bool]> = .init([])
		let store = TestStore(initialState: ICloudSyncSettingsFeature.State(isAvailable: true)) {
			ICloudSyncSettingsFeature()
		} withDependencies: {
			$0.workspaceSync.setSyncsDeletions = { isOn in requests.withValue { $0.append(isOn) } }
		}

		await store.send(.ui(.setSyncsDeletions(true))) {
			$0.status.syncDeletionsAfterDays = 30
		}
		await store.send(.ui(.setSyncsDeletions(false))) {
			$0.status.syncDeletionsAfterDays = nil
		}
		await store.finish()

		#expect(requests.value == [true, false])
	}

	@Test
	internal func aPreferenceGroupTurnedOffAsksTheAppToKeepItOnThisMac() async {
		let store = TestStore(initialState: ICloudSyncSettingsFeature.State(isAvailable: true)) {
			ICloudSyncSettingsFeature()
		}

		await store.send(.ui(.setToggle(.preferenceGroup(.routing), false))) {
			$0.status.localPreferenceGroups = [.routing]
		}
		await store.receive(\.delegate.setPreferenceGroup)

		// Already off: nothing more to do.
		await store.send(.ui(.setToggle(.preferenceGroup(.routing), false)))
	}

	@Test
	internal func aPreferenceGroupTurnedOnAsksWhoseValuesToKeep() async {
		let store = TestStore(
			initialState: ICloudSyncSettingsFeature.State(
				isAvailable: true,
				status: .init(localPreferenceGroups: [.shortcuts, .routing])
			)
		) {
			ICloudSyncSettingsFeature()
		}

		await store.send(.ui(.setToggle(.preferenceGroup(.shortcuts), true))) {
			$0.syncingPreferenceGroup = .shortcuts
		}
		await store.send(.ui(.cancelSyncingPreferenceGroup)) {
			$0.syncingPreferenceGroup = nil
		}
		#expect(!store.state.status.isOn(.preferenceGroup(.shortcuts)))

		await store.send(.ui(.setToggle(.preferenceGroup(.shortcuts), true))) {
			$0.syncingPreferenceGroup = .shortcuts
		}
		await store.send(.ui(.syncPreferenceGroup(keepingThisMac: false))) {
			$0.syncingPreferenceGroup = nil
			$0.status.localPreferenceGroups = [.routing]
		}
		await store.receive(\.delegate.setPreferenceGroup)
	}

	@Test
	internal func stopSyncingThisMacAsksFirst() async {
		let stops: LockIsolated<Int> = .init(0)
		let store = TestStore(
			initialState: ICloudSyncSettingsFeature.State(
				isAvailable: true,
				status: .init(isEnabled: true, canStopSyncing: true)
			)
		) {
			ICloudSyncSettingsFeature()
		} withDependencies: {
			$0.workspaceSync.stopSyncingThisMac = { stops.withValue { $0 += 1 } }
		}

		await store.send(.ui(.stopSyncingThisMac)) {
			$0.isConfirmingStop = true
		}
		await store.send(.ui(.cancelStopSyncingThisMac)) {
			$0.isConfirmingStop = false
		}
		#expect(stops.value == 0)

		await store.send(.ui(.stopSyncingThisMac)) {
			$0.isConfirmingStop = true
		}
		await store.send(.ui(.confirmStopSyncingThisMac)) {
			$0.isConfirmingStop = false
			$0.status.isStopping = true
		}
		await store.finish()
		#expect(stops.value == 1)
	}

	/// Sync drops a stop while an account decision runs, so Settings doesn't send one then.
	@Test
	internal func stopSyncingThisMacWaitsForAnAccountDecision() async {
		let stops: LockIsolated<Int> = .init(0)
		let store = TestStore(
			initialState: ICloudSyncSettingsFeature.State(
				isAvailable: true,
				status: .init(isEnabled: true, canStopSyncing: true)
			)
		) {
			ICloudSyncSettingsFeature()
		} withDependencies: {
			$0.workspaceSync.stopSyncingThisMac = { stops.withValue { $0 += 1 } }
			$0.workspaceSync.resolve = { _ in }
		}

		await store.send(.ui(.stopSyncingThisMac)) {
			$0.isConfirmingStop = true
		}
		await store.send(.ui(.resolve(.useWithThisAccount))) {
			$0.status.isResolving = true
		}
		await store.send(.ui(.confirmStopSyncingThisMac)) {
			$0.isConfirmingStop = false
		}
		await store.send(.ui(.stopSyncingThisMac))
		await store.finish()
		#expect(stops.value == 0)
	}

	/// The app drops a group change while another is being saved, so the toggles wait for it: one
	/// switched meanwhile would be undone by the next status.
	@Test
	internal func groupTogglesWaitForAChangeBeingSaved() async {
		var state: ICloudSyncSettingsFeature.State = .init(
			isAvailable: true,
			status: .init(localPreferenceGroups: [.shortcuts])
		)
		state.isChangingPreferenceGroup = true
		let store = TestStore(initialState: state) {
			ICloudSyncSettingsFeature()
		}

		await store.send(.ui(.setToggle(.preferenceGroup(.routing), false)))
		await store.send(.ui(.setToggle(.preferenceGroup(.shortcuts), true)))
		#expect(!store.state.status.isOn(.preferenceGroup(.shortcuts)))
	}

	/// A dialog already open when another group's change started closes without asking for this one.
	@Test
	internal func turningAGroupOnWaitsForAChangeThatStartedMeanwhile() async {
		var state: ICloudSyncSettingsFeature.State = .init(
			isAvailable: true,
			status: .init(localPreferenceGroups: [.shortcuts]),
			syncingPreferenceGroup: .shortcuts
		)
		state.isChangingPreferenceGroup = true
		let store = TestStore(initialState: state) {
			ICloudSyncSettingsFeature()
		}

		await store.send(.ui(.syncPreferenceGroup(keepingThisMac: false))) {
			$0.syncingPreferenceGroup = nil
		}
		#expect(!store.state.status.isOn(.preferenceGroup(.shortcuts)))
	}

	// MARK: - Merging (DEV-1216)

	private var mergePreview: MergePreview {
		.init(
			kind: .joining,
			plan: .init(
				profiles: [
					.init(
						mergedID: UUID(101),
						keptID: UUID(1),
						name: "Default",
						mergedName: "Default",
						separateName: "Default (Mac)",
						spaces: [
							.init(mergedID: UUID(111), keptID: UUID(11), name: "Work", mergedName: "Work", separateName: "Work (Mac)", reason: .name)
						]
					)
				]
			)
		)
	}

	@Test
	internal func theMergePreviewSendsWhatThePersonKeptSeparate() async {
		let confirmed: LockIsolated<[Set<UUID>]> = .init([])
		let store = TestStore(
			initialState: ICloudSyncSettingsFeature.State(
				isAvailable: true,
				status: .init(isEnabled: true, mergePreview: mergePreview)
			)
		) {
			ICloudSyncSettingsFeature()
		} withDependencies: {
			$0.workspaceSync.confirmMerge = { ids in confirmed.withValue { $0.append(ids) } }
		}

		await store.send(.ui(.setKeepingSeparate(UUID(111), true))) {
			$0.keepingSeparate = [UUID(111)]
		}

		// Only the preview's own matches can be kept separate.
		await store.send(.ui(.setKeepingSeparate(UUID(999), true)))
		await store.send(.ui(.confirmMerge))
		await store.finish()
		#expect(confirmed.value == [[UUID(111)]])

		// The preview ends: what was kept separate goes with it.
		await store.send(.event(.statusChanged(.init(isEnabled: true)))) {
			$0.status.mergePreview = nil
			$0.keepingSeparate = []
		}
	}

	@Test
	internal func cancelEndsTheMergeAndMergingDuplicatesAsksForAPreview() async {
		let cancels: LockIsolated<Int> = .init(0)
		let previews: LockIsolated<[[UUID]]> = .init([])
		let store = TestStore(
			initialState: ICloudSyncSettingsFeature.State(
				isAvailable: true,
				status: .init(isEnabled: true, mergePreview: mergePreview)
			)
		) {
			ICloudSyncSettingsFeature()
		} withDependencies: {
			$0.workspaceSync.cancelMerge = { cancels.withValue { $0 += 1 } }
			$0.workspaceSync.previewProfileMerge = { ids in previews.withValue { $0.append(ids) } }
		}

		await store.send(.ui(.setKeepingSeparate(UUID(101), true))) {
			$0.keepingSeparate = [UUID(101)]
		}
		await store.send(.ui(.cancelMerge)) {
			$0.keepingSeparate = []
		}
		await store.finish()
		#expect(cancels.value == 1)

		// No new preview while one shows.
		await store.send(.ui(.previewProfileMerge([UUID(1), UUID(2)])))
		await store.send(.event(.statusChanged(.init(isEnabled: true)))) {
			$0.status.mergePreview = nil
		}
		await store.send(.ui(.previewProfileMerge([UUID(1), UUID(2)])))
		await store.finish()
		#expect(previews.value == [[UUID(1), UUID(2)]])
	}
}
