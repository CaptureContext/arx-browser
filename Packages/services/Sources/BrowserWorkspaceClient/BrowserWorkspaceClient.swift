import BrowserCore
import Darwin
import Foundation
import HistoryDatabase
import os
import WorkspaceDatabase

/// Serializes local metadata and preserves the previous validated snapshot before replacement.
/// Live sessions and credentials belong to Chromium's profile directories, never this file.
///
/// With ``Storage/sqlite`` (the `ARX_SQLITE_WORKSPACE` feature flag) the workspace lives in
/// ``WorkspaceDatabase`` beside the file instead, migrated from the file on first use. The JSON file
/// is then only ever read: never written, renamed or replaced, so turning the flag off returns to it.
/// ADR 0001's rename to `arx-workspace.v4.json` and version-5 stub wait until the flag goes away.
public final class BrowserWorkspaceClient: @unchecked Sendable {
	/// Where the workspace lives.
	public enum Storage: Equatable, Sendable {
		/// The JSON file, as before SQLite.
		case json

		/// ``WorkspaceDatabase`` in the file's folder (DEV-560, phase 1).
		case sqlite

		/// The `ARX_SQLITE_WORKSPACE` feature flag, through the `FeatureFlag` registry: the
		/// environment first, then user defaults. On by default (DEV-1143), so a first launch
		/// migrates the file; `0`, `false`, `no` or `off` keeps the JSON file.
		public init(
			environment: [String: String],
			defaults: UserDefaults = .standard
		) {
			self = FeatureFlag.sqliteWorkspace.isOn(environment: environment, defaults: defaults) ? .sqlite : .json
		}

		public static let featureFlag: String = FeatureFlag.sqliteWorkspace.name
	}

	public struct Recovery: Sendable {
		public var organization: BrowserOrganization?
		public var usedBackup: Bool
		public var preferences: BrowserPreferences

		public init(
			organization: BrowserOrganization?,
			usedBackup: Bool,
			preferences: BrowserPreferences
		) {
			self.organization = organization
			self.usedBackup = usedBackup
			self.preferences = preferences
		}

		/// An older fallback cannot silently restore obsolete assistant grants.
		public func applyingAutomationRecoveryPolicy(makeID: () -> UUID = UUID.init) -> Self {
			guard usedBackup else { return self }
			var recovered = self
			recovered.preferences.automation = recovered.preferences.automation.revokingGrants(makeID: makeID)
			recovered.preferences.automation.isEnabled = false
			return recovered
		}
	}

	/// Language-neutral; AppFeature maps each case to the shared string catalog.
	public enum Failure: Error, Equatable, Sendable {
		case unsupportedVersion(Int)
		case unsupportedOrganization
		case changedOnDisk
		case synchronizationFailed
	}

	/// The writer must replace a file atomically or throw without changing it.
	public typealias AtomicWriter = @Sendable (Data, URL) throws -> Void
	private let file: URL

	/// `.json` again for the rest of the run when the database couldn't open or migrate.
	public var storage: Storage { lock.withLock { _storage } }

	/// Why the database couldn't take over this run, when it couldn't.
	public var databaseFailure: (any Error)? { lock.withLock { _databaseFailure } }
	private var _storage: Storage
	private var _databaseFailure: (any Error)?
	private var database: WorkspaceDatabase?

	/// Preference rows go through the preferences file's own connection, for iCloud sync.
	private let separatePreferencesConnection: Bool
	private let securitySynchronizer: @Sendable (URL) throws -> Void
	private let write: AtomicWriter
	private let lock: NSLock = .init()

	/// Guards only `issuedTicket`, so reserving a ticket never waits behind a write that holds
	/// `lock` (a headless stop reserves one on the main actor; DEV-865).
	private let ticketLock: NSLock = .init()
	private var loaded: Bool = false
	private var expectedBytes: Data?
	private var validatedBytes: Data?
	private var revision: Int = 0

	/// The version of the JSON snapshot last read, before migrating it in memory.
	private var sourceVersion: Int = 4
	private var recovered: Bool = false
	private var preferences: BrowserPreferences = .init()
	private var expectedAttributes: FileAttributes?
	private var savedOrganization: BrowserOrganization?
	private var backupBytes: Data?
	private var issuedTicket: UInt64 = 0
	private var writtenTicket: UInt64 = 0

