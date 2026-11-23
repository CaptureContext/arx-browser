import Foundation

/// Who gets a command's keys when the focused page would handle them too (DEV-1332): Settings ›
/// Shortcuts' Conflict resolution.
public enum ShortcutConflictResolution: String, Codable, CaseIterable, Sendable {
	/// Arx wins at once: its command runs, and the page never gets the keys.
	case arx

	/// The site wins at once: the page gets the keys. Arx's command runs only when the page
	/// doesn't use them (preventDefault), so no command becomes unreachable.
	case site

	/// The page gets the keys at once. When it uses them, a toast offers the second press: pressed
	/// again within the window, the keys run Arx's command and the page doesn't get them (DEV-1264).
	case both

	/// Arx holds the keys for the window, with the toast: pressed again within it, they run Arx's
	/// command and the page never sees either press; otherwise the page gets them when it ends,
	/// and Arx's command runs then if the page doesn't use them.
	case delayed

	/// How long a second press counts in Both and Delayed: 2 seconds the first time the keys are
	/// used on a tab, then 1 second (Max, DEV-1332).
	public static func window(firstUseOnTab: Bool) -> TimeInterval {
		firstUseOnTab ? 2 : 1
	}
}

/// A command's conflict resolution where it differs from the command's default (DEV-1332). Only
/// these are stored, so a later change to a default reaches everyone who never chose.
public struct ShortcutConflictOverride: Codable, Equatable, Sendable {
	public var command: BrowserCommand
	public var resolution: ShortcutConflictResolution

	public init(
		command: BrowserCommand,
		resolution: ShortcutConflictResolution
	) {
		self.command = command
		self.resolution = resolution
	}
}

extension BrowserCommand {
	/// Commands whose keys always stay Arx's (DEV-1332): the tab, window and app commands Chrome
	/// reserves from pages, so no page can trap you in a tab or keep you from leaving, and New
	/// Little Arx window, which also works from other apps. Settings shows them fixed at Arx.
	public static let keepsItsKeys: Set<Self> = [
		.newTab, .closeTab, .closeWindow, .newWindow, .newPrivateWindow, .reopenLastClosedTab,
		.nextTab, .previousTab, .quit, .littleArx,
	]

	/// Commands that are Arx by default but may be changed (DEV-1332): Back and Forward on ⌘[ and ⌘]
	/// (Max), and, the address (⌘L) and Copy URL with its Markdown form.
	public static let arxByDefault: Set<Self> = [.goBack, .goForward, .address, .copyURL, .copyMarkdownOriginal]

	/// Commands whose keys web apps commonly use and Arx wants too (DEV-1332):
	/// the command bar (⌘K), the sidebar (⌘S, Toggle Sidebar; sites use it to save), print (⌘P),
	/// bold (Pin Tab's ⌘B), duplicate (⌘D), open (⌘O), the developer keys, and adding or closing a
	/// split pane. The page gets them, and pressed again after it used them they run Arx's command.
	public static let bothByDefault: Set<Self> = [
		.commandBar, .toggleSidebar, .printPage, .pinTab, .duplicateTab, .openFile,
		.developerTools, .inspectElement, .viewSource, .newSplit, .closePane,
	]

	/// Who gets the command's keys unless the person chose otherwise: Arx for the commands that
	/// keep their keys and `arxByDefault`, Both for the keys web apps share, Site for the rest
	/// (find, reload, zoom, Select Tab, spaces, the other split keys…), where the page wins only
	/// when it uses the keys.
	public var defaultConflictResolution: ShortcutConflictResolution {
		if Self.keepsItsKeys.contains(self) || Self.arxByDefault.contains(self) { return .arx }
		return Self.bothByDefault.contains(self) ? .both : .site
	}

	/// Whether Settings offers a choice for the command (DEV-1332): never for the commands that
	/// keep their keys or have no shortcut, and only while one of its shortcuts can reach a page
	/// first. An engine that follows every key Arx can bind (`followsAllKeys`) reports on all of
	/// them; an older one on ⌘ keys only, so a page can't be asked first about ⌃1 or an F-key.
	public func offersConflictResolution(
		shortcuts: [KeyboardShortcut],
		followsAllKeys: Bool = false
	) -> Bool {
		!Self.keepsItsKeys.contains(self) && shortcuts.contains { $0.reachesPageFirst(followsAllKeys: followsAllKeys) }
	}
}

extension KeyboardShortcut {
	/// Whether a page can be asked about these keys before Arx: what the engine follows to the
	/// page's answer (ABI62, DEV-1264). With `followsAllKeys` (DEV-1332) that's every valid shortcut
	/// (⌘ or ⌃ held, or an F-key); before it, ⌘ keys only.
	public func reachesPageFirst(followsAllKeys: Bool = false) -> Bool {
		followsAllKeys ? isValid : modifiers.contains(.command)
	}
}

extension Array where Element == ShortcutConflictOverride {
	/// What the person chose for the command, else its default; always Arx for a command that
	/// keeps its keys.
	public func resolution(for command: BrowserCommand) -> ShortcutConflictResolution {
		guard !BrowserCommand.keepsItsKeys.contains(command) else { return .arx }

		return last { $0.command == command }?.resolution ?? command.defaultConflictResolution
	}

	/// Who gets these keys pressed for the command: its resolution, or Arx for keys a page can't
	/// be asked about first.
	public func resolution(
		for command: BrowserCommand,
		shortcut: KeyboardShortcut,
		followsAllKeys: Bool = false
	) -> ShortcutConflictResolution {
		shortcut.reachesPageFirst(followsAllKeys: followsAllKeys) ? resolution(for: command) : .arx
	}

	/// Stores the choice only where it differs from the command's default, sorted by command, so
	/// an unchanged choice is unchanged text.
	public mutating func setResolution(
		_ resolution: ShortcutConflictResolution,
		for command: BrowserCommand
	) {
		removeAll { $0.command == command }
		guard
			!BrowserCommand.keepsItsKeys.contains(command),
			resolution != command.defaultConflictResolution
		else { return }

		append(.init(command: command, resolution: resolution))
		sort { $0.command.rawValue < $1.command.rawValue }
	}
}
