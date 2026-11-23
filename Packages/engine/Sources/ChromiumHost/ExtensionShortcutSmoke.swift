import AppKit
import ChromiumEngine

/// Native events are dispatched only to the exact disposable source window.
/// This verifies browser routing, not hardware layout or system shortcut priority.
@MainActor
internal enum ExtensionShortcutSmoke {
	internal enum Command {
		case action
		case named

		fileprivate var keyCode: UInt16 { self == .action ? 16 : 32 }
		fileprivate var characters: String { self == .action ? "Y" : "U" }
	}

	internal static func run(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		extensionID: String,
		count: Int,
		profileTabs: Int = 1
	) async throws {
		try runtime.configureContentHosting(on: page, enabled: true)
		defer { cleanUp("content host") { try runtime.configureContentHosting(on: page, enabled: false) } }

		let originalURL = page.navigation.url
		let originalID = page.identifier
		try await focus(page, runtime: runtime)
		let event = try press(.named, on: page)

		// The storage relay and the direct tabs.sendMessage path both reach this
		// exact page; tabs.get/query see only this profile's ordinary pages.
		func title(_ invocations: Int) -> String {
			"ARX_EXTENSION_COMMAND:\(extensionID):count=\(count):invocations=\(invocations)"
			+ ":direct=\(invocations):get=true:tabs=\(profileTabs):reach=\(profileTabs)"
		}
		try await wait(page, title: title(1))

		guard let window = page.view.window
		else { throw Failure.host }

		// Reusing the same retained NSEvent cannot mint a second user command.
		window.sendEvent(event)
		try await Task.sleep(for: .milliseconds(500))
		guard page.navigation.title == title(1)
		else { throw Failure.replay }

		try runtime.configureContentHosting(on: page, enabled: false)
		try runtime.configureContentHosting(on: page, enabled: true)
		window.sendEvent(event)
		try await Task.sleep(for: .milliseconds(500))
		guard page.navigation.title == title(1)
		else { throw Failure.replay }

		// A fresh key on the replacement host is valid, in the same source/profile.
		try await focus(page, runtime: runtime)
		_ = try press(.named, on: page)
		try await wait(page, title: title(2))
		guard page.identifier == originalID, page.navigation.url == originalURL
		else { throw Failure.source }
	}

