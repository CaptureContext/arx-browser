import Foundation
import WorkspaceDatabase
import _Dependencies

/// Settings › iCloud Sync's view of ``WorkspaceSync``.
///
/// Its live value is ``unavailable``: the app installs ``live(_:)`` with `prepareDependencies` only
/// when the `ARX_ICLOUD_SYNC` feature flag is on and the workspace is in SQLite, so with the flag off
/// Settings shows nothing and nothing reaches CloudKit.
public struct WorkspaceSyncClient: Sendable {
	/// Whether this run has iCloud sync at all.
	public var isAvailable: @Sendable () -> Bool

	/// The status now, then after every change.
	public var statusUpdates: @Sendable () async -> AsyncStream<WorkspaceSyncStatus>

	public var setEnabled: @Sendable (_ isEnabled: Bool) async -> Void

	public var setCategory: @Sendable (_ category: SyncCategory, _ isEnabled: Bool) async -> Void

	/// How many days of visits History sync mirrors.
	public var setHistoryWindow: @Sendable (_ days: Int) async -> Void

	public var resolve: @Sendable (_ decision: AccountDecision) async -> Void

	/// A category after an engine changed its rows: the app reloads the workspace.
	public var remoteChanges: @Sendable () async -> AsyncStream<SyncCategory>

	/// This Mac's starter profiles the first merge emptied as copies of iCloud's, which the app
	/// offers to remove (DEV-989).
	public var duplicateStarterProfiles: @Sendable () async -> [UUID]

	/// The app offered to remove this profile, or it's no longer a copy: don't list it again.
	public var forgetDuplicateStarterProfile: @Sendable (_ id: UUID) async -> Void

	/// Turns "sync deletions after" on or off (DEV-980).
	public var setSyncsDeletions: @Sendable (_ isOn: Bool) async -> Void

	/// Publishes the status again, after the app kept a Preferences group on this Mac or synced it
	/// again (DEV-982).
	public var refreshStatus: @Sendable () async -> Void

	/// Repairs a Preferences group kept on this Mac before it takes iCloud's values (DEV-982).
	public var repairBeforeSyncing: @Sendable (_ group: PreferenceGroup) async -> Void

	/// "Stop syncing this Mac" (DEV-979).
	public var stopSyncingThisMac: @Sendable () async -> Void

	/// Whether the iCloud account can be read now: onboarding's Sync with iCloud step shows only
	/// then (DEV-1215).
	public var accountIsAvailable: @Sendable () async -> Bool

	/// Onboarding's Sync with iCloud: turns sync on and reports each category's first fetch, then
	/// what iCloud had (``WorkspaceSync/joinFromOnboarding(turningSyncOn:)``, DEV-1215). `false`
	/// waits without turning sync on.
	public var joinFromOnboarding: @Sendable (_ turningSyncOn: Bool) async -> AsyncStream<OnboardingSyncEvent>

	/// Shows what merging these synced profiles of the same name does, in
	/// ``WorkspaceSyncStatus/mergePreview`` (DEV-1216).
	public var previewProfileMerge: @Sendable (_ profileIDs: [UUID]) async -> Void

	/// The person's yes to ``WorkspaceSyncStatus/mergePreview``, with the matches they kept separate,
	/// by the merged side's profile or space ID.
	public var confirmMerge: @Sendable (_ keepingSeparate: Set<UUID>) async -> Void

	/// Cancel on ``WorkspaceSyncStatus/mergePreview``: turning sync on stops there, with nothing sent.
	public var cancelMerge: @Sendable () async -> Void

	/// Keep on a profile or space marked for deletion, with everything in it (DEV-1336).
	public var keep: @Sendable (_ ids: Set<UUID>) async -> Void

