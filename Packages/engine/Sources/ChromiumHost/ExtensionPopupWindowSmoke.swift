import AppKit
import ChromiumEngine

/// DEV-1316: an extension's action popup opens in a window of its own, the app's when it gives
/// one. The owned fixture's popup proves it: the window hangs from the anchor and takes the
/// keyboard, what's typed reaches the page, the page's new size resizes the window, losing focus
/// closes it, a moved one stays until closed, asking again brings the open one forward, and the
/// page's `window.close()` and Escape close it.
///
/// Then the app's rule, `.staysOpen`: clicking the page's window neither closes the popup nor sends
/// it behind that window, and after the window moves, a resize keeps the popup where the window
/// took it.
///
/// The smoke can't drag a window without taking the screen, so the move a drag would begin is
/// AppKit's own `NSWindowWillMoveNotification`, posted for the popup's window.
@MainActor
internal enum ExtensionPopupWindowSmoke {
	internal static func run(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		extensionID: String,
		count: Int
	) async throws {
		guard runtime.supportsExtensionPopupWindows, let source = page.view.window
		else { throw Failure.check("engine has no popup windows") }

		let record = Record()
		let windows = Self.windows(closing: .unlessMoved, record: record)
		guard runtime.setExtensionPopupWindows(windows)
		else { throw Failure.check("presenter refused") }

		defer { runtime.setExtensionPopupWindows(nil) }

		try await runClosingUnlessMoved(
			runtime: runtime,
			page: page,
			source: source,
			extensionID: extensionID,
			count: count,
			record: record
		)

		// The app's rule (Max's reference): the popup stays open when it loses focus, above
		// its window, and hangs from the same place on that window when it has moved.
		guard runtime.setExtensionPopupWindows(Self.windows(closing: .staysOpen, record: record))
		else { throw Failure.check("presenter refused") }

		try await runStaysOpen(runtime: runtime, page: page, source: source, extensionID: extensionID)
	}

	private static func windows(
		closing: ChromiumExtensionPopupClosing,
		record: Record
	) -> ChromiumExtensionPopupWindows {
		ChromiumExtensionPopupWindows(
			closing: closing,
			makeWindow: { view, title, icon, size in
				let window = NSPanel(
					contentRect: .init(origin: .zero, size: size),
					styleMask: [.titled, .closable, .utilityWindow],
					backing: .buffered,
					defer: false
				)
				window.title = title
				window.contentView = view
				record.made.append(window)
				record.titles.append(title)
				record.icons.append(icon)
				return window
			},
			resizeWindow: { window, size in
				record.resizes += 1
				let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
				window.setContentSize(size)
				window.setFrameTopLeftPoint(topLeft)
			}
		)
	}

