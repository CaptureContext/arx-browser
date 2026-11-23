import Foundation
import _Dependencies

/// Keeps tests out of the person's own home folder.
///
/// Every write the agent tools make, including installing `arx`, editing an agent app's
/// configuration and writing a credential, goes through ``check(_:)`` first. While tests run,
/// a target inside the real home folder is reported as a test failure and refused. Tests work
/// in temporary folders, which are outside it.
public enum RealHomeGuard {
	public struct Violation: Error, Equatable, Sendable {
		public var path: String

		public init(path: String) {
			self.path = path
		}
	}

	/// Refuses `url` while tests run if it's inside the real home folder.
	public static func check(_ url: URL) throws {
		guard
			isTesting,
			isInside(url, home: FileManager.default.homeDirectoryForCurrentUser)
		else { return }

		reportIssue("A test reached the real home folder: \(url.path)")
		throw Violation(path: url.path)
	}

	/// Whether `url` is `home` itself or inside it. Symbolic links and `..` are resolved first.
	public static func isInside(
		_ url: URL,
		home: URL
	) -> Bool {
		let target: String = resolved(url)
		let root: String = resolved(home)
		return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
	}

	/// Resolves the deepest existing ancestor, so a file that doesn't exist yet still resolves
	/// through links in its folders.
	private static func resolved(_ url: URL) -> String {
		var existing: URL = url.standardizedFileURL
		var missing: [String] = []
		while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
			missing.insert(existing.lastPathComponent, at: 0)
			existing.deleteLastPathComponent()
		}
		let base: URL = existing.resolvingSymlinksInPath()
		return missing.reduce(base) { $0.appending(path: $1) }.standardizedFileURL.path
	}
}
