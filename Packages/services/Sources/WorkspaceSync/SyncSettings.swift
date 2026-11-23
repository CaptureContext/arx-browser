import Foundation

/// What this Mac decided about iCloud sync. Device-local: it never syncs, and it lives in its own
/// file beside the workspace databases (``SyncSettingsStore``).
public struct SyncSettings: Codable, Equatable, Sendable {
	/// The overall toggle. Off pauses every category and keeps both copies.
	public var isEnabled: Bool

	/// Categories the person turned off, of those on by default (ADR 0001, section 3).
	public var disabledCategories: Set<SyncCategory>

	/// Categories the person turned on, of those off by default: History (DEV-984).
	public var enabledCategories: Set<SyncCategory>

	/// How many days of visits History sync mirrors (ADR 0001, decision 5).
	public var historyWindowDays: Int

	/// Categories whose `SyncEngine` has started on this Mac at least once. Their engines are made at
	/// every launch while the flag is on, even when paused, so edits made while paused are sent on
	/// resume.
	public var startedCategories: Set<SyncCategory>

	/// The iCloud account (its user record name) this Mac's data is connected to; `nil` until sync
	/// first starts, or after Keep on This Mac.
	public var account: String?

	/// Set when the account went away or changed: sync stays paused until the person decides.
	public var review: AccountReview?

	/// Categories deleted from iCloud whose engine state hasn't been forgotten yet. They can't start
	/// until it is, or the engine would apply the zone's deletion to this Mac's rows.
	public var pendingResets: Set<SyncCategory>

	/// Categories Replace with the Account's Data couldn't reach because their database didn't open
	/// that run. They're replaced before they next start, so the account never gets their old rows.
	public var pendingReplacements: Set<SyncCategory>

	/// This Mac's own starter profiles when sync first started, which the repair pass may drop in
	/// favor of an identical starter profile from iCloud (ADR 0001, section 7).
	public var starterProfileIDs: Set<UUID>

	/// Starter profiles of this Mac's that the first merge found a copy of from iCloud and emptied,
	/// until the app has offered to remove them (DEV-989).
	public var duplicateStarterProfileIDs: Set<UUID>

	/// "Sync deletions after": an item deleted on a Mac and used by none for this many days goes
	/// from every Mac (DEV-980). `nil`, the default, keeps a deletion on the Mac that made it until
	/// every Mac deletes the item.
	public var syncDeletionsAfterDays: Int?

	/// "Stop syncing this Mac" (DEV-979): this Mac left every category, and turning sync on again
	/// rejoins, merging its rows with iCloud's as a new member rather than sending what it queued.
	public var isStopped: Bool

	/// The stop isn't in the device directory in iCloud yet, as when this Mac was offline: it's sent
	/// the next time the account is reachable, even with sync off.
	public var stopIsUnpublished: Bool

	/// Categories rejoining after a stop whose engine state and other Macs' coordination rows are
	/// still to be forgotten before they start (``SyncSettings/isStopped``).
	public var pendingRejoins: Set<SyncCategory>

	/// The account the device directory's rows and engine state belong to. When it isn't
	/// ``account``, the directory is cleared and fetched again before it runs, so one account's Macs
	/// never show or upload under another.
	public var directoryAccount: String?

	/// Categories this Mac left by turning them off (DEV-1148, ``SyncCategory/leavesWhenTurnedOff``),
	/// while they're off: the device directory says so, and the other Macs' purges leave this Mac
	/// out of them.
	public var leftCategories: Set<SyncCategory>

	/// Leaves the device directory in iCloud doesn't have yet, as when this Mac was offline: sent the
	/// next time the account is reachable, even with sync off.
	public var unpublishedLeaves: Set<SyncCategory>

	/// Categories turned on again after a leave whose rows this Mac kept are still to be merged with
	/// iCloud's: a copy taken before the engine resumes brings back what purges deleted meanwhile.
	public var pendingMerges: Set<SyncCategory>

	/// The period "sync deletions after" uses when it's turned on.
	public static let defaultSyncDeletionsAfterDays: Int = 30

	/// The History sync window unless the person picks another.
	public static let defaultHistoryWindowDays: Int = 30

	/// The windows Settings offers, in days.
	public static let historyWindowChoices: [Int] = [7, 30, 90, 365]

