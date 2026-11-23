#if DEBUG
import AppKit
import BrowserCore
import CoreServices.AE
import Foundation
import _ComposableArchitecture

/// DEV-987. A local file Arx is asked to open (Finder's Open With, `open -a`, a drop on the
/// Dock icon, another app) opens in a new Little Arx in the space in front, as an external link
/// does, and Chromium shows no browser window of its own. The app sends itself the
/// open-documents Apple Event those send, naming a file it writes for the phase.
@MainActor
internal enum LocalFileSmoke {
	internal enum Failure: Error {
		case notOpened(String)
		case wrongSpace
		case chromiumWindow
		case notClosed
	}

	internal static func run(
		store: StoreOf<AppFeature>,
		littleWindow: @escaping (UUID) -> NSWindow?
	) async throws {
		let directory = FileManager.default.temporaryDirectory
			.appending(path: "arx-local-file-smoke-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let title = "Arx local file \(UUID().uuidString.prefix(8))"
		let file = directory.appending(path: "local report.html")
		let page = "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><h1>Local report</h1>"
		try Data(page.utf8).write(to: file)

		// Where an external link would open: the space in front.
		let spaceID = store.state.incomingSpaceID()

		// The Little Arx takes the keyboard; whatever had it gets it back, pass or fail.
		let previousKey = NSApp.keyWindow
		defer { previousKey?.makeKeyAndOrderFront(nil) }
		let before = Set(store.littleWindows.ids)
		try openDocuments([file])

		var opened: UUID?
		do {
			try await wait {
				guard
					let little = store.littleWindows.first(where: { !before.contains($0.id) }),
					let url = little.viewer.navigation.url
				else { return false }

				opened = little.id
				return url.isFileURL
				&& url.lastPathComponent == file.lastPathComponent
				&& little.viewer.navigation.title == title
				&& !little.viewer.navigation.isLoading
				&& littleWindow(little.id)?.isVisible == true
			}
		} catch {
			let state = store.littleWindows.first(where: { !before.contains($0.id) })
				.map { "\($0.viewer.navigation.url?.absoluteString ?? "nil") \($0.viewer.navigation.title)" }
			throw Failure.notOpened(state ?? "no Little Arx")
		}
		guard let id = opened else { throw Failure.notOpened("no Little Arx") }
		guard store.littleWindows[id: id]?.spaceID == spaceID else { throw Failure.wrongSpace }

		// A Chromium window would come from the same event; give a late one time to show.
		try await Task.sleep(for: .milliseconds(500))
		guard !NSApp.windows.contains(where: isChromiumBrowserWindow) else { throw Failure.chromiumWindow }
		print("ARX_LOCAL_FILE_SMOKE_LITTLE_ARX")

		store.send(.littleWindows(.element(id: id, action: .ui(.close))))
		do {
			try await wait { store.littleWindows[id: id] == nil }
		} catch {
			throw Failure.notClosed
		}
		print("ARX_LOCAL_FILE_SMOKE_SUCCESS")
	}

	/// The open-documents event Finder and LaunchServices send, to this process.
	private static func openDocuments(_ files: [URL]) throws {
		let event = NSAppleEventDescriptor(
			eventClass: AEEventClass(kCoreEventClass),
			eventID: AEEventID(kAEOpenDocuments),
			targetDescriptor: .currentProcess(),
			returnID: AEReturnID(kAutoGenerateReturnID),
			transactionID: AETransactionID(kAnyTransactionID)
		)
		let list = NSAppleEventDescriptor.list()
		for file in files {
			list.insert(NSAppleEventDescriptor(fileURL: file), at: list.numberOfItems + 1)
		}
		event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
		_ = try event.sendEvent(options: [.noReply], timeout: 10)
	}

	/// Chromium's own browser frame (`BrowserNativeWidgetWindow`), with its tab strip and toolbar.
	private static func isChromiumBrowserWindow(_ window: NSWindow) -> Bool {
		NSStringFromClass(type(of: window)) == "BrowserNativeWidgetWindow"
	}

	private static func wait(
		seconds: Int = 15,
		_ condition: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw CancellationError() }
			try await Task.sleep(for: .milliseconds(50))
		}
	}
}
#endif
