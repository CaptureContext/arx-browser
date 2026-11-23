import BrowserCore
import CustomDump
import Foundation
import Testing

/// Conflict resolution (DEV-1332): the defaults, what can be chosen, and how choices are stored.
internal struct ShortcutConflictResolutionTests {
	@Test
	internal func defaultsFollowMaxsTable() {
		let overrides: [ShortcutConflictOverride] = []

		// Arx: the commands that keep their keys, and Back and Forward.
		for command in BrowserCommand.keepsItsKeys.union(BrowserCommand.arxByDefault) {
			expectNoDifference(overrides.resolution(for: command), .arx, "\(command)")
		}

		// Both: the keys web apps share.
		for command in BrowserCommand.bothByDefault {
			expectNoDifference(overrides.resolution(for: command), .both, "\(command)")
		}
		let shared: [BrowserCommand] = [
			.commandBar, .toggleSidebar, .printPage, .pinTab, .duplicateTab, .openFile,
			.developerTools, .inspectElement, .viewSource, .newSplit, .closePane,
		]
		expectNoDifference(Set(shared), BrowserCommand.bothByDefault)

		// Arx: the address (⌘L) and Copy URL.
		for command in [BrowserCommand.address, .copyURL, .copyMarkdownOriginal, .goBack, .goForward] {
			expectNoDifference(overrides.resolution(for: command), .arx, "\(command)")
		}

		// Site: everything else, find included.
		for command in [BrowserCommand.reload, .tab1, .zoomIn, .findInPage, .findNext, .space1, .focusOtherPane, .settings] {
			expectNoDifference(overrides.resolution(for: command), .site, "\(command)")
		}

		#expect(BrowserCommand.bothByDefault.isDisjoint(with: BrowserCommand.keepsItsKeys))
		#expect(BrowserCommand.bothByDefault.isDisjoint(with: BrowserCommand.arxByDefault))
		#expect(BrowserCommand.arxByDefault.isDisjoint(with: BrowserCommand.keepsItsKeys))
	}

	@Test
	internal func theWindowIsTwoSecondsTheFirstTimeOnATabThenOne() {
		expectNoDifference(ShortcutConflictResolution.window(firstUseOnTab: true), 2)
		expectNoDifference(ShortcutConflictResolution.window(firstUseOnTab: false), 1)
	}

	/// A Both default the engine couldn't honour would be a choice that does nothing.
	@Test
	internal func everyBothDefaultHasAKeyAPageCanBeAskedAbout() {
		for command in BrowserCommand.bothByDefault {
			let reaches = command.defaultShortcuts.allSatisfy { $0.reachesPageFirst(followsAllKeys: true) }
			#expect(reaches, "\(command)")
			#expect(command.offersConflictResolution(shortcuts: command.defaultShortcuts, followsAllKeys: true), "\(command)")
		}
		#expect(BrowserCommand.goBack.offersConflictResolution(shortcuts: BrowserCommand.goBack.defaultShortcuts))
	}

	@Test
	internal func aChoiceIsOfferedOnlyForCommandKeysAPageCanBeAskedAbout() {
		#expect(BrowserCommand.findInPage.offersConflictResolution(shortcuts: [.init(key: "f")]))
		#expect(!BrowserCommand.littleArx.offersConflictResolution(shortcuts: [.init(key: "a", modifiers: [.command, .option])]))
		#expect(!BrowserCommand.closeTab.offersConflictResolution(shortcuts: [.init(key: "w")]))

		// With an engine that follows ⌘ keys only: not ⌃1 for a space, nor an F-key. Never without a
		// shortcut at all.
		#expect(!BrowserCommand.space1.offersConflictResolution(shortcuts: [.init(key: "1", modifiers: .control)]))
		#expect(!BrowserCommand.reload.offersConflictResolution(shortcuts: [.init(key: "f5", modifiers: [])]))
		#expect(!BrowserCommand.reload.offersConflictResolution(shortcuts: []))
		#expect(!BrowserCommand.reload.offersConflictResolution(shortcuts: [], followsAllKeys: true))

		// With one that follows every key Arx can bind (DEV-1332): ⌃1 and F-keys too, but still
		// never a command that keeps its keys.
		#expect(BrowserCommand.space1.offersConflictResolution(shortcuts: [.init(key: "1", modifiers: .control)], followsAllKeys: true))
		#expect(BrowserCommand.reload.offersConflictResolution(shortcuts: [.init(key: "f5", modifiers: [])], followsAllKeys: true))
		#expect(BrowserCommand.newSplit.offersConflictResolution(shortcuts: BrowserCommand.newSplit.defaultShortcuts, followsAllKeys: true))
		#expect(!BrowserCommand.newTab.offersConflictResolution(shortcuts: [.init(key: "t")], followsAllKeys: true))

		// A command with a ⌘ key among others.
		#expect(BrowserCommand.reload.offersConflictResolution(shortcuts: [.init(key: "f5", modifiers: []), .init(key: "r")]))
	}

