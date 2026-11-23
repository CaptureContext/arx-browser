import BrowserCore
import CloudKit
import Foundation
import HistoryDatabase
import WorkspaceDatabase
import GRDB
import _SQLiteData
import os

/// iCloud sync of the SQLite workspace (DEV-560, phase 2a): one `SyncEngine` and record zone per
/// ``SyncCategory``, behind the `ARX_ICLOUD_SYNC` feature flag.
///
/// - **The flag is on by default (DEV-1143), sync isn't.** Nothing is made while the flag is off (``make(isFeatureFlagOn:organization:preferences:history:directory:containerIdentifier:isEntitled:)``
///   returns `nil`), and no engine is made or account read until the person turns sync on.
/// - **Categories pause on their own.** Turning one off stops its engine and keeps the local and the
///   cloud copy. Once a category has started on this Mac its engine is made at every launch, even
///   paused, so edits made while paused are sent when it resumes.
/// - **Accounts.** The engines' delegate never deletes local data. Signing out pauses; signing in to
///   the same account resumes; another account pauses until the person picks an
///   ``AccountDecision``. Local rows aren't uploaded to a different account before that.
/// - **Repair.** After every batch an engine writes, ``WorkspaceRepair`` runs on that category's
///   database, and ``remoteChanges()`` tells the app the rows changed.
/// - **Delete from iCloud** (``deleteFromICloud(_:)``) deletes a category's zone and turns the
///   category off, keeping this Mac's rows. Other Macs syncing that category delete the rows they got
///   from it: SQLiteData deletes every local row of a zone another device deleted, with no delegate
///   hook. ADR 0001's decision 1 (deletions stay local by default) rules that out, so Settings
///   doesn't offer it; "Stop syncing this Mac" replaces it with per-machine data.
///
/// Every category's writer must be the connection Arx writes that category's rows through: the
/// engine's change tracking is temporary triggers on that one connection.
public actor WorkspaceSync {
	/// Makes a category's engine on its writer, not started. Tests make engines on a shared mock
	/// container instead of CloudKit.
	public typealias MakeEngine = @Sendable (
		_ category: SyncCategory,
		_ writer: any DatabaseWriter,
		_ delegate: any SyncEngineDelegate
	) throws -> SyncEngine

	/// Makes the device directory's engine on its writer, not started (DEV-979).
	public typealias MakeDirectoryEngine = @Sendable (
		_ writer: any DatabaseWriter,
		_ delegate: any SyncEngineDelegate
	) throws -> SyncEngine

	/// Sends the device directory's changes; tests make it fail as CloudKit can.
	public typealias SendDirectoryChanges = @Sendable (_ engine: SyncEngine) async throws -> Void

	/// Fetches everything a category's rejoin after a leave merges with (DEV-1148); tests make it
	/// fail partway, as a connection that drops or a Mac that quits can.
	public typealias FetchRejoinChanges = @Sendable (_ category: SyncCategory, _ engine: SyncEngine) async throws -> Void

	public static let containerIdentifier: String = "iCloud.dev.capturecontext.arx"
	public static let backupDirectoryName: String = "arx-icloud-sync-backups"

	private let writers: [SyncCategory: any DatabaseWriter]
	private let settingsStore: SyncSettingsStore
	private let cloud: CloudAccess
	private let makeEngine: MakeEngine
	private let now: @Sendable () -> Date
	private let logger: Logger = .init(subsystem: "dev.capturecontext.arx", category: "iCloudSync")

	private var settings: SyncSettings
	private var engines: [SyncCategory: SyncEngine] = [:]
	private var observers: [SyncCategory: SyncBatchObserver] = [:]
	private var activityTasks: [SyncCategory: Task<Void, Never>] = [:]
	private var accountTask: Task<Void, Never>?

	/// Categories an engine changed whose repair waits for the fetch to finish.
	private var pendingRepairs: Set<SyncCategory> = []
	private var accountRetryTask: Task<Void, Never>?

	/// Counts account checks, so an older one finishing late doesn't undo a newer one.
	private var accountCheck: Int = 0
	private var repairRetryTasks: [SyncCategory: Task<Void, Never>] = [:]

	/// The next organization repair while it syncs (DEV-980): passing time alone can make a deletion
	/// go everywhere, with no sync activity to start a repair.
	private var deletionRecheckTask: Task<Void, Never>?

	/// Each category's last purge check against iCloud's zone: this Mac's candidates then, and what
	/// iCloud agreed to.
	private var lastPurgeChecks: [SyncCategory: (
		candidates: Set<WorkspaceRepair.PurgeItem>,
		policy: WorkspaceRepair.DeletionPolicy,
		confirmed: [WorkspaceRepair.PurgeItem: Set<UUID>]
	)] = [:]
	private let accountRetryDelay: Duration

	/// Why the settings couldn't be saved, if the last save failed.
	private var saveError: String?

	/// Replace is deleting rows: no start path runs meanwhile.
	private var isReplacing: Bool = false

	/// An account decision is running; another waits for it to finish.
	private var isResolving: Bool = false

	/// Why the last account decision failed, shown with the review it leaves open.
	private var resolutionError: String?

	/// Categories whose Delete from iCloud is in flight; nothing starts them meanwhile.
	private var deletingCategories: Set<SyncCategory> = []
	private var pauses: [SyncCategory: PauseReason] = [:]
	private var errors: [SyncCategory: String] = [:]

	/// The rows each category queued again at its start because iCloud hadn't saved them, until
	/// iCloud saves them (DEV-1209). One a send tried, still unsaved once the engine stops sending,
	/// was refused: the library drops most refused saves without telling its delegate.
	private var awaitingConfirmation: [SyncCategory: Set<String>] = [:]

	/// How many of each category's rows iCloud refused in the last send.
	private var refusedRows: [SyncCategory: Int] = [:]
	private var statusContinuations: [UUID: AsyncStream<WorkspaceSyncStatus>.Continuation] = [:]
	private var remoteChangeContinuations: [UUID: AsyncStream<SyncCategory>.Continuation] = [:]
	private var repairSummaries: [SyncCategory: WorkspaceRepair.Summary] = [:]

	/// The Preferences groups kept on this Mac, read at start and on ``refreshStatus()``.
	private var localPreferenceGroups: Set<PreferenceGroup>

	/// Groups kept on this Mac that the next Preferences repair repairs anyway.
	private var repairingLocalGroups: Set<PreferenceGroup> = []

	/// The device directory (DEV-979): its file, its engine once made, and the Macs it lists.
	private let directory: (any DatabaseWriter)?
	private let makeDirectoryEngine: MakeDirectoryEngine?
	private let sendDirectoryChanges: SendDirectoryChanges
	private let fetchRejoinChanges: FetchRejoinChanges
	private let deviceName: @Sendable () -> String
	private var directoryEngine: SyncEngine?
	private var directoryObserver: SyncBatchObserver?
	private var devices: [SyncDevice] = []

	/// Writes this Mac's row again while sync runs, so it's seen daily even with nothing changing.
	private var heartbeatTask: Task<Void, Never>?

	/// Stop syncing this Mac is running; nothing starts meanwhile.
	private var isStopping: Bool = false

	/// Categories whose rejoin copy is attached to their writer, keeping what a fetch's cascade
	/// deletes (DEV-1148, ``KeptRows``).
	private var watchedCopies: Set<SyncCategory> = []

	/// Categories a start is rejoining after a leave: another start, as for another category turned
	/// on meanwhile, leaves them to it rather than stop the engine it uses.
	private var rejoining: Set<SyncCategory> = []

	/// Counts each category's turning off, so a rejoin attempt it interrupted knows, even when the
	/// category is on again by the time its fetch returns.
	private var rejoinAttempts: [SyncCategory: Int] = [:]

	/// Categories a start skipped while another was rejoining them: started again once it's done.
	private var startsWaitingForRejoin: Set<SyncCategory> = []

	/// Whether a Mac turning sync on with its own workspace merges what matches iCloud's, after a
	/// preview (DEV-1216, the `ARX_ICLOUD_SYNC_MERGE` feature flag).
	private let mergesWhenJoining: Bool

	/// Moves a merged profile's history to the kept one through the app's history store, which holds
	/// it in memory too; `nil` leaves history as it is, as in tests.
	private let moveHistory: (@Sendable (_ merged: UUID, _ kept: UUID) async -> Void)?

	/// The joining Mac's merge, waiting for the person: nothing starts meanwhile.
	private var joinPreview: WorkspaceMerge.Plan?

	/// The person's answer to the joining Mac's merge, by the matches kept separate; applied as the
	/// organization starts.
	private var joinDecision: Set<UUID>?

	/// The plan the answer was given to, and whether the person saw it: what the merge does when it's
	/// applied must be what was approved, or it's shown again.
	private var joinApproval: (plan: WorkspaceMerge.Plan, wasShown: Bool)?
	private var isPlanningJoin: Bool = false

	/// A merge of synced profiles from Settings, waiting for the person.
	private var profileMergePreview: (profileIDs: [UUID], plan: WorkspaceMerge.Plan)?
	private var isMerging: Bool = false
	private var mergeError: String?
	private var duplicateProfiles: [DuplicateProfiles] = []

	/// Profiles and spaces marked for deletion here (DEV-1336), by ID.
	private var deletionMarks: [UUID: WorkspaceRepair.DeletionMark] = [:]

	/// - Parameters:
	///   - history: the history database's connection, without which there's no History category
	///     this run (the history isn't in SQLite).
	///   - archive: Tab Archive's database connection, which the workspace store writes its entries
	///     through; without it there's no Tab Archive category this run (DEV-983).
	///   - devices: the device directory's connection (``DeviceDirectory``), and its engine maker;
	///     without them this run lists no Macs (DEV-979).
	///   - deviceName: this Mac's name, as the other Macs list it.
	///   - mergesWhenJoining: whether turning sync on merges this Mac's workspace into iCloud's after a
	///     preview (DEV-1216).
	///   - moveHistory: moves a merged profile's history through the app's history store.
	public init(
		organization: any DatabaseWriter,
		preferences: any DatabaseWriter,
		history: (any DatabaseWriter)? = nil,
		archive: (any DatabaseWriter)? = nil,
		devices: (any DatabaseWriter)? = nil,
		settings settingsStore: SyncSettingsStore,
		cloud: CloudAccess,
		makeEngine: @escaping MakeEngine,
		makeDirectoryEngine: MakeDirectoryEngine? = nil,
		sendDirectoryChanges: @escaping SendDirectoryChanges = { engine in try await engine.sendChanges() },
		fetchRejoinChanges: @escaping FetchRejoinChanges = { _, engine in try await engine.fetchChanges() },
		deviceName: @escaping @Sendable () -> String = WorkspaceSync.computerName,
		now: @escaping @Sendable () -> Date = Date.init,
		accountRetryDelay: Duration = .seconds(60),
		mergesWhenJoining: Bool = ICloudSyncMergeFeatureFlag.isOn(),
		moveHistory: (@Sendable (_ merged: UUID, _ kept: UUID) async -> Void)? = nil
	) throws {
		self.mergesWhenJoining = mergesWhenJoining
		self.moveHistory = moveHistory
		self.directory = devices
		self.makeDirectoryEngine = makeDirectoryEngine
		self.sendDirectoryChanges = sendDirectoryChanges
		self.fetchRejoinChanges = fetchRejoinChanges
		self.deviceName = deviceName
		self.accountRetryDelay = accountRetryDelay
		var writers: [SyncCategory: any DatabaseWriter] = [.organization: organization, .preferences: preferences]
		writers[.history] = history
		writers[.archive] = archive
		self.writers = writers
		self.settingsStore = settingsStore
		self.cloud = cloud
		self.makeEngine = makeEngine
		self.now = now
		self.settings = try settingsStore.load()
		self.localPreferenceGroups = Self.localPreferenceGroups(preferences)
	}

	/// The app's sync, or `nil` while the `ARX_ICLOUD_SYNC` feature flag is off or this build isn't
	/// entitled to the container, as a signed Arx Dev without its provisioning profile (DEV-1013).
	///
	/// - Parameters:
	///   - organization: the organization database's connection, which the workspace store writes
	///     through.
	///   - preferences: the preferences database's connection. It must be the one preference rows are
	///     written through; rows written through another connection, such as one that attaches the
	///     preferences file, aren't tracked.
	///   - history: the history database's connection, which the history store writes through;
	///     `nil` while history isn't in SQLite.
	///   - archive: Tab Archive's database connection, which the workspace store writes its entries
	///     through (`WorkspaceDatabase.archiveDatabase`).
	///   - directory: the workspace folder, where the settings file and backups go.
	///   - isEntitled: whether the build may open the container.
	public static func make(
		isFeatureFlagOn: Bool,
		organization: any DatabaseWriter,
		preferences: any DatabaseWriter,
		history: (any DatabaseWriter)? = nil,
		archive: (any DatabaseWriter)? = nil,
		directory: URL,
		containerIdentifier: String = WorkspaceSync.containerIdentifier,
		isEntitled: (String) -> Bool = ICloudEntitlement.grants,
		moveHistory: (@Sendable (_ merged: UUID, _ kept: UUID) async -> Void)? = nil
	) throws -> WorkspaceSync? {
		guard isFeatureFlagOn, isEntitled(containerIdentifier) else { return nil }

		return try .init(
			organization: organization,
			preferences: preferences,
			history: history,
			archive: archive,
			devices: DeviceDirectory.open(in: directory),
			settings: .init(directory: directory),
			cloud: .live(containerIdentifier: containerIdentifier),
			makeEngine: liveEngine(containerIdentifier: containerIdentifier),
			makeDirectoryEngine: liveDirectoryEngine(containerIdentifier: containerIdentifier),
			moveHistory: moveHistory
		)
	}

	/// The device directory's engine on CloudKit's private database, in its own zone (DEV-979).
	public static func liveDirectoryEngine(containerIdentifier: String) -> MakeDirectoryEngine {
		{ writer, delegate in
			try SyncEngine(
				for: writer,
				tables: DeviceDirectoryRecord.self,
				containerIdentifier: containerIdentifier,
				defaultZone: CKRecordZone(zoneName: DeviceDirectory.zoneName),
				startImmediately: false,
				delegate: delegate
			)
		}
	}

	/// The computer name the person gave this Mac, as Sharing settings shows it.
	public static let computerName: @Sendable () -> String = {
		Host.current().localizedName ?? ProcessInfo.processInfo.hostName
	}

	/// Engines on CloudKit's private database, one zone per category, started by ``WorkspaceSync``.
	public static func liveEngine(containerIdentifier: String) -> MakeEngine {
		{ category, writer, delegate in
			let zone: CKRecordZone = .init(zoneName: category.zoneName)
			switch category {
			case .organization:
				return try SyncEngine(
					for: writer,
					tables: ProfileRecord.self,
					SpaceRecord.self,
					FolderRecord.self,
					PinnedTabRecord.self,
					FavoriteRecord.self,
					DeletionRecord.self,
					UsageRecord.self,
					SyncDeviceRecord.self,
					MergedItemRecord.self,
					containerIdentifier: containerIdentifier,
					defaultZone: zone,
					startImmediately: false,
					delegate: delegate
				)

			case .preferences:
				return try SyncEngine(
					for: writer,
					tables: PreferenceRecord.self,
					SearchShortcutRecord.self,
					KeyboardShortcutRecord.self,
					RoutingRuleRecord.self,
					ProxyLinkRuleRecord.self,
					containerIdentifier: containerIdentifier,
					defaultZone: zone,
					startImmediately: false,
					delegate: delegate
				)

			case .history:
				return try SyncEngine(
					for: writer,
					tables: HistoryVisitRecord.self,
					HistoryClearRecord.self,
					containerIdentifier: containerIdentifier,
					defaultZone: zone,
					startImmediately: false,
					delegate: delegate
				)

			case .archive:
				return try SyncEngine(
					for: writer,
					tables: ArchiveEntryRecord.self,
					ArchiveDeletionRecord.self,
					ArchiveDeviceRecord.self,
					containerIdentifier: containerIdentifier,
					defaultZone: zone,
					startImmediately: false,
					delegate: delegate
				)
			}
		}
	}

	/// The synced tables of each category, as ADR 0001 section 3 lists them.
	public static func tableNames(_ category: SyncCategory) -> Set<String> {
		switch category {
		case .organization:
			[
				ProfileRecord.tableName,
				SpaceRecord.tableName,
				FolderRecord.tableName,
				PinnedTabRecord.tableName,
				FavoriteRecord.tableName,
				DeletionRecord.tableName,
				UsageRecord.tableName,
				SyncDeviceRecord.tableName,
				MergedItemRecord.tableName,
			]

		case .preferences:
			[
				PreferenceRecord.tableName,
				SearchShortcutRecord.tableName,
				KeyboardShortcutRecord.tableName,
				RoutingRuleRecord.tableName,
				ProxyLinkRuleRecord.tableName,
			]

		case .history:
			[
				HistoryVisitRecord.tableName,
				HistoryClearRecord.tableName,
			]

		case .archive:
			[
				ArchiveEntryRecord.tableName,
				ArchiveDeletionRecord.tableName,
				ArchiveDeviceRecord.tableName,
			]
		}
	}

	/// The categories this run can sync: History only when the history is in SQLite, Tab Archive
	/// only with its database connection.
	public var availableCategories: [SyncCategory] {
		SyncCategory.allCases.filter { writers[$0] != nil }
	}

	// MARK: - Status

	public var status: WorkspaceSyncStatus {
		var categories: [SyncCategory: CategoryStatus] = [:]
		for category in availableCategories {
			categories[category] = status(of: category)
		}
		return .init(
			isEnabled: settings.isEnabled,
			categories: categories,
			availableCategories: availableCategories,
			historyWindowDays: settings.historyWindowDays,
			review: settings.review,
			isResolving: isResolving,
			resolutionError: resolutionError,
			saveError: saveError,
			syncDeletionsAfterDays: settings.syncDeletionsAfterDays,
			localPreferenceGroups: localPreferenceGroups,
			devices: devices,
			isStopped: settings.isStopped,
			isStopping: isStopping,
			canStopSyncing: settings.account != nil && !settings.isStopped,
			mergePreview: joinPreview.map { MergePreview(kind: .joining, plan: $0) }
				?? profileMergePreview.map { MergePreview(kind: .profiles, plan: $0.plan) },
			// Only while the profiles sync, which merging them needs.
			duplicateProfiles: mergesWhenJoining
				&& settings.isEnabled
				&& settings.isOn(.organization)
				&& settings.startedCategories.contains(.organization)
			? duplicateProfiles
			: [],
			isMerging: isMerging,
			mergeError: mergeError,
			deletionMarks: settings.isEnabled && settings.isOn(.organization) ? deletionMarks : [:]
		)
	}

	/// The Preferences groups kept on this Mac, as the preferences file records them (DEV-982).
	private static func localPreferenceGroups(_ writer: (any DatabaseWriter)?) -> Set<PreferenceGroup> {
		guard let writer else { return [] }

		return (try? writer.read { db in try PreferenceGroup.local(db) }) ?? []
	}

	/// Publishes the status again after the app kept a Preferences group on this Mac or synced it again
	/// (DEV-982), reading the groups from the preferences file.
	public func refreshStatus() async {
		localPreferenceGroups = Self.localPreferenceGroups(writers[.preferences])
		await refreshDuplicateProfiles()
		await refreshDeletionMarks()
		publish()
		await publishThisMac()
	}

	public var currentSettings: SyncSettings { settings }

	/// The status now, then after every change.
	public func statusUpdates() -> AsyncStream<WorkspaceSyncStatus> {
		let (stream, continuation) = AsyncStream<WorkspaceSyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
		let id: UUID = .init()
		statusContinuations[id] = continuation
		continuation.yield(status)
		continuation.onTermination = { [weak self] _ in
			Task { await self?.removeStatusContinuation(id) }
		}
		return stream
	}

	/// ``SyncSettings/duplicateStarterProfileIDs``, in a stable order.
	public func duplicateStarterProfiles() -> [UUID] {
		settings.duplicateStarterProfileIDs.sorted { $0.uuidString < $1.uuidString }
	}

	/// Stops listing a starter profile the app offered to remove, or one that's no longer a copy.
	public func forgetDuplicateStarterProfile(_ id: UUID) {
		guard settings.duplicateStarterProfileIDs.remove(id) != nil else { return }

		persist()
	}

	/// A category whose rows an engine just changed, after the repair pass. The app reloads the
	/// workspace from the database on each one.
	public func remoteChanges() -> AsyncStream<SyncCategory> {
		let (stream, continuation) = AsyncStream<SyncCategory>.makeStream()
		let id: UUID = .init()
		remoteChangeContinuations[id] = continuation
		continuation.onTermination = { [weak self] _ in
			Task { await self?.removeRemoteChangeContinuation(id) }
		}
		return stream
	}

	/// What the last repair pass of `category` changed.
	public func lastRepair(_ category: SyncCategory) -> WorkspaceRepair.Summary? {
		repairSummaries[category]
	}

	/// The engine of `category`, once made. For tests and diagnostics.
	public func engine(_ category: SyncCategory) -> SyncEngine? {
		engines[category]
	}

	/// The device directory's engine, once made (DEV-979). For tests and diagnostics.
	public func directoryEngineForDiagnostics() -> SyncEngine? {
		directoryEngine
	}

	// MARK: - Lifecycle

	/// At launch: makes the engines of categories that started before, and starts those that are on.
	/// Reads nothing from iCloud when sync was never turned on.
	public func launch() async {
		// No store holds a workspace from before a joining merge any more (DEV-1216).
		if let organization = writers[.organization] {
			try? await organization.write { db in try MergeRemapRecord.forget(db) }
		}
		for category in availableCategories where settings.startedCategories.contains(category) {
			ensureEngine(category)
		}
		for category in settings.pendingResets {
			do {
				try await resetIfPending(category)
			} catch {
				fail([category], error)
			}
		}

		// Before the history mirror is turned on: it would mirror the old account's history.
		for category in settings.pendingReplacements where writers[category] != nil {
			do {
				try await replaceIfPending(category)
			} catch {
				fail([category], error)
			}
		}

		// A rejoin Arx quit during: what its fetch deleted comes back before anything reads the rows,
		// with sync on or off. The next attempt copies them again.
		for category in settings.pendingMerges where engines[category] != nil {
			await settleInterruptedMerge(category)
		}
		updateHistoryMirror()
		updateArchiveState()
		observeAccountChanges()

		// The account may have changed while Arx was closed, which no engine or notification reports:
		// check it before honoring a saved review.
		await accountDidChange()
		await readDevices()
		await publishDepartures()
		await refreshDuplicateProfiles()
		publish()
	}

	/// Checks the signed-in account again: after a sign-out, the same account resumes and another one
	/// asks for a decision; with no account, sync pauses.
	public func accountDidChange() async {
		guard settings.isEnabled, !isReplacing else { return }

		accountCheck += 1
		let check: Int = accountCheck
		let account: CloudAccess.Account? = await currentAccount()

		// A newer check started while this one read the account, or sync was turned off: its answer
		// is the current one.
		guard check == accountCheck, settings.isEnabled else { return }

		switch account {
		case let .available(account):
			if let bound = settings.account, bound != account {
				stopAll()
				settings.review = .accountChanged
				persist()
				publish()
			} else {
				// The account this Mac's data is connected to, or the first one: carry on.
				if settings.review != nil {
					settings.review = nil
					persist()
				}
				await startCategories()
			}

		case .noAccount:
			// Signed out, whatever review was open: signing in to the connected account resumes, and
			// another account asks again.
			stopAll()
			if settings.review != .signedOut {
				settings.review = .signedOut
				persist()
			}
			publish()

		case .unavailable, nil:
			pauseAll(.accountUnavailable)
		}
	}

	/// The overall toggle.
	public func setEnabled(_ isEnabled: Bool) async {
		// The same answer again retries a save that failed.
		guard settings.isEnabled != isEnabled || saveError != nil else { return }

		guard !isStopping else { return }

		settings.isEnabled = isEnabled

		// An account check still reading belongs to the previous state.
		accountCheck += 1
		let wasStopped: Bool = settings.isStopped
		let wasUnpublished: Bool = settings.stopIsUnpublished
		if isEnabled, wasStopped {
			// Rejoining after "Stop syncing this Mac": each category that synced before merges this
			// Mac's rows with iCloud's as a new member, instead of sending what it queued.
			settings.pendingRejoins.formUnion(settings.startedCategories)
			settings.isStopped = false
			settings.stopIsUnpublished = false
		}
		if !isEnabled {
			// Turning sync off isn't a decision about an account.
			settings.review = nil

			// Nor an answer to a merge: turning it on again asks again (DEV-1216).
			joinPreview = nil
			joinDecision = nil
			joinApproval = nil
		}
		let saved: Bool = persist()
		if isEnabled {
			// Nothing starts until the person's yes is on disk.
			guard saved else {
				settings.isEnabled = false
				if wasStopped {
					settings.isStopped = true
					settings.stopIsUnpublished = wasUnpublished
					settings.pendingRejoins = []
				}
				publish()
				return
			}

			updateHistoryMirror()
			updateArchiveState()
			observeAccountChanges()
			await startCategories()
		} else {
			updateHistoryMirror()
			updateArchiveState()
			for engine in engines.values {
				engine.stop()
			}
			publish()

			// The other Macs see that this Mac syncs nothing now, then the directory stops too.
			await publishThisMac()
			do {
				if let directoryEngine {
					try await sendDirectoryChanges(directoryEngine)
				}
			} catch {
				logger.error("Couldn't send this Mac's paused categories to the device directory: \(error.localizedDescription, privacy: .public)")
			}

			// Sending suspends: sync may have been turned on again meanwhile.
			guard !settings.isEnabled else { return }

			stopAll()
			publish()
		}
	}

	/// Turns "sync deletions after" on, for ``SyncSettings/defaultSyncDeletionsAfterDays``, or off,
	/// and applies it to what's already deleted (DEV-980).
	public func setSyncsDeletions(_ isOn: Bool) async {
		let days: Int? = isOn ? SyncSettings.defaultSyncDeletionsAfterDays : nil
		guard settings.syncDeletionsAfterDays != days || saveError != nil else { return }

		let previous: Int? = settings.syncDeletionsAfterDays
		settings.syncDeletionsAfterDays = days
		guard persist() else {
			settings.syncDeletionsAfterDays = previous
			publish()
			return
		}

		await refreshDeletionMarks()
		publish()

		// The other Macs purge by time only while every Mac that has an item syncs deletions (DEV-1337).
		await publishThisMac()

		// What other Macs used or deleted since the last fetch counts: fetch first, and leave the
		// purge to a later pass if that fails.
		guard
			isOn,
			let engine = engines[.organization],
			engine.isRunning,
			(try? await engine.fetchChanges()) != nil,
			(try? await repair(.organization).isEmpty) == false
		else { return }

		for continuation in remoteChangeContinuations.values {
			continuation.yield(.organization)
		}
	}

	/// One category's toggle. Off stops its engine and keeps both copies. For a category whose turning
	/// off is a leave (``SyncCategory/leavesWhenTurnedOff``, DEV-1148), once this Mac synced it, the
	/// device directory then says this Mac left, after its engine went quiet, and the other Macs'
	/// purges leave it out. On again after a leave, this Mac's rows merge with iCloud's
	/// (``SyncSettings/pendingMerges``) before anything else repairs them.
	public func setCategory(
		_ category: SyncCategory,
		isEnabled: Bool
	) async {
		// A category being deleted from iCloud turns off when that finishes.
		guard !deletingCategories.contains(category) else { return }

		if isEnabled {
			let previous: SyncSettings = settings
			settings.choose(category, true)
			if settings.leftCategories.remove(category) != nil {
				settings.unpublishedLeaves.remove(category)
				if !settings.pendingMerges.contains(category) {
					// A copy an earlier rejoin left behind isn't this one's.
					await removeKeptCopy(category)
				}
				settings.pendingMerges.insert(category)
			}
			guard persist() else {
				settings = previous
				publish()
				return
			}

			updateHistoryMirror()
			updateArchiveState()
			await startCategories()
		} else {
			settings.choose(category, false)

			// A rejoin running now is over, even if the category is on again before its fetch returns.
			rejoinAttempts[category, default: 0] += 1

			// A category this Mac never synced, or with no account, has no membership to leave.
			let leaves: Bool = category.leavesWhenTurnedOff
				&& settings.startedCategories.contains(category)
				&& settings.account != nil
				&& !settings.leftCategories.contains(category)
			if leaves {
				settings.leftCategories.insert(category)
				settings.unpublishedLeaves.insert(category)
			}
			let saved: Bool = persist()
			if leaves, !saved {
				// Unsaved, it stays a pause: a leave sent and then forgotten would have this Mac count
				// again while it applies what was purged without it.
				settings.leftCategories.remove(category)
				settings.unpublishedLeaves.remove(category)
			}
			engines[category]?.stop()

			// A rejoin cut short: what its fetch deleted comes back now, so the next rejoin copies it
			// with whatever changes meanwhile instead of reusing this copy.
			await settleInterruptedMerge(category)
			updateHistoryMirror()
			updateArchiveState()
			publish()
			if leaves, saved {
				await publishLeaves()
			} else {
				await publishThisMac()
			}
		}
	}

	/// How many days of visits History sync mirrors. A shorter window prunes the mirror, which
	/// deletes those visits from iCloud and the other Macs' mirrors, never from anyone's history.
	public func setHistoryWindow(days: Int) {
		guard days > 0, days != settings.historyWindowDays else { return }

		let previous: Int = settings.historyWindowDays
		settings.historyWindowDays = days
		guard persist() else {
			settings.historyWindowDays = previous
			publish()
			return
		}

		updateHistoryMirror()
		updateArchiveState()
		publish()
	}

	/// Marks Tab Archive's database once Tab Archive syncs: from then a removed entry is hidden on this
	/// Mac and stays with the others, as other deletions (DEV-980, DEV-983), even while it's off again.
	private func updateArchiveState() {
		guard settings.isOn(.archive), let writer = writers[.archive] else { return }

		do {
			try writer.writeAllowingSyncedDeletions { db in
				try ArchiveStateRecord.upsert {
					ArchiveStateRecord(id: ArchiveStateKey.deletionsStayLocal, value: "1")
				}
				.execute(db)
			}
		} catch {
			fail([.archive], error)
		}
	}

	/// Tells the history database whether to mirror visits, and for how long: while History syncs,
	/// paused for an account or not, so visits made meanwhile are sent when it resumes.
	private func updateHistoryMirror() {
		guard let writer = writers[.history] else { return }

		let days: Int? = settings.isOn(.history) ? settings.historyWindowDays : nil
		let date: Date = now()
		do {
			try writer.writeAllowingSyncedDeletions { db in
				try HistoryDatabase.setMirrorWindow(db, days: days, now: date)
			}
		} catch {
			fail([.history], error)
		}

		// A wider window, or History on again, lets in visits already fetched: the app takes the
		// mirror in again.
		if days != nil {
			for continuation in remoteChangeContinuations.values {
				continuation.yield(.history)
			}
		}
	}

	/// The person's answer when sync paused for an account review.
	public func resolve(_ decision: AccountDecision) async {
		guard !isResolving else { return }

		isResolving = true
		resolutionError = nil
		publish()
		defer {
			isResolving = false
			publish()
		}

		switch decision {
		case .useWithThisAccount:
			guard case let .available(account) = await currentAccount() else { return }

			if settings.account != account {
				// What each engine knows is the old account's: forget it, so the next start uploads
				// every row to this account and merges with what it already has. Saved as pending
				// first, so a category whose engine can't be made now is reset before it ever starts.
				stopAll()
				let categories: [SyncCategory] = availableCategories.filter {
					settings.startedCategories.contains($0) || engines[$0] != nil
				}

				// A category whose database didn't open this run stays pending until it does.
				let unavailable: [SyncCategory] = SyncCategory.allCases.filter {
					writers[$0] == nil && settings.startedCategories.contains($0)
				}
				settings.pendingResets.formUnion(categories + unavailable)
				persist()

				// SQLiteData's stop() doesn't cancel a fetch in flight: the old account's rows could
				// arrive after the reset. Wait for quiet; the resets stay pending if it doesn't come.
				for category in categories {
					do {
						try await Self.waitUntilIdle(engines[category])
					} catch {
						resolutionError = error.localizedDescription
						fail([category], error)
						return
					}
				}
				for category in categories {
					do {
						try await resetIfPending(category)
					} catch {
						// Still pending: it's reset before this category starts.
						fail([category], error)
					}
				}
			}

			// The resets suspend: bind only the account the person decided about.
			guard await currentAccount() == .available(account) else {
				stopAll()
				publish()
				return
			}
			settings.account = account
			settings.review = nil
			guard persist() else {
				resolutionError = saveError
				settings.review = .accountChanged
				publish()
				return
			}

			await startCategories()

		case .keepOnThisMac:
			// The engines' state still belongs to the account this Mac synced with, so the binding
			// stays: turning sync on again with another account asks again, and Use with This
			// Account then uploads every row.
			stopAll()
			settings.isEnabled = false
			settings.review = nil
			persist()
			updateHistoryMirror()
			updateArchiveState()
			publish()

		case .replaceWithAccountData:
			guard case let .available(account) = await currentAccount() else { return }
			guard await replaceLocalData(with: account) else { return }

			await startCategories()
		}
	}

	/// Replace's work: every category that ever synced is backed up and cleared, and the account is
	/// connected. `false`, with the review still open, when any step can't finish.
	private func replaceLocalData(with account: String) async -> Bool {
		// Nothing else starts an engine while rows are being replaced.
		isReplacing = true
		defer { isReplacing = false }

		let stamp: String = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")

		// The review stays until every category is replaced, so a failure can't leave one
		// category's old-account rows syncing with this account.
		var failed: Bool = false
		let scope: [SyncCategory] = availableCategories.filter {
			settings.isOn($0) || settings.startedCategories.contains($0) || engines[$0] != nil
		}

		// A category whose database didn't open this run is replaced when it next opens, before it
		// starts: saved with the new account, so its old rows never reach it.
		let unavailable: Set<SyncCategory> = Set(SyncCategory.allCases.filter {
			writers[$0] == nil && (settings.isOn($0) || settings.startedCategories.contains($0))
		})
		for category in scope {
			// Each step suspends: if the account changed meanwhile, this decision was about
			// another one, so nothing more is deleted.
			guard await currentAccount() == .available(account) else {
				resolutionError = nil
				stopAll()
				persist()
				publish()
				return false
			}
			guard ensureEngine(category) != nil, let writer = writers[category] else {
				failed = true
				continue
			}

			do {
				// SQLiteData's stop() doesn't cancel a fetch in flight, which could still write the
				// old account's rows after the clear: wait for the engine to go quiet first.
				engines[category]?.stop()
				try await Self.waitUntilIdle(engines[category])

				// The wait suspends: if the account changed meanwhile, nothing more is deleted.
				guard await currentAccount() == .available(account), settings.review != nil else {
					stopAll()
					publish()
					return false
				}

				// A Tab Archive change a save left for the archive file is the old account's: dropped, so
				// it never reaches the replaced archive (DEV-983).
				if category == .archive, let organization = writers[.organization] {
					try await organization.writeAllowingSyncedDeletions { db in
						try StoreInfoRecord.find(StoreInfoKey.pendingArchive).delete().execute(db)
					}
				}

				// Backed up and cleared with nothing else written in between; without the backup,
				// nothing is deleted.
				try await Self.replaceSyncedRows(category, writer: writer, backup: backupFile(category, stamp: stamp), at: now())

				// The rows changed under the app, as a fetch would change them.
				for continuation in remoteChangeContinuations.values {
					continuation.yield(category)
				}
				settings.startedCategories.insert(category)
				settings.pendingResets.remove(category)

				// The old account's rows a rejoin kept mustn't come back.
				settings.pendingMerges.remove(category)
				await removeKeptCopy(category)
				errors[category] = nil
			} catch {
				fail([category], error)
				failed = true
			}
		}
		guard !failed else {
			resolutionError = SyncCategory.allCases.compactMap { errors[$0] }.first
			stopAll()
			persist()
			publish()
			return false
		}

		guard await currentAccount() == .available(account) else {
			stopAll()
			publish()
			return false
		}
		let pendingBefore: Set<SyncCategory> = settings.pendingReplacements
		settings.pendingReplacements.formUnion(unavailable)
		settings.account = account
		settings.review = nil
		guard persist() else {
			resolutionError = saveError
			settings.review = .accountChanged
			settings.pendingReplacements = pendingBefore
			publish()
			return false
		}
		return true
	}

	/// Deletes `category`'s zone from iCloud and turns the category off. This Mac keeps its rows, and
	/// turning the category on again uploads them as new. Other Macs syncing the category delete the
	/// rows they got from it (the library's zone deletion, see the type's documentation).
	///
	/// Not offered in Settings: ADR 0001's decision 1 keeps deletions local by default. Kept for the
	/// per-machine design, which may still need to erase iCloud for every Mac as a separate,
	/// plainly worded action.
	public func deleteFromICloud(_ category: SyncCategory) async throws {
		// Only the zone of the account this Mac's data is connected to, and never while that's in
		// question: the deletion goes to whichever account is signed in.
		guard
			settings.review == nil,
			let bound = settings.account,
			await currentAccount() == .available(bound),
			settings.review == nil,
			settings.account == bound
		else { throw DeleteFailure.accountNotConnected }
		guard deletingCategories.insert(category).inserted else { return }
		defer { deletingCategories.remove(category) }

		// Saved before the zone goes, so a crash or a failed reset can't restart this engine with what
		// it knew of the deleted zone: it would delete this Mac's rows.
		let wasDisabled: Bool = !settings.isChosen(category)
		var marked: SyncSettings = settings
		marked.choose(category, false)
		marked.pendingResets.insert(category)

		// Without this saved, nothing is deleted.
		try settingsStore.save(marked)
		settings = marked
		engines[category]?.stop()
		do {
			// SQLiteData's stop() doesn't cancel a fetch in flight, which could still apply the
			// deletion to this Mac's rows before the reset below: wait for it to finish.
			try await Self.waitUntilIdle(engines[category])
		} catch {
			// Nothing was deleted or reset. The engine stays stopped until the person tries again
			// or toggles the category, since the old work may still be writing.
			if !wasDisabled {
				settings.choose(category, true)
			}
			settings.pendingResets.remove(category)
			persist()
			fail([category], error)
			throw error
		}
		do {
			// The last check before anything is deleted.
			guard await currentAccount() == .available(bound), settings.review == nil else {
				throw DeleteFailure.accountNotConnected
			}

			try await cloud.deleteZone(category.zoneName)
		} catch {
			// The zone may be gone even so, if only the reply was lost: forget what the engine knew
			// either way, so a restart uploads every row (recreating the zone, or merging with it)
			// instead of applying a deletion here. Until that's done the category stays off.
			do {
				try await resetIfPending(category)
			} catch {
				fail([category], error)
				throw error
			}
			if !wasDisabled {
				settings.choose(category, true)
				persist()
			}
			deletingCategories.remove(category)
			await startCategories()
			throw error
		}
		try await resetIfPending(category)
		errors[category] = nil
		pauses[category] = nil
		publish()
	}

	public enum DeleteFailure: Error, LocalizedError {
		/// Sync isn't connected to the signed-in account, or an account review is open.
		case accountNotConnected

		public var errorDescription: String? {
			"iCloud sync isn’t connected to the signed-in iCloud account."
		}
	}

	/// Runs the repair pass on `category`'s database.
	@discardableResult
	public func repair(_ category: SyncCategory) async throws -> WorkspaceRepair.Summary {
		try await repair(category, isFirstMerge: false)
	}

	/// Repairs a Preferences group kept on this Mac before it takes iCloud's values (DEV-982): the
	/// repair pass skipped its synced rows meanwhile, and two Macs' values may not be valid together.
	/// Only rows iCloud confirms are repaired, as in any pass; otherwise taking iCloud's values fails
	/// and the group stays on this Mac.
	public func repairBeforeSyncing(_ group: PreferenceGroup) async {
		repairingLocalGroups.insert(group)
		defer { repairingLocalGroups.remove(group) }

		do {
			try await repair(.preferences)
		} catch {
			logger.error("Couldn't repair a Preferences group before syncing it: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// - Parameters:
	///   - isFirstMerge: this Mac's first fetch of the category is in. Only then may the pass
	///     drop this Mac's own starter profile as a copy of one from iCloud: later, another Mac may be
	///     using it.
	private func repair(
		_ category: SyncCategory,
		isFirstMerge: Bool
	) async throws -> WorkspaceRepair.Summary {
		guard let writer = writers[category] else { return .init() }

		// Rows this Mac may not keep, under an account review, aren't changed until it's answered,
		// and a category that's off isn't repaired until it's on again.
		// A category rejoining after a leave isn't repaired until this Mac's kept rows are merged: a
		// purge now could delete what the merge brings back, and the merge would undo a repair.
		guard settings.review == nil, settings.isOn(category), !settings.pendingMerges.contains(category) else {
			pendingRepairs.insert(category)
			return .init()
		}

		let summary: WorkspaceRepair.Summary
		switch category {
		case .organization:
			let own: Set<UUID> = isFirstMerge ? settings.starterProfileIDs : []
			let lookupAccount: String? = settings.account
			let now: Date = self.now()

			// This Mac syncs the organization, so an item every syncing Mac deleted waits for it.
			try await writer.writeAllowingSyncedDeletions { db in try Self.markDeviceSeen(db, now: now) }
			let policy: WorkspaceRepair.DeletionPolicy = .init(
				now: now,
				syncDeletionsAfter: settings.syncDeletionsAfterDays.map { TimeInterval($0) * 24 * 60 * 60 },
				departedDevices: departedDevices(from: .organization),
				devicesSyncingDeletions: await devicesSyncingDeletions()
			)
			let deletions: WorkspaceRepair.DeletionPolicy = .init(
				now: policy.now,
				syncDeletionsAfter: policy.syncDeletionsAfter,
				confirmed: await confirmedPurges(.organization, writer, policy: policy),
				departedDevices: policy.departedDevices,
				devicesSyncingDeletions: policy.devicesSyncingDeletions
			)
			let remote: [WorkspaceRepair.PlacementRecord: WorkspaceRepair.Placement] = await remotePlacements(writer)

			// The lookups suspend: if sync paused, connected another account or changed when deletions
			// sync meanwhile, their answers don't count and nothing is repaired until a later pass.
			guard
				settings.review == nil,
				settings.isOn(category),
				settings.account == lookupAccount,
				settings.syncDeletionsAfterDays.map({ TimeInterval($0) * 24 * 60 * 60 }) == policy.syncDeletionsAfter
			else {
				pendingRepairs.insert(.organization)
				return .init()
			}

			summary = try await writer.writeAllowingSyncedDeletions { db in

				// The engine attaches its metadata to this connection: which profiles iCloud saved.
				let known: Set<String>? = try? ServerConfirmation.confirmedKeys(db, recordType: ProfileRecord.tableName)
				return try WorkspaceRepair.repairOrganization(
					db,
					ownStarterProfileIDs: own,
					serverKnownProfileIDs: known.map { Set($0.compactMap(UUID.init(uuidString:))) },
					remotePlacements: remote,
					deletions: deletions
				)
			}
			scheduleDeletionRecheck()

			// Merges from Settings another Mac made, or this one (DEV-1216): this Mac's history and Tab
			// Archive entries follow.
			await moveMergedReferences(profiles: summary.mergedProfiles, spaces: summary.mergedSpaces)
			await refreshDuplicateProfiles()
			await refreshDeletionMarks()
			if isFirstMerge {
				settings.starterProfileIDs = []
				settings.duplicateStarterProfileIDs.formUnion(summary.duplicateStarterProfiles)
				persist()
			}

		case .preferences:
			// A fetch can stop halfway through a change, such as two shortcuts swapping keys, which
			// looks like a conflict here. Repair only when these rows are as iCloud has them.
			let lookupAccount: String? = settings.account
			let included: Set<PreferenceGroup> = repairingLocalGroups
			guard
				let confirmed = await confirmedPreferenceRows(writer, including: included),
				settings.review == nil,
				settings.isOn(category),
				settings.account == lookupAccount
			else { return .init() }

			let repaired: WorkspaceRepair.Summary? = try await writer.writeAllowingSyncedDeletions { db in

				// Rows can change while iCloud was asked: repair only what it confirmed.
				let current: PreferenceRowsSnapshot = try .init(db)
				guard current == confirmed else { return nil }

				return try WorkspaceRepair.repairPreferences(db, including: included)
			}
			guard let repaired else {
				scheduleRepairRetry(.preferences)
				return .init()
			}

			summary = repaired

		case .history:
			// Nothing to repair: the app takes the mirror and the clears into its history when it
			// hears of the change.
			summary = .init()

		case .archive:
			// Tab Archive's deletions go everywhere by the organization's rules (DEV-983), with this Mac's
			// device ID from there.
			guard let organization = writers[.organization] else { return .init() }

			let lookupAccount: String? = settings.account
			let now: Date = self.now()
			let deviceID: UUID = try await organization.writeAllowingSyncedDeletions { db in try LocalDeletion.deviceID(db) }
			try await writer.writeAllowingSyncedDeletions { db in
				let today: Double = Calendar.current.startOfDay(for: now).timeIntervalSince1970
				if let seen = try ArchiveDeviceRecord.find(deviceID).fetchOne(db), seen.lastSeen >= today { return }

				try ArchiveDeviceRecord.upsert { ArchiveDeviceRecord(id: deviceID, lastSeen: now.timeIntervalSince1970) }.execute(db)
			}
			let policy: WorkspaceRepair.DeletionPolicy = .init(
				now: now,
				syncDeletionsAfter: settings.syncDeletionsAfterDays.map { TimeInterval($0) * 24 * 60 * 60 },
				departedDevices: departedDevices(from: .archive),
				devicesSyncingDeletions: await devicesSyncingDeletions()
			)
			let deletions: WorkspaceRepair.DeletionPolicy = .init(
				now: policy.now,
				syncDeletionsAfter: policy.syncDeletionsAfter,
				confirmed: await confirmedPurges(.archive, writer, policy: policy),
				departedDevices: policy.departedDevices,
				devicesSyncingDeletions: policy.devicesSyncingDeletions
			)
			guard
				settings.review == nil,
				settings.isOn(category),
				settings.account == lookupAccount,
				settings.syncDeletionsAfterDays.map({ TimeInterval($0) * 24 * 60 * 60 }) == policy.syncDeletionsAfter
			else {
				pendingRepairs.insert(.archive)
				return .init()
			}

			// Entries of a profile or space merged from Settings move to the kept one, whenever they
			// arrive (DEV-1216).
			let targets: [String: [UUID: UUID]] = (try? await organization.read { db in try WorkspaceMerge.mergedTargets(db) }) ?? [:]
			summary = try await writer.writeAllowingSyncedDeletions { db in
				for (column, table) in [("profileID", ProfileRecord.tableName), ("spaceID", SpaceRecord.tableName)] {
					for (merged, kept) in (targets[table] ?? [:]).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
						try db.execute(
							sql: "UPDATE \"archiveEntry\" SET \"\(column)\" = ? WHERE \"\(column)\" = ?",
							arguments: [kept.uuidString.lowercased(), merged.uuidString.lowercased()]
						)
					}
				}
				return try WorkspaceRepair.repairArchive(db, deletions: deletions)
			}
			scheduleDeletionRecheck()
		}
		repairSummaries[category] = summary
		return summary
	}

	/// The search shortcut and keyboard shortcut rows, when they need no repair or every one has
	/// iCloud's values; `nil` otherwise, with a later pass scheduled.
	private func confirmedPreferenceRows(
		_ writer: any DatabaseWriter,
		including included: Set<PreferenceGroup>
	) async -> PreferenceRowsSnapshot? {
		guard
			let (snapshot, needsRepair) = try? await writer.writeAllowingSyncedDeletions({ db in
				(try PreferenceRowsSnapshot(db), try WorkspaceRepair.preferencesNeedRepair(db, including: included))
			})
		else { return nil }
		guard needsRepair else { return snapshot }

		// Every field a repair reads, the position that picks the winner included.
		var local: [String: [String: String]] = [:]
		for shortcut in snapshot.searchShortcuts {
			local["\(shortcut.id):\(SearchShortcutRecord.tableName)"] = [
				"keyword": shortcut.keyword,
				"isEnabled": shortcut.isEnabled ? "1" : "0",
				"position": shortcut.position,
			]
		}
		for binding in snapshot.keyboardShortcuts {
			local["\(binding.id):\(KeyboardShortcutRecord.tableName)"] = [
				"bindings": binding.bindings,
				"position": binding.position,
			]
		}

		// The repair may add a row for a command that has none here, which is only right if iCloud
		// has none either.
		let rowIDs: Set<String> = .init(snapshot.keyboardShortcuts.map(\.id))
		let absent: [String] = BrowserCommand.allCases
			.filter { !rowIDs.contains($0.rawValue) }
			.map { "\($0.rawValue):\(KeyboardShortcutRecord.tableName)" }
		do {
			let remote: [String: [String: String]] = try await cloud.recordValues(
				SyncCategory.preferences.zoneName,
				local.keys.sorted() + absent
			)
			let matches: Bool = local.allSatisfy { name, fields in
				guard let values = remote[name] else { return false }

				return fields.allSatisfy { values[$0.key] == $0.value }
			}
			&& absent.allSatisfy { remote[$0] == nil }
			if !matches {
				scheduleRepairRetry(.preferences)
			}
			return matches ? snapshot : nil
		} catch {
			logger.error("Couldn't check preferences: \(error.localizedDescription, privacy: .public)")
			scheduleRepairRetry(.preferences)
			return nil
		}
	}

	/// The purges iCloud's own rows make too (DEV-980): the repair deletes an item for good only when
	/// both this Mac's rows and iCloud's, read from the whole zone, say so. A purge can't be undone,
	/// and a fetch can stop before a newer use, an undo, another Mac or a pin added to a deleted space
	/// arrived. Empty when iCloud can't say, with a later pass scheduled. After iCloud disagreed, the
	/// zone is read again once this Mac's candidates change or an hour passed.
	private func confirmedPurges(
		_ category: SyncCategory,
		_ writer: any DatabaseWriter,
		policy: WorkspaceRepair.DeletionPolicy
	) async -> [WorkspaceRepair.PurgeItem: Set<UUID>] {
		let isArchive: Bool = category == .archive
		guard
			settings.isOn(category),
			settings.review == nil,
			let candidates = try? await writer.read({ db in
				WorkspaceRepair.purgeCandidates(
					try isArchive ? WorkspaceRepair.PurgeSnapshot.archive(db) : WorkspaceRepair.PurgeSnapshot(db),
					policy: policy
				)
			}),
			!candidates.isEmpty
		else { return [:] }

		// iCloud disagreed lately with the same candidates: asked again in a while, not on every pass.
		if
			let last = lastPurgeChecks[category],
			last.confirmed.isEmpty,
			last.candidates == candidates,
			last.policy.syncDeletionsAfter == policy.syncDeletionsAfter,
			policy.now.timeIntervalSince(last.policy.now) < 60 * 60
		{
			return last.confirmed
		}
		do {
			let records: [CloudAccess.ZoneRecord] = try await cloud.zoneRecords(
				category.zoneName,
				WorkspaceRepair.PurgeSnapshot.fields
			)

			// Each item iCloud purges too, with what it holds there.
			let remote: WorkspaceRepair.PurgeSnapshot = isArchive
			? .init(records, itemTables: [ArchiveEntryRecord.tableName])
			: .init(records)
			let children: [UUID: [UUID]] = remote.children
			var confirmed: [WorkspaceRepair.PurgeItem: Set<UUID>] = [:]
			for item in candidates.intersection(WorkspaceRepair.purgeCandidates(remote, policy: policy)) {
				confirmed[item] = Set(WorkspaceRepair.PurgeSnapshot.itemAndContents(item.id, children: children))
			}
			lastPurgeChecks[category] = (candidates, policy, confirmed)
			return confirmed
		} catch {
			logger.error("Couldn't check deletions: \(error.localizedDescription, privacy: .public)")
			scheduleRepairRetry(category)
			return [:]
		}
	}

	/// Where iCloud has the records a placement repair would rely on. Empty when sync isn't running
	/// for this account or iCloud can't say, so nothing is moved on a guess; a later pass tries again.
	private func remotePlacements(
		_ writer: any DatabaseWriter
	) async -> [WorkspaceRepair.PlacementRecord: WorkspaceRepair.Placement] {
		guard
			settings.isOn(.organization),
			settings.review == nil,
			let records = try? await writer.read({ db in try WorkspaceRepair.placementRecordsToCheck(db) }),
			!records.isEmpty
		else { return [:] }

		do {
			let placements = try await cloud.placements(records)

			// The lookup suspends: answers from an account sync paused for don't count.
			guard settings.review == nil else { return [:] }

			// Something needs repairing: if iCloud doesn't agree yet, a pass after the next fetch or
			// upload might, and an upload changes no row the batch observer sees, so try again later.
			scheduleRepairRetry(.organization)
			return placements
		} catch {
			logger.error("Couldn't check folder placements: \(error.localizedDescription, privacy: .public)")
			scheduleRepairRetry(.organization)
			return [:]
		}
	}

	// MARK: - Merging what matches (DEV-1216)

	/// Whether the categories may start: always, except for a Mac turning sync on with its own
	/// workspace, while what merges into iCloud's waits for the person, or iCloud can't say what it
	/// has. A merge that adds nothing and changes nothing, such as an untouched starter profile into
	/// iCloud's, goes ahead without asking.
	private func joinMergeAllowsStart() async -> Bool {
		guard
			mergesWhenJoining,
			settings.isOn(.organization),
			!settings.startedCategories.contains(.organization),
			!deletingCategories.contains(.organization),
			writers[.organization] != nil
		else { return true }
		if joinDecision != nil { return true }
		if joinPreview != nil || isPlanningJoin { return false }

		isPlanningJoin = true
		defer { isPlanningJoin = false }
		let account: String? = settings.account
		do {
			let (matching, cloud) = try await planJoin(keepingSeparate: [])

			// Reading iCloud suspends: sync may have been turned off or paused meanwhile.
			guard settings.isEnabled, settings.review == nil, settings.account == account else { return false }

			pauses[.organization] = nil
			if !cloud.profiles.isEmpty, matching.plan.needsReview {
				joinPreview = matching.plan
				return false
			}
			joinDecision = []
			joinApproval = (matching.plan, false)
			return true
		} catch {
			// Offline, or iCloud can't say: nothing is merged on a guess, and nothing uploads.
			logger.error("Couldn't read iCloud's workspace before merging: \(error.localizedDescription, privacy: .public)")
			pauses[.organization] = .accountUnavailable
			scheduleAccountRetry()
			return false
		}
	}

	/// This Mac's workspace matched against what iCloud has now.
	private func planJoin(
		keepingSeparate: Set<UUID>
	) async throws -> (WorkspaceMerge.Matching, WorkspaceMerge.Snapshot) {
		guard let writer = writers[.organization] else { return (.init(), .init()) }

		let cloudSnapshot: WorkspaceMerge.Snapshot = try await iCloudWorkspace()
		let local: WorkspaceMerge.Snapshot = try await writer.read { db in try WorkspaceMerge.Snapshot(db) }
		let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(
			local: local,
			cloud: cloudSnapshot,
			macName: deviceName(),
			keepingSeparate: keepingSeparate
		)
		return (matching, cloudSnapshot)
	}

	/// iCloud's organization zone as it is now.
	private func iCloudWorkspace() async throws -> WorkspaceMerge.Snapshot {
		do {
			return .init(try await cloud.zoneRecords(SyncCategory.organization.zoneName, WorkspaceMerge.Snapshot.fields))
		} catch let error as CKError where error.code == .zoneNotFound {
			// No Mac synced its workspace yet.
			return .init()
		}
	}

	/// What applying the joining Mac's merge came to.
	private enum JoinOutcome: Sendable {
		case applied(WorkspaceMerge.Matching)

		/// It differs from what was approved: shown again, nothing written.
		case review(WorkspaceMerge.Plan)
		case nothing
	}

	/// Applies the person's answer, or the merge that needed none, as the organization first starts:
	/// matched against what iCloud has now and this Mac's rows in the same transaction that writes
	/// it, before the engine sends anything. If that differs from what was approved, it's shown
	/// again instead. `false` when the organization mustn't start now.
	private func applyJoinMerge() async throws -> Bool {
		guard
			mergesWhenJoining,
			let decision = joinDecision,
			let writer = writers[.organization]
		else { return true }

		let account: String? = settings.account
		let cloudSnapshot: WorkspaceMerge.Snapshot = try await iCloudWorkspace()

		// Reading iCloud suspends: sync may have been turned off, paused or connected to another
		// account meanwhile. Nothing is merged then; the next start reads again.
		guard
			settings.isEnabled,
			settings.review == nil,
			settings.account == account,
			settings.isOn(.organization),
			!settings.startedCategories.contains(.organization)
		else { return false }

		let macName: String = deviceName()
		let approval: (plan: WorkspaceMerge.Plan, wasShown: Bool)? = joinApproval
		let outcome: JoinOutcome = try await writer.writeAllowingSyncedDeletions { db in
			guard !cloudSnapshot.profiles.isEmpty else { return .nothing }

			// This Mac's rows as they are in this transaction: a save since the preview is merged too.
			let local: WorkspaceMerge.Snapshot = try .init(db)
			let shown: WorkspaceMerge.Plan = WorkspaceMerge.match(local: local, cloud: cloudSnapshot, macName: macName).plan
			let isApproved: Bool = switch approval {
			case let (plan, true)?: shown == plan
			case (_, false)?: !shown.needsReview
			case nil: !shown.needsReview
			}
			guard isApproved else { return .review(shown) }

			let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(
				local: local,
				cloud: cloudSnapshot,
				macName: macName,
				keepingSeparate: decision
			)
			guard !matching.plan.isEmpty else { return .nothing }

			try WorkspaceMerge.applyJoining(matching, cloud: cloudSnapshot, db)
			return .applied(matching)
		}
		switch outcome {
		case let .review(plan):
			joinDecision = nil
			joinApproval = nil
			joinPreview = plan
			return false

		case let .applied(matching):
			await moveMergedReferences(profiles: matching.profiles, spaces: matching.spaces)
			for continuation in remoteChangeContinuations.values {
				continuation.yield(.organization)
			}

		case .nothing:
			break
		}
		joinDecision = nil
		joinApproval = nil
		joinPreview = nil
		return true
	}

	/// The history and Tab Archive entries of merged profiles and spaces move to the kept ones: their
	/// own rows stay, only what they belong to changes.
	private func moveMergedReferences(
		profiles: [UUID: UUID],
		spaces: [UUID: UUID]
	) async {
		guard !profiles.isEmpty || !spaces.isEmpty else { return }

		if !profiles.isEmpty {
			let pairs: [(UUID, UUID)] = profiles.sorted { $0.key.uuidString < $1.key.uuidString }.map { ($0.key, $0.value) }
			for (merged, kept) in pairs {
				await moveHistory?(merged, kept)
			}

			// The app shows the kept profiles' history again.
			for continuation in remoteChangeContinuations.values {
				continuation.yield(.history)
			}
		}

		// Tab Archive's entries, through the archive's own connection when it syncs, else the copy
		// the organization's connection attaches.
		let schema: String = writers[.archive] == nil ? "archive" : "main"
		guard let writer = writers[.archive] ?? writers[.organization] else { return }

		do {
			try await writer.write { db in
				let attached: Bool = try Bool.fetchOne(
					db,
					sql: "SELECT EXISTS (SELECT 1 FROM pragma_database_list WHERE \"name\" = ?)",
					arguments: [schema]
				) ?? false
				guard attached else { return }

				for (column, map) in [("profileID", profiles), ("spaceID", spaces)] {
					for (merged, kept) in map.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
						try db.execute(
							sql: "UPDATE \"\(schema)\".\"archiveEntry\" SET \"\(column)\" = ? WHERE \"\(column)\" = ?",
							arguments: [kept.uuidString.lowercased(), merged.uuidString.lowercased()]
						)
					}
				}
			}
		} catch {
			logger.error("Couldn't move merged Tab Archive entries: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Shows what merging these synced profiles of the same name does (DEV-1216): the first in the
	/// profile switcher is kept, and the others merge into it.
	public func previewProfileMerge(_ profileIDs: [UUID]) async {
		guard
			mergesWhenJoining,
			settings.isEnabled,
			settings.isOn(.organization),
			settings.startedCategories.contains(.organization),
			joinPreview == nil,
			!isMerging,
			let writer = writers[.organization]
		else { return }

		mergeError = nil
		do {
			let local: WorkspaceMerge.Snapshot = try await writer.read { db in try WorkspaceMerge.Snapshot(db) }
			guard let matching = Self.profileMerge(profileIDs, in: local, macName: deviceName(), keepingSeparate: []) else {
				publish()
				return
			}

			profileMergePreview = (profileIDs, matching.plan)
		} catch {
			mergeError = error.localizedDescription
		}
		publish()
	}

	/// The merge of the second of `profileIDs` into the first, in the profile switcher's order, or
	/// `nil` when fewer than two are there. Two at a time: a third one is offered again after, against
	/// what the first merge made.
	private static func profileMerge(
		_ profileIDs: [UUID],
		in local: WorkspaceMerge.Snapshot,
		macName: String,
		keepingSeparate: Set<UUID>
	) -> WorkspaceMerge.Matching? {
		let profiles: [ProfileRecord] = local.profiles
			.filter { profileIDs.contains($0.id) }
			.sorted(by: WorkspaceMerge.ordered)
		guard profiles.count >= 2, let kept = profiles.first else { return nil }

		let merged: [UUID: UUID] = [profiles[1].id: kept.id]
		return WorkspaceMerge.match(
			local: local.only(profiles: Set(merged.keys)),
			cloud: local.only(profiles: [kept.id]),
			macName: macName,
			keepingSeparate: keepingSeparate,
			forcedProfiles: merged
		)
	}

	/// The person's yes to the merge shown, with the matches they kept separate.
	public func confirmMerge(keepingSeparate: Set<UUID>) async {
		if joinPreview != nil {
			joinApproval = joinPreview.map { ($0, true) }
			joinPreview = nil
			joinDecision = keepingSeparate
			publish()
			await startCategories()
			return
		}
		guard
			let preview = profileMergePreview,
			!isMerging,
			let writer = writers[.organization]
		else { return }

		isMerging = true
		mergeError = nil
		publish()
		defer {
			isMerging = false
			publish()
		}
		do {
			let macName: String = deviceName()
			let now: Date = self.now()
			let outcome: ProfileMergeOutcome = try await writer.writeAllowingSyncedDeletions { db in

				// The rows as they are now: a fetch may have changed them since the preview.
				let local: WorkspaceMerge.Snapshot = try .init(db)
				guard
					let shown = Self.profileMerge(preview.profileIDs, in: local, macName: macName, keepingSeparate: []),
					let matching = Self.profileMerge(preview.profileIDs, in: local, macName: macName, keepingSeparate: keepingSeparate)
				else { return .nothing }

				// Another Mac changed them meanwhile, as which one stays: shown again.
				guard shown.plan == preview.plan else { return .review(shown.plan) }

				return .applied(try WorkspaceMerge.applySynced(matching, now: now, db))
			}
			let summary: WorkspaceRepair.Summary
			switch outcome {
			case .nothing:
				profileMergePreview = nil
				return

			case let .review(plan):
				profileMergePreview = (preview.profileIDs, plan)
				return

			case let .applied(applied):
				profileMergePreview = nil
				summary = applied
			}

			await moveMergedReferences(profiles: summary.mergedProfiles, spaces: summary.mergedSpaces)
			for continuation in remoteChangeContinuations.values {
				continuation.yield(.organization)
			}
			await refreshDuplicateProfiles()
		} catch {
			mergeError = error.localizedDescription
		}
	}

	/// What confirming a merge from Settings came to.
	private enum ProfileMergeOutcome: Sendable {
		case applied(WorkspaceRepair.Summary)

		/// It differs from the preview: shown again, nothing written.
		case review(WorkspaceMerge.Plan)
		case nothing
	}

	/// Cancel: a joining Mac turns sync off again, with nothing sent; a merge from Settings is
	/// dropped.
	public func cancelMerge() async {
		if joinPreview != nil {
			joinPreview = nil
			await setEnabled(false)
			return
		}
		profileMergePreview = nil
		mergeError = nil
		publish()
	}

	/// The synced profiles that share a name, which Settings offers to merge.
	/// Reads which profiles and spaces another Mac removed from iCloud (DEV-1336), from this Mac's rows,
	/// and when "sync deletions after" deletes each here. A "this Mac only" profile's synced copy is left
	/// out.
	private func refreshDeletionMarks() async {
		let marks: [UUID: WorkspaceRepair.DeletionMark]
		if let writer = writers[.organization] {
			let policy: WorkspaceRepair.DeletionPolicy = .init(
				now: now(),
				syncDeletionsAfter: settings.syncDeletionsAfterDays.map { TimeInterval($0) * 24 * 60 * 60 },
				departedDevices: departedDevices(from: .organization),
				devicesSyncingDeletions: await devicesSyncingDeletions()
			)
			marks = (try? await writer.read { db in
				let local: Set<UUID> = Set(try LocalProfileRecord.select(\.id).fetchAll(db))
					.union(try LocalSpaceRecord.select(\.id).fetchAll(db))
				let found = WorkspaceRepair.deletionMarks(
					try WorkspaceRepair.PurgeSnapshot(db),
					policy: policy,
					thisDevice: try LocalDeletion.existingDeviceID(db)
				)
				return Dictionary(
					found.filter { !local.contains($0.key.id) }.map { ($0.key.id, $0.value) },
					uniquingKeysWith: { first, _ in first }
				)
			}) ?? [:]
		} else {
			marks = [:]
		}
		guard marks != deletionMarks else { return }

		deletionMarks = marks
		publish()
	}

	/// Keep on a profile or space marked for deletion, with everything in it (DEV-1336): clears the mark
	/// on every Mac and cancels the removal (``WorkspaceRepair/keep(_:_:)``), through the organization's
	/// own connection, which its engine sends from.
	public func keep(_ ids: Set<UUID>) async {
		guard let writer = writers[.organization], !ids.isEmpty else { return }

		do {
			_ = try await writer.writeAllowingSyncedDeletions { db in try WorkspaceRepair.keep(ids, db) }
		} catch {
			logger.error("Couldn't keep items marked for deletion: \(error.localizedDescription, privacy: .public)")
		}
		await refreshDeletionMarks()
	}

	private func refreshDuplicateProfiles() async {
		guard let writer = writers[.organization] else { return }

		let local: WorkspaceMerge.Snapshot? = try? await writer.read { db in try WorkspaceMerge.Snapshot(db) }
		let groups: [String: [ProfileRecord]] = .init(grouping: local?.profiles ?? []) { WorkspaceMerge.nameKey($0.name) }
		let duplicates: [DuplicateProfiles] = groups.values
			.filter { $0.count > 1 }
			.map { $0.sorted(by: WorkspaceMerge.ordered) }
			.sorted { WorkspaceMerge.ordered($0[0], $1[0]) }
			.map { DuplicateProfiles(name: $0[0].name, profileIDs: $0.map(\.id)) }
		guard duplicates != duplicateProfiles else { return }

		duplicateProfiles = duplicates
		publish()
	}

	// MARK: - Engines

	private func startCategories() async {
		guard !isReplacing, !isStopping else { return }
		guard settings.isEnabled else {
			publish()
			return
		}
		guard settings.review == nil else {
			stopAll()
			publish()
			return
		}

		accountCheck += 1
		let check: Int = accountCheck
		let current: CloudAccess.Account? = await currentAccount()

		// A newer account check started while this one read: its answer is the current one.
		guard check == accountCheck else { return }

		// The account read suspends: an account event may have paused sync meanwhile.
		guard settings.isEnabled, settings.review == nil else {
			stopAll()
			publish()
			return
		}

		switch current {
		case let .available(account):
			pauses = pauses.filter { $0.value == .quotaExceeded }
			if let bound = settings.account, bound != account {
				settings.review = .accountChanged
				persist()
				stopAll()
				publish()
				return
			}
			if settings.account == nil {
				settings.account = account
				if settings.startedCategories.isEmpty {
					settings.starterProfileIDs = await ownStarterProfileIDs()
				}

				// The binding must be on disk before anything is sent to the account.
				guard persist() else {
					settings.account = nil
					stopAll()
					publish()
					return
				}
			}
			guard settings.review == nil, settings.account == account else {
				stopAll()
				publish()
				return
			}

		case .noAccount:
			pauseAll(.noAccount)
			return

		case .unavailable, nil:
			pauseAll(.accountUnavailable)
			return
		}

		// A Mac rejoining after a stop says so in the device directory before its categories start:
		// until iCloud has it, the other Macs leave this Mac out of purges, and would delete for good
		// what it still keeps. So nothing starts, and the rejoin stays pending, until then; the account
		// retry tries again (DEV-1149 closes the window after it).
		// The same for a category turned on again after a leave (DEV-1148), though only that one waits.
		var waitingForRejoin: Set<SyncCategory> = []
		if !settings.pendingRejoins.isEmpty {
			guard await sendRejoin() else {
				scheduleAccountRetry()
				publish()
				return
			}
		} else if settings.pendingMerges.contains(where: settings.isOn), await !sendRejoin() {
			waitingForRejoin = settings.pendingMerges
			scheduleAccountRetry()
		}

		// A Mac joining with its own workspace merges it into iCloud's first, after the person saw what
		// merges (DEV-1216): nothing starts until then, so nothing uploads.
		guard await joinMergeAllowsStart() else {
			publish()
			return
		}

		for category in availableCategories {
			// Every start and repair suspends, so check again that nothing paused sync since: all of
			// it, or just this category.
			guard
				settings.isEnabled,
				settings.review == nil,
				current == .available(settings.account ?? "")
			else { break }
			guard settings.isOn(category), !waitingForRejoin.contains(category) else { continue }
			guard
				!deletingCategories.contains(category),
				let engine = ensureEngine(category)
			else { continue }

			let isRejoining: Bool = settings.pendingMerges.contains(category)
			let attempt: Int = rejoinAttempts[category, default: 0]
			if isRejoining {
				guard rejoining.insert(category).inserted else {
					// That start may have been interrupted, as by turning the category off and on again:
					// this one runs once it's done.
					startsWaitingForRejoin.insert(category)
					continue
				}
			}
			defer {
				if isRejoining {
					rejoining.remove(category)
					if startsWaitingForRejoin.remove(category) != nil {
						Task { [weak self] in await self?.startCategories() }
					}
				}
			}

			do {
				try await resetIfPending(category)
				try await replaceIfPending(category)
				try await rejoinIfPending(category)
				try await keepRowsIfMerging(category)
				guard
					settings.isOn(category),
					settings.review == nil,
					!deletingCategories.contains(category)
				else { continue }

				// Saved before the start suspends: once it begins, the library knows the tables, so the
				// engine must be made at every launch to track edits.
				if !settings.startedCategories.contains(category) {
					// What this Mac has before anything is sent or fetched (DEV-1207): without the copy,
					// the category doesn't start.
					try await backUpBeforeFirstSync(category)
					if category == .organization {
						// After the copy, before the engine knows the rows (DEV-1216).
						// A merge shown again, or one that failed, stops every category, so nothing uploads
						// before it's done.
						let mayStart: Bool
						do {
							mayStart = try await applyJoinMerge()
						} catch {
							fail([category], error)
							scheduleAccountRetry()
							break
						}
						guard mayStart else { break }
						guard settings.isOn(category), settings.review == nil else { continue }
					}
				}
				if settings.startedCategories.insert(category).inserted {
					guard persist() else {
						settings.startedCategories.remove(category)
						continue
					}
				}
				try await engine.start()
				guard settings.isOn(category), settings.review == nil else {
					engine.stop()
					continue
				}

				// SQLiteData's start returns early, though running, when iCloud isn't available at
				// that moment, without queuing this Mac's rows. Stopped again, the next account check
				// starts it for real.
				guard await currentAccount() == current else {
					engine.stop()
					pauses[category] = .accountUnavailable
					scheduleAccountRetry()
					continue
				}

				errors[category] = nil
				try await requeueUnconfirmed(category)
				if settings.pendingMerges.contains(category) {
					// Rejoining after a leave: what iCloud has now first, then this Mac's kept rows.
					guard try await mergeKeptRows(category, engine: engine, attempt: attempt) else { continue }
				}
				if category == .organization, !settings.starterProfileIDs.isEmpty {
					// The first merge (ADR 0001, section 7): fetch what iCloud has, then repair, which
					// may drop this Mac's untouched starter profile in favor of an identical one there.
					try await engine.fetchChanges()
					guard settings.isOn(category), settings.review == nil else { continue }

					// The batch notice may already be read: the repair's changes need their own.
					if try await !repair(category, isFirstMerge: true).isEmpty {
						for continuation in remoteChangeContinuations.values {
							continuation.yield(category)
						}
					}
				} else {
					// A running engine may be mid-fetch: the repair waits for it like a batch's does.
					pendingRepairs.insert(category)
					await repairIfFetched(category)
				}
			} catch {
				fail([category], error)
			}
		}
		await startDirectory()
		publish()
	}

	/// Forgets the category's engine state when a Delete from iCloud asked for it and it hasn't
	/// happened yet. The engine must exist (its metadatabase is attached to the writer) and be stopped.
	private func resetIfPending(_ category: SyncCategory) async throws {
		guard settings.pendingResets.contains(category) else { return }

		if engines[category] == nil, settings.startedCategories.contains(category) {
			// Its metadatabase is on disk, and only an engine attaches it: try again once one is made.
			struct EngineUnavailable: Error {}
			guard ensureEngine(category) != nil else { throw EngineUnavailable() }
		}
		if engines[category] != nil, let writer = writers[category] {
			engines[category]?.stop()
			try await Self.resetEngineState(writer)
		}

		// A category that never started has no engine state to forget.
		settings.pendingResets.remove(category)
		persist()
	}

	/// Rejoining after "Stop syncing this Mac" (DEV-979): forgets the category's engine state, so it
	/// fetches everything and sends every row as new, merging this Mac's rows with iCloud's. Other Macs'
	/// deletion, use and device rows are forgotten with it, to be fetched again rather than sent back
	/// as this Mac last saw them. Waits for the stopped engine to go quiet first.
	private func rejoinIfPending(_ category: SyncCategory) async throws {
		guard settings.pendingRejoins.contains(category) else { return }

		guard let writer = writers[category], let engine = ensureEngine(category) else {
			struct DatabaseUnavailable: Error {}
			throw DatabaseUnavailable()
		}

		engine.stop()
		try await Self.waitUntilIdle(engine)
		let deviceID: UUID? = await thisDeviceID()
		try await writer.writeWithoutTransaction { db in
			try SyncedDeletions.allowing {
				try db.inTransaction {
					try Self.resetEngineState(db)
					try Self.forgetOtherMacs(category, except: deviceID, db)
					return .commit
				}
			}
		}
		settings.pendingRejoins.remove(category)
		persist()
	}

	/// Other Macs' coordination rows in `category`'s database, deleted without sending the deletion
	/// (the engine state is forgotten first): a rejoining Mac fetches them again.
	private static func forgetOtherMacs(
		_ category: SyncCategory,
		except deviceID: UUID?,
		_ db: Database
	) throws {
		guard let deviceID else { return }

		switch category {
		case .organization:
			try DeletionRecord.where { $0.deviceID.neq(deviceID) }.delete().execute(db)
			try UsageRecord.where { $0.deviceID.neq(deviceID) }.delete().execute(db)
			try SyncDeviceRecord.where { $0.id.neq(deviceID) }.delete().execute(db)

		case .archive:
			try ArchiveDeletionRecord.where { $0.deviceID.neq(deviceID) }.delete().execute(db)
			try ArchiveDeviceRecord.where { $0.id.neq(deviceID) }.delete().execute(db)

		case .preferences, .history:
			break
		}
	}

	// MARK: - Device directory (DEV-979)

	/// "Stop syncing this Mac": this Mac leaves every category and keeps all its data, and every other
	/// Mac keeps theirs. Its engines stop and finish what they were doing first, so no fetch applies
	/// anything after it left; then the device directory says it stopped, which takes it out of the
	/// Macs that must all delete something. Saved first, so a stop cut short still holds, and sent the
	/// next time the account is reachable when it can't be now. Turning sync on again rejoins
	/// (``SyncSettings/pendingRejoins``). The account stays connected, as with Keep on This Mac.
	public func stopSyncingThisMac() async {
		guard !isStopping, !isResolving, !isReplacing, !settings.isStopped, settings.account != nil else { return }

		isStopping = true
		publish()
		defer {
			isStopping = false
			publish()
		}

		let previous: SyncSettings = settings
		settings.isStopped = true
		settings.stopIsUnpublished = true
		settings.isEnabled = false
		settings.review = nil
		guard persist() else {
			// Nothing stopped, so an account decision it replaced is still the person's to make.
			settings = previous
			return
		}
		accountCheck += 1

		for engine in engines.values {
			engine.stop()
		}

		// publishStop runs it only while it sends the stop.
		directoryEngine?.stop()
		for engine in engines.values {
			do {
				try await Self.waitUntilIdle(engine)
			} catch {
				// Not sent while it's busy: publishStop checks again and retries.
				logger.error("A stopped engine was still busy when this Mac stopped syncing: \(error.localizedDescription, privacy: .public)")
			}
		}
		updateHistoryMirror()
		updateArchiveState()
		await publishStop()
	}

	/// Sends this Mac's stop to the device directory, when one is waiting, every category's engine
	/// has gone quiet (a fetch in flight could still apply another Mac's change after it), and the
	/// account this Mac's data is connected to is reachable. Tried again after the account retry's
	/// delay, at the next account change and at launch otherwise.
	private func publishStop() async {
		guard settings.isStopped, settings.stopIsUnpublished else { return }

		guard !engines.values.contains(where: \.isSynchronizing) else {
			scheduleAccountRetry()
			return
		}
		guard
			let directory,
			let account = settings.account,
			// Schedules a retry itself when the account can't be read.
			await currentAccount() == .available(account),
			// The account read suspends: a rejoin may have started meanwhile.
			settings.isStopped
		else { return }

		// Not yet made, or still busy with another account: tried again later.
		guard let engine = await prepareDirectory(for: account), let id = await thisDeviceID() else {
			scheduleAccountRetry()
			return
		}
		guard

			// Each step above suspends, and a retry can overlap a rejoin: once sync is on again, this
			// stop is stale and mustn't overwrite the row the rejoin wrote. Nothing suspends between
			// here and queueing the write, so a later rejoin's row is written after it.
			settings.isStopped,
			settings.stopIsUnpublished
		else { return }

		let now: Date = self.now()
		let groups: Set<PreferenceGroup> = localPreferenceGroups
		let left: Set<SyncCategory> = leavesToSend
		let name: String = deviceName()
		do {
			try await directory.write { db in

				// A retry keeps the time of the stop.
				let stopped: Date? = try DeviceDirectoryRecord.find(id).fetchOne(db)?.stoppedAt
					.map(Date.init(timeIntervalSince1970:))
				try DeviceDirectory.write(
					db,
					id: id,
					name: name,
					categories: [],
					leftCategories: left,
					preferenceGroups: groups,
					stoppedAt: stopped ?? now,
					now: now
				)
			}

			// The write suspends: a rejoin meanwhile starts and runs the directory itself.
			guard settings.isStopped else { return }

			if !engine.isRunning {
				try await engine.start()
			}
			try await sendDirectoryChanges(engine)

			// A rejoin while this was sending supersedes it, and runs the directory itself.
			guard settings.isStopped else { return }

			engine.stop()

			// CloudKit can refuse the record alone, as over quota, and sending still succeeds: the
			// engine keeps it pending, and so does this Mac.
			guard let row = await confirmedRow(id: id), row.stoppedAt != nil else {
				logger.error("iCloud didn't save this Mac's stop yet; trying again later")
				scheduleAccountRetry()
				await readDevices()
				return
			}

			settings.stopIsUnpublished = false

			// The stop's row lists the categories left too.
			settings.unpublishedLeaves.subtract(DeviceDirectory.leftCategories(row))
			persist()
		} catch {
			if settings.isStopped {
				engine.stop()
			}
			logger.error("Couldn't send this Mac's stop to iCloud: \(error.localizedDescription, privacy: .public)")
			scheduleAccountRetry()
		}
		await readDevices()
	}

	/// Sends a stop or a leave still waiting for the device directory.
	private func publishDepartures() async {
		await publishStop()
		await publishLeaves()
	}

	/// Sends the categories this Mac left by turning them off to the device directory (DEV-1148), when
	/// a leave is waiting, those categories' engines have gone quiet (a fetch in flight could still
	/// apply another Mac's purge after it), and the account this Mac's data is connected to is
	/// reachable. With sync off the directory runs only while it sends. Tried again after the account
	/// retry's delay, at the next account change and at launch otherwise. A stop says it all, so none
	/// is sent while this Mac is stopped.
	private func publishLeaves() async {
		guard !settings.isStopped, !settings.unpublishedLeaves.isEmpty else { return }

		guard !settings.unpublishedLeaves.contains(where: { engines[$0]?.isSynchronizing == true }) else {
			scheduleAccountRetry()
			return
		}
		guard
			let directory,
			let account = settings.account,
			// Schedules a retry itself when the account can't be read.
			await currentAccount() == .available(account),
			// The account read suspends.
			!settings.isStopped,
			!settings.unpublishedLeaves.isEmpty
		else { return }

		// Not yet made, or still busy with another account: tried again later.
		guard let engine = await prepareDirectory(for: account), let id = await thisDeviceID() else {
			scheduleAccountRetry()
			return
		}

		// Each step above suspends: a stop or the toggle may have changed meanwhile. Nothing suspends
		// between here and queueing the write.
		guard !settings.isStopped, !settings.unpublishedLeaves.isEmpty else { return }

		let isSyncing: Bool = settings.isEnabled && settings.review == nil
		let categories: Set<SyncCategory> = isSyncing ? Set(availableCategories.filter { settings.isOn($0) }) : []
		let left: Set<SyncCategory> = leavesToSend
		let groups: Set<PreferenceGroup> = localPreferenceGroups
		let syncDeletionsAfterDays: Int? = settings.syncDeletionsAfterDays
		let name: String = deviceName()
		let now: Date = self.now()
		do {
			try await directory.write { db in
				try DeviceDirectory.write(
					db,
					id: id,
					name: name,
					categories: categories,
					leftCategories: left,
					preferenceGroups: groups,
					stoppedAt: nil,
					syncDeletionsAfterDays: syncDeletionsAfterDays,
					now: now
				)
			}

			// The write suspends: a stop meanwhile writes and sends its own row.
			guard !settings.isStopped else { return }

			if !engine.isRunning {
				try await engine.start()
			}
			try await sendDirectoryChanges(engine)

			// Sync off, or waiting for an account decision: the directory ran only to send this.
			if !settings.isEnabled || settings.review != nil || settings.isStopped {
				engine.stop()
			}
			guard let row = await confirmedRow(id: id), row.stoppedAt == nil else {
				logger.error("iCloud didn't save this Mac's leave yet; trying again later")
				scheduleAccountRetry()
				await readDevices()
				publish()
				return
			}

			leavesConfirmed(row)
		} catch {
			if !settings.isEnabled || settings.review != nil || settings.isStopped {
				engine.stop()
			}
			logger.error("Couldn't send this Mac's leave to iCloud: \(error.localizedDescription, privacy: .public)")
			scheduleAccountRetry()
		}
		await readDevices()
		publish()
	}

	/// The device directory's engine, made on first use, before anything writes its file.
	@discardableResult
	private func ensureDirectoryEngine() -> SyncEngine? {
		if let directoryEngine { return directoryEngine }
		guard let directory, let makeDirectoryEngine else { return nil }

		do {
			let delegate: DeviceDirectoryDelegate = .init(onAccountChange: { [weak self] change in
				await self?.accountChanged(change)
			})
			let engine: SyncEngine = try makeDirectoryEngine(directory, delegate)
			let observer: SyncBatchObserver = .init(tables: [DeviceDirectoryRecord.tableName]) { [weak self] in
				Task { await self?.directoryChanged() }
			}
			directory.add(transactionObserver: observer, extent: .observerLifetime)
			directoryEngine = engine
			directoryObserver = observer
			return engine
		} catch {
			logger.error("Couldn't make the device directory's engine: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	/// This Mac's row, when iCloud has it as this Mac last wrote it about leaving: its stop, or none,
	/// and the categories it left (DEV-1148). CloudKit can refuse the record alone, as over quota,
	/// and sending still succeeds; SQLiteData's copy of the server record takes what it sent even
	/// then, so this reads the record from iCloud itself. `nil` while iCloud can't say or differs.
	private func confirmedRow(id: UUID) async -> DeviceDirectoryRecord? {
		guard let directory else { return nil }

		let row: DeviceDirectoryRecord?? = try? await directory.read { db in
			try DeviceDirectoryRecord.find(id).fetchOne(db)
		}
		guard let row = row.flatMap(\.self) else { return nil }

		let name: String = "\(id.uuidString.lowercased()):\(DeviceDirectoryRecord.tableName)"
		do {
			let remote: [String: [String: String]] = try await cloud.recordValues(DeviceDirectory.zoneName, [name])
			guard let fields = remote[name] else { return nil }

			// A column without a value is left out of the record, and a row from before the leave per
			// category has no left categories.
			let isConfirmed: Bool = fields["stoppedAt"] == row.stoppedAt.map { NSNumber(value: $0).stringValue }
				&& (fields["leftCategories"] ?? DeviceDirectory.encode([])) == row.leftCategories
			return isConfirmed ? row : nil
		} catch {
			logger.error("Couldn't read this Mac's row from iCloud: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	/// The categories this Mac's row says it left: a leave not sent yet only once the engine that left
	/// went quiet, since a fetch still in flight could apply another Mac's purge after the others
	/// stopped counting this Mac. Every write of the row uses it: a heartbeat or a batch can write it
	/// before ``publishLeaves()`` runs.
	private var leavesToSend: Set<SyncCategory> {
		settings.leftCategories.filter { category in
			!settings.unpublishedLeaves.contains(category) || engines[category]?.isSynchronizing != true
		}
	}

	/// The leaves a confirmed row carries are sent.
	private func leavesConfirmed(_ row: DeviceDirectoryRecord) {
		let confirmed: Set<SyncCategory> = DeviceDirectory.leftCategories(row)
		guard !settings.unpublishedLeaves.isDisjoint(with: confirmed) else { return }

		settings.unpublishedLeaves.subtract(confirmed)
		persist()
	}

	/// Writes and sends this Mac's rejoin to the device directory, and whether iCloud has it: its row
	/// there no longer says this Mac stopped.
	private func sendRejoin() async -> Bool {
		await startDirectory()
		guard
			let engine = directoryEngine,
			engine.isRunning,
			let id = await thisDeviceID()
		else {
			logger.error("The device directory isn't running; this Mac's rejoin waits")
			return false
		}

		do {
			try await sendDirectoryChanges(engine)
		} catch {
			logger.error("Couldn't send this Mac's rejoin to the device directory: \(error.localizedDescription, privacy: .public)")
			return false
		}

		// The row must no longer say this Mac stopped or left a category it rejoins.
		guard
			let row = await confirmedRow(id: id),
			row.stoppedAt == nil,
			DeviceDirectory.leftCategories(row).isDisjoint(with: settings.pendingMerges.filter(settings.isOn))
		else {
			logger.error("iCloud didn't save this Mac's rejoin yet; its categories wait")
			return false
		}
		leavesConfirmed(row)
		return true
	}

	/// The device directory's engine for `account`. When its rows and engine state are another
	/// account's, they're forgotten first, without sending anything, so that account's Macs don't
	/// show under this one and this Mac's row goes to this account as new. `nil` while the engine
	/// can't be made or is still busy with the old account.
	private func prepareDirectory(for account: String) async -> SyncEngine? {
		guard let directory, let engine = ensureDirectoryEngine() else { return nil }
		guard settings.directoryAccount != account else { return engine }

		engine.stop()
		do {
			try await Self.waitUntilIdle(engine)

			// The wait suspends: only the account still connected is recorded.
			guard settings.account == account else { return nil }

			try await directory.writeWithoutTransaction { db in
				try db.inTransaction {
					try Self.resetEngineState(db)
					try DeviceDirectoryRecord.delete().execute(db)
					return .commit
				}
			}
		} catch {
			logger.error("Couldn't clear the device directory for another account: \(error.localizedDescription, privacy: .public)")
			return nil
		}
		settings.directoryAccount = account
		guard persist() else { return nil }

		devices = []
		return engine
	}

	/// Runs the device directory while sync does, and writes this Mac's row.
	private func startDirectory() async {
		guard
			settings.isEnabled,
			settings.review == nil,
			!settings.isStopped,
			let account = settings.account,
			let engine = await prepareDirectory(for: account),
			// Clearing another account's directory suspends.
			settings.isEnabled,
			settings.review == nil,
			!settings.isStopped
		else { return }

		if !engine.isRunning {
			do {
				try await engine.start()
			} catch {
				logger.error("Couldn't start the device directory: \(error.localizedDescription, privacy: .public)")
				return
			}
		}
		await publishThisMac()
		scheduleHeartbeat()
	}

	/// Writes this Mac's row every few hours while the directory runs; ``DeviceDirectory/write``
	/// sends it at most once a day when nothing else changed.
	private func scheduleHeartbeat() {
		guard heartbeatTask == nil else { return }

		heartbeatTask = Task { [weak self] in
			try? await Task.sleep(for: Self.heartbeatInterval)
			guard !Task.isCancelled else { return }

			await self?.heartbeat()
		}
	}

	private func heartbeat() async {
		heartbeatTask = nil
		guard directoryEngine?.isRunning == true else { return }

		await publishThisMac()
		scheduleHeartbeat()
	}

	private static let heartbeatInterval: Duration = .seconds(6 * 60 * 60)

	/// Writes this Mac's row while the directory runs: its name, the categories it syncs (none while
	/// sync is off) and the Preferences groups it keeps, when they changed, and at least once a day.
	private func publishThisMac() async {
		guard
			let directory,
			let engine = directoryEngine,
			engine.isRunning,
			!settings.isStopped,
			let id = await thisDeviceID(),
			// A stop that began meanwhile writes its own row, which this one mustn't replace.
			engine.isRunning,
			!settings.isStopped
		else { return }

		let categories: Set<SyncCategory> = Set(availableCategories.filter { settings.isOn($0) })
		let left: Set<SyncCategory> = leavesToSend
		let groups: Set<PreferenceGroup> = localPreferenceGroups
		let syncDeletionsAfterDays: Int? = settings.syncDeletionsAfterDays
		let name: String = deviceName()
		let now: Date = self.now()
		do {
			try await directory.write { db in
				try DeviceDirectory.write(
					db,
					id: id,
					name: name,
					categories: categories,
					leftCategories: left,
					preferenceGroups: groups,
					stoppedAt: nil,
					syncDeletionsAfterDays: syncDeletionsAfterDays,
					now: now
				)
			}
		} catch {
			logger.error("Couldn't write this Mac's row in the device directory: \(error.localizedDescription, privacy: .public)")
		}
		await readDevices()
		publish()
	}

	/// Another Mac's row arrived.
	private func directoryChanged() async {
		await readDevices()

		// Another Mac turning "sync deletions after" on or off changes when its marks go (DEV-1337).
		await refreshDeletionMarks()
		publish()
	}

	/// Reads the Macs in the directory: this one first, then by name.
	private func readDevices() async {
		guard let directory else { return }

		// Another account's Macs, until the directory is cleared for this one.
		guard settings.account != nil, settings.directoryAccount == settings.account else {
			devices = []
			return
		}

		let id: UUID? = await thisDeviceID()
		guard let read = try? await directory.read({ db in try DeviceDirectory.devices(db, thisMac: id) }) else { return }

		devices = read.sorted { lhs, rhs in
			if lhs.isThisMac != rhs.isThisMac { return lhs.isThisMac }
			return (lhs.name.localizedLowercase, lhs.id.uuidString) < (rhs.name.localizedLowercase, rhs.id.uuidString)
		}
	}

	/// The Macs that left `category`, which its purges leave out: they stopped syncing, or turned it
	/// off (DEV-1148).
	private func departedDevices(from category: SyncCategory) -> Set<UUID> {
		guard let directory, settings.account != nil, settings.directoryAccount == settings.account else { return [] }

		return (try? directory.read { db in try DeviceDirectory.departedDevices(db, from: category) }) ?? []
	}

	/// The Macs with "sync deletions after" on (DEV-1337), from their directory rows, with this Mac's
	/// own setting as it is now, or `nil` without a device directory. A Mac whose row doesn't say, as an
	/// older Arx's, counts as off; so does every other Mac until the directory is this account's.
	private func devicesSyncingDeletions() async -> Set<UUID>? {
		guard let directory else { return nil }

		var syncing: Set<UUID> = []
		if settings.account != nil, settings.directoryAccount == settings.account {
			syncing = (try? await directory.read { db in try DeviceDirectory.devicesSyncingDeletions(db) }) ?? []
		}
		if let id = await thisDeviceID() {
			if settings.syncDeletionsAfterDays != nil { syncing.insert(id) } else { syncing.remove(id) }
		}
		return syncing
	}

	/// This Mac's ID: the organization store's, which its deletion and use rows carry.
	private func thisDeviceID() async -> UUID? {
		guard let writer = writers[.organization] else { return nil }

		return try? await writer.writeAllowingSyncedDeletions { db in try LocalDeletion.deviceID(db) }
	}

	// MARK: - Rejoining after a leave (DEV-1148)

	/// The copy of a category's database a rejoin after a leave merges from (``KeptRows``), beside
	/// the settings file.
	private func keptCopyFile(_ category: SyncCategory) -> URL {
		settingsStore.file.deletingLastPathComponent()
			.appendingPathComponent(Self.keptCopyDirectoryName)
			.appendingPathComponent("\(category.rawValue).sqlite")
	}

	public static let keptCopyDirectoryName: String = "arx-icloud-sync-rejoins"

	private func removeKeptCopy(_ category: SyncCategory) async {
		await unwatchCascades(category)
		let file: URL = keptCopyFile(category)
		guard FileManager.default.fileExists(atPath: file.path) else { return }

		do {
			try FileManager.default.removeItem(at: file)
		} catch {
			logger.error("Couldn't remove a rejoin's copy: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Copies the rows this Mac kept while it was out of `category`, before its engine resumes and
	/// can apply what was purged meanwhile. Waits for a stopped engine to go quiet first. A copy an
	/// earlier attempt left, as when Arx quit while its fetch applied a purge, is merged first: reused,
	/// it would bring rows back as they were before any change made since.
	private func keepRowsIfMerging(_ category: SyncCategory) async throws {
		guard settings.pendingMerges.contains(category) else { return }

		guard let writer = writers[category] else {
			struct DatabaseUnavailable: Error {}
			throw DatabaseUnavailable()
		}

		engines[category]?.stop()
		try await Self.waitUntilIdle(engines[category])

		// A copy an earlier attempt left: what it has that's missing here comes back first, and this
		// attempt copies the rows as they are now, with any change made since.
		let file: URL = keptCopyFile(category)
		if FileManager.default.fileExists(atPath: file.path) {
			try await restoreKeptRows(category)
		}
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

		// Written beside it, then moved, so a copy cut short is never taken for a whole one.
		let partial: URL = file.appendingPathExtension("partial")
		try? FileManager.default.removeItem(at: partial)
		try await writer.writeWithoutTransaction { db in
			try db.execute(sql: "VACUUM main INTO ?", arguments: [partial.path])
		}
		try FileManager.default.moveItem(at: partial, to: file)
		await watchCascades(category, copy: file)
	}

	/// Attaches the rejoin's copy to the category's writer and logs there the rows only this Mac has
	/// that a fetch's cascade deletes until the merge (``KeptRows/watchCascades(_:)``). Profiles and
	/// spaces only: Tab Archive has none. Without it, those rows don't come back, and nothing else
	/// changes.
	private func watchCascades(
		_ category: SyncCategory,
		copy: URL
	) async {
		guard category == .organization, !watchedCopies.contains(category), let writer = writers[category] else { return }

		do {
			try await writer.writeWithoutTransaction { db in
				try db.execute(sql: #"ATTACH DATABASE ? AS "\#(KeptRows.schema)""#, arguments: [copy.path])
				do {
					try KeptRows.watchCascades(db)
				} catch {
					try? KeptRows.unwatchCascades(db)
					try? db.execute(sql: #"DETACH DATABASE "\#(KeptRows.schema)""#)
					throw error
				}
			}
			watchedCopies.insert(category)
		} catch {
			logger.error("Couldn't watch a rejoin for this Mac's open tabs: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Stops logging and detaches the copy, before it's read and removed.
	private func unwatchCascades(_ category: SyncCategory) async {
		guard watchedCopies.remove(category) != nil, let writer = writers[category] else { return }

		do {
			try await writer.writeWithoutTransaction { db in
				try KeptRows.unwatchCascades(db)
				try db.execute(sql: #"DETACH DATABASE "\#(KeptRows.schema)""#)
			}
		} catch {
			logger.error("Couldn't stop watching a rejoin: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// The rejoin after a leave, once the engine runs again with its conflict metadata, so it sends
	/// only this Mac's own changes: fetches everything iCloud has now, then brings back from the kept
	/// copy what purges deleted while this Mac was away (``KeptRows``). `false` when the category was
	/// turned off or paused meanwhile; a failed fetch stops the engine and waits for the account retry.
	///
	/// - Parameters:
	///   - attempt: ``rejoinAttempts`` when this start began: once the category was turned off
	///     since, the attempt is over, whether or not it's on again.
	private func mergeKeptRows(
		_ category: SyncCategory,
		engine: SyncEngine,
		attempt: Int
	) async throws -> Bool {
		do {
			try await fetchRejoinChanges(category, engine)

			// A fetch the engine started itself may still be applying.
			try await Self.waitUntilIdle(engine)
		} catch {
			engine.stop()
			scheduleAccountRetry()
			await settleInterruptedMerge(category)

			// What the fetch applied before it stopped shows.
			for continuation in remoteChangeContinuations.values {
				continuation.yield(category)
			}
			throw error
		}
		guard
			settings.isOn(category),
			settings.review == nil,
			settings.pendingMerges.contains(category),
			rejoinAttempts[category, default: 0] == attempt
		else {
			// Turned off or paused meanwhile: what the fetch deleted comes back now rather than stay
			// missing until the next attempt, which a start that waited for this one runs.
			engine.stop()
			await settleInterruptedMerge(category)
			return false
		}

		try await restoreKeptRows(category)

		// The fetch's batches weren't announced: the app reloads once, merged.
		for continuation in remoteChangeContinuations.values {
			continuation.yield(category)
		}
		settings.pendingMerges.remove(category)

		// Until that's on disk, the next launch merges again, from a new copy: nothing more comes back.
		persist()
		return true
	}

	/// Brings back from the kept copy what's missing here that this Mac didn't delete (``KeptRows``),
	/// then removes the copy: from then on this Mac's own rows have it all. The category's engine
	/// must be quiet.
	private func restoreKeptRows(_ category: SyncCategory) async throws {
		let file: URL = keptCopyFile(category)
		guard FileManager.default.fileExists(atPath: file.path) else { return }

		await unwatchCascades(category)
		guard let writer = writers[category], let deviceID = await thisDeviceID() else {
			struct DatabaseUnavailable: Error {}
			throw DatabaseUnavailable()
		}
		if let kept = try KeptRows.read(category, from: file, deviceID: deviceID) {
			let restored: Int = try await writer.writeAllowingSyncedDeletions { db in try kept.restore(db) }
			if restored > 0 {
				logger.info("A rejoin brought back \(restored) rows purged while this Mac was away")
			}
		}
		await removeKeptCopy(category)
	}

	/// A rejoin whose fetch stopped partway, or that's turned off or paused before its merge: what the
	/// fetch deleted comes back from the copy now, once the stopped engine went quiet, and the copy
	/// goes. The rejoin stays pending, and its next attempt copies this Mac's rows again, with any
	/// change made meanwhile. A copy the engine may still write past (it didn't go quiet) stays for
	/// the next attempt, which merges it first.
	private func settleInterruptedMerge(_ category: SyncCategory) async {
		guard settings.pendingMerges.contains(category) else { return }

		do {
			try await Self.waitUntilIdle(engines[category])
			try await restoreKeptRows(category)
			for continuation in remoteChangeContinuations.values {
				continuation.yield(category)
			}
		} catch {
			logger.error("Couldn't bring back what a rejoin cut short deleted: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Replace with the Account's Data for a category whose database didn't open when the person
	/// chose it: backed up, its synced rows cleared and its engine state forgotten, as then. Stays
	/// pending while the database is unavailable, and the category can't start until it's done.
	private func replaceIfPending(_ category: SyncCategory) async throws {
		guard settings.pendingReplacements.contains(category) else { return }

		guard let writer = writers[category], let engine = ensureEngine(category) else {
			struct DatabaseUnavailable: Error {}
			throw DatabaseUnavailable()
		}

		engine.stop()
		try await Self.waitUntilIdle(engine)
		let stamp: String = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
		try await Self.replaceSyncedRows(category, writer: writer, backup: backupFile(category, stamp: stamp), at: now())
		for continuation in remoteChangeContinuations.values {
			continuation.yield(category)
		}
		settings.pendingReplacements.remove(category)
		settings.pendingMerges.remove(category)
		persist()
		await removeKeptCopy(category)
	}

	/// The category's engine, made on first use; `nil` when it can't be made, with the error shown as
	/// the category's status.
	@discardableResult
	private func ensureEngine(_ category: SyncCategory) -> SyncEngine? {
		if let engine = engines[category] { return engine }
		guard let writer = writers[category] else { return nil }

		let delegate: WorkspaceSyncDelegate = .init(
			category: category,
			onAccountChange: { [weak self] category, change in
				await self?.accountChanged(change)
			},
			onQuotaExceeded: { [weak self] category, isExceeded in
				await self?.quotaExceeded(category, isExceeded)
			}
		)
		do {
			let engine: SyncEngine = try makeEngine(category, writer, delegate)

			// Only a fetch or Arx itself deletes synced rows: not the library's answer to a refused save
			// (DEV-1207, ``SyncedDeletions``).
			if category == .organization {
				try writer.writeWithoutTransaction { db in
					try SyncedDeletions.install(db, tables: SyncedDeletions.organizationTables)
				}
			}
			let observer: SyncBatchObserver = .init(tables: Self.tableNames(category)) { [weak self] in
				Task { await self?.syncBatchCommitted(category) }
			}
			writer.add(transactionObserver: observer, extent: .observerLifetime)
			engines[category] = engine
			observers[category] = observer
			observeActivity(of: engine, category: category)
			return engine
		} catch {
			fail([category], error)
			return nil
		}
	}

	private func observeActivity(
		of engine: SyncEngine,
		category: SyncCategory
	) {
		activityTasks[category]?.cancel()
		activityTasks[category] = Task { [weak self] in
			let activity = Observations {
				(engine.isRunning, engine.isSynchronizing, engine.isFetchingChanges, engine.isSendingChanges)
			}
			for await _ in activity {
				guard let self else { return }

				await self.checkConfirmations(category)
				await self.repairIfFetched(category)
				await self.publish()
			}
		}
	}

	private func observeAccountChanges() {
		guard accountTask == nil else { return }

		let changes: AsyncStream<Void> = cloud.accountChanges()
		accountTask = Task { [weak self] in
			for await _ in changes {
				guard let self else { return }

				await self.accountDidChange()
				await self.publishDepartures()
			}
		}
	}

	private func stopAll() {
		for engine in engines.values {
			engine.stop()
		}
		directoryEngine?.stop()
	}

	private func pauseAll(_ reason: PauseReason) {
		stopAll()
		for category in availableCategories where settings.isOn(category) {
			pauses[category] = reason
		}
		publish()
	}

	/// The signed-in account, or `nil` when it couldn't be read; then a check is scheduled again,
	/// since getting back online doesn't post an account change.
	private func currentAccount() async -> CloudAccess.Account? {
		do {
			let account: CloudAccess.Account = try await cloud.account()
			if account == .unavailable {
				// Temporarily unavailable or unknown: it may come back without an account change.
				scheduleAccountRetry()
			}
			return account
		} catch {
			logger.error("Couldn't read the iCloud account: \(error.localizedDescription, privacy: .public)")
			scheduleAccountRetry()
			return nil
		}
	}

	private func scheduleAccountRetry() {
		guard accountRetryTask == nil else { return }

		let delay: Duration = accountRetryDelay
		accountRetryTask = Task { [weak self] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled else { return }

			await self?.retryAccount()
		}
	}

	/// Runs the organization repair again in a few hours while it syncs, since time alone can make a
	/// deletion, this Mac's own included, go everywhere.
	private func scheduleDeletionRecheck() {
		guard deletionRecheckTask == nil else { return }

		deletionRecheckTask = Task { [weak self] in
			try? await Task.sleep(for: WorkspaceRepair.DeletionPolicy.recheckInterval)
			guard !Task.isCancelled else { return }

			await self?.endDeletionRecheck()
			await self?.retryRepair(.organization)
			await self?.retryRepair(.archive)
		}
	}

	private func endDeletionRecheck() {
		deletionRecheckTask = nil
	}

	/// Runs the repair pass again later, when it couldn't decide something now.
	private func scheduleRepairRetry(_ category: SyncCategory) {
		guard repairRetryTasks[category] == nil else { return }

		let delay: Duration = accountRetryDelay
		repairRetryTasks[category] = Task { [weak self] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled else { return }

			await self?.retryRepair(category)
		}
	}

	private func retryRepair(_ category: SyncCategory) async {
		repairRetryTasks[category] = nil
		pendingRepairs.insert(category)
		await repairIfFetched(category)
	}

	/// Also sends a stop or leave still waiting, which doesn't depend on sync being on.
	private func retryAccount() async {
		accountRetryTask = nil
		await accountDidChange()
		await publishDepartures()
	}

	/// Writes this Mac's ``SyncDeviceRecord``, at most once a day.
	private static func markDeviceSeen(
		_ db: Database,
		now: Date
	) throws {
		let deviceID: UUID = try LocalDeletion.deviceID(db)
		let today: Double = Calendar.current.startOfDay(for: now).timeIntervalSince1970
		if let seen = try SyncDeviceRecord.find(deviceID).fetchOne(db), seen.lastSeen >= today { return }

		try SyncDeviceRecord.upsert {
			SyncDeviceRecord(id: deviceID, lastSeen: now.timeIntervalSince1970)
		}
		.execute(db)
	}

	/// The starter profiles this Mac has before its first sync.
	private func ownStarterProfileIDs() async -> Set<UUID> {
		guard let writer = writers[.organization] else { return [] }

		let ids: [UUID]? = try? await writer.read { db in
			try ProfileRecord.where(\.isStarter).select(\.id).fetchAll(db)
		}
		return Set(ids ?? [])
	}

	// MARK: - Events

	/// An account event from any engine, the device directory's included. Stopping every engine,
	/// the directory too, keeps queued rows from reaching another account until the person decides.
	private func accountChanged(_ change: AccountChange) async {
		switch change {
		case .signOut:
			stopAll()
			if settings.isEnabled {
				settings.review = .signedOut
				persist()
			}
			publish()

		case let .signIn(account):
			if settings.account == account || (settings.account == nil && settings.review == nil) {
				// The same account again, or the first one sync connects to: carry on.
				if settings.review != nil {
					settings.review = nil
					persist()
				}
				await startCategories()
			} else {
				// The library has already queued this Mac's rows for the new account; stopping the
				// engines here keeps them from being sent until the person decides.
				stopAll()
				settings.review = .accountChanged
				persist()
				publish()
			}

		case let .switchAccounts(account):
			if settings.account == account {
				// Back to the account this Mac's data is connected to: as a sign-in to it.
				await accountChanged(.signIn(account))
				return
			}
			stopAll()
			settings.review = .accountChanged
			persist()
			publish()
		}
	}

	private func quotaExceeded(
		_ category: SyncCategory,
		_ isExceeded: Bool
	) {
		pauses[category] = isExceeded ? .quotaExceeded : nil
		publish()
	}

	/// A batch is one page of a fetch: a parent folder can arrive in a later page than its child, so
	/// the repair waits for the fetch to finish rather than treat the parent as missing.
	private func syncBatchCommitted(_ category: SyncCategory) async {
		// The rows changed, whether or not a repair may follow: the app reloads now. A rejoin after a
		// leave tells it once its merge is done instead, so items a purge deleted and the merge brings
		// back don't go and their pages close in between (DEV-1148).
		if !settings.pendingMerges.contains(category) {
			for continuation in remoteChangeContinuations.values {
				continuation.yield(category)
			}
		}
		pendingRepairs.insert(category)
		await repairIfFetched(category)
		publish()

		// Seen today, while it syncs.
		await publishThisMac()
	}

	private func repairIfFetched(_ category: SyncCategory) async {
		guard
			pendingRepairs.contains(category),
			engines[category]?.isFetchingChanges != true,
			settings.review == nil,
			settings.isOn(category)
		else { return }

		pendingRepairs.remove(category)
		do {
			// A repair is a change too: the app reloads after it.
			if try await !repair(category).isEmpty {
				for continuation in remoteChangeContinuations.values {
					continuation.yield(category)
				}
			}
		} catch {
			fail([category], error)
		}
		publish()
	}

	private func fail(
		_ categories: [SyncCategory],
		_ error: any Error
	) {
		logger.error("iCloud sync failed: \(error.localizedDescription, privacy: .public)")
		for category in categories {
			errors[category] = error.localizedDescription
		}
		publish()
	}

	// MARK: - State

	private func status(of category: SyncCategory) -> CategoryStatus {
		guard settings.isOn(category) else { return .off }
		if let saveError { return .error(saveError) }

		switch settings.review {
		case .signedOut: return .paused(.noAccount)
		case .accountChanged: return .accountChanged
		case nil: break
		}
		if let error = errors[category] { return .error(error) }
		if let count = refusedRows[category] { return .refused(count) }
		if joinPreview != nil { return .paused(.mergeReview) }
		if let pause = pauses[category] { return .paused(pause) }
		guard let engine = engines[category], engine.isRunning else { return .syncing }

		return engine.isSynchronizing ? .syncing : .synced
	}

	private func publish() {
		let status: WorkspaceSyncStatus = status
		for continuation in statusContinuations.values {
			continuation.yield(status)
		}
	}

	/// Saves the settings; on failure the error shows in Settings until a save succeeds.
	@discardableResult
	private func persist() -> Bool {
		do {
			try settingsStore.save(settings)
			saveError = nil
			return true
		} catch {
			logger.error("Couldn't save iCloud sync settings: \(error.localizedDescription, privacy: .public)")
			saveError = error.localizedDescription
			publish()
			return false
		}
	}

	private func removeStatusContinuation(_ id: UUID) {
		statusContinuations[id] = nil
	}

	private func removeRemoteChangeContinuation(_ id: UUID) {
		remoteChangeContinuations[id] = nil
	}

	/// Waits up to `timeout` for a stopped engine to finish what it was sending or fetching.
	private static func waitUntilIdle(
		_ engine: SyncEngine?,
		timeout: Duration = .seconds(30)
	) async throws {
		guard let engine else { return }

		struct StillSyncing: Error, LocalizedError {
			var errorDescription: String? { "iCloud sync is still busy. Try again in a moment." }
		}
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: timeout)
		while engine.isSynchronizing {
			guard clock.now < deadline else { throw StillSyncing() }

			try await Task.sleep(for: .milliseconds(100))
		}
	}

	/// Where Replace copies a category's database before deleting its synced rows.
	/// Copies `category`'s database to the backup folder before its first sync (DEV-1207), as Replace
	/// does before it deletes: a first sync can go wrong before anything else would notice, as when
	/// iCloud refuses every save.
	private func backUpBeforeFirstSync(_ category: SyncCategory) async throws {
		guard let writer = writers[category] else { return }

		let stamp: String = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
		var file: URL = try backupFile(category, stamp: "\(stamp)-first-sync")

		// Another attempt in the same second, as after a merge shown again (DEV-1216), keeps both.
		var attempt: Int = 2
		while FileManager.default.fileExists(atPath: file.path) {
			file = try backupFile(category, stamp: "\(stamp)-first-sync-\(attempt)")
			attempt += 1
		}

		// Written beside it, then moved, so a copy cut short is never taken for a whole one.
		let partial: URL = file.appendingPathExtension("partial")
		try? FileManager.default.removeItem(at: partial)
		try await writer.writeWithoutTransaction { db in
			try db.execute(sql: "VACUUM main INTO ?", arguments: [partial.path])
		}
		try FileManager.default.moveItem(at: partial, to: file)
	}

	/// Queues again what iCloud never saved of `category`'s rows (``ServerConfirmation``): the library
	/// drops a refused save for good.
	private func requeueUnconfirmed(_ category: SyncCategory) async throws {
		guard let writer = writers[category] else { return }

		let tables: Set<String> = Self.tableNames(category)
		let rows: Set<String> = try await writer.writeAllowingSyncedDeletions { db in
			try ServerConfirmation.watchSendAttempts(db)
			let queued: Set<String> = try ServerConfirmation.requeueUnconfirmed(db, tables: tables)
			if queued.isEmpty {
				try ServerConfirmation.stopWatchingSendAttempts(db)
			} else {
				// Only what a send does from here on counts.
				try ServerConfirmation.forgetSendAttempts(db)
			}
			return queued
		}
		awaitingConfirmation[category] = rows.isEmpty ? nil : rows
		refusedRows[category] = nil
		if !rows.isEmpty {
			logger.info("Queued \(rows.count) rows iCloud never saved in \(category.rawValue, privacy: .public) again")
		}
	}

	/// Whenever `category`'s engine isn't sending: which of the rows queued again at its start a send
	/// tried and iCloud still hasn't saved (DEV-1209). Settings shows the category as failing while any
	/// are left. Rows iCloud saved stop being watched; the rest are queued again at the next start.
	///
	/// A send is recognized by the library writing or clearing each row's last known record
	/// (``ServerConfirmation/watchSendAttempts(_:)``), not by watching ``SyncEngine/isSendingChanges``
	/// change: a short send can begin and end between two looks. A save CloudKit retries by itself (no
	/// network, a busy zone) counts until it succeeds.
	internal func checkConfirmations(_ category: SyncCategory) async {
		guard
			let awaiting = awaitingConfirmation[category],
			let writer = writers[category],
			engines[category]?.isSendingChanges != true
		else { return }

		let tables: Set<String> = Self.tableNames(category)
		do {
			// On the writer: the attempts are noted on its connection.
			let (watched, tried): (Set<String>, Set<String>) = try await writer.write { db in

				// Rows iCloud saved, or that are gone, stop being watched.
				let watched: Set<String> = awaiting.intersection(try ServerConfirmation.unconfirmedRows(db, tables: tables))
				let tried: Set<String> = try ServerConfirmation.sendAttempts(db)
				if watched.isEmpty {
					try ServerConfirmation.stopWatchingSendAttempts(db)
				}
				return (watched, tried)
			}
			let refusedCount: Int = watched.intersection(tried).count
			let refused: Int? = refusedCount == 0 ? nil : refusedCount
			if let refused, refused != refusedRows[category] {
				logger.error("iCloud refused \(refused) rows of \(category.rawValue, privacy: .public)")
			}
			awaitingConfirmation[category] = watched.isEmpty ? nil : watched
			refusedRows[category] = refused
		} catch {
			logger.error("Couldn't check what iCloud saved: \(error.localizedDescription, privacy: .public)")
		}
		publish()
	}

	private func backupFile(
		_ category: SyncCategory,
		stamp: String
	) throws -> URL {
		let folder: URL = settingsStore.file.deletingLastPathComponent()
			.appendingPathComponent(Self.backupDirectoryName)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return folder.appendingPathComponent("\(stamp)-\(category.rawValue).sqlite")
	}

	/// Replace's deletion, for a stopped engine, in one exclusive use of the connection so nothing
	/// written in between can be lost: copies the database to `backup`, then in one transaction that
	/// fails as a whole forgets the engine's state and deletes the category's synced rows. With no
	/// record metadata left, the deletions aren't sent: iCloud keeps the account's rows, which the
	/// next start downloads. The library's `deleteLocalData()` isn't used because it reports a failed
	/// deletion without throwing and starts the engine anyway.
	///
	/// History's local entries stay, as a sync never removes them, but from then on the mirror takes
	/// only visits made after `date`: the account doesn't get this Mac's earlier history.
	private static func replaceSyncedRows(
		_ category: SyncCategory,
		writer: any DatabaseWriter,
		backup: URL,
		at date: Date
	) async throws {
		try await writer.writeWithoutTransaction { db in
			try db.execute(sql: "VACUUM main INTO ?", arguments: [backup.path])
			try SyncedDeletions.allowing {
				try db.inTransaction {
					try resetEngineState(db)
					let tables: [String] = tableNames(category).sorted()
					for table in tables {
						try db.execute(sql: "DELETE FROM \"\(table)\"")
					}
					for table in tables {
						struct RowsRemain: Error {}
						guard try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(table)\"") == 0 else { throw RowsRemain() }
					}
					if category == .history {
						try HistoryDatabase.mirrorOnlyFrom(db, date)
					}
					return .commit
				}
			}
		}
	}

	/// Forgets what a stopped engine knew about its zone, as the library does when it tears an engine
	/// down, but without its row deletion: the change token, record metadata, pending changes and
	/// known record types. The next start then fetches from scratch and uploads every row as new,
	/// instead of applying the zone's deletion to this Mac's rows.
	///
	/// This writes the library's own metadatabase, attached to the writer by the engine, so it depends
	/// on SQLiteData 1.13's layout (a schema named `sqlitedata_icloud`): a library update must keep
	/// `deleteFromICloudKeepsThisMacsRows` passing.
	private static func resetEngineState(_ writer: any DatabaseWriter) async throws {
		try await writer.writeAllowingSyncedDeletions { db in
			try resetEngineState(db)
		}
	}

	private static func resetEngineState(_ db: Database) throws {
		let tables: [String] = try String.fetchAll(
			db,
			sql: """
			SELECT "name" FROM "sqlitedata_icloud"."sqlite_master"
			WHERE "type" = 'table' AND "name" NOT GLOB 'sqlite_*' AND "name" != 'grdb_migrations'
			"""
		)
		for table in tables {
			try db.execute(sql: "DELETE FROM \"sqlitedata_icloud\".\"\(table)\"")
		}
	}
}

/// The rows a preferences repair reads, to tell whether they changed.
private struct PreferenceRowsSnapshot: Equatable, Sendable {
	var searchShortcuts: [SearchShortcutRecord]
	var keyboardShortcuts: [KeyboardShortcutRecord]

	init(_ db: Database) throws {
		self.searchShortcuts = try SearchShortcutRecord.order(by: \.id).fetchAll(db)
		self.keyboardShortcuts = try KeyboardShortcutRecord.order(by: \.id).fetchAll(db)
	}
}

// MARK: - Onboarding (DEV-1215)

extension WorkspaceSync {
	/// Whether this Mac is signed in to iCloud and the account can be read now, for onboarding's
	/// "Sync with iCloud" step, which is skipped otherwise.
	public func accountIsAvailable() async -> Bool {
		guard case .available = try? await cloud.account() else { return false }
		return true
	}

	/// Onboarding's "Sync with iCloud": turns sync on, then waits for each category that's on to
	/// fetch once and its repair pass to run, telling which one it's on. It ends with what iCloud
	/// had, or why it couldn't fetch. The app reloads its workspace on the remote changes the
	/// fetches publish as usual; cancelling the stream stops the waiting, never sync itself.
	///
	/// The app keeps its own starter out of the first upload while this runs (it's "this Mac
	/// only"), so a Mac whose account already has a workspace adopts it as it is.
	///
	/// - Parameters:
	///   - turningSyncOn: `false` for the wait onboarding keeps after Continue without
	///     waiting: sync is never turned on again, and `turnedOff` ends it when the person turned
	///     it off.
	public func joinFromOnboarding(turningSyncOn: Bool = true) -> AsyncStream<OnboardingSyncEvent> {
		let (stream, continuation) = AsyncStream<OnboardingSyncEvent>.makeStream()
		let task: Task<Void, Never> = Task { [weak self] in
			guard let self else {
				continuation.finish()
				return
			}

			await self.runOnboardingJoin(continuation, turningSyncOn: turningSyncOn)
			continuation.finish()
		}
		continuation.onTermination = { _ in task.cancel() }
		return stream
	}

	private func runOnboardingJoin(
		_ continuation: AsyncStream<OnboardingSyncEvent>.Continuation,
		turningSyncOn: Bool
	) async {
		guard turningSyncOn || settings.isEnabled else {
			continuation.yield(.turnedOff)
			return
		}

		// The person asked for sync: it's on even when iCloud can't be reached now, and starts
		// once it can.
		if turningSyncOn, settings.isEnabled, saveError == nil {
			// Try again with sync already on: start what didn't, as an account change does.
			await accountDidChange()
		} else if turningSyncOn {
			await setEnabled(true)
		}
		guard settings.isEnabled || !turningSyncOn else {
			continuation.yield(saveError.map(OnboardingSyncEvent.failed) ?? .unavailable)
			return
		}
		guard settings.isEnabled else {
			// Turned off meanwhile.
			continuation.yield(.turnedOff)
			return
		}
		guard await accountIsAvailable() else {
			continuation.yield(.unavailable)
			return
		}
		guard settings.isEnabled, saveError == nil, settings.review == nil else {
			continuation.yield(saveError.map(OnboardingSyncEvent.failed) ?? .unavailable)
			return
		}

		for category in availableCategories where settings.isOn(category) {
			guard !Task.isCancelled else { return }

			continuation.yield(.fetching(category))

			// A paused category (no account, quota) or one an account review holds fetched nothing.
			guard pauses[category] == nil, settings.review == nil, let engine = engines[category], engine.isRunning else {
				continuation.yield(.unavailable)
				return
			}

			do {
				try await engine.fetchChanges()
			} catch {
				continuation.yield(.failed(error.localizedDescription))
				return
			}
			pendingRepairs.insert(category)
			await repairIfFetched(category)
			if let error = errors[category] {
				continuation.yield(.failed(error))
				return
			}
		}
		guard !Task.isCancelled else { return }

		// The fetches suspend: sync may have been turned off or paused for an account review meanwhile.
		guard settings.isEnabled else {
			continuation.yield(.turnedOff)
			return
		}
		guard settings.review == nil else {
			continuation.yield(.unavailable)
			return
		}
		do {
			continuation.yield(.finished(try await onboardingResult()))
		} catch {
			// What arrived can't be read: not an empty iCloud.
			continuation.yield(.failed(error.localizedDescription))
		}
	}

	/// Whether iCloud's workspace landed here, and the space used last on any Mac.
	private func onboardingResult() async throws -> OnboardingSyncResult {
		guard let writer = writers[.organization] else { return .init(hasWorkspace: false) }

		return try await writer.read { db in
			let spaces: Set<UUID> = Set(try SpaceRecord.select(\.id).fetchAll(db))
			let profiles: Int = try ProfileRecord.count().fetchOne(db) ?? 0
			let used: [UUID] = try UsageRecord
				.where { $0.itemTable.eq(SpaceRecord.tableName) }
				.order { $0.lastUsed.desc() }
				.select(\.itemID)
				.fetchAll(db)
			return OnboardingSyncResult(
				hasWorkspace: profiles > 0 && !spaces.isEmpty,
				lastUsedSpaceID: used.first(where: spaces.contains)
			)
		}
	}
}