	public init(
		file: URL,
		storage: Storage = .json,
		separatePreferencesConnection: Bool = false,
		write: @escaping AtomicWriter = { try $0.write(to: $1, options: .atomic) },
		securitySynchronizer: (@Sendable (URL) throws -> Void)? = nil
	) {
		self.securitySynchronizer = securitySynchronizer ?? Self.synchronizeSecuritySnapshot
		self.file = file
		self._storage = storage
		self.separatePreferencesConnection = separatePreferencesConnection
		self.write = write
	}

	public func load() throws -> BrowserOrganization? {
		try loadWithRecovery().organization
	}

	/// The SQLite store this run uses, once loaded; `nil` while the workspace is the JSON file.
	/// iCloud sync makes its engines on its connections.
	public var workspaceDatabase: WorkspaceDatabase? {
		lock.withLock { _storage == .sqlite ? database : nil }
	}

	/// Records that this Mac opened these spaces, pinned tabs and Favorites (DEV-980); see
	/// ``WorkspaceDatabase/recordUse(of:now:)``. Does nothing while the workspace is the JSON file.
	public func recordUse(of ids: Set<UUID>) throws {
		try workspaceDatabase?.recordUse(of: ids)
	}

	/// "Delete from This Mac Only" for these profiles or spaces (DEV-1336), before the save that
	/// removes them; see ``WorkspaceDatabase/keepRemovalOnThisMac(_:)``.
	public func keepRemovalOnThisMac(_ ids: Set<UUID>) {
		workspaceDatabase?.keepRemovalOnThisMac(ids)
	}

	/// The preferences last saved or loaded, which a reload reads back.
	public var savedPreferences: BrowserPreferences {
		lock.withLock { preferences }
	}

	/// Reads the database again after something other than this client changed its rows, as iCloud
	/// sync does, and accepts what it holds as saved. `nil` while the workspace is the JSON file or
	/// the store is empty. The caller makes sure no edit of its own is waiting to be saved.
	///
	/// - Parameters:
	///   - accepting: the caller's check of what was read, before it's accepted. When it
	///     throws, what this client and the store saved last stays the base later saves diff against.
	public func reloadDatabase(
		accepting: (BrowserOrganization) throws -> Void = { _ in }
	) throws -> Recovery? {
		try lock.withLock {
			guard
				_storage == .sqlite,
				let database,
				let snapshot = try loadDatabase(database, accepting: accepting)
			else { return nil }

			return .init(organization: snapshot.organization, usedBackup: false, preferences: snapshot.preferences)
		}
	}

	public var hasPersistedLegacyProfileIdentity: Bool {
		lock.withLock {
			// The database stores the legacy owner with every workspace it holds.
			if _storage == .sqlite, savedOrganization != nil { return true }
			guard let expectedBytes else { return false }
			do {
				return try JSONDecoder().decode(Header.self, from: expectedBytes).version >= 3
			} catch {
				return false
			}
		}
	}

	/// A future version is never replaced with an older backup. Corrupt data is preserved.
	public func loadWithRecovery() throws -> Recovery {
		try lock.withLock { try read() }
	}

	/// Orders asynchronous saves. Reserve a ticket at the moment the snapshot is selected,
	/// then pass it to ``save(_:preferences:synchronizeSecurityChange:ticket:)``.
	public struct SaveTicket: Comparable, Sendable {
		internal let rawValue: UInt64

		internal init(rawValue: UInt64) {
			self.rawValue = rawValue
		}

		public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
	}

	public func reserveSaveTicket() -> SaveTicket {
		ticketLock.withLock {
			issuedTicket += 1
			return .init(rawValue: issuedTicket)
		}
	}

	/// Writes off the caller's actor.
	///
	/// - Returns: `false` when a newer ticket was already written, so this snapshot is obsolete.
	@concurrent
	public func save(
		_ organization: BrowserOrganization,
		preferences: BrowserPreferences? = nil,
		synchronizeSecurityChange: Bool = false,
		ticket: SaveTicket
	) async throws -> Bool {
		try lock.withLock {
			guard ticket.rawValue > writtenTicket else { return false }
			try performSave(
				organization,
				preferences: preferences,
				synchronizeSecurityChange: synchronizeSecurityChange
			)
			writtenTicket = ticket.rawValue
			return true
		}
	}

