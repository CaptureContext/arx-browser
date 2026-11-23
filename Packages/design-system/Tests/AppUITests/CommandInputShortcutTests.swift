import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// How the command bar's field names a pressed key for the result actions' shortcuts (DEV-810).
// Hosts views, so it takes a render turn (DEV-1080).
@Suite(.renderTurn)
@MainActor
internal struct CommandInputShortcutTests {
	private typealias Coordinator = CommandInput.Coordinator

	@Test
	internal func modifiedReturnAndLettersAreNamedInMacOSOrder() {
		#expect(Coordinator.shortcut(modifiers: [.command], keyCode: 36, characters: "\r") == "⌘↩")
		#expect(Coordinator.shortcut(modifiers: [.command, .option], keyCode: 36, characters: "\r") == "⌥⌘↩")
		#expect(Coordinator.shortcut(modifiers: [.shift], keyCode: 76, characters: "\u{3}") == "⇧↩")
		#expect(Coordinator.shortcut(modifiers: [.control], keyCode: 7, characters: "x") == "⌃X")
		#expect(Coordinator.shortcut(modifiers: [.control, .shift], keyCode: 7, characters: "X") == "⌃⇧X")
		#expect(Coordinator.shortcut(modifiers: [.command, .shift, .capsLock], keyCode: 8, characters: "c") == "⇧⌘C")
	}

	@Test
	internal func plainTypingAndShiftedLettersAreNotShortcuts() {
		#expect(Coordinator.shortcut(modifiers: [], keyCode: 36, characters: "\r") == nil)
		#expect(Coordinator.shortcut(modifiers: [.shift], keyCode: 0, characters: "A") == nil)
		#expect(Coordinator.shortcut(modifiers: [], keyCode: 0, characters: "a") == nil)
	}

	@Test
	internal func theFieldRunsAnActionKeyOnlyWhileItIsBeingEdited() throws {
		let field = CommandInput.Field()
		let window = NSWindow(
			contentRect: .init(x: -10_000, y: -10_000, width: 300, height: 40),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		defer { window.close() }
		window.contentView = field
		var pressed: [String] = []
		field.onShortcut = { key in
			pressed.append(key)
			return key == "⌥⌘↩"
		}

		let littleArx = try #require(event(window, keyCode: 36, characters: "\r", modifiers: [.option, .command]))
		let typing = try #require(event(window, keyCode: 0, characters: "a", modifiers: []))
		#expect(!field.handleShortcut(littleArx))

		#expect(window.makeFirstResponder(field))
		#expect(field.handleShortcut(littleArx))
		#expect(!field.handleShortcut(typing))
		#expect(pressed == ["⌥⌘↩"])
	}

	private func event(
		_ window: NSWindow,
		keyCode: UInt16,
		characters: String,
		modifiers: NSEvent.ModifierFlags
	) -> NSEvent? {
		NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: 0,
			windowNumber: window.windowNumber,
			context: nil,
			characters: characters,
			charactersIgnoringModifiers: characters,
			isARepeat: false,
			keyCode: keyCode
		)
	}
}
