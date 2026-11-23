import Foundation
import Testing

@testable import ChromiumBrowserEngine

internal struct ChromiumUploadAdapterTests {
	@Test
	internal func onlyReadableRegularFilesQualify() throws {
		let manager = FileManager.default
		let directory = URL.temporaryDirectory.appending(path: "arx-upload-tests-\(UUID().uuidString)")
		try manager.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? manager.removeItem(at: directory) }
		let file = directory.appending(path: "file.txt")
		try Data("x".utf8).write(to: file)
		let link = directory.appending(path: "link.txt")
		try manager.createSymbolicLink(at: link, withDestinationURL: file)

		#expect(ChromiumUploadAdapter.isReadableFile(file.path, fileManager: manager))
		#expect(!ChromiumUploadAdapter.isReadableFile(directory.path, fileManager: manager))
		#expect(!ChromiumUploadAdapter.isReadableFile(link.path, fileManager: manager))
		#expect(!ChromiumUploadAdapter.isReadableFile(directory.appending(path: "missing").path, fileManager: manager))
		#expect(!ChromiumUploadAdapter.isReadableFile("relative.txt", fileManager: manager))
	}
}