	public init(
		isAvailable: @escaping @Sendable () -> Bool,
		statusUpdates: @escaping @Sendable () async -> AsyncStream<WorkspaceSyncStatus>,
		setEnabled: @escaping @Sendable (_ isEnabled: Bool) async -> Void,
		setCategory: @escaping @Sendable (_ category: SyncCategory, _ isEnabled: Bool) async -> Void,
		setHistoryWindow: @escaping @Sendable (_ days: Int) async -> Void = { _ in },
		resolve: @escaping @Sendable (_ decision: AccountDecision) async -> Void,
		remoteChanges: @escaping @Sendable () async -> AsyncStream<SyncCategory>,
		duplicateStarterProfiles: @escaping @Sendable () async -> [UUID] = { [] },
		forgetDuplicateStarterProfile: @escaping @Sendable (_ id: UUID) async -> Void = { _ in },
		setSyncsDeletions: @escaping @Sendable (_ isOn: Bool) async -> Void = { _ in },
		refreshStatus: @escaping @Sendable () async -> Void = {},
		repairBeforeSyncing: @escaping @Sendable (_ group: PreferenceGroup) async -> Void = { _ in },
		stopSyncingThisMac: @escaping @Sendable () async -> Void = {},
		accountIsAvailable: @escaping @Sendable () async -> Bool = { false },
		joinFromOnboarding: @escaping @Sendable (_ turningSyncOn: Bool) async -> AsyncStream<OnboardingSyncEvent> = { _ in
			AsyncStream { $0.finish() }
		},
		previewProfileMerge: @escaping @Sendable (_ profileIDs: [UUID]) async -> Void = { _ in },
		confirmMerge: @escaping @Sendable (_ keepingSeparate: Set<UUID>) async -> Void = { _ in },
		cancelMerge: @escaping @Sendable () async -> Void = {},
		keep: @escaping @Sendable (_ ids: Set<UUID>) async -> Void = { _ in }
	) {
		self.isAvailable = isAvailable
		self.statusUpdates = statusUpdates
		self.setEnabled = setEnabled
		self.setCategory = setCategory
		self.setHistoryWindow = setHistoryWindow
		self.resolve = resolve
		self.remoteChanges = remoteChanges
		self.duplicateStarterProfiles = duplicateStarterProfiles
		self.forgetDuplicateStarterProfile = forgetDuplicateStarterProfile
		self.setSyncsDeletions = setSyncsDeletions
		self.refreshStatus = refreshStatus
		self.repairBeforeSyncing = repairBeforeSyncing
		self.stopSyncingThisMac = stopSyncingThisMac
		self.accountIsAvailable = accountIsAvailable
		self.joinFromOnboarding = joinFromOnboarding
		self.previewProfileMerge = previewProfileMerge
		self.confirmMerge = confirmMerge
		self.cancelMerge = cancelMerge
		self.keep = keep
	}

	/// No iCloud sync this run: the flag is off, or this is a test or preview.
	public static var unavailable: Self {
		.init(
			isAvailable: { false },
			statusUpdates: { AsyncStream { $0.finish() } },
			setEnabled: { _ in },
			setCategory: { _, _ in },
			resolve: { _ in },
			remoteChanges: { AsyncStream { $0.finish() } }
		)
	}

	public static func live(_ sync: WorkspaceSync) -> Self {
		.init(
			isAvailable: { true },
			statusUpdates: { await sync.statusUpdates() },
			setEnabled: { await sync.setEnabled($0) },
			setCategory: { await sync.setCategory($0, isEnabled: $1) },
			setHistoryWindow: { await sync.setHistoryWindow(days: $0) },
			resolve: { await sync.resolve($0) },
			remoteChanges: { await sync.remoteChanges() },
			duplicateStarterProfiles: { await sync.duplicateStarterProfiles() },
			forgetDuplicateStarterProfile: { await sync.forgetDuplicateStarterProfile($0) },
			setSyncsDeletions: { await sync.setSyncsDeletions($0) },
			refreshStatus: { await sync.refreshStatus() },
			repairBeforeSyncing: { await sync.repairBeforeSyncing($0) },
			stopSyncingThisMac: { await sync.stopSyncingThisMac() },
			accountIsAvailable: { await sync.accountIsAvailable() },
			joinFromOnboarding: { turningSyncOn in await sync.joinFromOnboarding(turningSyncOn: turningSyncOn) },
			previewProfileMerge: { await sync.previewProfileMerge($0) },
			confirmMerge: { await sync.confirmMerge(keepingSeparate: $0) },
			cancelMerge: { await sync.cancelMerge() },
			keep: { await sync.keep($0) }
		)
	}
}

extension WorkspaceSyncClient: DependencyKey {
	public static var liveValue: Self { .unavailable }

	public static var testValue: Self { .unavailable }
}

extension DependencyValues {
	public var workspaceSync: WorkspaceSyncClient {
		get { self[WorkspaceSyncClient.self] }
		set { self[WorkspaceSyncClient.self] = newValue }
	}
}
