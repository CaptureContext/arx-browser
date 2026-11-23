import Foundation
import WorkspaceDatabase

/// What Settings › iCloud Sync shows.
public struct WorkspaceSyncStatus: Equatable, Sendable {
	public var isEnabled: Bool
	public var categories: [SyncCategory: CategoryStatus]

	/// The categories this run can sync, in the order Settings lists them.
	public var availableCategories: [SyncCategory]

	/// How many days of visits History sync mirrors.
	public var historyWindowDays: Int
	public var review: AccountReview?

	/// An account decision is running.
	public var isResolving: Bool

	/// Why the last account decision failed; the review stays open.
	public var resolutionError: String?

	/// Why the settings couldn't be saved. Shown even with sync off: a toggle that didn't save would
	/// be back on at the next launch.
	public var saveError: String?

	/// ``SyncSettings/syncDeletionsAfterDays``.
	public var syncDeletionsAfterDays: Int?

	/// The Preferences groups kept on this Mac (DEV-982). They stay so while the Preferences category
	/// is off too.
	public var localPreferenceGroups: Set<PreferenceGroup>

	/// The Macs in the device directory, this one first (DEV-979).
	public var devices: [SyncDevice]

	/// "Stop syncing this Mac" was chosen: turning sync on rejoins.
	public var isStopped: Bool

	/// "Stop syncing this Mac" is running.
	public var isStopping: Bool

	/// "Stop syncing this Mac" applies: this Mac is connected to an account and hasn't stopped. Sync
	/// may be off, so a paused Mac can leave without sending what it queued.
	public var canStopSyncing: Bool

	/// A merge waiting for the person's answer, with what it does (DEV-1216).
	public var mergePreview: MergePreview?

	/// Synced profiles with the same name, which Settings offers to merge (DEV-1216).
	public var duplicateProfiles: [DuplicateProfiles]

	/// A merge is running.
	public var isMerging: Bool

	/// Why the last merge failed; nothing changed.
	public var mergeError: String?

	/// Profiles and spaces another Mac removed from iCloud that "sync deletions after" deletes here,
	/// by ID (DEV-1336).
	public var deletionMarks: [UUID: WorkspaceRepair.DeletionMark]

	public init(
		isEnabled: Bool = false,
		categories: [SyncCategory: CategoryStatus] = [:],
		availableCategories: [SyncCategory] = SyncCategory.allCases,
		historyWindowDays: Int = SyncSettings.defaultHistoryWindowDays,
		review: AccountReview? = nil,
		isResolving: Bool = false,
		resolutionError: String? = nil,
		saveError: String? = nil,
		syncDeletionsAfterDays: Int? = nil,
		localPreferenceGroups: Set<PreferenceGroup> = [],
		devices: [SyncDevice] = [],
		isStopped: Bool = false,
		isStopping: Bool = false,
		canStopSyncing: Bool = false,
		mergePreview: MergePreview? = nil,
		duplicateProfiles: [DuplicateProfiles] = [],
		isMerging: Bool = false,
		mergeError: String? = nil,
		deletionMarks: [UUID: WorkspaceRepair.DeletionMark] = [:]
	) {
		self.isEnabled = isEnabled
		self.categories = categories
		self.availableCategories = availableCategories
		self.historyWindowDays = historyWindowDays
		self.review = review
		self.isResolving = isResolving
		self.resolutionError = resolutionError
		self.saveError = saveError
		self.syncDeletionsAfterDays = syncDeletionsAfterDays
		self.localPreferenceGroups = localPreferenceGroups
		self.devices = devices
		self.isStopped = isStopped
		self.isStopping = isStopping
		self.canStopSyncing = canStopSyncing
		self.mergePreview = mergePreview
		self.duplicateProfiles = duplicateProfiles
		self.isMerging = isMerging
		self.mergeError = mergeError
		self.deletionMarks = deletionMarks
	}

