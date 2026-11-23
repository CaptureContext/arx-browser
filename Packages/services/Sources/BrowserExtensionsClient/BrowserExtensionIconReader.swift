import Darwin
import Foundation

/// Reads an extension's manifest icon from the path the engine reported (DEV-824).
/// The read is bounded, never follows a final symlink, and happens off the main actor.
public enum BrowserExtensionIconReader {
	/// Manifest icons are small PNGs; anything larger is not drawn.
	public static let maximumBytes: Int = 512 * 1024

	public static func read(_ path: String) async -> Data? {
		await Task.detached(priority: .utility) { readFile(path) }.value
	}

	internal static func readFile(_ path: String) -> Data? {
		guard
			path.hasPrefix("/"),
			path.utf8.count <= 4096,
			!path.utf8.contains(where: { $0 < 32 || $0 == 127 }),
			!path.split(separator: "/").contains("..")
		else { return nil }

		let descriptor: Int32 = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		guard descriptor >= 0 else { return nil }
		defer { _ = Darwin.close(descriptor) }

		var info = stat()
		guard
			fstat(descriptor, &info) == 0,
			info.st_mode & S_IFMT == S_IFREG,
			info.st_size > 0,
			info.st_size <= maximumBytes
		else { return nil }

		let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
		guard
			let data = try? file.read(upToCount: maximumBytes + 1),
			!data.isEmpty,
			data.count <= maximumBytes
		else { return nil }

		return data
	}
}
