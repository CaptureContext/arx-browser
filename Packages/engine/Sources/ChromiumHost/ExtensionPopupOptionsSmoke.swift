import AppKit
import ChromiumEngine

/// Clicks the compiled popup’s real runtime.openOptionsPage button, with no
/// pending Settings inventory request or substitute native API invocation.
@MainActor
internal enum ExtensionPopupOptionsSmoke {
	internal static func run(
		runtime: ChromiumRuntime,
		source: ChromiumPage,
		profileID: UUID,
		popup: NSView,
		extensionID: String,
		count: Int
	) async throws {
		guard
			runtime.onExtensionView == nil,
			let sourceURL = source.navigation.url,
			sourceURL.scheme == "http",
			sourceURL.host == "127.0.0.1",
			sourceURL.port.map({ $0 > 0 }) == true,
			sourceURL.path == "/index.html",
			popup.identifier?.rawValue == "ARX_EXTENSION_ACTION:\(extensionID):count=\(count)"
		else { throw Failure.source }

		var child: ChromiumPage?
		var childWindow: NSWindow?
		var offers = 0
		let original = source.navigation
		runtime.onExtensionView = { offered, profile, id in
			offers += 1

			guard
				profile == profileID,
				id == extensionID,
				child == nil,
				!offered.isPrivate
			else { return false }

			let window = NSWindow(
				contentRect: .init(x: 0, y: 0, width: 720, height: 480),
				styleMask: [.titled],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.title = "Arx disposable extension API options fixture"
			window.contentView = offered.view
			child = offered
			childWindow = window
			window.makeKeyAndOrderFront(nil)
			return true
		}
		defer {
			runtime.onExtensionView = nil
			childWindow?.orderOut(nil)
			childWindow?.contentView = nil
			child?.close()
		}

		try clickOptions(in: popup)
		let expected = "ARX_EXTENSION_OPTIONS:\(extensionID):count=\(count)"
		for _ in 0..<300 {
			try Task.checkCancellation()

			if let child, child.navigation.title == expected, !child.navigation.isLoading {
				guard
					offers == 1,
					child.navigation.url?.scheme == "chrome-extension",
					child.navigation.url?.host == extensionID,
					child.navigation.url?.path == "/options.html",
					source.navigation == original,
					child.view.window === childWindow
				else { throw Failure.adoption }

				return
			}

			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.timeout
	}

	private static func clickOptions(in view: NSView) throws {
		guard
			let window = view.window,
			window.isVisible,
			!window.isMiniaturized,
			!view.isHiddenOrHasHiddenAncestor,
			view.bounds.width >= 280,
			view.bounds.height >= 140
		else { throw Failure.source }

		let point = NSPoint(x: 60, y: view.isFlipped ? 120 : view.bounds.height - 120)
		let location = view.convert(point, to: nil)
		let timestamp = ProcessInfo.processInfo.systemUptime
		for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: location,
				modifierFlags: [],
				timestamp: timestamp + Double(offset) * 0.001,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: offset + 1,
				clickCount: 1,
				pressure: offset == 0 ? 1 : 0
			)
			else { throw Failure.source }

			window.sendEvent(event)
		}
	}

	private enum Failure: Error {
		case adoption
		case source
		case timeout
	}
}