	@Test
	internal func keysWithoutCommandStayArxsWhateverWasChosen() {
		var overrides: [ShortcutConflictOverride] = []
		overrides.setResolution(.delayed, for: .reload)
		expectNoDifference(overrides.resolution(for: .reload, shortcut: .init(key: "r")), .delayed)
		expectNoDifference(overrides.resolution(for: .reload, shortcut: .init(key: "f5", modifiers: [])), .arx)
		expectNoDifference(overrides.resolution(for: .reload, shortcut: .init(key: "r", modifiers: .control)), .arx)
		expectNoDifference(
			overrides.resolution(for: .reload, shortcut: .init(key: "f5", modifiers: []), followsAllKeys: true),
			.delayed
		)
	}

	@Test
	internal func onlyChoicesOtherThanTheDefaultAreStoredSorted() {
		var overrides: [ShortcutConflictOverride] = []
		overrides.setResolution(.delayed, for: .reload)
		overrides.setResolution(.arx, for: .findInPage)
		overrides.setResolution(.site, for: .findInPage)
		overrides.setResolution(.site, for: .commandBar)
		overrides.setResolution(.site, for: .quit)
		expectNoDifference(overrides, [
			.init(command: .commandBar, resolution: .site),
			.init(command: .reload, resolution: .delayed),
		])
		expectNoDifference(overrides.resolution(for: .findInPage), .site)
		expectNoDifference(overrides.resolution(for: .quit), .arx)

		// Back to the default: nothing stored.
		overrides.setResolution(.both, for: .commandBar)
		overrides.setResolution(.site, for: .reload)
		expectNoDifference(overrides, [])
	}

	@Test
	internal func aStoredChoiceForAKeptCommandIsIgnored() {
		let overrides: [ShortcutConflictOverride] = [.init(command: .littleArx, resolution: .site)]
		expectNoDifference(overrides.resolution(for: .littleArx), .arx)
	}

	@Test
	internal func choicesRoundTripApartFromTheRecordedShortcuts() throws {
		var preferences = BrowserPreferences()
		preferences.setShortcut(.init(key: "y", modifiers: [.command, .shift]), for: .reload)
		let bindings = preferences.keyboardShortcuts
		preferences.shortcutConflictChoices.setResolution(.delayed, for: .reload)
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded, preferences)

		// Choosing never touches anyone's recorded shortcuts.
		expectNoDifference(decoded.keyboardShortcuts, bindings)
		try decoded.validate()
	}

	@Test
	internal func preferencesFromBeforeConflictResolutionKeepTheDefaults() throws {
		let old = Data(#"{"grainEnabled":true,"grainIntensity":0.35,"grainSize":1,"searchShortcuts":[]}"#.utf8)
		let preferences = try JSONDecoder().decode(BrowserPreferences.self, from: old)
		expectNoDifference(preferences.shortcutConflictChoices, [])

		// A command a later version added, read by this one: every command falls back to its default.
		let newer = Data(#"""
		{"grainEnabled":true,"grainIntensity":0.35,"grainSize":1,"searchShortcuts":[],
		"shortcutConflictChoices":[{"command":"someFutureCommand","resolution":"site"}]}
		"""#.utf8)
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: newer)
		expectNoDifference(decoded.shortcutConflictChoices, [])

		// The unreleased first version's choices, stored under another key with other meanings,
		// are dropped: every command takes the new defaults.
		let firstVersion = Data(#"""
		{"grainEnabled":true,"grainIntensity":0.35,"grainSize":1,"searchShortcuts":[],
		"shortcutConflictResolutions":[{"command":"reload","resolution":"both"}]}
		"""#.utf8)
		let migrated = try JSONDecoder().decode(BrowserPreferences.self, from: firstVersion)
		expectNoDifference(migrated.shortcutConflictChoices, [])
	}
}
