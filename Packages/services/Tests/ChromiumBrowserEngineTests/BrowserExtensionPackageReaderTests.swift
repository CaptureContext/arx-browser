import BrowserCore
import Darwin
import Foundation
import Testing

@testable import BrowserExtensionsClient

internal struct BrowserExtensionPackageReaderTests {
	@Test
	internal func selectedRegularFileIsCopiedAndSymbolicLinksAndPipesAreRejected() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: root) }
		let file = root.appendingPathComponent("Selected.crx")
		let bytes = Data([1, 2, 3, 4])
		try bytes.write(to: file)
		let package = try await BrowserExtensionPackageReader.readSelectedFile(file)
		#expect(package == .init(data: bytes, sourceBasename: "Selected.crx"))
		let link = root.appendingPathComponent("Link.crx")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
		await #expect(throws: BrowserExtensionsClient.Failure.invalidPackage) {
			try await BrowserExtensionPackageReader.readSelectedFile(link)
		}
		let pipe = root.appendingPathComponent("Pipe.crx")
		#expect(mkfifo(pipe.path, 0o600) == 0)
		await #expect(throws: BrowserExtensionsClient.Failure.invalidPackage) {
			try await BrowserExtensionPackageReader.readSelectedFile(pipe)
		}
	}

	@Test
	internal func oversizedSparseFileIsRejectedBeforeReading() async throws {
		let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".crx")
		defer { try? FileManager.default.removeItem(at: file) }
		#expect(FileManager.default.createFile(atPath: file.path, contents: nil))
		let handle = try FileHandle(forWritingTo: file)
		try handle.truncate(atOffset: UInt64(BrowserExtensionPackage.maximumBytes) + 1)
		try handle.close()
		await #expect(throws: BrowserExtensionsClient.Failure.limitExceeded) {
			try await BrowserExtensionPackageReader.readSelectedFile(file)
		}
	}

	@Test
	internal func growingSourceCannotRetainPastLimitAndReadsOnlyOneSentinelByte() throws {
		var reads: [Int] = []
		#expect(throws: BrowserExtensionsClient.Failure.limitExceeded) {
			try BrowserExtensionPackageReader.readBounded(maximumBytes: 4) { count in
				reads.append(count)
				return Data(repeating: 1, count: reads.count == 1 ? 4 : count)
			}
		}
		#expect(reads == [5, 1])
		var calls = 0
		#expect(throws: BrowserExtensionsClient.Failure.invalidResponse) {
			try BrowserExtensionPackageReader.readBounded(maximumBytes: 4) { count in
				calls += 1
				return Data(repeating: 1, count: count + 1)
			}
		}
		#expect(calls == 1)
	}

	@Test
	internal func cancellationStopsBeforeTheNextRead() async throws {
		let began = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let task = Task {
			began.continuation.yield(())
			for await _ in release.stream { break }
			return try BrowserExtensionPackageReader.readBounded(maximumBytes: 4) { _ in
				Issue.record("Cancelled intake reached the reader")
				return Data()
			}
		}
		var iterator = began.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		task.cancel()
		release.continuation.finish()
		await #expect(throws: CancellationError.self) { try await task.value }
	}
}
