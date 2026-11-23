import BrowserCore
import Darwin
import Foundation

/// Private installation identity and consent live under this exact browser root,
/// independently of exportable workspace metadata and its recovery backups.
public final class BrowserProfileRetirementStore: @unchecked Sendable {
	/// Language-neutral; AppFeature maps each case to the shared string catalog.
	public enum Failure: Error, Equatable, Sendable {
		case ownershipChanged
		case corrupt
		case busy
		case io
		case limit
	}

	public let installationID: UUID
	public let rootDirectory: URL
	public let legacyProfileID: Profile.ID
	private let root: URL
	private let rootDescriptor: Int32
	private let lockDescriptor: Int32
	private let device: UInt64
	private let volume: UUID
	private let inode: UInt64
	private let lockInode: UInt64
	private let mutex: NSLock = .init()
	private static let identityName: String = ".arx-installation-v1"
	private static let intentsName: String = ".arx-profile-retirement-intents-v1"
	private static let lockName: String = ".arx-profile-retirement-lock"

	public init(
		root: URL,
		legacyProfileID: Profile.ID,
		uuid: () -> UUID = { UUID() }
	) throws {
		guard
			root.isFileURL,
			let resolved = realpath(root.path, nil)
		else { throw Failure.ownershipChanged }
		let physicalRoot = URL(fileURLWithPath: String(cString: resolved))
		free(resolved)
		let directory = try Self.openRoot(physicalRoot)
		var rootInfo = stat()
		guard
			fstat(directory, &rootInfo) == 0,
			rootInfo.st_uid == getuid(),
			rootInfo.st_mode & 0o022 == 0,
			let volume = Self.volume(of: directory)
		else {
			close(directory)
			throw Failure.ownershipChanged
		}
		let descriptor = openat(
			directory,
			Self.lockName,
			O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
			0o600
		)
		guard descriptor >= 0 else {
			close(directory)
			throw Failure.io
		}
		var lockInfo = stat()
		guard
			fstat(descriptor, &lockInfo) == 0,
			Self.privateFile(lockInfo),
			flock(descriptor, LOCK_EX | LOCK_NB) == 0
		else {
			close(descriptor)
			close(directory)
			throw Failure.busy
		}
		do {
			defer { flock(descriptor, LOCK_UN) }
			var identity: Identity
			if let bytes = try Self.read(Self.identityName, directory: directory) {
				identity = try JSONDecoder().decode(Identity.self, from: bytes)
				if identity.version == 1 {
					// Version 1 bound st_dev, which macOS renumbers across reboots.
					// Path and inode still identify the root; rebind to its volume.
					guard
						identity.legacyProfileID == legacyProfileID,
						identity.rootPath == physicalRoot.path,
						identity.inode == rootInfo.st_ino
					else { throw Failure.ownershipChanged }
					identity = .init(
						installationID: identity.installationID,
						legacyProfileID: identity.legacyProfileID,
						rootPath: identity.rootPath,
						volume: volume,
						inode: identity.inode
					)
					try Self.replace(
						Self.encode(identity),
						name: Self.identityName,
						directory: directory
					)
				}
			} else {
				// Never adopt an existing journal by manufacturing a new identity.
				guard
					try Self.read(".arx-profile-erasure-v1", directory: directory) == nil,
					try Self.read(Self.intentsName, directory: directory) == nil
				else { throw Failure.corrupt }
				identity = .init(
					installationID: uuid(),
					legacyProfileID: legacyProfileID,
					rootPath: physicalRoot.path,
					volume: volume,
					inode: rootInfo.st_ino
				)
				try Self.create(
					Self.encode(identity),
					name: Self.identityName,
					directory: directory
				)
			}
			guard
				identity.version == Identity.currentVersion,
				identity.legacyProfileID == legacyProfileID,
				identity.rootPath == physicalRoot.path,
				identity.volume == volume,
				identity.inode == rootInfo.st_ino
			else { throw Failure.ownershipChanged }
			if try Self.read(Self.intentsName, directory: directory) == nil {
				guard try Self.read(".arx-profile-erasure-v1", directory: directory) == nil
				else { throw Failure.corrupt }
				let intents: Intents = .init(
					version: 1,
					installationID: identity.installationID,
					values: []
				)
				try Self.create(
					Self.encode(intents),
					name: Self.intentsName,
					directory: directory
				)
			}
			self.installationID = identity.installationID
			self.rootDirectory = physicalRoot
			self.legacyProfileID = identity.legacyProfileID
			self.root = physicalRoot
			self.rootDescriptor = directory
			self.lockDescriptor = descriptor
			self.device = UInt64(truncatingIfNeeded: rootInfo.st_dev)
			self.volume = volume
			self.inode = rootInfo.st_ino
			self.lockInode = lockInfo.st_ino
		} catch {
			close(descriptor)
			close(directory)
			throw error
		}
		_ = try load()
	}

	deinit {
		close(lockDescriptor)
		close(rootDescriptor)
	}

