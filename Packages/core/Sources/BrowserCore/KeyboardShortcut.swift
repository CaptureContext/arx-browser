import Foundation

/// A layout-aware character binding. Platform key codes deliberately stay out of persistence.
public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
	public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
		public static let command: Self = .init(rawValue: 1)
		public static let option: Self = .init(rawValue: 2)
		public static let shift: Self = .init(rawValue: 4)
		public static let control: Self = .init(rawValue: 8)

		public let rawValue: Int

		public init(rawValue: Int) {
			self.rawValue = rawValue
		}
	}

	public var key: String
	public var modifiers: Modifiers

	public init(
		key: String,
		modifiers: Modifiers = .command
	) {
		self.key = key.lowercased()
		self.modifiers = modifiers
	}

	public var display: String {
		var result = ""
		if modifiers.contains(.control) { result += "⌃" }
		if modifiers.contains(.option) { result += "⌥" }
		if modifiers.contains(.shift) { result += "⇧" }
		if modifiers.contains(.command) { result += "⌘" }
		return result + keyLabel
	}

	/// The key as a key cap shows it: ↑, ↩, F5 or the character.
	public var keyLabel: String {
		switch key {
		case "up": "↑"
		case "down": "↓"
		case "left": "←"
		case "right": "→"
		case "return": "↩"
		default: key.uppercased()
		}
	}

	/// One label per key, as key caps show them: the modifiers in menu order, then the key.
	public var keyCaps: [String] {
		var caps: [String] = []
		if modifiers.contains(.control) { caps.append("⌃") }
		if modifiers.contains(.option) { caps.append("⌥") }
		if modifiers.contains(.shift) { caps.append("⇧") }
		if modifiers.contains(.command) { caps.append("⌘") }
		return caps + [keyLabel]
	}

	public var searchTerms: String {
		var terms = [key, keyLabel]
		if modifiers.contains(.control) { terms.append("control ctrl") }
		if modifiers.contains(.option) { terms.append("option alt") }
		if modifiers.contains(.shift) { terms.append("shift") }
		if modifiers.contains(.command) { terms.append("command cmd") }
		return terms.joined(separator: " ")
	}

	/// One printable key, an arrow, Return or F1–F12 (DEV-920). Every key but an F-key needs
	/// ⌘ or ⌃; F-keys type nothing, so they work alone too.
	public var isValid: Bool {
		let printable = key.count == 1
		&& key == key.lowercased()
		&& key.unicodeScalars.allSatisfy { scalar in
			!CharacterSet.controlCharacters.contains(scalar)
			&& !CharacterSet.whitespacesAndNewlines.contains(scalar)
		}
		&& !(0xF700...0xF8FF).contains(key.unicodeScalars.first?.value ?? 0)
		guard printable || isNamedKey, modifiers.rawValue & ~15 == 0 else { return false }

		return isFunctionKey || !modifiers.intersection([.command, .control]).isEmpty
	}

	/// Keys a shortcut may name besides one printable character (DEV-920).
	public static let namedKeys: [String] = ["up", "down", "left", "right", "return"] + (1...12).map { "f\($0)" }

	public var isNamedKey: Bool { Self.namedKeys.contains(key) }

	/// F1 to F12.
	public var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && isNamedKey }

	/// The key as a menu item's key equivalent takes it: AppKit's function-key characters for
	/// arrows and F-keys, a carriage return for Return.
	public var menuKeyEquivalent: String {
		switch key {
		case "up": "\u{F700}"
		case "down": "\u{F701}"
		case "left": "\u{F702}"
		case "right": "\u{F703}"
		case "return": "\r"
		default:
			if isFunctionKey, let number = Int(key.dropFirst()), let scalar = UnicodeScalar(0xF704 + number - 1) {
				String(Character(scalar))
			} else {
				key
			}
		}
	}

	/// The shortcut a key press makes, from the characters it types without ⌥, ⇧ or ⌃
	/// (`NSEvent.characters(byApplyingModifiers:)`): arrows, Return, Enter and F-keys get their
	/// names. Nil for keys a shortcut can't use.
	public init?(
		characters: String,
		modifiers: Modifiers
	) {
		guard let scalar = characters.unicodeScalars.first, characters.unicodeScalars.count == 1
		else { return nil }

		let key: String? = switch scalar.value {
		case 0xF700: "up"
		case 0xF701: "down"
		case 0xF702: "left"
		case 0xF703: "right"
		case 0x0D, 0x03: "return"
		case 0xF704...0xF70F: "f\(scalar.value - 0xF704 + 1)"
		default: CharacterSet.controlCharacters.contains(scalar) ? nil : characters.lowercased()
		}
		guard let key else { return nil }

		self.init(key: key, modifiers: modifiers)
	}

	/// Editing and standard window/application commands continue through the responder chain.
	public var isReserved: Bool {
		(modifiers == .command && ["a", "c", "x", "v", "z", "h", "m"].contains(key))
		|| (modifiers == [.command, .shift] && key == "z")
		|| (modifiers == [.command, .option] && key == "h")
	}
}

extension KeyboardShortcut {
	/// Paste and Match Style's keys (DEV-795). It's an Edit menu item for the focused text
	/// view, not a browser command, so it can't be rebound; it gives way to a command the
	/// user binds to the same keys.
	public static let pasteAndMatchStyle: Self = .init(key: "v", modifiers: [.command, .option, .shift])

	/// Edit ▸ Find ▸ Use Selection for Find's keys. Like Paste and Match Style, it gives way to a
	/// command the user binds to them (DEV-1014).
	public static let useSelectionForFind: Self = .init(key: "e")

