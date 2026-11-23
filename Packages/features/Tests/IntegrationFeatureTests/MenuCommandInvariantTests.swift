import AppKit
import BrowserCore
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// Rules that tie the menu bar, the command bar and Settings › Shortcuts together (DEV-1014).
/// `.agents/AGENTS.md` names each one beside its test.
@Suite(.dependencies)
@MainActor
internal struct MenuCommandInvariantTests {
	/// AppKit's own actions for the focused text view, the key window and the app, as every Mac
	/// app's menus have them. They aren't browser commands, so the command bar doesn't list them.
	private static let standardActions: Set<String> = [
		"hide:", "hideOtherApplications:", "unhideAllApplications:",
		"undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "pasteAndMatchStyle:",
		"useSelectionForFind:", "centerSelectionInVisibleArea:",
		"showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:", "toggleGrammarChecking:",
		"toggleAutomaticSpellingCorrection:", "orderFrontSubstitutionsPanel:", "toggleAutomaticQuoteSubstitution:",
		"toggleAutomaticDashSubstitution:", "toggleAutomaticLinkDetection:", "toggleAutomaticTextReplacement:",
		"uppercaseWord:", "lowercaseWord:", "capitalizeWord:", "startSpeaking:", "stopSpeaking:",
		"performMiniaturize:", "performZoom:", "arrangeInFront:",
	]

	/// Arx's own menu items that aren't browser commands yet, so neither the command bar nor
	/// Settings › Shortcuts has them. DEV-1015 brings them to the command bar with their toggle
	/// state. Take one out when the command bar finds it; never add one.
	private static let notYetCommands: Set<String> = [
		"showAbout:", "checkForUpdates:", "moveToApplications:", "toggleFullURL:", "toggleKeepWindowOnTop:",
		"showKeyboardShortcuts:", "openManual:", "reportProblem:", "copyDiagnostics:",
	]

	/// Only shown when the app runs outside /Applications.
	private static let conditionalActions: Set<String> = ["moveToApplications:"]

