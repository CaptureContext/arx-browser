import AppKit
import ChromiumEngine

/// Uses the actual popup renderer and its owned NSWindow. No page script or
/// synthetic extension API request substitutes for the link's normal dispatch.
@MainActor
internal enum ExtensionPopupLinkSmoke {
	internal static func run(
		runtime: ChromiumRuntime,
		source: ChromiumPage,
		popup: NSView,
		extensionID: String,
		count: Int
	) async throws {
		guard
			runtime.onNewContents == nil,
			let sourceURL = source.navigation.url,
			sourceURL.scheme == "http",
			sourceURL.host == "127.0.0.1",
			sourceURL.port.map({ $0 > 0 }) == true,
			sourceURL.path == "/index.html",
			let target = URL(string: "index.html?popup_child=1", relativeTo: sourceURL)?.absoluteURL,
			popup.identifier?.rawValue == "ARX_EXTENSION_ACTION:\(extensionID):count=\(count)"
		else { throw Failure.source }

		var child: ChromiumPage?
		var childWindow: NSWindow?
		var offers = 0
		let original = source.navigation
		runtime.onNewContents = { opener, generation, offered, url, disposition in
			offers += 1

			guard
				opener === source,
				generation > 0,
				child == nil,
				!offered.isPrivate,
				url == target,
				disposition == .foregroundTab
			else { return false }

			let window = NSWindow(
				contentRect: .init(x: 0, y: 0, width: 720, height: 480),
				styleMask: [.titled],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.title = "Arx disposable extension link fixture"
			window.contentView = offered.view
			child = offered
			childWindow = window
			window.makeKeyAndOrderFront(nil)
			return true
		}
		defer {
			runtime.onNewContents = nil
			childWindow?.orderOut(nil)
			childWindow?.contentView = nil
			child?.close()
		}

		try clickOutgoingLink(in: popup)
		let expected = "ARX_EXTENSION_POPUP_CHILD:\(extensionID):count=\(count)"
		for _ in 0..<300 {
			try Task.checkCancellation()

			if let child, child.navigation.title == expected, !child.navigation.isLoading {
				guard
					offers == 1,
					child.navigation.url == target,
					source.navigation == original,
					child.view.window === childWindow
				else { throw Failure.adoption }

				return
			}

			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.timeout
	}

	private static func clickOutgoingLink(in view: NSView) throws {
		guard
			let window = view.window,
			window.isVisible,
			!window.isMiniaturized,
			!view.isHiddenOrHasHiddenAncestor,
			view.bounds.width >= 280,
			view.bounds.height >= 80
		else { throw Failure.source }

		let point = NSPoint(x: 60, y: view.isFlipped ? 60 : view.bounds.height - 60)
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