	/// Edit ▸ Find ▸ Jump to Selection's keys, which give way the same way (DEV-1014).
	public static let jumpToSelection: Self = .init(key: "j")

	/// The keys of Edit menu items that act on the focused text view, aren't browser commands
	/// and can't be rebound. Each gives way to a command the user binds to the same keys.
	public static let textMenuKeys: [Self] = [.pasteAndMatchStyle, .useSelectionForFind, .jumpToSelection]
}

/// A nil shortcut explicitly disables a command's default binding.
public struct ShortcutBinding: Codable, Equatable, Sendable {
	public var command: BrowserCommand
	public var shortcut: KeyboardShortcut?

	public init(
		command: BrowserCommand,
		shortcut: KeyboardShortcut?
	) {
		self.command = command
		self.shortcut = shortcut
	}
}

extension Array where Element == ShortcutBinding {
	/// A command's own bindings, else its defaults; empty when it has none or they were
	/// removed. A command may have several (DEV-920); the first is the one menus show. A
	/// default added after people could already bind keys yields to a binding the user gave
	/// another command, so saved shortcuts stay valid.
	public func shortcuts(for command: BrowserCommand) -> [KeyboardShortcut] {
		let own = filter { $0.command == command }
		if !own.isEmpty { return own.compactMap(\.shortcut) }

		return command.defaultShortcuts.filter { shortcut in
			!command.defaultShortcutYieldsToUserBindings
			|| !contains { $0.command != command && $0.shortcut == shortcut }
		}
	}

	/// The command's first shortcut, the one its menu item shows.
	public func shortcut(for command: BrowserCommand) -> KeyboardShortcut? {
		shortcuts(for: command).first
	}

	/// The command `shortcut` runs, if any.
	public func command(for shortcut: KeyboardShortcut) -> BrowserCommand? {
		BrowserCommand.allCases.first { shortcuts(for: $0).contains(shortcut) }
	}

	public func conflicts(
		for shortcut: KeyboardShortcut,
		excluding command: BrowserCommand
	) -> [BrowserCommand] {
		BrowserCommand.allCases.filter { $0 != command && shortcuts(for: $0).contains(shortcut) }
	}

	/// Paste and Match Style's keys, unless a command has them (DEV-795).
	public var pasteAndMatchStyleShortcut: KeyboardShortcut? {
		textMenuShortcut(.pasteAndMatchStyle)
	}

	/// A text menu item's keys (one of `KeyboardShortcut.textMenuKeys`), unless a command has them.
	public func textMenuShortcut(_ keys: KeyboardShortcut) -> KeyboardShortcut? {
		BrowserCommand.allCases.contains { shortcuts(for: $0).contains(keys) } ? nil : keys
	}

	/// Replaces the command's shortcuts with one, or removes them all with nil.
	public mutating func setShortcut(
		_ shortcut: KeyboardShortcut?,
		for command: BrowserCommand
	) {
		removeAll { $0.command == command }
		append(.init(command: command, shortcut: shortcut))
	}

	/// Gives the command another shortcut beside the ones it has (DEV-920).
	public mutating func addShortcut(
		_ shortcut: KeyboardShortcut,
		for command: BrowserCommand
	) {
		let current = shortcuts(for: command)
		guard !current.contains(shortcut) else { return }

		removeAll { $0.command == command }
		append(contentsOf: (current + [shortcut]).map { .init(command: command, shortcut: $0) })
	}

	/// Takes one shortcut from the command, keeping its others (DEV-920).
	public mutating func removeShortcut(
		_ shortcut: KeyboardShortcut,
		for command: BrowserCommand
	) {
		let remaining = shortcuts(for: command).filter { $0 != shortcut }
		removeAll { $0.command == command }
		if remaining.isEmpty {
			append(.init(command: command, shortcut: nil))
		} else {
			append(contentsOf: remaining.map { .init(command: command, shortcut: $0) })
		}
	}
}

extension BrowserPreferences {
	public func shortcut(for command: BrowserCommand) -> KeyboardShortcut? {
		keyboardShortcuts.shortcut(for: command)
	}

	public func conflicts(
		for shortcut: KeyboardShortcut,
		excluding command: BrowserCommand
	) -> [BrowserCommand] {
		keyboardShortcuts.conflicts(for: shortcut, excluding: command)
	}

	public mutating func setShortcut(
		_ shortcut: KeyboardShortcut?,
		for command: BrowserCommand
	) {
		keyboardShortcuts.setShortcut(shortcut, for: command)
	}

	/// A command has either one nil binding (no shortcut) or distinct shortcuts (DEV-920).
	public func validateKeyboardShortcuts() throws {
		var own: [BrowserCommand: [KeyboardShortcut?]] = [:]
		for binding in keyboardShortcuts {
			own[binding.command, default: []].append(binding.shortcut)
			if let shortcut = binding.shortcut {
				guard shortcut.isValid else { throw ShortcutFailure.invalidBinding }
				guard !shortcut.isReserved else { throw ShortcutFailure.reserved }
			}
		}
		for shortcuts in own.values where shortcuts.count > 1 {
			let set = Set(shortcuts.compactMap(\.self))
			guard set.count == shortcuts.count else { throw ShortcutFailure.duplicateCommand }
		}
		var bindings: Set<KeyboardShortcut> = []
		for command in BrowserCommand.allCases {
			for shortcut in keyboardShortcuts.shortcuts(for: command) where !bindings.insert(shortcut).inserted {
				throw ShortcutFailure.conflict
			}
		}
	}

	public enum ShortcutFailure: Error, Equatable {
		case duplicateCommand
		case invalidBinding
		case reserved
		case conflict
	}
}
