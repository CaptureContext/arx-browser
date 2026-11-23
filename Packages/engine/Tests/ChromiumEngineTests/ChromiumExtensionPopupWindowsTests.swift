import AppKit
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1316: the closing rule the app gives crosses to the engine as its `ArxExtensionPopupClosing`
/// value, so each case keeps the number the native header gives it.
@Suite
internal struct ChromiumExtensionPopupWindowsTests {
	@Test
	internal func eachClosingRuleIsTheEnginesValue() throws {
		let header = try String(contentsOf: Self.nativeHeader, encoding: .utf8)
		let expected: [(ChromiumExtensionPopupClosing, String)] = [
			(.unlessMoved, "ARX_EXTENSION_POPUP_CLOSES_UNLESS_MOVED"),
			(.onFocusLoss, "ARX_EXTENSION_POPUP_CLOSES_ON_FOCUS_LOSS"),
			(.staysOpen, "ARX_EXTENSION_POPUP_STAYS_OPEN"),
		]
		for (closing, name) in expected {
			#expect(header.contains("\(name) = \(closing.rawValue),"), "\(name)")
		}
		#expect(ChromiumExtensionPopupClosing.allCases.count == expected.count)
	}

	@Test
	internal func theExportIsTheOneTheEngineListsOutsideTheTable() throws {
		let overlay = try String(contentsOf: Self.root.appending(path: "Scripts/engine/overlay.py"), encoding: .utf8)
		#expect(overlay.contains("\"_\(ChromiumSetExtensionPopupPresenterSymbol)\","))
	}

	/// The header's icon: the engine's PNG first, else a regular file within bounds, else none.
	@Test
	internal func theIconIsTheEnginesPNGOrABoundedFile() throws {
		let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
		let fromBytes = png.withUnsafeBufferPointer { buffer in
			ChromiumRuntime.extensionPopupIcon(png: buffer.baseAddress, size: buffer.count, path: "/nonexistent")
		}
		#expect(fromBytes == Data(png))

		let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "icon.png")
		try Data([1, 2, 3]).write(to: file)
		#expect(ChromiumRuntime.extensionPopupIcon(png: nil, size: 0, path: file.path) == Data([1, 2, 3]))

		#expect(ChromiumRuntime.extensionPopupIcon(png: nil, size: 0, path: directory.path) == nil)
		#expect(ChromiumRuntime.extensionPopupIcon(png: nil, size: 0, path: "icon.png") == nil)
		#expect(ChromiumRuntime.extensionPopupIcon(png: nil, size: 0, path: nil) == nil)
		let large = directory.appending(path: "large.png")
		try Data(count: ChromiumRuntime.maximumExtensionPopupIconBytes + 1).write(to: large)
		#expect(ChromiumRuntime.extensionPopupIcon(png: nil, size: 0, path: large.path) == nil)
	}

	/// The page's view has the keyboard before the window shows, so AppKit doesn't pick a key
	/// view as Tab would: the engine answers that by focusing the page's first control, and a
	/// field the page focused itself lost the keyboard (extensions-smoke, "timed out: input").
	@Test
	@MainActor
	internal func thePageTakesTheKeyboardBeforeItsWindowShows() {
		let page = NSView(frame: .init(x: 0, y: 0, width: 100, height: 100))
		let widget = KeyView(frame: page.bounds)
		page.addSubview(widget)
		let window = NSPanel(contentRect: page.frame, styleMask: [.titled], backing: .buffered, defer: true)
		window.contentView = page
		#expect(window.firstResponder === window)

		ChromiumRuntime.focusPage(page, in: window)
		#expect(window.firstResponder === widget)

		// A window that chose its own first responder keeps it.
		let other = KeyView(frame: page.bounds)
		page.addSubview(other)
		window.makeFirstResponder(other)
		ChromiumRuntime.focusPage(page, in: window)
		#expect(window.firstResponder === other)

		// A view that isn't in the window is left alone.
		let elsewhere = NSPanel(contentRect: page.frame, styleMask: [.titled], backing: .buffered, defer: true)
		ChromiumRuntime.focusPage(page, in: elsewhere)
		#expect(elsewhere.firstResponder === elsewhere)
	}

	private final class KeyView: NSView {
		override var acceptsFirstResponder: Bool { true }
	}

	private static let root: URL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()

	private static let nativeHeader: URL = root.appending(path: "Packages/engine/Native/extension_action_host.h")
}