	public func load() throws -> [ProfileRetirementIntent] {
		try locked { try readIntents().values }
	}

	/// A failed first setup must not disable ordinary retain-data browsing. Once
	/// a native ledger or any consent exists, unknown retired IDs cannot safely be
	/// admitted through ordinary Run; those failures require record recovery.
	public static func permitsOrdinaryBrowsingAfterInitializationFailure(root: URL) -> Bool {
		guard
			root.isFileURL,
			let resolved = realpath(root.path, nil)
		else { return false }

		defer { free(resolved) }
		do {
			let directory = try openRoot(URL(fileURLWithPath: String(cString: resolved)))
			defer { close(directory) }
			guard try read(".arx-profile-erasure-v1", directory: directory) == nil
			else { return false }
			guard let bytes = try read(intentsName, directory: directory) else { return true }
			let intents = try JSONDecoder().decode(Intents.self, from: bytes)
			return intents.version == 1 && intents.values.isEmpty
		} catch {
			return false
		}
	}

	/// Called before irreversible dispatch, including each retry's fresh revision.
	public func record(_ intent: ProfileRetirementIntent) throws {
		try locked {
			guard
				intent.expectedRevision > 0,
				intent.attemptRevision >= intent.expectedRevision,
				intent.profileName.utf8.count <= 4096
			else { throw Failure.corrupt }
			var record = try readIntents()
			if let index = record.values.firstIndex(where: { $0.profileID == intent.profileID }) {
				let prior = record.values[index]
				guard
					prior.requestID == intent.requestID,
					prior.expectedRevision == intent.expectedRevision,
					prior.profileName == intent.profileName,
					!prior.acknowledged,
					intent.attemptRevision >= prior.attemptRevision,
					!intent.acknowledged
				else { throw Failure.corrupt }
				record.values[index] = intent
			} else {
				guard record.values.count < 128 else { throw Failure.limit }
				guard
					!record.values.contains(where: { $0.requestID == intent.requestID }),
					!intent.acknowledged
				else { throw Failure.corrupt }
				record.values.append(intent)
			}
			try save(record)
		}
	}

	public func acknowledge(_ requestID: UUID) throws {
		try locked {
			var record = try readIntents()
			guard let index = record.values.firstIndex(where: { $0.requestID == requestID })
			else { throw Failure.corrupt }
			if record.values[index].acknowledged { return }
			record.values[index].acknowledged = true
			try save(record)
		}
	}

	private func locked<T>(_ operation: () throws -> T) throws -> T {
		try mutex.withLock {
			guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
			defer { flock(lockDescriptor, LOCK_UN) }
			try validate()
			return try operation()
		}
	}

	private func validate() throws {
		let current = try Self.openRoot(root)
		defer { close(current) }
		var info = stat()
		var held = stat()
		var lockInfo = stat()
		guard
			fstat(current, &info) == 0,
			fstat(rootDescriptor, &held) == 0,
			UInt64(truncatingIfNeeded: info.st_dev) == device,
			info.st_ino == inode,
			info.st_ino == held.st_ino,
			info.st_uid == getuid(),
			info.st_mode & 0o022 == 0,
			fstatat(rootDescriptor, Self.lockName, &lockInfo, AT_SYMLINK_NOFOLLOW) == 0,
			Self.privateFile(lockInfo),
			lockInfo.st_ino == lockInode
		else { throw Failure.ownershipChanged }
		guard let bytes = try Self.read(Self.identityName, directory: rootDescriptor) else {
			throw Failure.corrupt
		}
		let identity = try JSONDecoder().decode(Identity.self, from: bytes)
		guard
			identity.version == Identity.currentVersion,
			identity.installationID == installationID,
			identity.legacyProfileID == legacyProfileID,
			identity.rootPath == root.path,
			identity.volume == volume,
			identity.inode == inode
		else { throw Failure.ownershipChanged }
	}

	private func readIntents() throws -> Intents {
		guard let bytes = try Self.read(Self.intentsName, directory: rootDescriptor) else {
			throw Failure.corrupt
		}
		let record = try JSONDecoder().decode(Intents.self, from: bytes)
		guard
			record.version == 1,
			record.installationID == installationID,
			record.values.count <= 128,
			Set(record.values.map(\.profileID)).count == record.values.count,
			Set(record.values.map(\.requestID)).count == record.values.count,
			record.values.allSatisfy({
				$0.expectedRevision > 0
				&& $0.attemptRevision >= $0.expectedRevision
				&& $0.profileName.utf8.count <= 4096
			})
		else { throw Failure.corrupt }
		return record
	}

	private func save(_ record: Intents) throws {
		let bytes = try Self.encode(record)
		guard bytes.count <= 128 * 1024 else { throw Failure.limit }
		let temporary = ".arx-retirement-writing-" + UUID().uuidString.lowercased()
		try Self.create(bytes, name: temporary, directory: rootDescriptor)
		defer { unlinkat(rootDescriptor, temporary, 0) }
		try validate()
		guard
			renameat(rootDescriptor, temporary, rootDescriptor, Self.intentsName) == 0,
			fsync(rootDescriptor) == 0
		else { throw Failure.io }
	}