	public func save(
		_ organization: BrowserOrganization,
		preferences: BrowserPreferences? = nil,
		synchronizeSecurityChange: Bool = false
	) throws {
		try lock.withLock {
			try performSave(
				organization,
				preferences: preferences,
				synchronizeSecurityChange: synchronizeSecurityChange
			)
		}
	}

	/// Keeps a Preferences group on this Mac or syncs it again (DEV-982), saving the workspace with
	/// it; see ``WorkspaceDatabase/setPreferenceGroup(_:syncs:keepingThisMac:organization:preferences:)``.
	/// Saves with an earlier ticket are obsolete afterwards, so none writes the group under the old
	/// choice. A save with a later one already written makes this use what it saved instead. Does
	/// nothing while the workspace is the JSON file.
	///
	/// - Returns: the preferences saved.
	@concurrent
	public func setPreferenceGroup(
		_ group: PreferenceGroup,
		syncs: Bool,
		keepingThisMac: Bool,
		organization: BrowserOrganization,
		preferences: BrowserPreferences,
		ticket: SaveTicket
	) async throws -> BrowserPreferences {
		try lock.withLock {
			guard _storage == .sqlite, let database else { return preferences }

			var organization: BrowserOrganization = organization
			var preferences: BrowserPreferences = preferences
			if ticket.rawValue <= writtenTicket, let savedOrganization {
				organization = savedOrganization
				preferences = self.preferences
			}
			Self.repairSelections(in: &organization)
			try Self.validate(organization)
			if !loaded { _ = try read() }
			organization.legacyProfileID = organization.legacyProfileID ?? organization.profiles.first?.id
			let saved: BrowserPreferences
			do {
				saved = try database.setPreferenceGroup(
					group,
					syncs: syncs,
					keepingThisMac: keepingThisMac,
					organization: organization,
					preferences: preferences,
					validate: { try $0.validate() }
				)
			} catch WorkspaceDatabase.Failure.changedOnDisk {
				throw Failure.changedOnDisk
			}
			savedOrganization = organization
			self.preferences = saved
			writtenTicket = max(writtenTicket, ticket.rawValue)
			return saved
		}
	}