	/// DEV-974. Presses as soon as the page's view holds first responder in the key window,
	/// without waiting for the renderer to report focus, as a person switching windows or
	/// right after a reload does. The command must still run, its `invocations`-th for the
	/// profile.
	internal static func pressWithoutRendererFocus(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		extensionID: String,
		invocations: Int
	) async throws {
		try runtime.configureContentHosting(on: page, enabled: true)
		defer { cleanUp("content host") { try runtime.configureContentHosting(on: page, enabled: false) } }

		try await focusView(page)
		try press(.named, on: page)
		let prefix = "ARX_EXTENSION_COMMAND:\(extensionID):"
		let count = ":invocations=\(invocations):direct=\(invocations):"
		for _ in 0..<300 {
			try Task.checkCancellation()

			let title = page.navigation.title
			if title.hasPrefix(prefix), title.contains(count) { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		FileHandle.standardError.write(Data("ARX_EXTENSION_SHORTCUT_TITLE \(page.navigation.title)\n".utf8))
		throw Failure.timeout
	}

	@discardableResult
	internal static func press(
		_ command: Command,
		on page: ChromiumPage
	) throws -> NSEvent {
		guard
			!page.isClosed,
			!page.isPrivate,
			page.navigation.url?.scheme == "http",
			page.navigation.url?.host == "127.0.0.1",
			page.navigation.url?.port.map({ $0 > 0 }) == true,
			page.navigation.url?.path == "/index.html",
			let window = page.view.window,
			window.contentView === page.view,
			window.isVisible,
			!window.isMiniaturized,
			!page.view.isHiddenOrHasHiddenAncestor
		else { throw Failure.host }

		guard window.isKeyWindow, renderViewIsFocused(in: page.view, window: window)
		else { throw Failure.host }

		let timestamp = ProcessInfo.processInfo.systemUptime
		let down = NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: [.command, .shift],
			timestamp: timestamp,
			windowNumber: window.windowNumber,
			context: nil,
			characters: command.characters,
			charactersIgnoringModifiers: command.characters.lowercased(),
			isARepeat: false,
			keyCode: command.keyCode
		)
		let up = NSEvent.keyEvent(
			with: .keyUp,
			location: .zero,
			modifierFlags: [.command, .shift],
			timestamp: timestamp + 0.001,
			windowNumber: window.windowNumber,
			context: nil,
			characters: command.characters,
			charactersIgnoringModifiers: command.characters.lowercased(),
			isARepeat: false,
			keyCode: command.keyCode
		)
		guard let down, let up
		else { throw Failure.host }

		window.sendEvent(down)
		window.sendEvent(up)
		return down
	}

	/// Waits until the page's render widget view holds first responder in the
	/// key window and Chromium knows the page's focused frame, so native shortcut
	/// keys reach Chrome's extension commands.
	internal static func focus(
		_ page: ChromiumPage,
		runtime: ChromiumRuntime
	) async throws {
		try await focusView(page)
		try await waitForRendererFocus(page, runtime: runtime)
	}

	/// AppKit moves first responder at once, but Chromium records the page's focused frame only
	/// when the renderer answers the focus with `DidFocusFrame`, and a navigation or reload clears
	/// it. A shortcut pressed before that answer finds no focused frame: the engine leaves the key
	/// to the page as an ordinary key and no command runs. That was the extensions-smoke flake on
	/// the first press after switching windows. A developer-world script travels over the same
	/// frame channel as `DidFocusFrame`, so once it reads `document.hasFocus()` as true, Chromium
	/// has the frame.
	///
	/// A navigation or reload can replace the page's render widget view. Focused while the old
	/// view was still a subview, the new one never gets focus, so the wait gives the page's
	/// content focus again every half second; that changes nothing once the right view has it.
	private static func waitForRendererFocus(
		_ page: ChromiumPage,
		runtime: ChromiumRuntime
	) async throws {
		guard runtime.supportsDeveloperTier else { throw Failure.host }

		var last: ChromiumScriptValue?
		for attempt in 0..<150 {
			try Task.checkCancellation()

			last = try await runtime.evaluateScript(page, source: "return document.hasFocus();", timeoutMilliseconds: 2_000)
			if last == .json("true") { return }
			if attempt % 25 == 24 { _ = page.focusContent() }
			try await Task.sleep(for: .milliseconds(20))
		}

		let diagnostic = "ARX_EXTENSION_SHORTCUT_RENDERER_FOCUS \(String(describing: last))\n"
		FileHandle.standardError.write(Data(diagnostic.utf8))
		throw Failure.host
	}

	private static func focusView(_ page: ChromiumPage) async throws {
		guard let window = page.view.window
		else { throw Failure.host }

		// A key window needs the app in front. With a real display another app may hold it, and
		// under cooperative activation a plain activate() from a host the runner started can be
		// declined, so the smoke host insists, as a click would (DEV-965).
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		guard page.focusContent()
		else { throw Failure.host }

		for attempt in 0..<150 {
			try Task.checkCancellation()

			if window.isKeyWindow, renderViewIsFocused(in: page.view, window: window) { return }

			// Ask again once a second while another app keeps the front.
			if attempt % 50 == 49, !NSApp.isActive {
				NSApp.activate(ignoringOtherApps: true)
				window.makeKeyAndOrderFront(nil)
				_ = page.focusContent()
			}
			try await Task.sleep(for: .milliseconds(20))
		}

		let diagnostic = "ARX_EXTENSION_SHORTCUT_FOCUS key=\(window.isKeyWindow) active=\(NSApp.isActive) "
		+ "rendered=\(renderViewIsFocused(in: page.view, window: window))\n"
		FileHandle.standardError.write(Data(diagnostic.utf8))
		throw Failure.host
	}

	private static func renderViewIsFocused(
		in view: NSView,
		window: NSWindow
	) -> Bool {
		guard let responder = window.firstResponder as? NSView
		else { return false }

		return responder !== view && responder.isDescendant(of: view)
	}

	private static func wait(
		_ page: ChromiumPage,
		title: String
	) async throws {
		for _ in 0..<300 {
			try Task.checkCancellation()

			if page.navigation.title == title, !page.navigation.isLoading { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		FileHandle.standardError.write(Data("ARX_EXTENSION_SHORTCUT_TITLE \(page.navigation.title)\n".utf8))
		throw Failure.timeout
	}

	private enum Failure: Error {
		case host
		case replay
		case source
		case timeout
	}
}