	private static func runClosingUnlessMoved(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		source: NSWindow,
		extensionID: String,
		count: Int,
		record: Record
	) async throws {
		source.makeKeyAndOrderFront(nil)
		try await ExtensionActionSmoke.waitForKeyHost(in: page.view, window: source)
		try runtime.configureContentHosting(on: page, enabled: true)

		// A failing phase still releases its owned host before runtime teardown.
		defer { cleanUp("content host") { try runtime.configureContentHosting(on: page, enabled: false) } }
		source.makeKeyAndOrderFront(nil)
		try await ExtensionActionSmoke.waitForKeyHost(in: page.view, window: source)

		let point = CGPoint(x: source.frame.minX + 120, y: source.frame.maxY - 60)
		let proof = "ARX_EXTENSION_ACTION:\(extensionID):count=\(count)"

		// Opens in the app's window, hanging from the anchor, with the keyboard.
		let popup = try await open(runtime: runtime, page: page, extensionID: extensionID, at: point)
		guard record.made.count == 1, popup === record.made.last
		else { throw Failure.check("popup not in the app's window made=\(record.made.count)") }
		// The header names whose window it is: the extension's own name, never the page's title.
		guard record.titles.last?.hasPrefix("Arx Disposable Extension Fixture") == true
		else { throw Failure.check("popup title \(record.titles.last ?? "none")") }
		guard popup.frame.insetBy(dx: -48, dy: -48).contains(point), popup.parent === source
		else { throw Failure.check("popup not at the anchor \(point) frame=\(popup.frame)") }
		try await wait("popup key") { popup.isKeyWindow }

		// Asked for again, the open popup comes forward; no second window.
		guard try runtime.runExtensionAction(extensionID, on: page, at: point) == .popup, record.made.count == 1
		else { throw Failure.check("reopening made another window") }

		// What's typed reaches the page, which grows; the window follows its size.
		try type("a", in: popup)
		do {
			try await wait("input") { contains("\(proof):input=a", in: popup) }
		} catch {
			throw Failure.check(
				"timed out: input key=\(popup.isKeyWindow) active=\(NSApplication.shared.isActive) "
				+ "responder=\(popup.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none") "
				+ "visible=\(ExtensionActionSmoke.popupVisible(extensionID: extensionID)) keyWindow=\(NSApplication.shared.keyWindow === popup)"
			)
		}
		try await wait("resize") {
			record.resizes > 0 && popup.contentView.map { abs($0.frame.width - 340) < 1 && abs($0.frame.height - 200) < 1 } == true
		}

		// Losing focus closes it.
		source.makeKeyAndOrderFront(nil)
		try await wait("closed on focus loss") { !ExtensionActionSmoke.popupVisible(extensionID: extensionID) }

		// A moved popup stays when it loses focus, until it's closed.
		let moved = try await open(runtime: runtime, page: page, extensionID: extensionID, at: point)
		NotificationCenter.default.post(name: NSWindow.willMoveNotification, object: moved)
		source.makeKeyAndOrderFront(nil)
		try await Task.sleep(for: .milliseconds(400))
		guard ExtensionActionSmoke.popupVisible(extensionID: extensionID)
		else { throw Failure.check("moved popup closed on focus loss") }

		moved.performClose(nil)
		try await wait("closed by Close") { !ExtensionActionSmoke.popupVisible(extensionID: extensionID) }

		// The page's own window.close(): the fixture closes when "!" is typed.
		let closing = try await open(runtime: runtime, page: page, extensionID: extensionID, at: point)
		try await wait("popup key again") { closing.isKeyWindow }
		try type("!", in: closing)
		try await wait("closed by window.close()") { !ExtensionActionSmoke.popupVisible(extensionID: extensionID) }

		// Escape the page doesn't take closes it, as Chrome's popup does.
		let escaping = try await open(runtime: runtime, page: page, extensionID: extensionID, at: point)
		try await wait("popup key for Escape") { escaping.isKeyWindow }
		try press(keyCode: 53, characters: "\u{1B}", in: escaping)
		try await wait("closed by Escape") { !ExtensionActionSmoke.popupVisible(extensionID: extensionID) }

