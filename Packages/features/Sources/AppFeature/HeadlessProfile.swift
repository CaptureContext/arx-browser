import Darwin
import Foundation

/// Owns a headless run's private directory and its profile lock.
///
/// The default profile is a fresh mode-0700 directory deleted after shutdown. A
/// persistent profile is locked exclusively for the run; another headless run is
/// rejected by the lock and an interactive Arx by Chromium's live SingletonLock.
internal final class HeadlessProfile {
	internal let runDirectory: URL
	internal let profileDirectory: URL
	internal let isPersistent: Bool
	private var lock: Int32 = -1

	internal init(persistent: URL?) throws(HeadlessFailure) {
		let fileManager = FileManager.default
		let run = fileManager.temporaryDirectory
			.appendingPathComponent("arx-headless-" + UUID().uuidString.lowercased(), isDirectory: true)
		do {
			try fileManager.createDirectory(
				at: run,
				withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700]
			)
		} catch {
			throw .profileUnavailable
		}
		self.runDirectory = run

		if let persistent {
			self.profileDirectory = persistent.resolvingSymlinksInPath()
			self.isPersistent = true
		} else {
			self.profileDirectory = run.appendingPathComponent("Browser", isDirectory: true)
			self.isPersistent = false
		}
		do {
			try fileManager.createDirectory(
				at: profileDirectory, withIntermediateDirectories: isPersistent,
				attributes: [.posixPermissions: 0o700]
			)
		} catch {
			removeRunDirectory()
			throw .profileUnavailable
		}
		do throws(HeadlessFailure) { try acquire() } catch {
			removeRunDirectory()
			throw error
		}
	}

	/// Chromium writes SingletonLock in its user-data directory; check every root it may use.
	internal func rejectLiveBrowser(in directories: [URL]) throws(HeadlessFailure) {
		for directory in Set(directories.map(\.standardizedFileURL)) where Self.hasLiveSingleton(in: directory) {
			throw .profileInUse
		}
	}

	internal func finish() {
		if lock >= 0 {
			flock(lock, LOCK_UN)
			close(lock)
			lock = -1
		}
		removeRunDirectory()
	}

	private func acquire() throws(HeadlessFailure) {
		let path = profileDirectory.appendingPathComponent(".arx-headless.lock").path
		let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw .profileUnavailable }
		guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
			let busy = errno == EWOULDBLOCK
			close(descriptor)
			throw busy ? .profileInUse : .profileUnavailable
		}
		lock = descriptor
		try rejectLiveBrowser(in: [profileDirectory])
	}

	private func removeRunDirectory() {
		// The persistent profile lives elsewhere and is never removed.
		try? FileManager.default.removeItem(at: runDirectory)
	}

	/// SingletonLock is a symlink to `<host>-<pid>`. A stale link from a crashed
	/// process does not block the run; Chromium replaces it.
	internal static func hasLiveSingleton(in directory: URL) -> Bool {
		let link = directory.appendingPathComponent("SingletonLock").path
		guard
			let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link),
			let separator = target.lastIndex(of: "-"),
			let pid = pid_t(target[target.index(after: separator)...]), pid > 0
		else { return false }
		let host = String(target[..<separator])

		// Chromium treats another host's lock as in use; so does a headless run.
		guard host == Self.hostName else { return true }
		return kill(pid, 0) == 0 || errno == EPERM
	}

	private static var hostName: String {
		var buffer = [CChar](repeating: 0, count: 256)
		guard gethostname(&buffer, buffer.count) == 0 else { return "" }
		let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
		return String(decoding: bytes, as: UTF8.self)
	}
}