	@Test
	internal func everyMenuItemIsACommandOrAStandardAction() {
		let items = menuItems(bindings: [])
		var unexpected: [String] = []
		var found: Set<String> = []
		for (path, item) in items {
			let action = item.action.map(NSStringFromSelector) ?? "none"
			found.insert(action)
			if action == "invoke:" {
				if item.command == nil { unexpected.append("\(path): invoke: without a command") }
			} else if !Self.standardActions.contains(action), !Self.notYetCommands.contains(action) {
				unexpected.append("\(path): \(action)")
			}
		}

		#expect(
			unexpected.isEmpty,
			"Make these menu items BrowserCommands, which puts them in the command bar and Settings › Shortcuts: \(unexpected)"
		)
		let stale = Self.notYetCommands.subtracting(found).subtracting(Self.conditionalActions)
		#expect(stale.isEmpty, "No longer in the menu bar; take them out of notYetCommands: \(stale)")
	}

	@Test
	internal func everyMenuCommandIsInTheCommandBar() {
		let commands = Set(menuItems(bindings: []).compactMap(\.item.command))
		var neverListed = commands
		for context in Self.contexts {
			let listed = Set(
				CommandBarFeature.Entry.commands(in: context, bindings: [])
					.compactMap(\.command)
			)
			let omitted = CommandBarFeature.Entry.omittedCommands(in: context.host)
			for command in commands where command.isEnabled(in: context) {
				#expect(
					listed.contains(command) || omitted.contains(command),
					"\(command) is enabled in the menu bar for \(context.host) but missing from its command bar"
				)
			}
			neverListed.subtract(listed)
		}

		#expect(neverListed.isEmpty, "The command bar never lists these menu commands: \(neverListed)")
		expectNoDifference(CommandBarFeature.Entry.omittedCommands(in: .little), [.littleArx])
	}

	/// Hide Element waits for its `ARX_HIDE_ELEMENT` feature flag (DEV-1019): off, neither the menu
	/// bar nor a command bar has it, and ⇧⌘H isn't taken; on, both have it, with ⇧⌘H.
	@Test(arguments: [false, true])
	internal func hideElementIsInTheMenuAndTheCommandBarOnlyWithItsFeatureFlag(isOn: Bool) {
		let items = menuItems(bindings: [], hideElementEnabled: isOn).filter { $0.item.command == .hideElement }
		let shortcut: BrowserCore.KeyboardShortcut = .init(key: "h", modifiers: [.command, .shift])
		expectNoDifference(items.map(\.item.shortcut), isOn ? [shortcut] : [])

		var state = appState(bindings: [], hideElementEnabled: isOn)

		// The app smoke's menu check skips what the menu leaves out.
		expectNoDifference(BrowserCommand.leftOutOfMenu(in: state).contains(.hideElement), !isOn)
		_ = state.reconcileDeveloperMode()

		// The menu bar's and ⇧⌘H's context, and the window's own, which its command bar lists.
		let routed = state.commandContext(for: state.commandTarget(in: state.main.id))
		expectNoDifference(routed?.canHideElements, isOn)
		expectNoDifference(state.main.commandContext.canHideElements, isOn)
		for var context in Self.contexts where context.host == .main && !context.isPrivate {
			context.canHideElements = state.main.commandContext.canHideElements
			let listed = CommandBarFeature.Entry.commands(in: context, bindings: []).compactMap(\.command)
			expectNoDifference(listed.contains(.hideElement), isOn, "\(context.isSplit ? "split" : "single") window")

			// uBlock's picker is Chromium's: a page WebKit shows has none.
			context.usesWebKit = true
			#expect(!BrowserCommand.hideElement.isEnabled(in: context))
		}
	}

	/// The Tab menu's copy and share items sit in Copy ▸ with short titles and keep their
	/// shortcuts (DEV-1162); without the feature flag they stay at the top of the Tab menu.
	@Test(arguments: [false, true])
	internal func theTabMenusCopyItemsNestWithTheirFeatureFlag(nests: Bool) {
		var custom: [ShortcutBinding] = []
		custom.setShortcut(.init(key: "k", modifiers: [.command, .option]), for: .copyMarkdownProxy)
		let items = menuItems(bindings: custom, nestsCopies: nests)
		let copies = items.filter { $0.path.hasPrefix("Tabs ▸ ") && $0.item.command?.isCopyOrShareLink == true }

		expectNoDifference(
			copies.map(\.path),
			nests
			? [
				"Tabs ▸ Copy ▸ Link",
				"Tabs ▸ Copy ▸ Clean Link",
				"Tabs ▸ Copy ▸ Markdown",
				"Tabs ▸ Copy ▸ Proxy Link",
				"Tabs ▸ Copy ▸ Markdown (Proxy Link)",
				"Tabs ▸ Copy ▸ Share Proxy Link",
			]
			: [
				"Tabs ▸ Copy Current URL",
				"Tabs ▸ Copy Clean Link",
				"Tabs ▸ Copy Original Link as Markdown",
				"Tabs ▸ Copy Proxy Link",
				"Tabs ▸ Copy Proxy Link as Markdown",
				"Tabs ▸ Share Proxy Link",
			]
		)
		expectNoDifference(copies.map { $0.item.shortcut?.display }, ["⇧⌘C", nil, nil, nil, "⌥⌘K", nil])

		// Route Current URL stays in the Tab menu itself.
		#expect(items.contains { $0.path == "Tabs ▸ " + BrowserCommand.routeCurrentURL.title })
	}

	@Test
	internal func theWindowsCommandBarListsTheCommandsItsMenuBarEnables() {
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let listed = main.commandCandidates.compactMap(\.command)

		expectNoDifference(
			listed,
			BrowserCommand.allCases.filter { $0.isEnabled(in: main.commandContext) }
		)
	}

	/// On a site no proxy link rule matches, the menu bar disables the proxy link commands and the
	/// window's command bar lists them disabled, where choosing one does nothing (DEV-1262).
	@Test(arguments: [("https://x.com/user/status/1", true), ("https://capturecontext.dev", false)])
	internal func theCommandBarListsProxyLinkCommandsDisabledWhereNoRuleMatches(
		url: String,
		matches: Bool
	) async throws {
		@Shared(.proxyLinkRules)
		var rules: [ProxyLinkRule]

		$rules.withLock { $0 = ProxyLinkRule.defaults }
		let organization = IntegrationFeatureTests().fixture()
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let tab = try #require(main.sidebar.selectedTab)
		main.sidebar.organization.tabs[id: tab.id]?.restoration.url = try #require(URL(string: url))
		let proxyCommands: [BrowserCommand] = [.copyProxyLink, .copyMarkdownProxy, .shareProxyLink]
		let context = main.commandContext

		expectNoDifference(context.canProxyLink, matches)
		expectNoDifference(proxyCommands.filter { $0.isEnabled(in: context) }, matches ? proxyCommands : [])
		let entries = main.commandCandidates.filter { entry in
			proxyCommands.contains { entry.presentation.id == "command-" + $0.rawValue }
		}
		expectNoDifference(entries.map(\.presentation.isEnabled), [matches, matches, matches])
		expectNoDifference(
			entries.map(\.intent),
			proxyCommands.map { matches ? .command($0) : .disabledCommand($0) }
		)
	}

	@Test(arguments: Self.bindingSets)
	internal func everyMenuCommandShowsItsShortcutInTheMenuAndTheCommandBar(bindings: [ShortcutBinding]) {
		for (path, item) in menuItems(bindings: bindings) {
			guard let command = item.command else { continue }

			let shortcut = bindings.shortcut(for: command)
			#expect(item.shortcut == shortcut, "\(path) shows \(String(describing: item.shortcut?.display))")
			let entry = CommandBarFeature.Entry.command(command, bindings: bindings)
			#expect(entry.presentation.shortcut == shortcut?.display, "\(command) in the command bar")
		}
	}

	/// A fixed key that isn't reserved or a text menu key could be bound to a command, and then one
	/// of the two would never run.
	@Test(arguments: Self.bindingSets)
	internal func everyMenuKeyIsInTheShortcutCatalog(bindings: [ShortcutBinding]) {
		var owners: [BrowserCore.KeyboardShortcut: String] = [:]
		for (path, item) in menuItems(bindings: bindings) {
			guard let shortcut = item.shortcut else { continue }

			if item.command == nil {
				let isTextMenuKey = BrowserCore.KeyboardShortcut.textMenuKeys.contains(shortcut)
				#expect(
					shortcut.isReserved || isTextMenuKey,
					"\(path) has \(shortcut.display), which is neither reserved nor a text menu key that gives way"
				)
				if isTextMenuKey {
					#expect(bindings.command(for: shortcut) == nil, "\(path) keeps \(shortcut.display) from a command")
				}
			}

			// New Tab is in both the File and Tab menus.
			let owner = item.command?.rawValue ?? path
			if let other = owners[shortcut], other != owner {
				Issue.record("\(shortcut.display) is both \(other) and \(owner)")
			}
			owners[shortcut] = owner
		}
	}

	@Test
	internal func textMenuKeysGiveWayToABoundCommand() {
		var bindings: [ShortcutBinding] = []
		bindings.setShortcut(.useSelectionForFind, for: .reload)
		bindings.addShortcut(.jumpToSelection, for: .reload)
		let items = menuItems(bindings: bindings)
		let reload = items.filter { $0.item.command == .reload }.map(\.item.shortcut)
		let textItems = items.filter { item in
			let action = item.item.action.map(NSStringFromSelector)
			return ["useSelectionForFind:", "centerSelectionInVisibleArea:"].contains(action)
		}

		let none: BrowserCore.KeyboardShortcut? = nil
		expectNoDifference(reload, [BrowserCore.KeyboardShortcut.useSelectionForFind])
		expectNoDifference(textItems.map(\.item.shortcut), [none, none])
		expectNoDifference(bindings.textMenuShortcut(.jumpToSelection), none)
		expectNoDifference([ShortcutBinding]().textMenuShortcut(.jumpToSelection), .jumpToSelection)
	}

	@Test
	internal func everyDefaultShortcutIsValidUnreservedAndUnique() throws {
		for command in BrowserCommand.allCases {
			for shortcut in command.defaultShortcuts {
				#expect(shortcut.isValid, "\(command)'s default \(shortcut.display) is invalid")
				#expect(!shortcut.isReserved, "\(command)'s default \(shortcut.display) is reserved")
				#expect(
					!BrowserCore.KeyboardShortcut.textMenuKeys.contains(shortcut),
					"\(command)'s default \(shortcut.display) takes a text menu item's keys"
				)
			}
		}

		try BrowserPreferences(keyboardShortcuts: []).validate()
	}

	@Test(arguments: Self.bindingSets)
	internal func everyCommandIsInSettingsShortcuts(bindings: [ShortcutBinding]) {
		let rows = BrowserCommand.settingsShortcuts(bindings: bindings)

		expectNoDifference(rows.map(\.id), BrowserCommand.allCases.map(\.rawValue))
		for (command, row) in zip(BrowserCommand.allCases, rows) {
			let shortcuts = bindings.shortcuts(for: command)
			let keys = shortcuts.isEmpty
			? String.localized(.appUI.settings.shortcutNone)
			: shortcuts.map(\.display).joined(separator: ", ")
			#expect(row.keys == keys, "\(command) in Settings › Shortcuts")
		}
	}
}