	private func performSave(
		_ organization: BrowserOrganization,
		preferences: BrowserPreferences?,
		synchronizeSecurityChange: Bool
	) throws {
		var organization = organization
		Self.repairSelections(in: &organization)
		try Self.validate(organization)
		if !loaded { _ = try read() }
		if _storage == .sqlite, let database {
			let preferences = preferences ?? self.preferences
			try preferences.validate()
			try saveToDatabase(database, organization, preferences: preferences)
			return
		}
		guard try fileIsUnchanged() else { throw Failure.changedOnDisk }
		let preferences = preferences ?? self.preferences
		try preferences.validate()

		// Skips encoding and both writes when the file and its backup already hold this value.
		let isRedundant = !recovered
		&& savedOrganization == organization
		&& self.preferences == preferences
		&& backupBytes == expectedBytes

		if !isRedundant {
			let data = try Self.encode(organization, revision: revision + 1, preferences: preferences)
			try FileManager.default.createDirectory(
				at: file.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			if recovered, let expectedBytes {
				// Preserve the damaged original before allowing any subsequent save.
				try write(expectedBytes, file.appendingPathExtension("damaged-\(UUID().uuidString)"))
			}
			if let validatedBytes {
				try write(validatedBytes, backupFile)
				backupBytes = validatedBytes
			}
			try write(data, file)
			expectedBytes = data
			expectedAttributes = FileAttributes(of: file)
			validatedBytes = data
			savedOrganization = organization
			revision += 1
			recovered = false
		}
		self.preferences = preferences

		// Atomic replacement already completed. Update the expected-byte state
		// before a fallible sync so a retry remains possible after rename.
		// A sync failure does NOT claim that the file was left unchanged.
		if synchronizeSecurityChange { try securitySynchronizer(file) }
	}

	/// Compares cheap file attributes first; reads the file only when they differ,
	/// so an unrelated metadata change still can't cause a false conflict.
	private func fileIsUnchanged() throws -> Bool {
		if let expectedAttributes, expectedAttributes == FileAttributes(of: file) { return true }
		guard try bytes(at: file) == expectedBytes else { return false }
		expectedAttributes = FileAttributes(of: file)
		return true
	}

	private static func synchronizeSecuritySnapshot(_ file: URL) throws {
		let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		guard descriptor >= 0 else { throw Failure.synchronizationFailed }
		defer { close(descriptor) }
		let directory = open(
			file.deletingLastPathComponent().path,
			O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
		)
		guard directory >= 0 else { throw Failure.synchronizationFailed }
		defer { close(directory) }
		guard fsync(descriptor) == 0, fsync(directory) == 0
		else { throw Failure.synchronizationFailed }
	}

	/// Export is independent of the primary file and does not mark pending edits as saved.
	public func export(
		_ organization: BrowserOrganization,
		preferences: BrowserPreferences = .init(),
		to destination: URL
	) throws {
		// The database files are primary storage while the feature flag is on, and never an export.
		let directory: URL = file.deletingLastPathComponent()
		let protected: [URL] = [file, backupFile] + WorkspaceDatabase.files(in: directory) + HistoryDatabase.files(in: directory)
		guard !protected.contains(where: { $0.standardizedFileURL == destination.standardizedFileURL })
		else { throw Failure.changedOnDisk }
		var organization = organization
		Self.repairSelections(in: &organization)
		try Self.validate(organization)
		try preferences.validate()
		try write(Self.encode(organization, revision: 0, preferences: preferences), destination)
	}

	private var backupFile: URL { file.appendingPathExtension("backup") }

	private func bytes(at url: URL) throws -> Data? {
		do {
			return try Data(contentsOf: url)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return nil
		}
	}

	private func read() throws -> Recovery {
		switch _storage {
		case .json: try readFile()
		case .sqlite: try readDatabase()
		}
	}

	/// The database's workspace, or the file's migrated into the database in one transaction. A new
	/// store that can't open, or a store that can't migrate, leaves the file as it was and the run
	/// continues on the file. An existing store that can't open or read fails, as a corrupt file
	/// without a backup does: it may hold edits the file never saw.
	private func readDatabase() throws -> Recovery {
		let database: WorkspaceDatabase
		let directory: URL = file.deletingLastPathComponent()
		let existed: Bool = WorkspaceDatabase.files(in: directory).contains {
			FileManager.default.fileExists(atPath: $0.path)
		}
		do {
			database = try self.database ?? WorkspaceDatabase(
				directory: directory,
				separatePreferencesConnection: separatePreferencesConnection
			)
		} catch {
			// A store with a workspace, this run's or another's, may hold edits the file never saw,
			// and so may an unreadable one that was here before. Only this attempt's own leftovers,
			// or nothing, fall back to the file.
			switch WorkspaceDatabase.contents(of: directory) {
			case .workspace: throw error
			case .unreadable where existed: throw error
			case .unreadable, .empty: return try fallBackToFile(after: error)
			}
		}
		self.database = database

		if let snapshot = try loadDatabase(database) {
			return .init(organization: snapshot.organization, usedBackup: false, preferences: snapshot.preferences)
		}

		var recovery = try readFile()

		// A backup's assistant grants are revoked before they reach the database, which a later
		// launch reads as a normal load, never as a recovery.
		if recovery.usedBackup {
			let revoked = recovery.applyingAutomationRecoveryPolicy().preferences
			recovery.preferences = revoked
		}
		guard let organization = recovery.organization else {
			// A first launch: the first save creates the workspace in the database.
			acceptDatabase(nil, preferences: recovery.preferences)
			return recovery
		}
		do {
			try database.migrate(
				organization: organization,
				preferences: recovery.preferences,
				fromWorkspaceVersion: sourceVersion,
				sourceRevision: revision
			)
		} catch {
			// Another run may have migrated first: its workspace wins, as the file's next writer would.
			// A store that is still empty leaves this run on the file; one that can't be read fails.
			if let snapshot = try loadDatabase(database) {
				return .init(organization: snapshot.organization, usedBackup: false, preferences: snapshot.preferences)
			}
			return try fallBackToFile(after: error)
		}
		acceptDatabase(organization, preferences: recovery.preferences)
		return recovery
	}

	/// The database's validated workspace, accepted as saved, or `nil` when it has none.
	private func loadDatabase(
		_ database: WorkspaceDatabase,
		accepting: (BrowserOrganization) throws -> Void = { _ in }
	) throws -> WorkspaceDatabase.Snapshot? {
		let stored: WorkspaceDatabase.Snapshot?
		do {
			stored = try database.load { snapshot in
				try Self.validate(snapshot.organization)
				try snapshot.preferences.validate()
				try accepting(snapshot.organization)
			}
		} catch WorkspaceDatabase.Failure.partialStore {
			throw Failure.unsupportedOrganization
		}
		guard let snapshot = stored else { return nil }

		acceptDatabase(snapshot.organization, preferences: snapshot.preferences)
		return snapshot
	}

	private func fallBackToFile(after error: any Error) throws -> Recovery {
		_storage = .json
		database = nil
		_databaseFailure = error
		return try readFile()
	}

	private func acceptDatabase(
		_ organization: BrowserOrganization?,
		preferences: BrowserPreferences
	) {
		self.savedOrganization = organization
		self.preferences = preferences
		self.recovered = false
		self.loaded = true
	}

	private func saveToDatabase(
		_ database: WorkspaceDatabase,
		_ organization: BrowserOrganization,
		preferences: BrowserPreferences
	) throws {
		var organization = organization
		organization.legacyProfileID = organization.legacyProfileID ?? organization.profiles.first?.id
		do {
			// Each commit is synchronous and covers both files, so a security change is on disk
			// once this returns; the file's separate sync doesn't apply.
			try database.save(organization, preferences: preferences)
		} catch WorkspaceDatabase.Failure.changedOnDisk {
			throw Failure.changedOnDisk
		}
		savedOrganization = organization
		self.preferences = preferences
	}

	private func readFile() throws -> Recovery {
		let primary = try bytes(at: file)
		var source = primary
		var usedBackup = false
		let snapshot: Snapshot?
		do {
			snapshot = try primary.map(Self.decode)
		} catch let Failure.unsupportedVersion(version) {
			throw Failure.unsupportedVersion(version)
		} catch {
			guard let backup = try bytes(at: backupFile) else { throw error }
			snapshot = try Self.decode(backup)
			source = backup
			usedBackup = true
		}

		// A missing primary may follow interrupted setup; don't silently discard its backup.
		if primary == nil, let backup = try bytes(at: backupFile) {
			let snapshot = try Self.decode(backup)
			accept(snapshot, primary: nil, validated: backup, recovered: true)
			return .init(
				organization: snapshot.organization,
				usedBackup: true,
				preferences: snapshot.preferences
			)
		}
		accept(snapshot, primary: primary, validated: source, recovered: usedBackup)
		return .init(
			organization: snapshot?.organization,
			usedBackup: usedBackup,
			preferences: snapshot?.preferences ?? .init()
		)
	}

	private func accept(
		_ snapshot: Snapshot?,
		primary: Data?,
		validated: Data?,
		recovered: Bool
	) {
		self.expectedBytes = primary
		self.expectedAttributes = primary == nil ? nil : FileAttributes(of: file)
		self.validatedBytes = validated
		self.backupBytes = nil
		self.savedOrganization = primary == nil ? nil : snapshot?.organization
		self.revision = snapshot?.revision ?? 0
		self.sourceVersion = snapshot?.version ?? 4
		self.preferences = snapshot?.preferences ?? .init()
		self.recovered = recovered
		self.loaded = true
	}

	private struct Header: Decodable {
		internal var version: Int

		internal init(version: Int) {
			self.version = version
		}
	}

	private struct Snapshot: Codable {
		internal var version: Int
		internal var revision: Int
		internal var organization: BrowserOrganization
		internal var preferences: BrowserPreferences

		private enum CodingKeys: String, CodingKey {
			case version
			case revision
			case organization
			case preferences
		}

		internal init(
			version: Int,
			revision: Int,
			organization: BrowserOrganization,
			preferences: BrowserPreferences = .init()
		) {
			self.version = version
			self.revision = revision
			self.organization = organization
			self.preferences = preferences
		}

		internal init(from decoder: any Decoder) throws {
			let values = try decoder.container(keyedBy: CodingKeys.self)
			self.version = try values.decode(Int.self, forKey: .version)
			self.revision = try values.decode(Int.self, forKey: .revision)
			self.organization = try values.decode(BrowserOrganization.self, forKey: .organization)
			self.preferences = try values.decodeIfPresent(
				BrowserPreferences.self,
				forKey: .preferences
			) ?? .init()
		}
	}

	private struct VersionOne: Decodable {
		internal var organization: BrowserOrganization

		internal init(organization: BrowserOrganization) {
			self.organization = organization
		}
	}

	private static func decode(_ data: Data) throws -> Snapshot {
		let decoder: JSONDecoder = .init()
		decoder.userInfo[AppearanceOverride.storageCoding] = true
		let version = try decoder.decode(Header.self, from: data).version
		var snapshot: Snapshot
		switch version {
		case 1:
			// V1 had no revision. Its organization/identities remain unchanged. The version stays 1
			// so a migration into the database records where it came from.
			snapshot = .init(
				version: 1,
				revision: 0,
				organization: try decoder.decode(VersionOne.self, from: data).organization
			)

		case 2, 3, 4:
			snapshot = try decoder.decode(Snapshot.self, from: data)

		default:
			throw Failure.unsupportedVersion(version)
		}

		if version < 3 {
			snapshot.organization.legacyProfileID = snapshot.organization.legacyProfileID
			?? snapshot.organization.profiles.first?.id
		} else if snapshot.organization.legacyProfileID == nil {
			throw Failure.unsupportedOrganization
		}

		try validate(snapshot.organization)
		try snapshot.preferences.validate()
		return snapshot
	}

	/// Clears a space's selection of a tab it doesn't hold, which would otherwise refuse the whole
	/// save, and logs each one so the action that left it can be found (DEV-1261).
	private static func repairSelections(in organization: inout BrowserOrganization) {
		for repair in organization.repairSelections() {
			log.error(
				"Saved without an invalid selection: space \(repair.spaceID.rawValue, privacy: .public) selected tab \(repair.tabID.rawValue, privacy: .public), which it doesn't hold."
			)
		}
	}

	private static func validate(_ organization: BrowserOrganization) throws {
		try organization.validate()
		guard
			!organization.profiles.isEmpty,
			!organization.spaces.isEmpty
		else { throw Failure.unsupportedOrganization }
	}

	private static func encode(
		_ organization: BrowserOrganization,
		revision: Int,
		preferences: BrowserPreferences
	) throws -> Data {
		var organization = organization
		organization.legacyProfileID = organization.legacyProfileID ?? organization.profiles.first?.id
		let snapshot: Snapshot = .init(
			version: 4,
			revision: revision,
			organization: organization,
			preferences: preferences
		)
		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.sortedKeys]
		encoder.userInfo[AppearanceOverride.storageCoding] = true
		return try encoder.encode(snapshot)
	}

	/// Identity, size and modification time; an atomic replacement always changes the inode.
	private struct FileAttributes: Equatable {
		private let inode: UInt64
		private let size: Int64
		private let modification: timespec

		internal init?(of url: URL) {
			var info: stat = .init()
			guard stat(url.path, &info) == 0 else { return nil }
			self.inode = info.st_ino
			self.size = info.st_size
			self.modification = info.st_mtimespec
		}

		internal static func == (lhs: Self, rhs: Self) -> Bool {
			lhs.inode == rhs.inode
			&& lhs.size == rhs.size
			&& lhs.modification.tv_sec == rhs.modification.tv_sec
			&& lhs.modification.tv_nsec == rhs.modification.tv_nsec
		}
	}
}

private let log: Logger = .init(subsystem: "dev.capturecontext.arx", category: "Workspace")
