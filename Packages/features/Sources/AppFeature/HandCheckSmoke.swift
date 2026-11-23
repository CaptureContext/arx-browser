#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// The hand checks Max still owed on five merged fixes, as one window smoke
/// (`make hand-check-smoke`). It needs the screen and nobody using the Mac, so it isn't part of
/// `make app-smoke`, and each phase can run alone:
///
/// - `find`: ⌘F refocuses the find field and selects its text after focus went to the page, the
///   URL bar or the sidebar, also in reading mode (the find refocus ticket, DEV-1222).
/// - `full-screen`: the traffic lights' space closes and comes back in step with the window's
///   full screen, and hovering the top edge doesn't move the page (the full-screen layout ticket,
///   DEV-912).
/// - `address`: an address wider than the expanded URL bar shows no inline suffix, and its text
///   and caret scroll normally (the inline completion ticket, DEV-1223).
/// - `private-save`: Save Page As in a private window, through AppKit's real save panel, leaves
///   AppKit's remembered folder alone (the private Save Page As ticket, DEV-816). The runner
///   checks the defaults and the saved file's attributes once Arx has quit.
/// - `hide-element-toast`: with Hide Element on, the pointer over the toast outlines nothing and
///   the toast holds still and solid; clicks on its padding, corners, title and the gaps between
///   its controls reach neither the page nor the picker, and each control does its own thing (the
///   Hide Element toast clicks ticket, DEV-1315).
///
/// Runs only with `ARX_HAND_CHECK_SMOKE` naming the phases and a disposable `ARX_ENGINE_PROFILE`.
/// Each phase prints `ARX_HAND_CHECK_<PHASE>_SUCCESS`; a failure prints
/// `ARX_HAND_CHECK_SMOKE_FAILED: <phase>: <reason>` and stops the run.
@MainActor
internal enum HandCheckSmoke {
	internal enum Phase: String, CaseIterable, Sendable {
		case find
		case fullScreen = "full-screen"
		case address
		case privateSave = "private-save"
		case hideElementToast = "hide-element-toast"

		/// The line a phase prints when it passes.
		internal var successMarker: String {
			"ARX_HAND_CHECK_\(rawValue.uppercased().replacingOccurrences(of: "-", with: "_"))_SUCCESS"
		}
	}

	internal struct Failure: Error, CustomStringConvertible {
		internal var description: String

		internal init(_ description: String) {
			self.description = description
		}
	}

	internal static let environmentKey: String = "ARX_HAND_CHECK_SMOKE"

	/// The phases `ARX_HAND_CHECK_SMOKE` names, comma-separated, in the order they run; `1` or
	/// `all` is every phase. Nil when the smoke isn't requested or names an unknown phase.
	internal static func phases(environment: [String: String]) -> [Phase]? {
		guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
		else { return nil }
		if raw == "1" || raw == "all" { return Phase.allCases }

		var phases: [Phase] = []
		for name in raw.split(separator: ",") {
			guard let phase = Phase(rawValue: name.trimmingCharacters(in: .whitespaces)) else { return nil }
			if !phases.contains(phase) { phases.append(phase) }
		}

		// Always in the catalog's order, whatever order they were named in.
		return Phase.allCases.filter(phases.contains)
	}

	// MARK: - Shared steps

	/// Waits up to `seconds` for `ready`, naming `step` when it doesn't come.
	internal static func wait(
		_ step: String,
		seconds: Double = 10,
		context: () -> String = { "" },
		until ready: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now + .seconds(seconds)
		while ContinuousClock.now < deadline {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		if ready() { return }
		let detail = context()
		throw Failure("timed out: \(step)" + (detail.isEmpty ? "" : " (\(detail))"))
	}

	/// Presses `command`'s current shortcut as the keyboard sends it, through the main menu, so
	/// the key reaches the same item a person's press does.
	internal static func press(
		_ command: BrowserCommand,
		store: StoreOf<AppFeature>,
		window: NSWindow
	) throws {
		guard let shortcut = store.settings.keyboardShortcuts.shortcut(for: command)
		else { throw Failure("\(command.rawValue) has no shortcut") }
		guard let code = keyCodes[shortcut.key]
		else { throw Failure("no key code for \(shortcut.key)") }
		guard window.isKeyWindow, let menu = NSApp.mainMenu
		else { throw Failure("\(command.rawValue): the window isn't key") }

		var flags: CGEventFlags = []
		if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
		if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
		if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
		if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }

		// The system's own translation gives the characters a keyboard sends (DEV-795).
		let source = CGEventSource(stateID: .privateState)
		guard
			let key = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
		else { throw Failure("\(command.rawValue): no key event") }

		key.flags = flags
		guard let event = NSEvent(cgEvent: key), menu.performKeyEquivalent(with: event)
		else { throw Failure("the menu didn't take \(command.rawValue)'s key") }
	}