extension MenuCommandInvariantTests {
	/// The defaults, and bindings that move, add and remove keys.
	nonisolated internal static let bindingSets: [[ShortcutBinding]] = {
		var custom: [ShortcutBinding] = []
		custom.setShortcut(.init(key: "e"), for: .reload)
		custom.addShortcut(.init(key: "r", modifiers: [.command, .control]), for: .reload)
		custom.setShortcut(nil, for: .newTab)
		custom.setShortcut(.pasteAndMatchStyle, for: .copyCleanLink)
		return [[], custom]
	}()

	/// Every host, private or not, split or not, with everything else that enables a command.
	private static var contexts: [BrowserCommandContext] {
		let hosts: [BrowserCommandContext.Host] = [
			.application, .downloads, .main, .little, .peek, .settings, .onboarding, .taskManager,
		]
		return hosts.flatMap { host in
			[false, true].flatMap { isPrivate in
				[false, true].map { isSplit in
					BrowserCommandContext(
						host: host,
						hasTab: true,
						isPrivate: isPrivate,
						canUndo: true,
						canReopenArchivedTab: true,
						canReopenClosedWindow: true,
						canArchiveSpace: true,
						canSwitchSpace: true,
						spaceCount: 9,
						isSplit: isSplit,
						canAddPane: true,
						canGoBack: true,
						canGoForward: true,
						isLoading: true,
						canSavePage: true,
						tabCount: 9,
						captureAvailable: true,
						downloadsAvailable: true,
						// Dark pages offered, as the menu has Dark Page with its flag on (DEV-1020, DEV-1143).
						darkPagesOffered: true,
						mediaAvailable: true,
						canPresentMedia: true,
						developerModeEnabled: true,
						// Content blocking on, so Hide Element is offered (DEV-1019).
						canHideElements: true,
						// A proxy link rule matches the page, so the proxy link commands are offered (DEV-1262).
						canProxyLink: true
					)
				}
			}
		}
	}