	public init(
		isEnabled: Bool = false,
		disabledCategories: Set<SyncCategory> = [],
		enabledCategories: Set<SyncCategory> = [],
		historyWindowDays: Int = Self.defaultHistoryWindowDays,
		startedCategories: Set<SyncCategory> = [],
		account: String? = nil,
		review: AccountReview? = nil,
		pendingResets: Set<SyncCategory> = [],
		pendingReplacements: Set<SyncCategory> = [],
		starterProfileIDs: Set<UUID> = [],
		duplicateStarterProfileIDs: Set<UUID> = [],
		syncDeletionsAfterDays: Int? = nil,
		isStopped: Bool = false,
		stopIsUnpublished: Bool = false,
		pendingRejoins: Set<SyncCategory> = [],
		directoryAccount: String? = nil,
		leftCategories: Set<SyncCategory> = [],
		unpublishedLeaves: Set<SyncCategory> = [],
		pendingMerges: Set<SyncCategory> = []
	) {
		self.isEnabled = isEnabled
		self.disabledCategories = disabledCategories
		self.enabledCategories = enabledCategories
		self.historyWindowDays = historyWindowDays
		self.startedCategories = startedCategories
		self.account = account
		self.review = review
		self.pendingResets = pendingResets
		self.pendingReplacements = pendingReplacements
		self.starterProfileIDs = starterProfileIDs
		self.duplicateStarterProfileIDs = duplicateStarterProfileIDs
		self.syncDeletionsAfterDays = syncDeletionsAfterDays
		self.isStopped = isStopped
		self.stopIsUnpublished = stopIsUnpublished
		self.pendingRejoins = pendingRejoins
		self.directoryAccount = directoryAccount
		self.leftCategories = leftCategories
		self.unpublishedLeaves = unpublishedLeaves
		self.pendingMerges = pendingMerges
	}

	public init(from decoder: any Decoder) throws {
		let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
			disabledCategories: try container.decode(Set<SyncCategory>.self, forKey: .disabledCategories),
			enabledCategories: try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .enabledCategories) ?? [],
			historyWindowDays: try container.decodeIfPresent(Int.self, forKey: .historyWindowDays)
				.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultHistoryWindowDays,
			startedCategories: try container.decode(Set<SyncCategory>.self, forKey: .startedCategories),
			account: try container.decodeIfPresent(String.self, forKey: .account),
			review: try container.decodeIfPresent(AccountReview.self, forKey: .review),
			pendingResets: try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .pendingResets) ?? [],
			pendingReplacements: try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .pendingReplacements) ?? [],
			starterProfileIDs: try container.decode(Set<UUID>.self, forKey: .starterProfileIDs),
			duplicateStarterProfileIDs: try container.decodeIfPresent(
				Set<UUID>.self,
				forKey: .duplicateStarterProfileIDs
			) ?? [],
			syncDeletionsAfterDays: try container.decodeIfPresent(Int.self, forKey: .syncDeletionsAfterDays),
			isStopped: try container.decodeIfPresent(Bool.self, forKey: .isStopped) ?? false,
			stopIsUnpublished: try container.decodeIfPresent(Bool.self, forKey: .stopIsUnpublished) ?? false,
			pendingRejoins: try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .pendingRejoins) ?? [],
			directoryAccount: try container.decodeIfPresent(String.self, forKey: .directoryAccount),
			leftCategories: try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .leftCategories) ?? [],
			unpublishedLeaves: try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .unpublishedLeaves) ?? [],
			pendingMerges: try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .pendingMerges) ?? []
		)
	}

	/// Whether the category should be syncing, ignoring the account.
	public func isOn(_ category: SyncCategory) -> Bool {
		isEnabled && isChosen(category)
	}

	/// Whether the category's own toggle is on, whatever the overall toggle.
	public func isChosen(_ category: SyncCategory) -> Bool {
		category.isOnByDefault ? !disabledCategories.contains(category) : enabledCategories.contains(category)
	}

	/// Turns the category's own toggle on or off.
	public mutating func choose(
		_ category: SyncCategory,
		_ isOn: Bool
	) {
		if category.isOnByDefault {
			if isOn {
				disabledCategories.remove(category)
			} else {
				disabledCategories.insert(category)
			}
		} else {
			if isOn {
				enabledCategories.insert(category)
			} else {
				enabledCategories.remove(category)
			}
		}
	}
}

/// Why sync is waiting for the person before it connects this Mac's data to an account.
public enum AccountReview: String, Codable, Hashable, Sendable {
	/// Signed out of iCloud. Signing in to the same account resumes without asking.
	case signedOut

	/// A different iCloud account is signed in than the one this Mac's data is connected to.
	case accountChanged
}

/// The person's answer to an ``AccountReview`` (ADR 0001, section 8).
public enum AccountDecision: Hashable, Sendable {
	/// Connect this Mac's data to the signed-in account and upload it there.
	case useWithThisAccount

	/// Leave sync off. Local data stays as it is.
	case keepOnThisMac

	/// Back up this Mac's synced data, delete it here, and download the signed-in account's.
	case replaceWithAccountData
}

/// Reads and writes ``SyncSettings`` as JSON, replacing the file atomically.
public struct SyncSettingsStore: Sendable {
	public static let fileName: String = "arx-icloud-sync.json"

	public let file: URL

	public init(directory: URL) {
		self.file = directory.appendingPathComponent(Self.fileName)
	}

	/// The saved settings, or the defaults when there's no file yet.
	public func load() throws -> SyncSettings {
		guard FileManager.default.fileExists(atPath: file.path) else { return .init() }

		return try JSONDecoder().decode(SyncSettings.self, from: Data(contentsOf: file))
	}

	public func save(_ settings: SyncSettings) throws {
		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(settings).write(to: file, options: .atomic)
	}
}