	private static func openRoot(_ root: URL) throws -> Int32 {
		var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		guard descriptor >= 0 else { throw Failure.io }
		for component in root.pathComponents.dropFirst() {
			let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			close(descriptor)
			guard next >= 0 else { throw Failure.ownershipChanged }
			descriptor = next
		}
		return descriptor
	}

	/// Stable across reboots and OS updates, unlike `st_dev`, which macOS
	/// assigns at mount time. Live checks within a session still use `st_dev`.
	private static func volume(of descriptor: Int32) -> UUID? {
		var request = attrlist()
		request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
		request.volattr = attrgroup_t(truncatingIfNeeded: ATTR_VOL_INFO)
		| attrgroup_t(truncatingIfNeeded: ATTR_VOL_UUID)

		// Packed reply: UInt32 length followed by a 16-byte uuid_t.
		var reply = [UInt8](repeating: 0, count: 20)
		let result = reply.withUnsafeMutableBytes { buffer in
			fgetattrlist(descriptor, &request, buffer.baseAddress, buffer.count, 0)
		}
		guard
			result == 0,
			reply.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == 20
		else { return nil }
		let value = reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: uuid_t.self) }
		let volume = UUID(uuid: value)
		return volume == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) ? nil : volume
	}

	private static func privateFile(_ info: stat) -> Bool {
		info.st_mode & S_IFMT == S_IFREG
		&& info.st_uid == getuid()
		&& info.st_nlink == 1
		&& info.st_mode & 0o077 == 0
	}

	private static func read(
		_ name: String,
		directory: Int32
	) throws -> Data? {
		let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
		if descriptor < 0, errno == ENOENT { return nil }
		guard descriptor >= 0 else { throw Failure.ownershipChanged }
		defer { close(descriptor) }
		var info = stat()
		guard
			fstat(descriptor, &info) == 0,
			privateFile(info),
			info.st_size >= 0,
			info.st_size <= 128 * 1024
		else { throw Failure.corrupt }

		var bytes = Data(count: Int(info.st_size))
		try bytes.withUnsafeMutableBytes { buffer in
			var count = 0
			while count < buffer.count {
				let read = Darwin.read(
					descriptor,
					buffer.baseAddress!.advanced(by: count),
					buffer.count - count
				)
				if read < 0, errno == EINTR { continue }
				guard read > 0 else { throw Failure.io }
				count += read
			}
		}
		return bytes
	}

	private static func create(
		_ bytes: Data,
		name: String,
		directory: Int32
	) throws {
		let descriptor = openat(
			directory,
			name,
			O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
			0o600
		)
		guard descriptor >= 0 else { throw Failure.io }
		defer { close(descriptor) }
		try bytes.withUnsafeBytes { buffer in
			var count = 0
			while count < buffer.count {
				let wrote = Darwin.write(
					descriptor,
					buffer.baseAddress!.advanced(by: count),
					buffer.count - count
				)
				if wrote < 0, errno == EINTR { continue }
				guard wrote > 0 else { throw Failure.io }
				count += wrote
			}
		}
		guard fsync(descriptor) == 0, fsync(directory) == 0 else { throw Failure.io }
	}

	/// Atomically replaces an existing private record under the held lock.
	private static func replace(
		_ bytes: Data,
		name: String,
		directory: Int32
	) throws {
		let temporary = ".arx-retirement-writing-" + UUID().uuidString.lowercased()
		try create(bytes, name: temporary, directory: directory)
		defer { unlinkat(directory, temporary, 0) }
		guard
			renameat(directory, temporary, directory, name) == 0,
			fsync(directory) == 0
		else { throw Failure.io }
	}

	private static func encode<T: Encodable>(_ value: T) throws -> Data {
		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.sortedKeys]
		return try encoder.encode(value)
	}

	/// Version 1 stored `device` (`st_dev`); version 2 stores `volume`.
	private struct Identity: Codable {
		internal static let currentVersion: Int = 2

		internal let version: Int
		internal let installationID: UUID
		internal let legacyProfileID: Profile.ID
		internal let rootPath: String
		internal let volume: UUID?
		internal let inode: UInt64

		internal init(
			installationID: UUID,
			legacyProfileID: Profile.ID,
			rootPath: String,
			volume: UUID,
			inode: UInt64
		) {
			self.version = Self.currentVersion
			self.installationID = installationID
			self.legacyProfileID = legacyProfileID
			self.rootPath = rootPath
			self.volume = volume
			self.inode = inode
		}
	}

	private struct Intents: Codable {
		internal let version: Int
		internal let installationID: UUID
		internal var values: [ProfileRetirementIntent]

		internal init(
			version: Int,
			installationID: UUID,
			values: [ProfileRetirementIntent]
		) {
			self.version = version
			self.installationID = installationID
			self.values = values
		}
	}
}