	/// Types `text` into the window's first responder, one key press per character, paced as a
	/// fast typist: each keystroke's round trip through the store lands before the next, where a
	/// burst in one run-loop turn races the field's binding.
	internal static func typeText(
		_ text: String,
		in window: NSWindow,
		interval: Duration = .milliseconds(20)
	) async throws {
		for character in text {
			try key(String(character), code: 0, in: window)
			try await Task.sleep(for: interval)
		}
	}

	/// Sends one key's down and up to `window`, as AppKit delivers a key press.
	/// - Parameters:
	///   - throughApp: Posts the key on the app's event queue, as a person's key press
	///     arrives: its local key monitors see it before the window does (DEV-1297).
	///     `NSApplication.sendEvent` alone skips them; they run as the run loop takes an event.
	internal static func key(
		_ characters: String,
		code: UInt16,
		modifiers: NSEvent.ModifierFlags = [],
		throughApp: Bool = false,
		in window: NSWindow
	) throws {
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: modifiers,
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: code
			) else { throw Failure("no key event for \(characters)") }

			if throughApp {
				NSApplication.shared.postEvent(event, atStart: false)
			} else {
				window.sendEvent(event)
			}
		}
	}

	/// A left click at `point`, in window coordinates, as a person's click arrives.
	internal static func click(
		at point: NSPoint,
		in window: NSWindow
	) throws {
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 1,
				clickCount: 1,
				pressure: type == .leftMouseDown ? 1 : 0
			) else { throw Failure("no mouse event") }

			window.sendEvent(event)
		}
	}

	/// The view AppKit picks for a mouse-down at `point`, in window coordinates.
	internal static func hit(
		at point: NSPoint,
		in window: NSWindow
	) -> NSView? {
		guard let frame = window.contentView?.superview ?? window.contentView else { return nil }
		return frame.hitTest(point)
	}

	/// Every view under `root`, depth first.
	internal static func views(under root: NSView) -> [NSView] {
		[root] + root.subviews.flatMap(views(under:))
	}

	/// The window's first responder, by its class and its two nearest ancestors' classes.
	internal static func responder(in window: NSWindow) -> String {
		guard let responder = window.firstResponder else { return "none" }
		guard let view = responder as? NSView else { return String(describing: type(of: responder)) }

		return sequence(first: view, next: \.superview).prefix(3)
			.map { String(describing: type(of: $0)) }
			.joined(separator: "<")
	}

	/// The text field `window`'s field editor is editing, if it's editing one.
	internal static func editedField(in window: NSWindow) -> (field: NSTextField, editor: NSTextView)? {
		guard
			let editor = window.firstResponder as? NSTextView,
			editor.isFieldEditor,
			let field = editor.delegate as? NSTextField
		else { return nil }
		return (field, editor)
	}

	/// Every label, value and title in the window's own accessibility tree: what it shows,
	/// SwiftUI text included, without asking for the Accessibility permission.
	internal static func accessibilityTexts(in window: NSWindow) -> [String] {
		accessibilityElements(in: window).flatMap { element in
			[element.accessibilityLabel(), element.accessibilityValue() as? String, element.accessibilityTitle()]
				.compactMap { $0 }
				.filter { !$0.isEmpty }
		}
	}

	/// Every element of the window's own accessibility tree, each once: every view under the
	/// window's frame view and the elements under each, SwiftUI's included. The walk starts from
	/// each view, since a hosting view can leave its elements out of its superview's children.
	internal static func accessibilityElements(in window: NSWindow) -> [NSAccessibilityProtocol] {
		var seen: Set<ObjectIdentifier> = []
		var found: [NSAccessibilityProtocol] = []
		func visit(_ element: Any, depth: Int) {
			guard depth < 40, let element = element as? NSAccessibilityProtocol & AnyObject else { return }
			guard seen.insert(ObjectIdentifier(element)).inserted else { return }
			found.append(element)
			for child in element.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
		}
		guard let root = window.contentView?.superview ?? window.contentView else { return [] }
		for view in views(under: root) { visit(view, depth: 0) }
		return found
	}

	/// ANSI key codes for the letters and digits a default shortcut uses.
	private static let keyCodes: [String: UInt16] = [
		"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
		"q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
		"6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
		"l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
	]
}
#endif