		try runtime.configureContentHosting(on: page, enabled: false)
	}

	private static func runStaysOpen(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		source: NSWindow,
		extensionID: String
	) async throws {
		try runtime.configureContentHosting(on: page, enabled: true)
		defer { cleanUp("content host") { try runtime.configureContentHosting(on: page, enabled: false) } }

		let point = CGPoint(x: source.frame.minX + 120, y: source.frame.maxY - 60)
		let popup = try await open(runtime: runtime, page: page, extensionID: extensionID, at: point)
		try await wait("popup key") { popup.isKeyWindow }

		// Clicking the page window doesn't close it or send it behind that window.
		source.makeKeyAndOrderFront(nil)
		try await Task.sleep(for: .milliseconds(400))
		// Front to back. `NSApplication.orderedWindows` leaves panels out, and the popup's
		// window may be one, so the window server's order is read instead.
		let order = NSWindow.windowNumbers(options: []) ?? []
		guard
			ExtensionActionSmoke.popupVisible(extensionID: extensionID),
			popup.parent === source,
			let above = order.firstIndex(where: { $0.intValue == popup.windowNumber }),
			let below = order.firstIndex(where: { $0.intValue == source.windowNumber }),
			above < below
		else {
			throw Failure.check(
				"popup closed or went behind its window visible=\(ExtensionActionSmoke.popupVisible(extensionID: extensionID)) "
				+ "popupVisible=\(popup.isVisible) parent=\(popup.parent === source) key=\(popup.isKeyWindow) sourceKey=\(source.isKeyWindow) "
				+ "active=\(NSApplication.shared.isActive) "
				+ "order=\(order.map { $0.intValue == popup.windowNumber ? "popup" : $0.intValue == source.windowNumber ? "source" : "other" })"
			)
		}

		// Its window moves and the popup with it; when the page then resizes, it stays where the
		// window took it (Codex review: it jumped back to the old screen point).
		let before = popup.frame
		let original = source.frame
		source.setFrameOrigin(NSPoint(x: original.minX + 40, y: original.minY))
		defer { source.setFrame(original, display: true) }
		try type("b", in: popup)
		try await wait("resize after the window moved") {
			popup.contentView.map { abs($0.frame.width - 340) < 1 } == true
		}
		guard abs(popup.frame.midX - (before.midX + 40)) < 2
		else { throw Failure.check("popup left its window: before=\(before) after=\(popup.frame)") }

		popup.performClose(nil)
		try await wait("closed by Close") { !ExtensionActionSmoke.popupVisible(extensionID: extensionID) }
		try runtime.configureContentHosting(on: page, enabled: false)
	}

	private static func open(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		extensionID: String,
		at point: CGPoint
	) async throws -> NSWindow {
		guard let source = page.view.window
		else { throw Failure.check("source closed") }

		source.makeKeyAndOrderFront(nil)
		try await ExtensionActionSmoke.waitForKeyHost(in: page.view, window: source)
		guard try runtime.runExtensionAction(extensionID, on: page, at: point) == .popup
		else { throw Failure.check("app action had no popup") }

		try await wait("popup") { ExtensionActionSmoke.popupWindow(extensionID: extensionID) != nil }
		guard let popup = ExtensionActionSmoke.popupWindow(extensionID: extensionID)
		else { throw Failure.check("popup window") }

		return popup
	}

	private static func type(
		_ text: String,
		in window: NSWindow
	) throws {
		for character in text {
			try press(keyCode: 0, characters: String(character), in: window)
		}
	}

	private static func press(
		keyCode: UInt16,
		characters: String,
		in window: NSWindow
	) throws {
		let timestamp = ProcessInfo.processInfo.systemUptime
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard
				let event = NSEvent.keyEvent(
					with: type,
					location: .zero,
					modifierFlags: [],
					timestamp: type == .keyDown ? timestamp : timestamp + 0.001,
					windowNumber: window.windowNumber,
					context: nil,
					characters: characters,
					charactersIgnoringModifiers: characters,
					isARepeat: false,
					keyCode: keyCode
				)
			else { throw Failure.check("key event") }

			window.sendEvent(event)
		}
	}

	private static func contains(
		_ proof: String,
		in window: NSWindow
	) -> Bool {
		func find(_ view: NSView) -> Bool {
			view.identifier?.rawValue == proof || view.subviews.contains(where: find)
		}

		return window.contentView.map(find) == true
	}

	private static func wait(
		_ step: String,
		_ ready: () -> Bool
	) async throws {
		for _ in 0..<200 {
			try Task.checkCancellation()

			if ready() { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.check("timed out: \(step)")
	}

	/// What the smoke's presenter was asked for.
	@MainActor
	private final class Record {
		var made: [NSWindow] = []
		var titles: [String] = []
		var icons: [Data?] = []
		var resizes: Int = 0
	}

	private enum Failure: Error {
		case check(String)
	}
}
