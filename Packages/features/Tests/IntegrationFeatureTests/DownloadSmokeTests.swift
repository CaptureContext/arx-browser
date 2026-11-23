#if DEBUG
import BrowserCore
import CryptoKit
import Foundation
import Testing

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct DownloadSmokeTests {
	@Test(arguments: [false, true])
	internal func verifiesCompletedFileWithDirectoryPathFromEnvironment(useDirectorySymlink: Bool) async throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let directory = root.appending(path: "downloads", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let configured = useDirectorySymlink ? root.appending(path: "alias") : directory

		if useDirectorySymlink {
			try FileManager.default.createSymbolicLink(at: configured, withDestinationURL: directory)
		}

		let data = Data("controlled fixture".utf8)
		let target = directory.appending(path: "fixture.txt")
		try data.write(to: target)
		let runner = try runner(directory: configured.path)

		try runner.verify(
			record(target: target, bytes: data.count),
			bytes: data.count,
			hash: hash(data),
			phase: "test-complete"
		)
	}

	@Test
	internal func rejectsSymlinkOutsideDestinationWithoutDisclosingPrivateMetadata() async throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let directory = root.appending(path: "downloads", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let outside = root.appending(path: "PRIVATE_DESTINATION.txt")
		let target = directory.appending(path: "PRIVATE_LINK.txt")
		let data = Data("controlled fixture".utf8)
		try data.write(to: outside)
		try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
		let runner = try runner(directory: directory.path)
		var value = record(target: target, bytes: data.count)
		value.isPrivate = true
		value.url = URL(string: "https://private.example/?secret=PRIVATE_QUERY")
		value.filename = "PRIVATE_FILENAME"
		value.id.guid = "PRIVATE_GUID"

		do {
			try runner.verify(value, bytes: data.count, hash: hash(data), phase: "test-private")
			Issue.record("A file outside the configured destination was accepted")
		} catch {
			let message = error.localizedDescription
			#expect(message.contains("phase=test-private"))
			#expect(message.contains("canOpen=true status=complete"))
			#expect(message.contains("destinationMatches=false"))
			#expect(!message.contains("PRIVATE_"))
			#expect(!message.contains(root.path))
			#expect(!message.contains("private.example"))
		}
	}

	@Test(arguments: ["byte-count", "content", "dangerous", "missing"])
	internal func preservesByteAndOpenabilityChecks(failure: String) async throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let data = Data("controlled fixture".utf8)
		let target = directory.appending(path: "fixture.txt")
		try data.write(to: target)
		let runner = try runner(directory: directory.path)
		var value = record(target: target, bytes: data.count)

		switch failure {
		case "byte-count": value.receivedBytes -= 1
		case "content": try Data(repeating: 0, count: data.count).write(to: target)
		case "dangerous": value.isDangerous = true
		case "missing": value.isMissing = true
		default: Issue.record("Unknown fixture failure")
		}

		#expect(throws: (any Error).self) {
			try runner.verify(value, bytes: data.count, hash: hash(data), phase: "test-rejected")
		}
	}

	private func temporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appending(path: "arx-download-smoke-" + UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private func runner(directory: String) throws -> DownloadSmoke.Runner {
		try .init(
			engine: .init(status: { .notIntegrated }),
			downloads: .init(),
			organization: IntegrationFeatureTests().fixture(),
			baseURL: URL(string: "http://127.0.0.1/index.html")!,
			metadataFile: URL(filePath: directory).appending(path: "unused.json"),
			environment: [
				"ARX_DOWNLOAD_SMOKE_DIRECTORY": directory,
				"ARX_DOWNLOAD_SMOKE_SHA256": "unused",
				"ARX_DOWNLOAD_SMOKE_BYTES": "1",
				"ARX_DOWNLOAD_SMOKE_SLOW_SHA256": "unused",
				"ARX_DOWNLOAD_SMOKE_SLOW_BYTES": "1",
				"ARX_DOWNLOAD_SMOKE_PRIVATE_MARKER": "unused"
			]
		)
	}

	private func record(
		target: URL,
		bytes: Int
	) -> BrowserDownload {
		.init(
			id: .init(profileID: IntegrationFeatureTests().fixture().profiles[0].id, guid: "fixture"),
			profileName: "Fixture",
			target: target,
			filename: "fixture.txt",
			status: .complete,
			receivedBytes: Int64(bytes),
			totalBytes: Int64(bytes),
			startedAt: Date(timeIntervalSince1970: 0)
		)
	}

	private func hash(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}
#endif
