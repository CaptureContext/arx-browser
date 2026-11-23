import BrowserCore
import Foundation
import _SQLiteData

/// The workspace in SQLite (ADR 0001, phase 1): the organization database and the preferences
/// database, beside the JSON workspace file.
///
/// One connection opens the organization file and attaches the preferences file, in SQLite's rollback
/// journal mode, so every write to both is one transaction that commits atomically across the two
/// files. Writes are diffs against the rows this store last wrote: only rows that changed are written.
///
/// Callers serialize access, as `BrowserWorkspaceClient` does under its lock.
///
/// With iCloud sync (`separatePreferencesConnection`), preference rows are written through
/// ``preferencesDatabase``, the preferences file's own connection, because the Preferences
/// `SyncEngine` sees only writes made on the connection it was made on; the attached copy is then
/// only read. A save writes the preferences file first, then the organization file, each in its own
/// transaction. One cut short between the two leaves the preferences file one revision ahead,
/// which a load accepts as that save's preferences with the previous save's organization.
public final class WorkspaceDatabase: @unchecked Sendable {
	public static let organizationFileName: String = "arx-organization.sqlite"
	public static let preferencesFileName: String = "arx-preferences.sqlite"

	/// Tab Archive's file, so it can sync on its own (DEV-983).
	public static let archiveFileName: String = "arx-archive.sqlite"

	/// "This Mac only" profiles' file, which never syncs (DEV-981).
	public static let localFileName: String = "arx-organization-local.sqlite"

	/// Held for a whole save, so saves from different processes never interleave (DEV-1005).
	public static let lockFileName: String = "arx-workspace.lock"

	/// Both databases, their rollback journals and the save lock in `directory`: files nothing else
	/// may replace. A lock file replaced while a save holds it would let another save run alongside.
	public static func files(in directory: URL) -> [URL] {
		[organizationFileName, preferencesFileName, archiveFileName, localFileName].flatMap { name in
			[directory.appendingPathComponent(name), directory.appendingPathComponent("\(name)-journal")]
		}
		+ [directory.appendingPathComponent(lockFileName)]
	}

	/// What the store holds.
	public struct Snapshot: Equatable, Sendable {
		public var organization: BrowserOrganization
		public var preferences: BrowserPreferences

		/// The JSON snapshot version it was migrated from, or `nil` when it started empty.
		public var migratedFromWorkspaceVersion: Int?

		public init(
			organization: BrowserOrganization,
			preferences: BrowserPreferences,
			migratedFromWorkspaceVersion: Int?
		) {
			self.organization = organization
			self.preferences = preferences
			self.migratedFromWorkspaceVersion = migratedFromWorkspaceVersion
		}
	}

	/// How many rows one write upserted and deleted, by table.
	public struct WriteSummary: Equatable, Sendable {
		public var upserted: [String: Int]
		public var deleted: [String: Int]

		public init(
			upserted: [String: Int] = [:],
			deleted: [String: Int] = [:]
		) {
			self.upserted = upserted
			self.deleted = deleted
		}

		public var rowCount: Int {
			upserted.values.reduce(0, +) + deleted.values.reduce(0, +)
		}
	}

	public enum Failure: Error, Equatable, Sendable {
		/// The store already holds a workspace, so it can't be migrated into again.
		case alreadyInitialized

		/// Another writer changed the store since this one last read or wrote it.
		case changedOnDisk

		/// The two databases don't hold the same workspace, as after one file was lost, or restored
		/// or replaced alone. Nothing is read from or migrated over it; it needs recovery by hand.
		case partialStore
	}

	/// What a folder's database files hold, read without opening them for writing.
	public enum Contents: Equatable, Sendable {
		/// No files, or files without a workspace yet.
		case empty

		/// At least one file records a written workspace.
		case workspace

		/// A file is there but can't be read.
		case unreadable
	}

	/// What `directory`'s database files hold. Never creates or changes a file.
	public static func contents(of directory: URL) -> Contents {
		let checks: [(name: String, table: String)] = [
			(organizationFileName, StoreInfoRecord.tableName),
			(preferencesFileName, PreferenceStoreInfoRecord.tableName),
		]
		var result: Contents = .empty
		for check in checks {
			let path: String = directory.appendingPathComponent(check.name).path
			guard FileManager.default.fileExists(atPath: path) else { continue }

			do {
				var configuration: Configuration = .init()
				configuration.readonly = true
				let queue: DatabaseQueue = try .init(path: path, configuration: configuration)
				let hasRevision: Bool = try queue.read { db in
					guard try db.tableExists(check.table) else { return false }

					// A first save cut short between the files left nothing saved in full.
					return try Bool.fetchOne(
						db,
						sql: """
							SELECT EXISTS (SELECT 1 FROM "\(check.table)" WHERE "id" = ?)
							AND NOT EXISTS (SELECT 1 FROM "\(check.table)" WHERE "id" = ?)
							""",
						arguments: [StoreInfoKey.revision, StoreInfoKey.unfinishedFirstWrite]
					) ?? false
				}
				try queue.close()
				if hasRevision { return .workspace }
			} catch {
				result = .unreadable
			}
		}
		return result
	}

	/// The organization database, with the preferences database attached as `preferences`.
	public let database: DatabaseQueue

	/// The preferences file's own connection, when preference rows are written through it (iCloud
	/// sync); `nil` when they're written through the attached copy.
	public let preferencesDatabase: DatabaseQueue?

	/// The Tab Archive file's own connection, when its rows are written through it (iCloud sync),
	/// as for ``preferencesDatabase``; `nil` when they're written through the attached copy, `archive`.
	public let archiveDatabase: DatabaseQueue?
	public let organizationFile: URL
	public let preferencesFile: URL
	public let archiveFile: URL
	public let localFile: URL
	private let lockFile: URL
	private let lock: NSLock = .init()
	private var cache: Cache?

	/// The last load found no workspace, so a write must find none either.
	private var loadedEmpty: Bool = false

	/// What ``recordUse(of:now:)`` recorded today, so opening it again today doesn't write.
	private var recordedToday: (day: Double, ids: Set<UUID>) = (0, [])

	/// Profiles and spaces whose next removal stays on this Mac (``keepRemovalOnThisMac(_:)``).
	private var keptElsewhere: Set<UUID> = []

	private struct Cache {
		internal var organizationRows: OrganizationRows
		internal var preferenceRows: PreferenceRows
		internal var organization: BrowserOrganization
		internal var preferences: BrowserPreferences
		internal var revision: Int
	}

	/// Opens or creates both databases in `directory` and runs their migrations.
	///
	/// - Parameters:
	///   - separatePreferencesConnection: write preference rows through their own connection,
	///     ``preferencesDatabase``, for the Preferences sync engine. Off, one transaction covers both files.
	public init(
		directory: URL,
		separatePreferencesConnection: Bool = false
	) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		self.organizationFile = directory.appendingPathComponent(Self.organizationFileName)
		self.preferencesFile = directory.appendingPathComponent(Self.preferencesFileName)
		self.archiveFile = directory.appendingPathComponent(Self.archiveFileName)
		self.localFile = directory.appendingPathComponent(Self.localFileName)
		self.lockFile = directory.appendingPathComponent(Self.lockFileName)

		var preferencesConfiguration: Configuration = .init()
		preferencesConfiguration.busyMode = .timeout(10)
		preferencesConfiguration.prepareDatabase { db in
			try db.execute(sql: "PRAGMA synchronous = FULL")
		}
		let preferences: DatabaseQueue = try .init(
			path: preferencesFile.path,
			configuration: preferencesConfiguration
		)
		try WorkspaceSchema.preferencesMigrator().migrate(preferences)
		if separatePreferencesConnection {
			self.preferencesDatabase = preferences
		} else {
			try preferences.close()
			self.preferencesDatabase = nil
		}

		let archive: DatabaseQueue = try .init(path: archiveFile.path, configuration: preferencesConfiguration)
		try WorkspaceSchema.archiveMigrator().migrate(archive)

		// The local file has the organization's schema and no engine; it's only ever written attached.
		let local: DatabaseQueue = try .init(path: localFile.path, configuration: preferencesConfiguration)
		try WorkspaceSchema.organizationMigrator().migrate(local)
		try local.close()

		let preferencesPath: String = preferencesFile.path
		let archivePath: String = archiveFile.path
		let localPath: String = localFile.path
		var configuration: Configuration = .init()
		configuration.busyMode = .timeout(10)
		configuration.prepareDatabase { db in
			try db.execute(sql: "PRAGMA synchronous = FULL")
			try db.execute(sql: "ATTACH DATABASE ? AS preferences", arguments: [preferencesPath])
			try db.execute(sql: "PRAGMA preferences.synchronous = FULL")
			try db.execute(sql: "ATTACH DATABASE ? AS archive", arguments: [archivePath])
			try db.execute(sql: "PRAGMA archive.synchronous = FULL")
			try db.execute(sql: "ATTACH DATABASE ? AS local", arguments: [localPath])
			try db.execute(sql: "PRAGMA local.synchronous = FULL")
		}
		self.database = try .init(path: organizationFile.path, configuration: configuration)
		try WorkspaceSchema.organizationMigrator().migrate(database)

