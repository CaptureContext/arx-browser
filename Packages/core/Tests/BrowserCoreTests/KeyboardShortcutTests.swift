import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct KeyboardShortcutTests {
	@Test
	internal func legacyPreferencesUseDefaultBindingsAndDisabledBindingsRoundTrip() async throws {
		let old = Data(#"{"grainEnabled":true,"grainIntensity":0.35,"grainSize":1,"searchShortcuts":[]}"#.utf8)
		var preferences = try JSONDecoder().decode(BrowserPreferences.self, from: old)
		expectNoDifference(preferences.shortcut(for: .newTab), .init(key: "t"))
		preferences.globalLittleArxEnabled = true
		preferences.setShortcut(nil, for: .newTab)
		preferences.setShortcut(.init(key: "y", modifiers: [.command, .shift]), for: .reload)
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONEncoder().encode(preferences)
		)
		expectNoDifference(decoded, preferences)
		#expect(decoded.shortcut(for: .newTab) == nil)
		try decoded.validate()
	}

	@Test
	internal func collisionsIncludeDefaultsAndReservedEditingBindingsAreRejected() async throws {
		var preferences = BrowserPreferences()
		expectNoDifference(preferences.conflicts(for: .init(key: "t"), excluding: .reload), [.newTab])
		preferences.setShortcut(.init(key: "t"), for: .reload)
		#expect(throws: BrowserPreferences.ShortcutFailure.conflict) { try preferences.validate() }
		preferences.setShortcut(.init(key: "c"), for: .reload)
		#expect(throws: BrowserPreferences.ShortcutFailure.reserved) { try preferences.validate() }
		preferences.setShortcut(.init(key: "r", modifiers: .option), for: .reload)
		#expect(throws: BrowserPreferences.ShortcutFailure.invalidBinding) { try preferences.validate() }
	}

	@Test
	internal func availabilityExcludesUnsupportedHostsAndBusyTabActions() async throws {
		let empty = BrowserCommandContext(host: .main)
		#expect(BrowserCommand.newFolder.isEnabled(in: empty))
		#expect(!BrowserCommand.reload.isEnabled(in: empty))
		#expect(!BrowserCommand.duplicateTab.isEnabled(in: .init(host: .little, hasTab: true)))
		#expect(!BrowserCommand.littleArx.isEnabled(in: .init(host: .main, isPrivate: true)))
		#expect(!BrowserCommand.pinTab.isEnabled(in: .init(host: .main, hasTab: true, isSaved: true)))
		#expect(!BrowserCommand.copyURL.isEnabled(in: .init(host: .main, hasTab: true, isBusy: true)))
		#expect(!BrowserCommand.quit.isEnabled(in: .init(host: .main, isClosing: true)))
	}

	/// DEV-1019: Hide Element is ⇧⌘H, on an ordinary web page in a window with content blocking on.
	@Test
	internal func hideElementNeedsAnOrdinaryWebPageWithContentBlocking() {
		#expect(BrowserCommand.hideElement.shortcut == .init(key: "h", modifiers: [.command, .shift]))
		var context = BrowserCommandContext(host: .main, hasTab: true, canSavePage: true, canHideElements: true)
		#expect(BrowserCommand.hideElement.isEnabled(in: context))
		context.canHideElements = false
		#expect(!BrowserCommand.hideElement.isEnabled(in: context))
		context.canHideElements = true
		context.canSavePage = false
		#expect(!BrowserCommand.hideElement.isEnabled(in: context))
		context.canSavePage = true
		context.isPrivate = true
		#expect(!BrowserCommand.hideElement.isEnabled(in: context))
		// Peek and Little Arx too (DEV-1298); not Settings.
		#expect(BrowserCommand.hideElement.isEnabled(in: .init(host: .peek, hasTab: true, canSavePage: true, canHideElements: true)))
		#expect(BrowserCommand.hideElement.isEnabled(in: .init(host: .little, hasTab: true, canSavePage: true, canHideElements: true)))
		#expect(!BrowserCommand.hideElement.isEnabled(in: .init(host: .settings, hasTab: true, canSavePage: true, canHideElements: true)))
		// No other command takes ⇧⌘H.
		expectNoDifference(
			BrowserPreferences().conflicts(for: .init(key: "h", modifiers: [.command, .shift]), excluding: .hideElement),
			[]
		)
		#expect(throws: Never.self) { try BrowserPreferences().validate() }
	}

	@Test
	internal func aNewDefaultYieldsToKeysTheUserAlreadyGaveAnotherCommand() async throws {
		var preferences = BrowserPreferences()
		let keys = KeyboardShortcut(key: "p", modifiers: [.command, .shift])
		preferences.setShortcut(keys, for: .commandBar)
		try preferences.validateKeyboardShortcuts()
		#expect(preferences.shortcut(for: .commandBar) == keys)
		#expect(preferences.shortcut(for: .openFocusedLinkInPeek) == nil)
		expectNoDifference(preferences.conflicts(for: keys, excluding: .reload), [.commandBar])

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		try decoded.validate()
		preferences.setShortcut(nil, for: .commandBar)
		#expect(preferences.shortcut(for: .openFocusedLinkInPeek) == keys)
	}

	@Test
	internal func focusedLinkPeekNeedsAnOrdinaryPageOutsidePeek() async throws {
		let command = BrowserCommand.openFocusedLinkInPeek
		#expect(command.isEnabled(in: .init(host: .main, hasTab: true)))
		#expect(command.isEnabled(in: .init(host: .little, hasTab: true)))
		#expect(!command.isEnabled(in: .init(host: .main)))
		#expect(!command.isEnabled(in: .init(host: .main, hasTab: true, isPrivate: true)))
		#expect(!command.isEnabled(in: .init(host: .main, hasTab: true, isBusy: true)))
		for host in [BrowserCommandContext.Host.peek, .settings, .downloads, .onboarding, .application] {
			#expect(!command.isEnabled(in: .init(host: host, hasTab: true)))
		}
		let shortcut = try #require(command.shortcut)
		#expect(shortcut.isValid && !shortcut.isReserved)
		#expect(BrowserCommand.allCases.filter { $0.shortcut == shortcut } == [command])
	}

	@Test
	internal func archiveCommandsRespectProfilePrivacyAndAvailableHistory() async throws {
		let ordinary = BrowserCommandContext(host: .main, hasTab: true, canReopenArchivedTab: true)
		for command in [BrowserCommand.openArchive, .reopenLastClosedTab, .archiveSelectedTabs] {
			#expect(command.isEnabled(in: ordinary))
			#expect(!command.isEnabled(in: .init(host: .main, hasTab: true, isPrivate: true, canReopenArchivedTab: true)))
			#expect(!command.isEnabled(in: .init(host: .little, hasTab: true, canReopenArchivedTab: true)))
			#expect(!command.isEnabled(in: .init(
				host: .main,
				hasTab: true,
				isBusy: true,
				canReopenArchivedTab: true
			)))
		}
		#expect(!BrowserCommand.reopenLastClosedTab.isEnabled(in: .init(host: .main)))
		#expect(!BrowserCommand.archiveSelectedTabs.isEnabled(in: .init(host: .main, hasTab: true, isSaved: true)))
		expectNoDifference(
			BrowserCommand.reopenLastClosedTab.shortcut,
			.init(key: "t", modifiers: [.command, .shift])
		)
	}

	// MARK: - DEV-920

	@Test
	internal func arrowsReturnAndFunctionKeysAreShortcuts() async throws {
		let up = try #require(KeyboardShortcut(characters: "\u{F700}", modifiers: [.command, .option]))
		expectNoDifference(up, .init(key: "up", modifiers: [.command, .option]))
		#expect(up.isValid)
		expectNoDifference(up.display, "⌥⌘↑")
		expectNoDifference(up.menuKeyEquivalent, "\u{F700}")

		let enter = try #require(KeyboardShortcut(characters: "\u{3}", modifiers: [.command, .shift]))
		expectNoDifference(enter.key, "return")
		expectNoDifference(enter.menuKeyEquivalent, "\r")
		expectNoDifference(enter.keyCaps, ["⇧", "⌘", "↩"])

		let f7 = try #require(KeyboardShortcut(characters: "\u{F70A}", modifiers: []))
		expectNoDifference(f7.key, "f7")
		expectNoDifference(f7.display, "F7")
		#expect(f7.isValid)
		expectNoDifference(f7.menuKeyEquivalent, "\u{F70A}")

		// Arrows and Return still need ⌘ or ⌃; only F-keys work alone.
		#expect(!KeyboardShortcut(key: "left", modifiers: [.shift]).isValid)
		#expect(!KeyboardShortcut(key: "return", modifiers: []).isValid)
		#expect(!KeyboardShortcut(key: "f13", modifiers: [.command]).isValid)
		// Other function-key characters and control codes make no shortcut.
		#expect(KeyboardShortcut(characters: "\u{F72C}", modifiers: [.command])?.isValid != true)
		#expect(KeyboardShortcut(characters: "\u{1D}", modifiers: [.control]) == nil)
		expectNoDifference(KeyboardShortcut(characters: "K", modifiers: [.command])?.key, "k")
	}

	@Test
	internal func aCommandCanHaveSeveralShortcuts() async throws {
		var bindings: [ShortcutBinding] = []
		let extra = KeyboardShortcut(key: "right", modifiers: [.command, .option])
		bindings.addShortcut(extra, for: .nextTab)
		expectNoDifference(bindings.shortcuts(for: .nextTab), [BrowserCommand.nextTab.shortcut!, extra])
		expectNoDifference(bindings.shortcut(for: .nextTab), BrowserCommand.nextTab.shortcut)
		expectNoDifference(bindings.command(for: extra), .nextTab)
		expectNoDifference(bindings.conflicts(for: extra, excluding: .reload), [.nextTab])

		var preferences = BrowserPreferences()
		preferences.keyboardShortcuts = bindings
		try preferences.validateKeyboardShortcuts()
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONEncoder().encode(preferences)
		)
		expectNoDifference(decoded.keyboardShortcuts.shortcuts(for: .nextTab), bindings.shortcuts(for: .nextTab))

		bindings.removeShortcut(BrowserCommand.nextTab.shortcut!, for: .nextTab)
		expectNoDifference(bindings.shortcuts(for: .nextTab), [extra])
		bindings.removeShortcut(extra, for: .nextTab)
		#expect(bindings.shortcuts(for: .nextTab).isEmpty)
		// Adding to a command whose shortcuts were removed starts it again.
		bindings.addShortcut(extra, for: .nextTab)
		expectNoDifference(bindings.shortcuts(for: .nextTab), [extra])

		// The same shortcut twice for one command, or beside "none", isn't valid.
		preferences.keyboardShortcuts = [
			.init(command: .reload, shortcut: extra),
			.init(command: .reload, shortcut: extra),
		]
		#expect(throws: BrowserPreferences.ShortcutFailure.duplicateCommand) {
			try preferences.validateKeyboardShortcuts()
		}
		preferences.keyboardShortcuts = [
			.init(command: .reload, shortcut: extra),
			.init(command: .reload, shortcut: nil),
		]
		#expect(throws: BrowserPreferences.ShortcutFailure.duplicateCommand) {
			try preferences.validateKeyboardShortcuts()
		}
	}

	@Test
	internal func splitViewHasDefaultsThatYieldToTheUsersKeys() async throws {
		let bindings: [ShortcutBinding] = []
		expectNoDifference(bindings.shortcut(for: .newSplit), .init(key: "=", modifiers: [.control, .shift]))
		expectNoDifference(bindings.shortcuts(for: .focusOtherPane), [
			.init(key: "]", modifiers: [.control, .shift]),
			.init(key: "[", modifiers: [.control, .shift]),
		])
		for command in [BrowserCommand.newSplit, .focusOtherPane, .closePane, .swapPanes, .toggleSplitOrientation] {
			#expect(command.shortcut != nil)
			#expect(command.defaultShortcutYieldsToUserBindings)
		}
		try BrowserPreferences().validateKeyboardShortcuts()

		// Someone who gave ⌃⇧[ to another command keeps it.
		let taken: [ShortcutBinding] = [.init(command: .reload, shortcut: .init(key: "[", modifiers: [.control, .shift]))]
		expectNoDifference(taken.shortcuts(for: .focusOtherPane), [.init(key: "]", modifiers: [.control, .shift])])
	}

	@Test
	internal func developerKeysNeedDeveloperMode() async throws {
		expectNoDifference(BrowserCommand.inspectElement.shortcut, .init(key: "c", modifiers: [.command, .option]))
		expectNoDifference(BrowserCommand.javaScriptConsole.shortcut, .init(key: "j", modifiers: [.command, .option]))
		for command in [BrowserCommand.inspectElement, .javaScriptConsole] {
			#expect(!command.isEnabled(in: .init(host: .main, hasTab: true)))
			#expect(command.isEnabled(in: .init(host: .main, hasTab: true, developerModeEnabled: true)))
		}
		try BrowserPreferences().validateKeyboardShortcuts()
	}
}
