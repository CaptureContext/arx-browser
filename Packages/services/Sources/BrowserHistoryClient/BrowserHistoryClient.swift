import BrowserCore
import Foundation
import HistoryDatabase
import _Dependencies

public struct BrowserHistoryClient: Sendable {
	public struct Outcome: Equatable, Sendable {
		public var snapshot: BrowsingHistorySnapshot
		public var failure: Failure?

		public init(
			snapshot: BrowsingHistorySnapshot,
			failure: Failure? = nil
		) {
			self.snapshot = snapshot
			self.failure = failure
		}
	}

	public enum Failure: Error, Equatable, Sendable {
		case unavailable
		case corrupt
		case futureVersion
		case changedOnDisk
		case writeFailed
	}

	public var isAvailable: Bool
	public var load: @Sendable (Profile.ID) async throws -> Outcome

	/// Records a page view: a new one counts as a visit, and a typed one as a typed visit too.
	public var record: @Sendable (Profile.ID, BrowsingVisit) async throws -> Outcome

	/// Adds imported entries and writes at once. A URL keeps one entry, its newest visit and
	/// the larger visit and typed counts; the given entry IDs are ignored.
	public var merge: @Sendable (Profile.ID, [BrowsingHistoryEntry]) async throws -> Outcome
	public var clear: @Sendable (Profile.ID) async throws -> Outcome

	/// Removes entries last visited at or after a moment, and writes at once.
	public var clearSince: @Sendable (Profile.ID, Date) async throws -> Outcome

	/// Removes chosen entries or a whole site last visited at or before the given moment, when
	/// the removal was asked for, and writes at once: Delete from History in the command bar,
	/// and the Library's History page. A visit after that moment stays.
	public var removeEntries: @Sendable (Profile.ID, BrowsingHistoryRemoval, Date) async throws -> Outcome
	public var retry: @Sendable (Profile.ID) async throws -> Outcome
	public var remove: @Sendable (Profile.ID) async throws -> Void

	/// Writes any throttled history immediately. Call before the process exits.
	public var flush: @Sendable () async -> Void

	/// Takes what other Macs mirrored and cleared with iCloud sync into these profiles' history
	/// (DEV-984), and answers for each profile whose history changed.
	public var applySynced: @Sendable (Set<Profile.ID>) async -> [Outcome]

	/// The "this Mac only" profiles and the profiles that sync (DEV-981): the former's history never
	/// syncs either way; one of them turned back on, among the latter, mirrors its history again.
	public var setLocalProfiles: @Sendable (ProfileSync) async -> Void

	/// A profile merged into another with iCloud sync (DEV-1216): its history here moves to the kept
	/// profile, whose next ``applySynced`` answer shows it.
	public var moveProfile: @Sendable (_ merged: Profile.ID, _ kept: Profile.ID) async -> Void

	public init(
		isAvailable: Bool = true,
		load: @escaping @Sendable (Profile.ID) async throws -> Outcome = { .init(snapshot: .init(profileID: $0)) },
		record: @escaping @Sendable (Profile.ID, BrowsingVisit) async throws -> Outcome = { profile, _ in
			.init(snapshot: .init(profileID: profile))
		},
		merge: @escaping @Sendable (Profile.ID, [BrowsingHistoryEntry]) async throws -> Outcome = { profile, _ in
			.init(snapshot: .init(profileID: profile))
		},
		clear: @escaping @Sendable (Profile.ID) async throws -> Outcome = { .init(snapshot: .init(profileID: $0)) },
		clearSince: @escaping @Sendable (Profile.ID, Date) async throws -> Outcome = { profile, _ in
			.init(snapshot: .init(profileID: profile))
		},
		removeEntries: @escaping @Sendable (Profile.ID, BrowsingHistoryRemoval, Date) async throws -> Outcome = { profile, _, _ in
			.init(snapshot: .init(profileID: profile))
		},
		retry: @escaping @Sendable (Profile.ID) async throws -> Outcome = { .init(snapshot: .init(profileID: $0)) },
		remove: @escaping @Sendable (Profile.ID) async throws -> Void = { _ in },
		flush: @escaping @Sendable () async -> Void = {},
		applySynced: @escaping @Sendable (Set<Profile.ID>) async -> [Outcome] = { _ in [] },
		setLocalProfiles: @escaping @Sendable (ProfileSync) async -> Void = { _ in },
		moveProfile: @escaping @Sendable (_ merged: Profile.ID, _ kept: Profile.ID) async -> Void = { _, _ in }
	) {
		self.isAvailable = isAvailable
		self.load = load
		self.record = record
		self.merge = merge
		self.clear = clear
		self.clearSince = clearSince
		self.removeEntries = removeEntries
		self.retry = retry
		self.remove = remove
		self.flush = flush
		self.applySynced = applySynced
		self.setLocalProfiles = setLocalProfiles
		self.moveProfile = moveProfile
	}

	/// The per-profile JSON files in `directory`.
	public static func local(directory: URL) -> Self {
		BrowserHistoryStore(directory: directory).client
	}

	/// `arx-history.sqlite` (DEV-984), moving each profile's JSON file from `legacyDirectory` in the
	/// first time it's read.
	///
	/// - Parameters:
	///   - localProfiles: the "this Mac only" profiles now, or `nil` while the app can't say
	///     yet (DEV-981).
	public static func database(
		_ history: HistoryDatabase,
		legacyDirectory: URL,
		localProfiles: @escaping @Sendable () -> ProfileSync? = { nil }
	) -> Self {
		BrowserHistoryDatabaseStore(history: history, legacyDirectory: legacyDirectory, localProfiles: localProfiles).client
	}
}

extension BrowserHistoryClient: DependencyKey {
	public static var liveValue: Self { .init(isAvailable: false) }
	public static var testValue: Self { .init(isAvailable: false) }
	public static var previewValue: Self { .init(isAvailable: false) }
}

extension DependencyValues {
	public var browserHistory: BrowserHistoryClient {
		get { self[BrowserHistoryClient.self] }
		set { self[BrowserHistoryClient.self] = newValue }
	}
}

/// Which profiles sync with iCloud, as the history store needs it (DEV-981).
public struct ProfileSync: Equatable, Sendable {
	/// "This Mac only" profiles.
	public var local: Set<Profile.ID>

	/// Every other profile in the workspace.
	public var syncing: Set<Profile.ID>

	public init(
		local: Set<Profile.ID>,
		syncing: Set<Profile.ID>
	) {
		self.local = local
		self.syncing = syncing
	}

	public init(_ organization: BrowserOrganization) {
		self.init(
			local: Set(organization.profiles.filter(\.isThisMacOnly).map(\.id)),
			syncing: Set(organization.profiles.filter { !$0.isThisMacOnly }.map(\.id))
		)
	}
}
