import BrowserCore
import Darwin
import Foundation

/// Reads only the explicitly selected regular CRX file. Intake is bounded
/// during reads, including a source that grows after its initial size check.
public enum BrowserExtensionPackageReader {
	public static func readSelectedFile(_ url: URL) async throws -> BrowserExtensionPackage {
		let task = Task.detached { [url] in try readFile(url) }
		return try await withTaskCancellationHandler {
			try await task.value
		} onCancel: {
			task.cancel()
		}
	}

	private static func readFile(_ url: URL) throws -> BrowserExtensionPackage {
		try Task.checkCancellation()
		let name: String = url.lastPathComponent
		let hasForbiddenByte: Bool = name.utf8.contains { $0 < 32 || $0 == 127 || $0 == 47 || $0 == 92 }
		guard
			url.isFileURL,
			url.pathExtension.lowercased() == "crx",
			!name.isEmpty,
			name.utf8.count <= 255,
			!hasForbiddenByte
		else { throw BrowserExtensionsClient.Failure.invalidPackage }

		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
			guard let path else { return -1 }
			return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		}
		guard descriptor >= 0 else { throw BrowserExtensionsClient.Failure.invalidPackage }
		defer { _ = Darwin.close(descriptor) }
		var before = stat()
		guard
			fstat(descriptor, &before) == 0,
			before.st_mode & S_IFMT == S_IFREG,
			before.st_size > 0
		else { throw BrowserExtensionsClient.Failure.invalidPackage }

		guard before.st_size <= BrowserExtensionPackage.maximumBytes
		else { throw BrowserExtensionsClient.Failure.limitExceeded }

		let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
		let data: Data
		do {
			data = try readBounded(maximumBytes: BrowserExtensionPackage.maximumBytes) { count in
				try file.read(upToCount: count) ?? Data()
			}
		} catch is CancellationError {
			throw CancellationError()
		} catch let failure as BrowserExtensionsClient.Failure {
			throw failure
		} catch {
			throw BrowserExtensionsClient.Failure.failed
		}
		var after = stat()
		guard
			fstat(descriptor, &after) == 0,
			after.st_size == before.st_size,
			data.count == after.st_size,
			after.st_dev == before.st_dev,
			after.st_ino == before.st_ino,
			after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
			after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
			after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
			after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
		else { throw BrowserExtensionsClient.Failure.sourceChanged }

		try Task.checkCancellation()
		return .init(data: data, sourceBasename: url.lastPathComponent)
	}

	internal static func readBounded(
		maximumBytes: Int,
		read: (Int) throws -> Data
	) throws -> Data {
		guard maximumBytes > 0, maximumBytes <= BrowserExtensionPackage.maximumBytes
		else { throw BrowserExtensionsClient.Failure.limitExceeded }

		var result = Data()
		while true {
			try Task.checkCancellation()
			let remaining = maximumBytes - result.count

			// Read one sentinel byte at the limit, before retaining it. No read
			// request or temporary chunk can grow without this per-call bound.
			let count = min(64 * 1024, remaining + 1)
			let chunk = try read(count)
			guard chunk.count <= count
			else { throw BrowserExtensionsClient.Failure.invalidResponse }

			guard chunk.count <= remaining
			else { throw BrowserExtensionsClient.Failure.limitExceeded }

			if chunk.isEmpty { return result }
			result.append(chunk)
		}
	}
}
