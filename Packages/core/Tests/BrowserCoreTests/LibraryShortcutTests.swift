import BrowserCore
import Testing

/// DEV-753: the Library opens with ⇧⌘L, and the new default never takes a key someone already bound.
internal struct LibraryShortcutTests {
	@Test
	internal func theLibraryDefaultsToShiftCommandL() {
		let shortcut = KeyboardShortcut(key: "l", modifiers: [.command, .shift])
		#expect(BrowserCommand.toggleLibrary.shortcut == shortcut)
		#expect([ShortcutBinding]().shortcut(for: .toggleLibrary)?.keyCaps == ["⇧", "⌘", "L"])
		#expect(BrowserCommand.allCases.filter { $0.shortcut == shortcut } == [.toggleLibrary])
	}

	@Test
	internal func aKeyAlreadyBoundElsewhereKeepsItsCommand() {
		let shortcut = KeyboardShortcut(key: "l", modifiers: [.command, .shift])
		let bindings = [ShortcutBinding(command: .copyURL, shortcut: shortcut)]
		#expect(bindings.shortcut(for: .toggleLibrary) == nil)
		#expect(bindings.shortcut(for: .copyURL) == shortcut)
	}

	@Test
	internal func aReboundLibraryShowsItsOwnKeys() {
		let bindings = [ShortcutBinding(command: .toggleLibrary, shortcut: .init(key: "y", modifiers: [.command, .option]))]
		#expect(bindings.shortcut(for: .toggleLibrary)?.keyCaps == ["⌥", "⌘", "Y"])
	}
}