		// Another process opening the same folder for the first time pairs the files too.
		let database: DatabaseQueue = self.database
		try Self.withLockFile(at: lockFile) {
			try Self.pair(database, archive: archive)
			try Self.pairLocal(database)
			try Self.moveArchiveOut(of: database, into: archive)
		}
		if separatePreferencesConnection {
			self.archiveDatabase = archive
		} else {
			try archive.close()
			self.archiveDatabase = nil
		}
	}

	/// Pairs the organization file with the archive file by an ID both keep (DEV-983), the first time
	/// they're opened together.
	///
	/// - Throws: ``Failure/partialStore`` when the organization file was paired with an archive file
	///   that isn't this one, as after the archive file was lost, restored or replaced alone.
	private static func pair(
		_ database: DatabaseQueue,
		archive: DatabaseQueue
	) throws {
		let paired: String? = try database.read { db in
			try StoreInfoRecord.find(StoreInfoKey.archiveFileID).fetchOne(db)?.value
		}
		let fileID: String? = try archive.read { db in
			try ArchiveStateRecord.find(ArchiveStateKey.fileID).fetchOne(db)?.value
		}
		if let paired {
			guard paired == fileID else { throw Failure.partialStore }

			return
		}

		let id: String = fileID ?? UUID().uuidString.lowercased()
		if fileID == nil {
			try archive.writeAllowingSyncedDeletions { db in
				try ArchiveStateRecord.upsert { ArchiveStateRecord(id: ArchiveStateKey.fileID, value: id) }.execute(db)
			}
		}
		try database.writeAllowingSyncedDeletions { db in
			try StoreInfoRecord.upsert { StoreInfoRecord(id: StoreInfoKey.archiveFileID, value: id) }.execute(db)
		}
	}

	/// Pairs the organization file with the local file by an ID both keep (DEV-981), as ``pair(_:archive:)``.
	///
	/// - Throws: ``Failure/partialStore`` when the organization file was paired with a local file that
	///   isn't this one: "this Mac only" profiles mustn't silently fall back to their synced copies.
	private static func pairLocal(_ database: DatabaseQueue) throws {
		try database.writeAllowingSyncedDeletions { db in
			let paired: String? = try StoreInfoRecord.find(StoreInfoKey.localFileID).fetchOne(db)?.value
			let fileID: String? = try LocalStoreInfoRecord.find(StoreInfoKey.localFileID).fetchOne(db)?.value
			if let paired {
				guard paired == fileID else { throw Failure.partialStore }

				return
			}

			let id: String = fileID ?? UUID().uuidString.lowercased()
			try LocalStoreInfoRecord.upsert { LocalStoreInfoRecord(id: StoreInfoKey.localFileID, value: id) }.execute(db)
			try StoreInfoRecord.upsert { StoreInfoRecord(id: StoreInfoKey.localFileID, value: id) }.execute(db)

			// A store from before has a revision already: the local file takes it, so from now on the two
			// must agree.
			if let revision = try StoreInfoRecord.find(StoreInfoKey.revision).fetchOne(db) {
				try LocalStoreInfoRecord.upsert { LocalStoreInfoRecord(id: StoreInfoKey.revision, value: revision.value) }.execute(db)
			}
		}
	}

	/// Moves Tab Archive's entries from the organization file, where phase 1 kept them as JSON, into
	/// the archive file (DEV-983). Through the archive's own connection, as its sync engine needs, and
	/// safe to repeat: an entry the archive has already isn't added again.
	private static func moveArchiveOut(
		of database: DatabaseQueue,
		into archive: DatabaseQueue
	) throws {
		// The archive file isn't attached under this name, so `archivedTab` is the organization file's.
		let rows: [ArchivedTabRecord] = try database.read { db in try ArchivedTabRecord.all.fetchAll(db) }
		guard !rows.isEmpty else { return }

		try archive.writeAllowingSyncedDeletions { db in
			let existing: Set<UUID> = Set(try ArchiveEntryRecord.select(\.id).fetchAll(db))
			let entries: [ArchiveEntryRecord] = try rows.filter { !existing.contains($0.id) }.map { row in
				ArchiveEntryRecord(try JSONColumn.decode(ArchivedTab.self, from: row.value), position: row.position)
			}
			for batch in stride(from: 0, to: entries.count, by: 200) {
				let chunk: [ArchiveEntryRecord] = Array(entries[batch ..< min(batch + 200, entries.count)])
				try ArchiveEntryRecord.insert { chunk }.execute(db)
			}
		}
		try database.writeAllowingSyncedDeletions { db in
			try ArchivedTabRecord.delete().execute(db)
		}
	}

	// MARK: - Reading

	/// Whether the store holds a workspace, migrated or written by a first save.
	public var isInitialized: Bool {
		get throws {
			try database.read { db in
				try StoreInfoRecord.find(StoreInfoKey.revision).fetchOne(db) != nil
			}
		}
	}

	/// The stored workspace, or `nil` when the store has none yet.
	///
	/// - Parameters:
	///   - validate: the caller's check, run before the workspace becomes the base later
	///     writes are diffed against. When it throws, that base stays as it was.
	/// - Throws: ``Failure/partialStore`` when only one of the two databases holds a workspace.
	public func load(
		validate: (Snapshot) throws -> Void = { _ in }
	) throws -> Snapshot? {
		try lock.withLock {
			// Another process's save could apply, and then supersede, the same pending archive change.
			let (organizationRows, preferenceRows, info, preferencesInfo, localRevision, storageAliases) = try withLockFile {
				try applyPendingArchive()
				return try database.read { db in
					(
						try Self.fetchOrganization(db),
						try Self.fetchPreferences(db),
						try Self.fetchInfo(db),
						try Self.fetchPreferencesInfo(db),
						try LocalStoreInfoRecord.find(StoreInfoKey.revision).fetchOne(db)?.value,
						try ProfileStorageRecord.aliases(db)
					)
				}
			}

			// Before anyone sees the profiles: a merged profile's pages must open on this Mac's website
			// data (DEV-1216).
			ProfileStorageAliases.shared.set(storageAliases)
			guard let revision = info[StoreInfoKey.revision].flatMap(Int.init) else {
				// A first save cut short between the files reads as empty, and the next first save
				// replaces the preference rows it left.
				// Tab Archive's rows can be there alone, as from a store moved out of the JSON file.
				var withoutArchive: OrganizationRows = organizationRows
				withoutArchive.archivedTabs = [:]
				guard
					withoutArchive == .init(),
					Self.isUnfinishedFirstWrite(preferencesInfo)
						|| (preferencesInfo.isEmpty && preferenceRows == .init())
				else { throw Failure.partialStore }

				cache = nil
				loadedEmpty = true
				return nil
			}
			try Self.checkPair(info, preferencesInfo)

			// The local file has the revision of the save that last wrote it, the organization's.
			guard localRevision == info[StoreInfoKey.revision] else { throw Failure.partialStore }

			var organization: BrowserOrganization = try organizationRows.organization()

			// iCloud sync can bring back a profile this Mac retired, when another Mac edited it
			// offline. It stays retired here, and the next save that changes the organization
			// deletes it again.
			if organization.profiles.contains(where: { organization.retiredProfileIDs.contains($0.id) }) {
				organization = try organization.excludingRetiredProfiles([])
			}
			let preferences: BrowserPreferences = try preferenceRows.preferences()
			let snapshot: Snapshot = .init(
				organization: organization,
				preferences: preferences,
				migratedFromWorkspaceVersion: info[StoreInfoKey.migratedFromWorkspaceVersion].flatMap(Int.init)
			)
			try validate(snapshot)

			loadedEmpty = false
			cache = .init(
				organizationRows: organizationRows,
				preferenceRows: preferenceRows,
				organization: organization,
				preferences: preferences,
				revision: revision
			)
			return snapshot
		}
	}

	// MARK: - Writing

	/// Writes a whole workspace read from the JSON file into an empty store, in one transaction.
	/// The JSON file is never touched.
	@discardableResult
	public func migrate(
		organization: BrowserOrganization,
		preferences: BrowserPreferences,
		fromWorkspaceVersion version: Int,
		sourceRevision: Int
	) throws -> WriteSummary {
		try lock.withLock {
			try withLockFile {
				try write(
					organization,
					preferences,
					info: [
					StoreInfoKey.migratedFromWorkspaceVersion: String(version),
						StoreInfoKey.sourceRevision: String(sourceRevision),
					],
					isMigration: true
				)
			}
		}
	}

	/// Writes the rows that differ from what this store last read or wrote, in one transaction. Writes
	/// a new workspace into an empty store, as a first launch's first save does.
	///
	/// - Throws: ``Failure/changedOnDisk`` when another writer changed the store since then.
	@discardableResult
	public func save(
		_ organization: BrowserOrganization,
		preferences: BrowserPreferences
	) throws -> WriteSummary {
		try lock.withLock {
			try withLockFile {
				try write(organization, preferences, info: [:], isMigration: false)
			}
		}
	}

	/// The Preferences groups kept on this Mac (DEV-982), as this store last read or wrote them.
	public var localPreferenceGroups: Set<PreferenceGroup> {
		lock.withLock { cache?.preferenceRows.localGroups ?? [] }
	}

	/// Keeps a Preferences group on this Mac, or syncs it again (DEV-982), saving `organization` and
	/// `preferences` with it in one write, as ``save(_:preferences:)`` does. Its revision makes any
	/// other writer's save that read the store before this one stop with ``Failure/changedOnDisk``,
	/// in this process or another, so none writes the group under the old choice.
	///
	/// Kept on this Mac, the group's override row takes its values from `preferences`, and its synced
	/// rows stay as they are. Synced again, `keepingThisMac` writes `preferences`' values over the
	/// synced rows, replacing what other Macs changed meanwhile, including removing list entries only
	/// they have; otherwise the group takes the synced rows' values, as last downloaded.
	///
	/// - Parameters:
	///   - validate: the caller's check of the preferences to save, run before anything is
	///     written: the synced values may not be valid together, as a repair skipped while the group
	///     was kept on this Mac.
	/// - Returns: the preferences saved: `preferences`, with the synced values for a group that
	///   doesn't keep this Mac's.
	/// - Throws: ``Failure/changedOnDisk`` before the store was loaded or after another writer
	///   changed it since.
	@discardableResult
	public func setPreferenceGroup(
		_ group: PreferenceGroup,
		syncs: Bool,
		keepingThisMac: Bool,
		organization: BrowserOrganization,
		preferences: BrowserPreferences,
		validate: (BrowserPreferences) throws -> Void = { _ in }
	) throws -> BrowserPreferences {
		try lock.withLock {
			try withLockFile {
				guard let cache else { throw Failure.changedOnDisk }

				var groups: Set<PreferenceGroup> = cache.preferenceRows.localGroups
				var preferences: BrowserPreferences = preferences
				if syncs {
					if groups.remove(group) != nil, !keepingThisMac {
						var synced: PreferenceRows = try database.read { db in try Self.fetchPreferences(db) }
						synced.local[group.overrideKey] = nil
						preferences = try preferences.replacing(group, with: synced.preferences())
					}
				} else {
					groups.insert(group)
				}
				try validate(preferences)
				try write(organization, preferences, info: [:], isMigration: false, localGroups: groups)
				return preferences
			}
		}
	}

	/// Records that this Mac opened the spaces, pinned tabs and Favorites among `ids`, and their
	/// profiles, at most once a day each (DEV-980). Opening one doesn't always change a saved row, so
	/// a save alone can miss it. Only a store that syncs (``preferencesDatabase``) records use, and
	/// only once it holds a workspace. IDs of other rows, such as open tabs, are left out. An ID this
	/// store already looked up today isn't again, even after another Mac deleted it since: a day
	/// matters little against the wait before a deletion syncs.
	public func recordUse(
		of ids: Set<UUID>,
		now: Date = .init()
	) throws {
		guard preferencesDatabase != nil else { return }

		try lock.withLock {
			let today: Double = Calendar.current.startOfDay(for: now).timeIntervalSince1970
			if recordedToday.day != today { recordedToday = (today, []) }
			let opened: Set<UUID> = ids.subtracting(recordedToday.ids)
			guard !opened.isEmpty else { return }

			let recorded: Bool = try withLockFile {
				try database.writeAllowingSyncedDeletions { db in
					guard try StoreInfoRecord.find(StoreInfoKey.revision).fetchOne(db) != nil else { return false }

					let used: [UUID: String] = try LocalDeletion.storedItems(opened, db)
					if !used.isEmpty {
						_ = try LocalDeletion.recordUse(used, deviceID: LocalDeletion.deviceID(db), now: now, db)
					}
					return true
				}
			}
			if recorded { recordedToday.ids.formUnion(opened) }
		}
	}

	/// "Delete from This Mac Only" (DEV-1336): the next save that removes any of these profiles or
	/// spaces marks this Mac's deletion rows for it, and for everything in it, as kept elsewhere
	/// (``DeletionRecord/keepsElsewhere``). Rows this Mac already wrote for them are marked at that
	/// save too. Without iCloud sync a removal deletes, and this does nothing.
	public func keepRemovalOnThisMac(_ ids: Set<UUID>) {
		guard preferencesDatabase != nil else { return }

		lock.withLock { keptElsewhere.formUnion(ids) }
	}

	/// Runs `body` holding the store's lock file, which other processes' saves wait for. A save through
	/// separate connections takes two transactions, and another process's save that landed between
	/// them, accepting the preferences file one revision ahead, would overwrite this save's
	/// preferences. One transaction covers a save otherwise, but it can meet such a save too.
	///
	/// - Throws: ``Failure/changedOnDisk`` when another save holds the lock for as long as a busy
	///   database is waited for.
	private func withLockFile<T>(_ body: () throws -> T) throws -> T {
		try Self.withLockFile(at: lockFile, body)
	}

	private static func withLockFile<T>(
		at lockFile: URL,
		_ body: () throws -> T
	) throws -> T {
		let descriptor: Int32 = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
		guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

		// Closing releases the lock, as the process ending does.
		defer { close(descriptor) }

		let deadline: ContinuousClock.Instant = .now + .seconds(10)
		while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
			let failure: Int32 = errno
			guard failure == EWOULDBLOCK || failure == EINTR else {
				throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
			}
			guard ContinuousClock.now < deadline else { throw Failure.changedOnDisk }

			usleep(5_000)
		}
		return try body()
	}

	/// - Parameters:
	///   - isMigration: a migration needs an empty store and ignores what this store cached.
	///   - localGroups: the Preferences groups kept on this Mac after this write (DEV-982); `nil` keeps
	///     the ones the base has.
	private func write(
		_ organization: BrowserOrganization,
		_ preferences: BrowserPreferences,
		info: [String: String],
		isMigration: Bool,
		localGroups: Set<PreferenceGroup>? = nil
	) throws -> WriteSummary {
		// A change an earlier save left for the archive file goes there first, even when this save has
		// nothing to write.
		try applyPendingArchive()
		if
			let cache,
			cache.organization == organization,
			cache.preferences == preferences,
			localGroups == nil || localGroups == cache.preferenceRows.localGroups,
			!isMigration
		{
			// Nothing to write, but a newer workspace from another writer still isn't this one.
			let (info, preferencesInfo) = try database.read { db in
				(try Self.fetchInfo(db), try Self.fetchPreferencesInfo(db))
			}
			guard info[StoreInfoKey.revision].flatMap(Int.init) == cache.revision
			else { throw Failure.changedOnDisk }

			try Self.checkPair(info, preferencesInfo)

			return .init()
		}

		if let preferencesDatabase {
			return try writeSeparately(
				organization,
				preferences,
				info: info,
				isMigration: isMigration,
				localGroups: localGroups,
				preferencesDatabase
			)
		}

		let cached: Cache? = isMigration ? nil : cache
		let loadedEmpty: Bool = self.loadedEmpty
		let (organizationRows, preferenceRows, summary, revision) = try database.writeAllowingSyncedDeletions { db in
			let storedInfo: [String: String] = try Self.fetchInfo(db)
			let stored: Int? = storedInfo[StoreInfoKey.revision].flatMap(Int.init)
			if isMigration, stored != nil { throw Failure.alreadyInitialized }
			let preferencesInfo: [String: String] = try Self.fetchPreferencesInfo(db)
			if stored != nil {
				try Self.checkPair(storedInfo, preferencesInfo)
			} else if !preferencesInfo.isEmpty, !Self.isUnfinishedFirstWrite(preferencesInfo) {
				// The organization file is new but the preferences file holds a workspace.
				throw Failure.partialStore
			}
			if let cached, stored != cached.revision { throw Failure.changedOnDisk }
			if cached == nil, loadedEmpty, stored != nil { throw Failure.changedOnDisk }

			// Without a cache the rows on disk are the base: none for a new store, whose leftovers
			// this write clears, or the workspace a save before any load replaces.
			let oldOrganization: OrganizationRows = try cached?.organizationRows ?? Self.fetchOrganization(db)
			let oldPreferences: PreferenceRows = try cached?.preferenceRows ?? Self.fetchPreferences(db)
			let positions: (OrganizationRows, PreferenceRows) = stored == nil
			? (.init(), .init())
			: (oldOrganization, oldPreferences)
			let organizationRows: OrganizationRows = try .init(
				organization,
				previous: positions.0,
				archiveIsUnchanged: cached?.organization.archive == organization.archive
			)
			let preferenceRows: PreferenceRows = try Self.preferenceRows(
				preferences,
				cached: cached,
				base: positions.1,
				localGroups: localGroups
			)

			var summary: WriteSummary = .init()

			// A save from before a joining Mac's merge lands on the kept items (DEV-1216).
			let (rebasedRows, rebasedBase): (OrganizationRows, OrganizationRows) = cached == nil
			? (organizationRows, oldOrganization)
			: try OrganizationRows.rebased(organizationRows, oldOrganization, across: MergeRemapRecord.remap(db), db)
			try Self.apply(rebasedRows, replacing: rebasedBase, deletionsStayLocal: false, db, &summary)
			try Self.apply(preferenceRows, replacing: oldPreferences, db, &summary)

			let revision: Int = (stored ?? 0) + 1
			let storeID: String = storedInfo[StoreInfoKey.storeID] ?? UUID().uuidString.lowercased()
			let pair: [String: String] = [StoreInfoKey.revision: String(revision), StoreInfoKey.storeID: storeID]
			var info: [String: String] = info.merging(pair) { _, pair in pair }
			if let legacy = organizationRows.legacyProfileID {
				info[StoreInfoKey.legacyProfileID] = legacy.uuidString.lowercased()
			} else {
				try StoreInfoRecord.find(StoreInfoKey.legacyProfileID).delete().execute(db)
			}
			try StoreInfoRecord.upsert {
				info.map { StoreInfoRecord(id: $0.key, value: $0.value) }
			}
			.execute(db)

			// The local file takes every save's revision too, so one restored alone is caught (DEV-981).
			try LocalStoreInfoRecord.upsert {
				pair.map { LocalStoreInfoRecord(id: $0.key, value: $0.value) }
			}
			.execute(db)
			try PreferenceStoreInfoRecord.upsert {
				pair.map { PreferenceStoreInfoRecord(id: $0.key, value: $0.value) }
			}
			.execute(db)
			try PreferenceStoreInfoRecord.find(StoreInfoKey.unfinishedFirstWrite).delete().execute(db)
			return (organizationRows, preferenceRows, summary, revision)
		}

		self.loadedEmpty = false

		cache = .init(
			organizationRows: organizationRows,
			preferenceRows: preferenceRows,
			organization: organization,
			preferences: preferences,
			revision: revision
		)
		return summary
	}

	/// ``write(_:_:info:isMigration:)`` through two connections: the checks and the rows first, then
	/// the preferences file through its own connection, then the organization file.
	private func writeSeparately(
		_ organization: BrowserOrganization,
		_ preferences: BrowserPreferences,
		info: [String: String],
		isMigration: Bool,
		localGroups: Set<PreferenceGroup>?,
		_ preferencesDatabase: DatabaseQueue
	) throws -> WriteSummary {
		let cached: Cache? = isMigration ? nil : cache
		let loadedEmpty: Bool = self.loadedEmpty
		let (storedInfo, preferencesInfo, oldOrganization, oldPreferences) = try database.read { db in
			(
				try Self.fetchInfo(db),
				try Self.fetchPreferencesInfo(db),
				try cached?.organizationRows ?? Self.fetchOrganization(db),
				try cached?.preferenceRows ?? Self.fetchPreferences(db)
			)
		}
		let stored: Int? = storedInfo[StoreInfoKey.revision].flatMap(Int.init)
		if isMigration, stored != nil { throw Failure.alreadyInitialized }
		if stored != nil {
			try Self.checkPair(storedInfo, preferencesInfo)
		} else if !preferencesInfo.isEmpty, !Self.isUnfinishedFirstWrite(preferencesInfo) {
			throw Failure.partialStore
		}
		if let cached, stored != cached.revision { throw Failure.changedOnDisk }
		if cached == nil, loadedEmpty, stored != nil { throw Failure.changedOnDisk }

		let positions: (OrganizationRows, PreferenceRows) = stored == nil
		? (.init(), .init())
		: (oldOrganization, oldPreferences)
		let organizationRows: OrganizationRows = try .init(
			organization,
			previous: positions.0,
			archiveIsUnchanged: cached?.organization.archive == organization.archive
		)
		let preferenceRows: PreferenceRows = try Self.preferenceRows(
			preferences,
			cached: cached,
			base: positions.1,
			localGroups: localGroups
		)


		let revision: Int = (stored ?? 0) + 1
		let storeID: String = storedInfo[StoreInfoKey.storeID] ?? UUID().uuidString.lowercased()
		let pair: [String: String] = [StoreInfoKey.revision: String(revision), StoreInfoKey.storeID: storeID]

		// Preferences first: a save cut short after this leaves them one revision ahead, which a
		// load accepts.
		let preferencesSummary: WriteSummary = try preferencesDatabase.writeAllowingSyncedDeletions { db in
			var summary: WriteSummary = .init()

			// Another process's save since the checks above changes this file first: stop before
			// overwriting its preferences with rows diffed against an older base.
			guard try Self.fetchPreferencesInfo(db) == preferencesInfo else { throw Failure.changedOnDisk }

			try Self.apply(preferenceRows, replacing: oldPreferences, db, &summary)
			try PreferenceStoreInfoRecord.upsert {
				pair.map { PreferenceStoreInfoRecord(id: $0.key, value: $0.value) }
			}
			.execute(db)

			// A first save marks the preferences file until the organization file has the
			// workspace too. Any later save clears a mark that was left behind.
			if stored == nil {
				try PreferenceStoreInfoRecord.upsert {
					PreferenceStoreInfoRecord(id: StoreInfoKey.unfinishedFirstWrite, value: storeID)
				}
				.execute(db)
			} else {
				try PreferenceStoreInfoRecord.find(StoreInfoKey.unfinishedFirstWrite).delete().execute(db)
			}
			return summary
		}

		let organizationSummary: WriteSummary
		let keptRoots: Set<UUID> = keptElsewhere
		var keptHere: Set<UUID> = []
		do {
			organizationSummary = try database.writeAllowingSyncedDeletions { db in
				var summary: WriteSummary = .init()

				// Nothing else writes the store under the caller's lock, but another process could.
				guard try Self.fetchInfo(db)[StoreInfoKey.revision].flatMap(Int.init) == stored
				else { throw Failure.changedOnDisk }

				// A save from before a joining Mac's merge lands on the kept items (DEV-1216).
				let remap: [UUID: UUID] = cached == nil ? [:] : try MergeRemapRecord.remap(db)
				let (rebasedRows, rebasedBase): (OrganizationRows, OrganizationRows) = try OrganizationRows.rebased(
					organizationRows,
					oldOrganization,
					across: remap,
					db
				)

				// Tab Archive's change goes in with the organization's transaction, then to its own file
				// through its own connection, which its sync engine sees (DEV-983).
				// Only synced profiles' entries: a "this Mac only" profile's stay in the local file (DEV-981).
				let archiveChange: PendingArchiveChange? = {
					let (newSynced, newLocal) = rebasedRows.split()
					let (oldSynced, _) = rebasedBase.split()
					return Self.archiveChange(newSynced.keepingMoved(to: newLocal, from: oldSynced), replacing: oldSynced)
				}()

				// With iCloud sync, deleting a synced item hides it here and leaves it on other Macs.
				let archiveRemovals: [UUID] = try Self.apply(
					rebasedRows,
					replacing: rebasedBase,
					deletionsStayLocal: true,
					moves: Dictionary(
						organization.tabs.filter { !$0.movedFrom.isEmpty }.map { tab in
							(remap[tab.id.rawValue] ?? tab.id.rawValue, tab.movedFrom.map { remap[$0.rawValue] ?? $0.rawValue })
						},
						uniquingKeysWith: { first, _ in first }
					),
					writesArchive: false,
					db,
					&summary
				)

				// "Delete from This Mac Only" (DEV-1336), once its deletion rows are written.
				if !keptRoots.isEmpty {
					keptHere = try LocalDeletion.keepElsewhere(keptRoots, in: rebasedBase, db)
				}
				var change: PendingArchiveChange = archiveChange ?? .init(upserted: [], removed: [])
				change.removed = Array(Set(change.removed).union(archiveRemovals)).sorted { $0.uuidString < $1.uuidString }
				if !change.upserted.isEmpty || !change.removed.isEmpty {
					// A removal hides with this Mac's ID; an entry added back clears its deletion row.
					change.deviceID = try change.removed.isEmpty
					? LocalDeletion.existingDeviceID(db)
					: LocalDeletion.deviceID(db)
					let value: String = try JSONColumn.encode(change)
					try StoreInfoRecord.upsert {
						StoreInfoRecord(id: StoreInfoKey.pendingArchive, value: value)
					}
					.execute(db)
				}
				var info: [String: String] = info.merging(pair) { _, pair in pair }
				if let legacy = organizationRows.legacyProfileID {
					info[StoreInfoKey.legacyProfileID] = legacy.uuidString.lowercased()
				} else {
					try StoreInfoRecord.find(StoreInfoKey.legacyProfileID).delete().execute(db)
				}
				try StoreInfoRecord.upsert {
					info.map { StoreInfoRecord(id: $0.key, value: $0.value) }
				}
				.execute(db)

				// The local file takes every save's revision too, so one restored alone is caught (DEV-981).
				try LocalStoreInfoRecord.upsert {
					pair.map { LocalStoreInfoRecord(id: $0.key, value: $0.value) }
				}
				.execute(db)
				return summary
			}
		} catch {
			// The preferences file moved on without the organization, so its rows are the base the
			// next write diffs preferences against. Not a read of the disk: that would also take in
			// rows sync wrote that the caller hasn't read yet, and the next write would undo them.
			if cached != nil {
				cache?.preferenceRows = preferenceRows
				cache?.preferences = preferences
			} else {
				cache = nil
			}
			throw error
		}

		// The archive file next. Cut short, the change stays in the organization file, which the next
		// open or save applies first.
		let archiveSummary: WriteSummary = (try? applyPendingArchive()) ?? .init()
		if stored == nil {
			// Both files hold the workspace now. A mark left by a failure here is cleared by the next
			// save, and until then both files hold the pair, which outweighs it.
			try? preferencesDatabase.writeAllowingSyncedDeletions { db in
				try db.execute(
					sql: "DELETE FROM \"\(PreferenceStoreInfoRecord.tableName)\" WHERE \"id\" = ? AND \"value\" = ?",
					arguments: [StoreInfoKey.unfinishedFirstWrite, storeID]
				)
			}
		}

		self.loadedEmpty = false
		keptElsewhere.subtract(keptHere)
		cache = .init(
			organizationRows: organizationRows,
			preferenceRows: preferenceRows,
			organization: organization,
			preferences: preferences,
			revision: revision
		)
		return .init(
			upserted: organizationSummary.upserted
				.merging(preferencesSummary.upserted) { $0 + $1 }
				.merging(archiveSummary.upserted) { $0 + $1 },
			deleted: organizationSummary.deleted
				.merging(preferencesSummary.deleted) { $0 + $1 }
				.merging(archiveSummary.deleted) { $0 + $1 }
		)
	}

	// MARK: - Rows

	/// A save's preference rows. The groups kept on this Mac (DEV-982) keep their synced rows as `base`
	/// has them, so other Macs' changes that arrived meanwhile stay, and write this Mac's values to their
	/// override rows instead, whether or not `base` had those.
	///
	/// - Parameters:
	///   - localGroups: the groups kept on this Mac after the save; `nil` keeps `base`'s.
	private static func preferenceRows(
		_ preferences: BrowserPreferences,
		cached: Cache?,
		base: PreferenceRows,
		localGroups: Set<PreferenceGroup>?
	) throws -> PreferenceRows {
		let groups: Set<PreferenceGroup> = localGroups ?? base.localGroups

		// Unchanged preferences keep their rows exactly, whatever order their encoding chose.
		if let cached, cached.preferences == preferences, cached.preferenceRows.localGroups == groups {
			return cached.preferenceRows
		}
		return try PreferenceRows(preferences, previous: base).keepingLocal(groups, of: preferences, previous: base)
	}

	/// Both files must record the same store and revision, or one came back without the other. The
	/// preferences file may be exactly one revision ahead: a save through separate connections writes
	/// it first, and one cut short there left the organization file at the previous save.
	private static func checkPair(
		_ organization: [String: String],
		_ preferences: [String: String]
	) throws {
		guard
			organization[StoreInfoKey.storeID] != nil,
			organization[StoreInfoKey.storeID] == preferences[StoreInfoKey.storeID],
			let organizationRevision = organization[StoreInfoKey.revision].flatMap(Int.init),
			let preferencesRevision = preferences[StoreInfoKey.revision].flatMap(Int.init),
			preferencesRevision == organizationRevision || preferencesRevision == organizationRevision + 1
		else { throw Failure.partialStore }
	}

	/// The preferences file holds the first revision of a first save through separate connections
	/// that never reached the organization file, as opposed to a workspace whose organization file
	/// was lost.
	private static func isUnfinishedFirstWrite(_ preferences: [String: String]) -> Bool {
		guard let storeID = preferences[StoreInfoKey.storeID] else { return false }

		return preferences[StoreInfoKey.unfinishedFirstWrite] == storeID
			&& preferences[StoreInfoKey.revision] == "1"
	}

	private static func fetchPreferencesInfo(_ db: Database) throws -> [String: String] {
		Dictionary(
			try PreferenceStoreInfoRecord.all.fetchAll(db).map { ($0.id, $0.value) },
			uniquingKeysWith: { first, _ in first }
		)
	}

	private static func fetchInfo(_ db: Database) throws -> [String: String] {
		Dictionary(
			try StoreInfoRecord.all.fetchAll(db).map { ($0.id, $0.value) },
			uniquingKeysWith: { first, _ in first }
		)
	}

	/// The organization's rows without what this Mac deleted while deletions stay local (DEV-980):
	/// what loads, and the base writes diff against, so hidden rows are never touched here. "This Mac
	/// only" profiles come from the local file, never from their synced copies (DEV-981).
	private static func fetchOrganization(_ db: Database) throws -> OrganizationRows {
		var rows: OrganizationRows = try fetchAllOrganization(db).hiding(LocalDeletion.hiddenItems(db))

		// The Tab Archive entries this Mac removed while they sync stay with the other Macs (DEV-983).
		if let deviceID = try LocalDeletion.existingDeviceID(db) {
			let hidden: Set<UUID> = Set(try UUID.fetchAll(
				db,
				sql: #"SELECT "itemID" FROM "archive"."archiveDeletion" WHERE "deviceID" = ?"#,
				arguments: [deviceID.uuidString.lowercased()]
			))
			if !hidden.isEmpty {
				rows.archivedTabs = rows.archivedTabs.filter { !hidden.contains($0.key) }
			}
		}
		return .merging(synced: rows, local: try fetchLocalOrganization(db))
	}

	/// The local file's rows: "this Mac only" profiles and what's theirs (DEV-981).
	private static func fetchLocalOrganization(_ db: Database) throws -> OrganizationRows {
		func rows<Local: Table & Identifiable, Record>(
			_ type: Local.Type,
			_ record: (Local) -> Record
		) throws -> [UUID: Record] where Local.QueryOutput == Local, Local.ID == UUID {
			Dictionary(try Local.all.fetchAll(db).map { ($0.id, record($0)) }, uniquingKeysWith: { first, _ in first })
		}
		let profiles: [UUID: ProfileRecord] = try rows(LocalProfileRecord.self, \.record)
		var archived: [UUID: ArchiveEntryRecord] = [:]
		for row in try LocalArchivedTabRecord.all.fetchAll(db) {
			let value: String = row.value

			// A damaged entry is left out, as the synced file's are.
			do {
				let entry: ArchivedTab = try JSONColumn.decode(ArchivedTab.self, from: value)
				archived[row.id] = .init(entry, position: row.position)
			} catch {
				continue
			}
		}

		// What profiles turned local had in the synced file stays out of sight here while they're
		// local, wherever another Mac moves it, even once deleted here.
		var shadowed: Set<UUID> = []
		for row in try LocalStoreInfoRecord.where({ $0.id.like("\(LocalStoreInfoKey.baselinePrefix)%") }).fetchAll(db) {
			let value: String = row.value
			let baseline: [String: [UUID]] = try JSONColumn.decode([String: [UUID]].self, from: value)
			shadowed.formUnion(baseline.values.joined())
		}
		var local: OrganizationRows = .init(
			profiles: profiles,
			spaces: try rows(LocalSpaceRecord.self, \.record),
			folders: try rows(LocalFolderRecord.self, \.record),
			pinnedTabs: try rows(LocalPinnedTabRecord.self, \.record),
			favorites: try rows(LocalFavoriteRecord.self, \.record),
			spaceStates: try rows(LocalSpaceStateRecord.self, \.record),
			folderStates: try rows(LocalFolderStateRecord.self, \.record),
			regularTabs: try rows(LocalRegularTabRecord.self, \.record),
			archivedTabs: archived,
			localProfileIDs: Set(profiles.keys)
		)
		local.shadowedIDs = shadowed
		return local
	}

	private static func fetchAllOrganization(_ db: Database) throws -> OrganizationRows {
		.init(
			profiles: try fetch(ProfileRecord.self, db),
			spaces: try fetch(SpaceRecord.self, db),
			folders: try fetch(FolderRecord.self, db),
			pinnedTabs: try fetch(PinnedTabRecord.self, db),
			favorites: try fetch(FavoriteRecord.self, db),
			retiredProfiles: try fetch(RetiredProfileRecord.self, db),
			spaceStates: try fetch(SpaceStateRecord.self, db),
			folderStates: try fetch(FolderStateRecord.self, db),
			tabStates: try fetch(TabStateRecord.self, db),
			regularTabs: try fetch(RegularTabRecord.self, db),
			archivedTabs: try fetch(ArchiveEntryRecord.self, db),
			splitGroups: try fetch(SplitGroupRecord.self, db),
			tabGroups: try fetch(TabGroupRecord.self, db),
			legacyProfileID: try StoreInfoRecord.find(StoreInfoKey.legacyProfileID).fetchOne(db).flatMap { UUID(uuidString: $0.value) }
		)
	}

	private static func fetchPreferences(_ db: Database) throws -> PreferenceRows {
		.init(
			domains: try fetch(PreferenceRecord.self, db),
			searchShortcuts: try fetch(SearchShortcutRecord.self, db),
			keyboardShortcuts: try fetch(KeyboardShortcutRecord.self, db),
			routingRules: try fetch(RoutingRuleRecord.self, db),
			proxyLinkRules: try fetch(ProxyLinkRuleRecord.self, db),
			local: try fetch(LocalPreferenceRecord.self, db)
		)
	}

	private static func fetch<Record: Table & Identifiable>(
		_ type: Record.Type,
		_ db: Database
	) throws -> [Record.ID: Record] where Record.QueryOutput == Record {
		Dictionary(
			try Record.all.fetchAll(db).map { ($0.id, $0) },
			uniquingKeysWith: { first, _ in first }
		)
	}

	/// Writes a save's organization rows: those of synced profiles to the synced file, those of "this
	/// Mac only" profiles to the local file (DEV-981). A profile turned local leaves its synced copies
	/// as they are and records which rows it had; turned back on, its rows are written over the synced
	/// copies and those it deleted meanwhile are deleted here as any deletion is, while what other Macs
	/// added meanwhile shows.
	///
	/// - Returns: the Tab Archive entries a profile turned back on deleted meanwhile, for the archive's
	///   own connection when `writesArchive` is off.
	@discardableResult
	private static func apply(
		_ organization: OrganizationRows,
		replacing old: OrganizationRows,
		deletionsStayLocal: Bool,
		moves: [UUID: [UUID]] = [:],
		writesArchive: Bool = true,
		_ db: Database,
		_ summary: inout WriteSummary
	) throws -> [UUID] {
		let (newSynced, newLocal) = organization.split()
		let (oldSynced, oldLocal) = old.split()
		let synced: OrganizationRows = newSynced.keepingMoved(to: newLocal, from: oldSynced)
		try pruneBaselines(keeping: newLocal.localProfileIDs, showing: newSynced, db)
		let deletedWhileLocal: [String: [UUID]] = try reconnect(
			synced: synced,
			local: newLocal,
			oldLocal: oldLocal,
			oldSynced: oldSynced,
			db
		)
		let archiveRemovals: [UUID] = deletedWhileLocal[ArchiveEntryRecord.tableName] ?? []
		try applySynced(
			synced,
			replacing: oldSynced,
			deletionsStayLocal: deletionsStayLocal,
			moves: moves,
			writesArchive: writesArchive,
			archiveRemovals: writesArchive ? archiveRemovals : [],
			db,
			&summary
		)
		let tables: [(table: String, ids: [UUID])] = deletedWhileLocal
			.filter { $0.key != ArchiveEntryRecord.tableName && !$0.value.isEmpty }
			.map { (table: $0.key, ids: $0.value) }
		if !tables.isEmpty {
			if deletionsStayLocal {
				_ = try LocalDeletion.hide(tables, deviceID: LocalDeletion.deviceID(db), now: .init(), db)
			} else {
				for (table, ids) in tables {
					for id in ids {
						try db.execute(sql: "DELETE FROM \"main\".\"\(table)\" WHERE \"id\" = ?", arguments: [id.uuidString.lowercased()])
					}
				}
			}
		}
		try applyLocal(newLocal, replacing: oldLocal, db, &summary)
		return writesArchive ? [] : archiveRemovals
	}

	/// Takes out of the local profiles' baselines what this save shows as a synced profile's, as a space
	/// moved out of a local profile: it's no longer theirs to hide.
	private static func pruneBaselines(
		keeping local: Set<UUID>,
		showing synced: OrganizationRows,
		_ db: Database
	) throws {
		let shown: Set<UUID> = Set(synced.profiles.keys)
			.union(synced.spaces.keys)
			.union(synced.folders.keys)
			.union(synced.pinnedTabs.keys)
			.union(synced.favorites.keys)
			.union(synced.archivedTabs.keys)
		guard !shown.isEmpty else { return }

		for id in local {
			let key: String = LocalStoreInfoKey.baseline(id)
			guard let stored = try LocalStoreInfoRecord.find(key).fetchOne(db) else { continue }

			let value: String = stored.value
			let baseline: [String: [UUID]] = try JSONColumn.decode([String: [UUID]].self, from: value)
			let pruned: [String: [UUID]] = baseline.mapValues { $0.filter { !shown.contains($0) } }
			guard pruned != baseline else { continue }

			let encoded: String = try JSONColumn.encode(pruned)
			try LocalStoreInfoRecord.upsert { LocalStoreInfoRecord(id: key, value: encoded) }.execute(db)
		}
	}

	/// The synced rows of each profile turned "this Mac only" by this save, recorded in the local file,
	/// and, for each turned back on, those it had then that it no longer has (DEV-981).
	private static func reconnect(
		synced: OrganizationRows,
		local: OrganizationRows,
		oldLocal: OrganizationRows,
		oldSynced: OrganizationRows,
		_ db: Database
	) throws -> [String: [UUID]] {
		func subtree(of profileID: UUID, in rows: OrganizationRows) -> [String: [UUID]] {
			var rows: OrganizationRows = rows
			rows.localProfileIDs = [profileID]
			let (_, owned) = rows.split()
			return [
				ProfileRecord.tableName: Array(owned.profiles.keys),
				SpaceRecord.tableName: Array(owned.spaces.keys),
				FolderRecord.tableName: Array(owned.folders.keys),
				PinnedTabRecord.tableName: Array(owned.pinnedTabs.keys),
				FavoriteRecord.tableName: Array(owned.favorites.keys),
				ArchiveEntryRecord.tableName: Array(owned.archivedTabs.keys),
			]
		}

		for id in local.localProfileIDs.subtracting(oldLocal.localProfileIDs) where oldSynced.profiles[id] != nil {
			let baseline: String = try JSONColumn.encode(subtree(of: id, in: oldSynced))
			try LocalStoreInfoRecord.upsert {
				LocalStoreInfoRecord(id: LocalStoreInfoKey.baseline(id), value: baseline)
			}
			.execute(db)
		}

		var deleted: [String: [UUID]] = [:]

		// A "this Mac only" profile removed here: its synced copy, which other Macs keep, is deleted
		// here as any deletion, so it never shows again.
		for id in oldLocal.localProfileIDs.subtracting(local.localProfileIDs) where synced.profiles[id] == nil {
			try LocalStoreInfoRecord.find(LocalStoreInfoKey.baseline(id)).delete().execute(db)
			if try ProfileRecord.find(id).fetchOne(db) != nil {
				deleted[ProfileRecord.tableName, default: []].append(id)
			}
		}
		for id in oldLocal.localProfileIDs.subtracting(local.localProfileIDs) where synced.profiles[id] != nil {
			let key: String = LocalStoreInfoKey.baseline(id)
			guard let stored = try LocalStoreInfoRecord.find(key).fetchOne(db) else { continue }

			let baseline: [String: [UUID]] = try JSONColumn.decode([String: [UUID]].self, from: stored.value)

			// Still anywhere in the workspace, as a space moved to another profile meanwhile, isn't deleted.
			let present: [String: Set<UUID>] = [
				ProfileRecord.tableName: Set(synced.profiles.keys).union(local.profiles.keys),
				SpaceRecord.tableName: Set(synced.spaces.keys).union(local.spaces.keys),
				FolderRecord.tableName: Set(synced.folders.keys).union(local.folders.keys),
				PinnedTabRecord.tableName: Set(synced.pinnedTabs.keys).union(local.pinnedTabs.keys),
				FavoriteRecord.tableName: Set(synced.favorites.keys).union(local.favorites.keys),
				ArchiveEntryRecord.tableName: Set(synced.archivedTabs.keys).union(local.archivedTabs.keys),
			]

			// A pin turned into a Favorite meanwhile, or back, keeps its ID: a move, whose old row goes from
			// every Mac, as DEV-980 treats it, rather than a deletion a duplicate repair could undo.
			let other: [String: String] = [
				PinnedTabRecord.tableName: FavoriteRecord.tableName,
				FavoriteRecord.tableName: PinnedTabRecord.tableName,
			]
			for (table, ids) in baseline {
				let kept: Set<UUID> = present[table] ?? []
				for id in ids where !kept.contains(id) {
					if let switched = other[table], present[switched]?.contains(id) == true {
						try db.execute(sql: "DELETE FROM \"main\".\"\(table)\" WHERE \"id\" = ?", arguments: [id.uuidString.lowercased()])
					} else {
						deleted[table, default: []].append(id)
					}
				}
			}

			// What moved to another local profile stays shadowed there: its baseline takes it.
			for (table, ids) in baseline {
				for id in ids {
					guard let owner = localOwner(of: id, table: table, in: local), owner != id else { continue }

					let ownerKey: String = LocalStoreInfoKey.baseline(owner)
					var theirs: [String: [UUID]] = [:]
					if let stored = try LocalStoreInfoRecord.find(ownerKey).fetchOne(db) {
						let value: String = stored.value
						theirs = try JSONColumn.decode([String: [UUID]].self, from: value)
					}
					guard theirs[table]?.contains(id) != true else { continue }

					theirs[table, default: []].append(id)
					let encoded: String = try JSONColumn.encode(theirs)
					try LocalStoreInfoRecord.upsert { LocalStoreInfoRecord(id: ownerKey, value: encoded) }.execute(db)
				}
			}
			try LocalStoreInfoRecord.find(key).delete().execute(db)
		}
		return deleted
	}

	/// The local profile that has `id` of `table` in `local`, if one does.
	private static func localOwner(
		of id: UUID,
		table: String,
		in local: OrganizationRows
	) -> UUID? {
		let owners: OrganizationRows.Owners = .init(local)
		switch table {
		case SpaceRecord.tableName: return local.spaces[id]?.profileID
		case FolderRecord.tableName: return local.folders[id] == nil ? nil : owners.folders[id]
		case PinnedTabRecord.tableName: return local.pinnedTabs[id].flatMap { owners.spaces[$0.spaceID] }
		case FavoriteRecord.tableName: return local.favorites[id]?.profileID
		case ArchiveEntryRecord.tableName: return local.archivedTabs[id]?.profileID
		default: return nil
		}
	}

	/// Writes the local file's rows: "this Mac only" profiles and what's theirs. Nothing there syncs,
	/// so a removal deletes.
	private static func applyLocal(
		_ new: OrganizationRows,
		replacing old: OrganizationRows,
		_ db: Database,
		_ summary: inout WriteSummary
	) throws {
		var deletions: [() throws -> Void] = []
		func local<Record, Local: PrimaryKeyedTable & Identifiable & Equatable>(
			_ path: KeyPath<OrganizationRows, [UUID: Record]>,
			_ make: (Record) -> Local
		) throws where Local.QueryOutput == Local, Local.ID == UUID, Local.ID.QueryValue == Local.PrimaryKey {
			try step(new[keyPath: path].mapValues(make), old[keyPath: path].mapValues(make), db, &summary, &deletions)
		}
		try local(\.profiles, LocalProfileRecord.init)
		try local(\.spaces, LocalSpaceRecord.init)
		try local(\.folders, LocalFolderRecord.init)
		try local(\.pinnedTabs, LocalPinnedTabRecord.init)
		try local(\.favorites, LocalFavoriteRecord.init)
		try local(\.spaceStates, LocalSpaceStateRecord.init)
		try local(\.folderStates, LocalFolderStateRecord.init)
		try local(\.regularTabs, LocalRegularTabRecord.init)
		try local(\.archivedTabs) { row in
			LocalArchivedTabRecord(id: row.id, value: (row.entry.flatMap { try? JSONColumn.encode($0) }) ?? "{}", position: row.position)
		}
		for deletion in deletions.reversed() {
			try deletion()
		}
	}

	/// Upserts parents before children, then deletes children before parents, so every foreign key
	/// holds at each step and a row moved out of a deleted parent is never cascaded away.
	/// - Parameters:
	///   - deletionsStayLocal: a removed profile, space, folder, pinned tab or Favorite gets
	///     a deletion row instead of being deleted, and what's edited or opened records its use
	///     (DEV-980). Rows only this Mac has are deleted either way.
	///   - moves: each tab a move copied into another profile, by the copy's ID, to the IDs of
	///     the tabs it copies, latest first (`Tab.movedFrom`). The row the copy replaces goes from every Mac.
	private static func applySynced(
		_ organization: OrganizationRows,
		replacing old: OrganizationRows,
		deletionsStayLocal: Bool,
		moves: [UUID: [UUID]],
		writesArchive: Bool,
		archiveRemovals: [UUID],
		_ db: Database,
		_ summary: inout WriteSummary
	) throws {
		var deletions: [() throws -> Void] = []
		let deletes: Bool = !deletionsStayLocal
		let profiles = try step(organization.profiles, old.profiles, db, &summary, &deletions, deletesRemoved: deletes)
		let spaces = try step(organization.spaces, old.spaces, db, &summary, &deletions, deletesRemoved: deletes)
		let folders = try step(
			keepingStoredParents(organization.folders, old.folders, db),
			old.folders,
			db,
			&summary,
			&deletions,
			deletesRemoved: deletes
		)
		let pinnedTabs = try step(
			keepingStoredFolders(organization.pinnedTabs, old.pinnedTabs, db),
			old.pinnedTabs,
			db,
			&summary,
			&deletions,
			deletesRemoved: deletes
		)
		let favorites = try step(organization.favorites, old.favorites, db, &summary, &deletions, deletesRemoved: deletes)
		try step(organization.retiredProfiles, old.retiredProfiles, db, &summary, &deletions)
		try step(organization.spaceStates, old.spaceStates, db, &summary, &deletions)
		try step(organization.folderStates, old.folderStates, db, &summary, &deletions)
		try step(organization.tabStates, old.tabStates, db, &summary, &deletions)
		try step(organization.regularTabs, old.regularTabs, db, &summary, &deletions)

		// Through the attached copy, `archive`, unless the archive's own connection writes it, by the
		// same rules: once Tab Archive has synced, a removal is hidden here.
		if writesArchive {
			var change: PendingArchiveChange = archiveChange(organization, replacing: old) ?? .init(upserted: [], removed: [])
			change.removed = Array(Set(change.removed).union(archiveRemovals)).sorted { $0.uuidString < $1.uuidString }
			if !change.upserted.isEmpty || !change.removed.isEmpty {
				change.deviceID = try change.removed.isEmpty ? LocalDeletion.existingDeviceID(db) : LocalDeletion.deviceID(db)
				try apply(change, db, &summary)
			}
		}
		try step(organization.splitGroups, old.splitGroups, db, &summary, &deletions)
		try step(organization.tabGroups, old.tabGroups, db, &summary, &deletions)
		for deletion in deletions.reversed() {
			try deletion()
		}

		let synced: [(table: String, changed: [UUID], removed: [UUID])] = [
			(ProfileRecord.tableName, profiles.changed, profiles.removed),
			(SpaceRecord.tableName, spaces.changed, spaces.removed),
			(FolderRecord.tableName, folders.changed, folders.removed),
			(PinnedTabRecord.tableName, pinnedTabs.changed, pinnedTabs.removed),
			(FavoriteRecord.tableName, favorites.changed, favorites.removed),
		]

		// What this Mac deleted and writes again, such as an undo, shows again.
		try LocalDeletion.show(synced.map { (table: $0.table, ids: $0.changed) }, db)
		guard deletionsStayLocal else { return }

		// A tab moved to another profile is a copy with a new ID there and its old row removed: a
		// move, not a deletion, so the old row goes from every Mac as the copy arrives.
		let moved: Set<UUID> = movedAcrossProfiles(organization, replacing: old, moves: moves)
		if !moved.isEmpty {
			let ids: [UUID] = Array(moved)
			try PinnedTabRecord.where { $0.id.in(ids) }.delete().execute(db)
			try FavoriteRecord.where { $0.id.in(ids) }.delete().execute(db)
		}

		// A tab turned from a pin into a Favorite, or back, keeps its ID: a move too, so the row it left
		// goes from every Mac, and no Mac's duplicate repair picks between the two.
		let pinsNowFavorites: [UUID] = pinnedTabs.removed.filter { organization.favorites[$0] != nil }
		let favoritesNowPins: [UUID] = favorites.removed.filter { organization.pinnedTabs[$0] != nil }
		if !pinsNowFavorites.isEmpty {
			try PinnedTabRecord.where { $0.id.in(pinsNowFavorites) }.delete().execute(db)
		}
		if !favoritesNowPins.isEmpty {
			try FavoriteRecord.where { $0.id.in(favoritesNowPins) }.delete().execute(db)
		}
		let switched: [String: Set<UUID>] = [
			PinnedTabRecord.tableName: Set(pinsNowFavorites),
			FavoriteRecord.tableName: Set(favoritesNowPins),
		]

		// One that went through an open tab first, over earlier saves, left the row it was hidden here:
		// that row goes now too, as the move it was, or a duplicate repair would keep it over the new one.
		let hiddenHere: HiddenItems = try LocalDeletion.hiddenItems(db)
		let favoritesLeft: [UUID] = pinnedTabs.changed.filter { id in
			old.pinnedTabs[id] == nil && hiddenHere.contains(id, in: FavoriteRecord.tableName)
		}
		let pinsLeft: [UUID] = favorites.changed.filter { id in
			old.favorites[id] == nil && hiddenHere.contains(id, in: PinnedTabRecord.tableName)
		}
		for (table, ids) in [(FavoriteRecord.tableName, favoritesLeft), (PinnedTabRecord.tableName, pinsLeft)] where !ids.isEmpty {
			if table == FavoriteRecord.tableName {
				try FavoriteRecord.where { $0.id.in(ids) }.delete().execute(db)
			} else {
				try PinnedTabRecord.where { $0.id.in(ids) }.delete().execute(db)
			}
			try DeletionRecord.where { $0.itemID.in(ids) && $0.itemTable.eq(table) }.delete().execute(db)
		}

		let deviceID: UUID = try LocalDeletion.deviceID(db)
		let now: Date = .init()
		let hidden: Int = try LocalDeletion.hide(
			synced.map { table, _, removed in
				(table: table, ids: removed.filter { !moved.contains($0) && switched[table]?.contains($0) != true })
			},
			deviceID: deviceID,
			now: now,
			db
		)
		if hidden > 0 { summary.upserted[DeletionRecord.tableName] = hidden }

		let used: Int = try LocalDeletion.recordUse(
			usedItems(organization, replacing: old, edited: synced.map { (table: $0.table, ids: $0.changed) }),
			deviceID: deviceID,
			now: now,
			db
		)
		if used > 0 { summary.upserted[UsageRecord.tableName] = used }
	}

	/// `new`'s pinned tabs, where one saved without a change of space or folder keeps the space and
	/// folder it has on disk, and its position unless the rows gave it a new one: a folder this Mac
	/// hid shows its other children higher up (DEV-980), and another Mac may have moved the tab, or
	/// removed its folder, since this store read it.
	private static func keepingStoredFolders(
		_ new: [UUID: PinnedTabRecord],
		_ old: [UUID: PinnedTabRecord],
		_ db: Database
	) throws -> [UUID: PinnedTabRecord] {
		let candidates: [UUID] = new.compactMap { id, row in
			guard
				let base = old[id],
				base != row,
				base.spaceID == row.spaceID,
				base.folderID == row.folderID
			else { return nil }

			return id
		}
		guard !candidates.isEmpty else { return new }

		var rows: [UUID: PinnedTabRecord] = new
		for batch in stride(from: 0, to: candidates.count, by: 500) {
			let ids: [UUID] = Array(candidates[batch ..< min(batch + 500, candidates.count)])
			for stored in try PinnedTabRecord.where({ $0.id.in(ids) }).fetchAll(db) {
				// A position the rows gave it anew, as when two keys collide, goes with it.
				let keepsPosition: Bool = old[stored.id]?.position == rows[stored.id]?.position
				rows[stored.id]?.spaceID = stored.spaceID
				rows[stored.id]?.folderID = stored.folderID
				if keepsPosition { rows[stored.id]?.position = stored.position }
			}
		}
		return rows
	}

	/// ``keepingStoredFolders(_:_:_:)`` for folders.
	private static func keepingStoredParents(
		_ new: [UUID: FolderRecord],
		_ old: [UUID: FolderRecord],
		_ db: Database
	) throws -> [UUID: FolderRecord] {
		let candidates: [UUID] = new.compactMap { id, row in
			guard
				let base = old[id],
				base != row,
				base.spaceID == row.spaceID,
				base.parentFolderID == row.parentFolderID
			else { return nil }

			return id
		}
		guard !candidates.isEmpty else { return new }

		var rows: [UUID: FolderRecord] = new
		for batch in stride(from: 0, to: candidates.count, by: 500) {
			let ids: [UUID] = Array(candidates[batch ..< min(batch + 500, candidates.count)])
			for stored in try FolderRecord.where({ $0.id.in(ids) }).fetchAll(db) {
				let keepsPosition: Bool = old[stored.id]?.position == rows[stored.id]?.position
				rows[stored.id]?.spaceID = stored.spaceID
				rows[stored.id]?.parentFolderID = stored.parentFolderID
				if keepsPosition { rows[stored.id]?.position = stored.position }
			}
		}
		return rows
	}

	/// What a save changes in Tab Archive, written through the archive's own connection (sync), or
	/// `nil` when it changes nothing.
	private static func archiveChange(
		_ rows: OrganizationRows,
		replacing old: OrganizationRows
	) -> PendingArchiveChange? {
		guard rows.archivedTabs != old.archivedTabs else { return nil }

		var upserted: [PendingArchiveChange.Entry] = []
		for (id, row) in rows.archivedTabs where old.archivedTabs[id] != row {
			guard let entry = row.entry else { continue }

			upserted.append(.init(entry: entry, position: row.position))
		}
		let removed: [UUID] = old.archivedTabs.keys.filter { rows.archivedTabs[$0] == nil }
		return .init(
			upserted: upserted.sorted { $0.entry.id.rawValue.uuidString < $1.entry.id.rawValue.uuidString },
			removed: removed.sorted { $0.uuidString < $1.uuidString },
			deviceID: nil
		)
	}

	/// Applies the Tab Archive change a save left in the organization file to the archive file, then
	/// clears it. Safe to repeat. Callers hold the lock file, so no other process applies one meanwhile.
	@discardableResult
	private func applyPendingArchive() throws -> WriteSummary {
		guard let archiveDatabase else {
			// Without sync the attached copy takes it, in one transaction with clearing it.
			return try database.writeAllowingSyncedDeletions { db in
				guard let stored = try StoreInfoRecord.find(StoreInfoKey.pendingArchive).fetchOne(db)?.value
				else { return .init() }

				var summary: WriteSummary = .init()
				try Self.apply(try JSONColumn.decode(PendingArchiveChange.self, from: stored), db, &summary)
				try StoreInfoRecord.find(StoreInfoKey.pendingArchive).delete().execute(db)
				return summary
			}
		}

		let stored: String? = try database.read { db in
			try StoreInfoRecord.find(StoreInfoKey.pendingArchive).fetchOne(db)?.value
		}
		guard let stored else { return .init() }

		let change: PendingArchiveChange = try JSONColumn.decode(PendingArchiveChange.self, from: stored)
		let summary: WriteSummary = try archiveDatabase.writeAllowingSyncedDeletions { db in
			var summary: WriteSummary = .init()
			try Self.apply(change, db, &summary)
			return summary
		}
		try database.writeAllowingSyncedDeletions { db in
			try db.execute(
				sql: "DELETE FROM \"\(StoreInfoRecord.tableName)\" WHERE \"id\" = ? AND \"value\" = ?",
				arguments: [StoreInfoKey.pendingArchive, stored]
			)
		}
		return summary
	}

	/// Writes `change` to the archive file. Once Tab Archive has synced
	/// (``ArchiveStateKey/deletionsStayLocal``), a removed entry, as a restore leaves, is hidden on this
	/// Mac and stays with the others (DEV-980, DEV-983); before, it's deleted.
	private static func apply(
		_ change: PendingArchiveChange,
		_ db: Database,
		_ summary: inout WriteSummary
	) throws {
		let rows: [ArchiveEntryRecord] = change.upserted.map { ArchiveEntryRecord($0.entry, position: $0.position) }
		for batch in stride(from: 0, to: rows.count, by: 200) {
			let chunk: [ArchiveEntryRecord] = Array(rows[batch ..< min(batch + 200, rows.count)])
			try ArchiveEntryRecord.upsert { chunk }.execute(db)
		}
		if !rows.isEmpty { summary.upserted[ArchiveEntryRecord.tableName] = rows.count }

		let staysLocal: Bool = try ArchiveStateRecord.find(ArchiveStateKey.deletionsStayLocal).fetchOne(db) != nil
		if let deviceID = change.deviceID {
			// An entry archived here again shows again.
			let shown: [UUID] = rows.map(\.id)
			for batch in stride(from: 0, to: shown.count, by: 500) {
				let ids: [UUID] = Array(shown[batch ..< min(batch + 500, shown.count)])
				try ArchiveDeletionRecord
					.where { $0.deviceID.eq(deviceID) && $0.itemID.in(ids) }
					.delete()
					.execute(db)
			}
		}
		guard !change.removed.isEmpty else { return }

		guard staysLocal, let deviceID = change.deviceID else {
			for batch in stride(from: 0, to: change.removed.count, by: 500) {
				let ids: [UUID] = Array(change.removed[batch ..< min(batch + 500, change.removed.count)])
				try ArchiveEntryRecord.where { $0.id.in(ids) }.delete().execute(db)
			}
			summary.deleted[ArchiveEntryRecord.tableName] = change.removed.count
			return
		}

		let already: Set<UUID> = Set(
			try ArchiveDeletionRecord.where { $0.deviceID.eq(deviceID) }.select(\.itemID).fetchAll(db)
		)
		let now: Double = Date().timeIntervalSince1970
		let hidden: [ArchiveDeletionRecord] = change.removed.filter { !already.contains($0) }.map { id in
			ArchiveDeletionRecord(
				id: LocalDeletion.rowID(item: id, table: ArchiveEntryRecord.tableName, device: deviceID),
				itemID: id,
				deviceID: deviceID,
				deletedAt: now
			)
		}
		for batch in stride(from: 0, to: hidden.count, by: 200) {
			let chunk: [ArchiveDeletionRecord] = Array(hidden[batch ..< min(batch + 200, hidden.count)])
			try ArchiveDeletionRecord.insert { chunk }.execute(db)
		}
		if !hidden.isEmpty { summary.upserted[ArchiveDeletionRecord.tableName] = hidden.count }
	}

	/// Removed pinned tabs and Favorites that a tab new in this save copies into another profile
	/// (`Tab.movedFrom`, keyed here by the copy's ID): what a move between profiles leaves. Of the tabs
	/// a copy came from through moves before this save, the latest this store has is its source. A
	/// removal beside an identical tab that no move made is a deletion (DEV-1089).
	private static func movedAcrossProfiles(
		_ organization: OrganizationRows,
		replacing old: OrganizationRows,
		moves: [UUID: [UUID]]
	) -> Set<UUID> {
		func isHere(_ id: UUID, in rows: OrganizationRows) -> Bool {
			rows.pinnedTabs[id] != nil || rows.favorites[id] != nil || rows.regularTabs[id] != nil
		}
		var moved: Set<UUID> = []
		for (copy, sources) in moves {
			guard
				isHere(copy, in: organization),
				!isHere(copy, in: old),
				let source = sources.first(where: { isHere($0, in: old) }),
				old.pinnedTabs[source] != nil || old.favorites[source] != nil,
				!isHere(source, in: organization)
			else { continue }

			moved.insert(source)
		}
		return moved
	}

	/// The synced items a save shows were used (DEV-980): edited ones, a space whose selected tab
	/// changed and that tab, a folder that was expanded, and the profile of a used space or Favorite.
	private static func usedItems(
		_ organization: OrganizationRows,
		replacing old: OrganizationRows,
		edited: [(table: String, ids: [UUID])]
	) -> [UUID: String] {
		var used: [UUID: String] = [:]
		for (table, ids) in edited {
			for id in ids { used[id] = table }
		}
		for (spaceID, state) in organization.spaceStates where old.spaceStates[spaceID] != state {
			used[spaceID] = SpaceRecord.tableName
			guard let tabID = state.selectedTabID else { continue }

			if organization.pinnedTabs[tabID] != nil {
				used[tabID] = PinnedTabRecord.tableName
			} else if organization.favorites[tabID] != nil {
				used[tabID] = FavoriteRecord.tableName
			}
		}
		for (folderID, state) in organization.folderStates
		where state.isExpanded && old.folderStates[folderID]?.isExpanded != true {
			used[folderID] = FolderRecord.tableName
		}
		for (id, table) in used {
			let profileID: UUID? = switch table {
			case SpaceRecord.tableName: organization.spaces[id]?.profileID
			case FavoriteRecord.tableName: organization.favorites[id]?.profileID
			default: nil
			}
			if let profileID, organization.profiles[profileID] != nil {
				used[profileID] = ProfileRecord.tableName
			}
		}
		return used
	}

	private static func apply(
		_ preferences: PreferenceRows,
		replacing old: PreferenceRows,
		_ db: Database,
		_ summary: inout WriteSummary
	) throws {
		var deletions: [() throws -> Void] = []
		try step(preferences.domains, old.domains, db, &summary, &deletions)
		try step(preferences.searchShortcuts, old.searchShortcuts, db, &summary, &deletions)
		try step(preferences.keyboardShortcuts, old.keyboardShortcuts, db, &summary, &deletions)
		try step(preferences.routingRules, old.routingRules, db, &summary, &deletions)
		try step(preferences.proxyLinkRules, old.proxyLinkRules, db, &summary, &deletions)
		try step(preferences.local, old.local, db, &summary, &deletions)
		for deletion in deletions.reversed() {
			try deletion()
		}
	}

	/// Upserts the rows of one table that changed and queues the deletion of those removed, unless
	/// `deletesRemoved` is off.
	///
	/// - Returns: the IDs upserted and the IDs removed.
	@discardableResult
	private static func step<Record: PrimaryKeyedTable & Identifiable & Equatable>(
		_ new: [Record.ID: Record],
		_ old: [Record.ID: Record],
		_ db: Database,
		_ summary: inout WriteSummary,
		_ deletions: inout [() throws -> Void],
		deletesRemoved: Bool = true
	) throws -> (changed: [Record.ID], removed: [Record.ID])
	where Record.QueryOutput == Record, Record.ID: QueryBindable, Record.ID.QueryValue == Record.PrimaryKey {
		let changed: [Record] = new.values.filter { old[$0.id] != $0 }
		if !changed.isEmpty {
			summary.upserted[Record.tableName] = changed.count
			for batch in stride(from: 0, to: changed.count, by: 200) {
				let rows: [Record] = Array(changed[batch ..< min(batch + 200, changed.count)])
				try Record.upsert { rows }.execute(db)
			}
		}
		let removed: [Record.ID] = old.keys.filter { new[$0] == nil }
		if !removed.isEmpty, deletesRemoved {
			summary.deleted[Record.tableName] = removed.count
			deletions.append {
				for batch in stride(from: 0, to: removed.count, by: 500) {
					let ids: [Record.ID] = Array(removed[batch ..< min(batch + 500, removed.count)])
					try Record.find(ids).delete().execute(db)
				}
			}
		}
		return (changed.map(\.id), removed)
	}
}