	/// The app with these bindings, and Hide Element's feature flag on or off.
	private func appState(
		bindings: [ShortcutBinding],
		hideElementEnabled: Bool
	) -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$keyboardShortcuts.withLock { $0 = bindings }
		state.hideElementEnabled = hideElementEnabled
		return state
	}

	/// Every item of the menu bar Arx installs, with its path, built with these bindings. Hide
	/// Element's (DEV-1019) and Copy ▸'s (DEV-1162) feature flags are on unless a test turns them off.
	private func menuItems(
		bindings: [ShortcutBinding],
		hideElementEnabled: Bool = true,
		nestsCopies: Bool = true
	) -> [(path: String, item: NSMenuItem)] {
		let state = appState(bindings: bindings, hideElementEnabled: hideElementEnabled)
		let store = Store(initialState: state) { AppFeature() }
		let menu = BrowserCommands(store: store, nestsCopies: nestsCopies).makeMainMenu()

		func items(
			in menu: NSMenu,
			path: String
		) -> [(path: String, item: NSMenuItem)] {
			menu.items.flatMap { item -> [(path: String, item: NSMenuItem)] in
				let itemPath = path.isEmpty ? item.title : path + " ▸ " + item.title
				if let submenu = item.submenu { return items(in: submenu, path: itemPath) }
				if item.isSeparatorItem { return [] }
				return [(itemPath, item)]
			}
		}
		return items(in: menu.root, path: "")
	}
}

extension BrowserCommand {
	fileprivate var isCopyOrShareLink: Bool {
		[.copyURL, .copyCleanLink, .copyMarkdownOriginal, .copyProxyLink, .copyMarkdownProxy, .shareProxyLink]
			.contains(self)
	}
}

extension NSMenuItem {
	fileprivate var command: BrowserCommand? {
		guard action.map(NSStringFromSelector) == "invoke:", let raw = representedObject as? String
		else { return nil }

		return BrowserCommand(rawValue: raw)
	}

	fileprivate var shortcut: BrowserCore.KeyboardShortcut? {
		guard !keyEquivalent.isEmpty else { return nil }

		return BrowserCore.KeyboardShortcut(characters: keyEquivalent, modifiers: .init(keyEquivalentModifierMask))
	}
}

extension CommandBarFeature.Entry {
	fileprivate var command: BrowserCommand? {
		guard case let .command(command) = intent else { return nil }

		return command
	}
}