	/// Whether removing a synced profile or space asks whether to delete it from this Mac only or
	/// remove it from iCloud (DEV-1336): Profiles and spaces sync here and on another Mac seen in the
	/// last 30 days that hasn't left them.
	public func asksWhereToRemove(now: Date) -> Bool {
		guard isEnabled, self[.organization] != .off else { return false }

		let seen: Date = now.addingTimeInterval(-WorkspaceRepair.DeletionPolicy.deviceExpiry)
		return devices(syncing: .organization).contains { device in
			!device.isThisMac && device.lastSeen >= seen && !device.leftCategories.contains(.organization)
		}
	}

	/// The name of the Mac with this device ID, from the device directory.
	public func deviceName(_ id: UUID) -> String? {
		devices.first { $0.id == id }?.name
	}

	/// The Macs syncing `category`, this one first, leaving out stopped ones.
	public func devices(syncing category: SyncCategory) -> [SyncDevice] {
		devices.filter { $0.stoppedAt == nil && $0.categories.contains(category) }
	}

	/// Whether the toggle shows on: a category that isn't off, a Preferences group that syncs. A group
	/// syncs only while the Preferences category does.
	public func isOn(_ toggle: SyncToggle) -> Bool {
		switch toggle {
		case let .category(category): self[category] != .off
		case let .preferenceGroup(group): !localPreferenceGroups.contains(group)
		}
	}

	public subscript(_ category: SyncCategory) -> CategoryStatus {
		categories[category] ?? .off
	}

	/// One line for the whole section: the most pressing of the categories' states.
	public var overall: CategoryStatus {
		if let saveError { return .error(saveError) }
		guard isEnabled else { return .off }
		switch review {
		case .signedOut: return .paused(.noAccount)
		case .accountChanged: return .accountChanged
		case nil: break
		}

		let states: [CategoryStatus] = SyncCategory.allCases.map { self[$0] }
		if let error = states.first(where: \.isError) { return error }
		if let paused = states.first(where: \.isPaused) { return paused }
		if states.contains(.syncing) { return .syncing }
		if states.contains(.synced) { return .synced }
		return .off
	}
}

/// One category's state.
public enum CategoryStatus: Equatable, Sendable {
	case off

	/// Running, with nothing being sent or fetched. SQLiteData doesn't report a failed background
	/// send or fetch, so this doesn't claim everything arrived: Settings says "On".
	case synced
	case syncing
	case paused(PauseReason)

	/// Waiting for the person's ``AccountDecision``.
	case accountChanged

	/// The last start, send or fetch failed; the text is for the person to read.
	case error(String)

	/// iCloud refused this many rows a send tried (DEV-1209): they stay on this Mac and are sent again
	/// at the next start. A container without Arx's record types refuses every save.
	case refused(Int)

	public var isError: Bool {
		switch self {
		case .error, .refused: true
		default: false
		}
	}

	public var isPaused: Bool {
		if case .paused = self { return true }
		return false
	}
}

public enum PauseReason: Equatable, Sendable {
	/// No iCloud account is signed in.
	case noAccount

	/// The account is restricted, or iCloud can't say right now.
	case accountUnavailable

	/// The person's iCloud storage is full.
	case quotaExceeded

	/// Turning sync on waits for the person to look at what merges (DEV-1216).
	case mergeReview
}

/// A merge the person sees before it happens (DEV-1216).
public struct MergePreview: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		/// Turning sync on for a Mac with its own workspace: nothing uploads until it's answered, and
		/// Cancel turns sync off again.
		case joining

		/// Synced profiles of the same name, from Settings.
		case profiles
	}

	public var kind: Kind
	public var plan: WorkspaceMerge.Plan

	public init(
		kind: Kind,
		plan: WorkspaceMerge.Plan
	) {
		self.kind = kind
		self.plan = plan
	}
}

/// Synced profiles with the same name, ignoring case and spaces (DEV-1216).
public struct DuplicateProfiles: Equatable, Identifiable, Sendable {
	/// The profile the others merge into: the first in the profile switcher.
	public var id: UUID { profileIDs[0] }

	public var name: String

	/// In the profile switcher's order, at least two.
	public var profileIDs: [UUID]

	public init(
		name: String,
		profileIDs: [UUID]
	) {
		self.name = name
		self.profileIDs = profileIDs
	}
}
