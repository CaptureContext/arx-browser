import Darwin
import Foundation
import Testing

@testable import BrowserExtensionsClient

/// DEV-824: the site menu's extension icons are read from the path the engine names.
internal struct BrowserExtensionIconReaderTests {
	@Test
	internal func readsRegularFilesAndRefusesEverythingElse() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: root) }

		let icon = root.appendingPathComponent("icon.png")
		let bytes = Data([0x89, 0x50, 0x4E, 0x47])
		try bytes.write(to: icon)
		let read = await BrowserExtensionIconReader.read(icon.path)
		#expect(read == bytes)

		var refused: [String] = []
		let link = root.appendingPathComponent("link.png")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: icon)
		refused.append(link.path)

		let pipe = root.appendingPathComponent("pipe.png")
		#expect(mkfifo(pipe.path, 0o600) == 0)
		refused.append(pipe.path)

		let large = root.appendingPathComponent("large.png")
		try Data(count: BrowserExtensionIconReader.maximumBytes + 1).write(to: large)
		refused.append(large.path)

		let empty = root.appendingPathComponent("empty.png")
		try Data().write(to: empty)
		refused.append(empty.path)

		refused.append("icon.png")
		refused.append(root.appendingPathComponent("sub/../icon.png", isDirectory: false).path)
		refused.append(root.path)
		for path in refused {
			let data = await BrowserExtensionIconReader.read(path)
			#expect(data == nil, "\(path)")
		}
	}
}
