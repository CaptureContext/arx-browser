import AppKit
import AppUI
import BrowserCore
import BrowserSiteIconClient
import MainFeature
import _ComposableArchitecture

@MainActor
internal final class BrowserCommands: NSObject, NSMenuItemValidation {
	internal private(set) static var installed: BrowserCommands?

	internal let store: StoreOf<AppFeature>

	/// The store's own client: the menu bar lives outside the store's dependency scope.
	private let siteIcons: BrowserSiteIconClient

	/// Whether the Tab menu's copy and share items sit in Copy ▸ (`CopySubmenuFeatureFlag`, DEV-1162).
	private let nestsCopies: Bool

	/// Whether Edit › Undo takes back the window's last step where no text has ⌘Z
	/// (`WindowUndoFeatureFlag`, DEV-1030).
	private let windowUndo: Bool
	private var keyMonitor: Any?

	/// The Arx page whose view holds a view, if any (DEV-1264, DEV-1073): only a page reports
	/// whether it used a key, so only a page is offered one.
	internal var pageContaining: (@MainActor (NSView) -> AnyObject?)?

	/// The keys let through to the page, kept to run Arx's command once the page leaves one.
	internal var offeredEvents: [SiteShortcutState.Key: NSEvent] = [:]

	/// The page's address, so a held Delayed press goes only to the document it was pressed on
	/// (DEV-1332).
	internal var pageURL: (@MainActor (AnyObject) -> URL?)?

	/// Delayed presses Arx holds until `SiteShortcuts` releases them (DEV-1332).
	internal var heldEvents: [SiteShortcutState.Key: NSEvent] = [:]

	/// The released press being posted to the page: the key monitor lets it through untouched.
	internal var releasingEvent: NSEvent?
	private var releaseObservation: ObserveToken?

	/// Where the last page-first key went, for its repeats while it's held.
	internal var heldPageFirstKey: HeldPageFirstKey?
	internal var pageFocusObservers: [Any] = []
	internal var responderObservation: NSKeyValueObservation?

	/// The page that has keyboard focus as far as the two-second rule knows.
	internal var pageFocusArrivals = PageFocusArrivals()
	private var observation: ObserveToken?
	private var selectionCopyTask: Task<Void, Never>?
	private var recentlyClosedMenu: RecentlyClosedMenu?

	/// ⌃Tab's recent-tab switcher while ⌃ is held (DEV-544).
	internal private(set) lazy var tabSwitcherKeys: RecentTabSwitcherKeys = .init(store: store)

	internal init(
		store: StoreOf<AppFeature>,
		siteIcons: BrowserSiteIconClient = .init(),
		nestsCopies: Bool = CopySubmenuFeatureFlag.isOn(),
		windowUndo: Bool = WindowUndoFeatureFlag.atLaunch
	) {
		self.store = store
		self.siteIcons = siteIcons
		self.nestsCopies = nestsCopies
		self.windowUndo = windowUndo
		super.init()
	}

	internal static func install(
		store: StoreOf<AppFeature>,
		siteIcons: BrowserSiteIconClient,
		pageURL: (@MainActor (AnyObject) -> URL?)? = nil,
		pageContaining: (@MainActor (NSView) -> AnyObject?)? = nil
	) {
		if let monitor = installed?.keyMonitor { NSEvent.removeMonitor(monitor) }
		installed?.stopFollowingPageFocus()
		let commands = BrowserCommands(store: store, siteIcons: siteIcons)
		commands.pageContaining = pageContaining
		commands.pageURL = pageURL
		installed = commands
		commands.followPageFocus()
		commands.installMenu()
		if let delegate = NSApplication.shared.delegate {
			BrowserDockMenu.install(on: delegate) { Self.installed?.makeDockMenu() }
		}
		commands.observation = commands.observe { [weak commands] in commands?.updateShortcuts() }

		// Delayed presses whose window ended go to their page after the current event (DEV-1332).
		commands.releaseObservation = commands.observe { [weak commands] in
			guard let commands, !commands.store.siteShortcuts.release.isEmpty else { return }
			DispatchQueue.main.async { [weak commands] in commands?.deliverReleasedKeys() }
		}

		// Chromium handles browser keys before the usual responder-chain menu route.
		// Let AppKit match equivalents so modifiers and keyboard layouts remain native.
		commands.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak commands] event in

			// While ⌃Tab's switcher is up, it takes the keys, Escape and the arrows too (DEV-544).
			if let commands, let taken = commands.tabSwitcherKeys.handle(keyDown: event) {
				return taken ? nil : event
			}
			guard let commands, !event.modifierFlags.intersection([.command, .control]).isEmpty || Self.isFunctionKey(event)
			else { return event }

			if commands.store.settings.recordingCommand != nil { return event }

			// The inspector window owns its keys; Close Tab must never reach the inspected page. So
			// does an extension's popup window (DEV-1316): its page gets them, and Close Window
			// closes it.
			if Self.ownsItsKeys(NSApplication.shared.keyWindow) { return event }
			let input = NSApplication.shared.keyWindow?.firstResponder as? NSTextInputClient
			if input?.hasMarkedText() == true { return event }

			// Docked DevTools searches its own panels and zooms its own interface (DEV-733).
			if Self.developerToolsHaveFocus, commands.belongsToDeveloperTools(event) { return event }

			// A held Delayed press Arx is giving to its page now (DEV-1332).
			if event === commands.releasingEvent { return event }

			// Keys whose Conflict resolution isn't Arx, ⌘Z and ⇧⌘Z go to a site that may use them
			// first (DEV-1264, DEV-1073, DEV-1332).
			if let handled = commands.offerToPage(event) { return handled ? nil : event }
			return commands.performKeyEquivalent(with: event) ? nil : event
		}
	}

	/// Whether keyboard focus is in a page's docked DevTools.
	internal static var developerToolsHaveFocus: Bool {
		var view = NSApplication.shared.keyWindow?.firstResponder as? NSView
		while let current = view {
			if current.identifier?.rawValue == "ArxDockedDeveloperTools" { return true }
			view = current.superview
		}
		return false
	}

	/// Keys DevTools uses itself, which focused docked DevTools keeps, as its separate
	/// window did: find, zoom, the command menu, Quick Open, Clear Console, Save, Inspect
	/// Element and panel switching (⌘[, ⌘] and ⌘1–⌘9, DEV-795). Everything else stays Arx's
	/// (⌥⌘I, ⌘W, ⌘T…).
	internal static let developerToolsKeys: Set<BrowserCore.KeyboardShortcut> = [
		.init(key: "f"), .init(key: "g"), .init(key: "g", modifiers: [.command, .shift]),
		.init(key: "="), .init(key: "-"), .init(key: "0"), .init(key: "=", modifiers: [.command, .shift]),
		.init(key: "+"), .init(key: "p"), .init(key: "p", modifiers: [.command, .shift]), .init(key: "o"),
		.init(key: "k"), .init(key: "s"), .init(key: "c", modifiers: [.command, .shift]),
		.init(key: "["), .init(key: "]"),
		.init(key: "1"), .init(key: "2"), .init(key: "3"), .init(key: "4"), .init(key: "5"),
		.init(key: "6"), .init(key: "7"), .init(key: "8"), .init(key: "9"),
	]

	private func belongsToDeveloperTools(_ event: NSEvent) -> Bool {
		let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
		guard let key = event.characters(byApplyingModifiers: modifiers.subtracting([.option, .shift]))?.lowercased()
		else { return false }

		var flags: BrowserCore.KeyboardShortcut.Modifiers = []
		if modifiers.contains(.command) { flags.insert(.command) }
		if modifiers.contains(.shift) { flags.insert(.shift) }
		if modifiers.contains(.option) { flags.insert(.option) }
		if modifiers.contains(.control) { flags.insert(.control) }
		return Self.developerToolsKeys.contains(.init(key: key, modifiers: flags))
		|| isZoomInAlias(event, modifiers: modifiers)
	}

	/// The command bound to the event's keys, by any of its shortcuts (DEV-920).
	internal func command(for event: NSEvent) -> BrowserCommand? {
		guard let shortcut = Self.shortcut(for: event) else { return nil }
		return store.settings.keyboardShortcuts.command(for: shortcut)
	}

	/// The shortcut a key press makes: one key typed without ⌥, ⇧ or ⌃, an arrow, Return or
	/// an F-key, with ⌘ or ⌃ unless it's an F-key.
	internal static func shortcut(for event: NSEvent) -> BrowserCore.KeyboardShortcut? {
		let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
		guard
			let characters = event.characters(byApplyingModifiers: flags.subtracting([.option, .shift, .control])),
			let shortcut = BrowserCore.KeyboardShortcut(characters: characters, modifiers: .init(flags))
		else { return nil }

		return shortcut.isValid ? shortcut : nil
	}

	private static func isFunctionKey(_ event: NSEvent) -> Bool {
		guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
		else { return false }
		return (0xF704...0xF70F).contains(scalar.value)
	}

	internal func performKeyEquivalent(with event: NSEvent) -> Bool {
		if NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) == true { return true }

		let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
		guard !modifiers.intersection([.command, .control]).isEmpty || Self.isFunctionKey(event)
		else { return false }
		let command = command(for: event)
		if let command, isEnabled(command) {
			perform(command)
			return true
		}

		// ⌘1–9 while Page PiP is key move its tab to that space (DEV-1184). Only by key: the
		// menu's Select Tab items stay the window's, and stay disabled here.
		if let command, movesPagePictureInPictureToSpace(command) {
			store.send(.ui(.command(command, target)))
			return true
		}

		// ⌃Tab and ⌃⇧Tab switch tabs too. Tab can't be bound, so these stay fixed beside Next
		// Tab's and Previous Tab's own keys (DEV-795). With `ARX_RECENT_TAB_SWITCHER` they go
		// back through the tabs the window showed last (DEV-544); off, they're Next
		// Tab and Previous Tab in the sidebar's order, as in Safari and Chrome.
		if command == nil, let step = RecentTabSwitcherKeys.step(keyCode: event.keyCode, modifiers: modifiers) {
			if let windowID = recentTabSwitcherWindow {
				tabSwitcherKeys.step(step, in: windowID)
				return true
			}
			let tabCommand: BrowserCommand = step > 0 ? .nextTab : .previousTab
			if isEnabled(tabCommand) {
				perform(tabCommand)
				return true
			}
		}

		// ⌘+ zooms in too, as in Chrome: ⇧⌘= on most layouts, or a + key of its own.
		if
			command == nil,
			isZoomInAlias(event, modifiers: modifiers),
			isEnabled(.zoomIn)
		{
			perform(.zoomIn)
			return true
		}
		return false
	}

	/// The browser window ⌃Tab's recent-tab switcher works in now: the target's, with its feature
	/// flag on, while nothing else holds the keyboard (DEV-544).
	private var recentTabSwitcherWindow: UUID? {
		guard
			case let .window(id, _) = target,
			NSApplication.shared.modalWindow == nil,
			store.settings.recordingCommand == nil,
			store.state.window(id)?.recentTabSwitcherEnabled == true,
			let context = store.state.commandContext(for: target),
			context.host == .main,
			!context.isBusy,
			!context.isClosing
		else { return nil }

		return id
	}

	/// ⌘+ while Zoom In keeps its default ⌘=. Only reached when no command is bound to the key.
	private func isZoomInAlias(
		_ event: NSEvent,
		modifiers: NSEvent.ModifierFlags
	) -> Bool {
		store.settings.keyboardShortcuts.shortcut(for: .zoomIn) == BrowserCommand.zoomIn.shortcut
		&& modifiers.subtracting(.shift) == .command
		&& event.charactersIgnoringModifiers == "+"
	}

	internal var target: AppFeature.CommandTarget {
		let identifier = NSApplication.shared.keyWindow?.identifier?.rawValue
		if identifier == "downloads" { return .downloads }
		if identifier == "task-manager" { return .taskManager }

		// Page PiP's window holds a page, not a browser window's commands (DEV-950).
		if identifier == PagePictureInPicturePanel.identifier { return .application }

		// Nor does an extension's popup window: no page command reaches the page behind it (DEV-1316).
		if identifier == ExtensionPopupPanel.identifier { return .application }
		if identifier == "settings" { return .settings }
		if identifier == "onboarding" { return .onboarding }
		if let id = store.focusedWindowID {
			let focusedTarget = store.state.commandTarget(in: id)
			if store.state.commandContext(for: focusedTarget) != nil { return focusedTarget }
		}
		return store.windowIsOpen ? store.state.commandTarget(in: store.main.id) : .application
	}

	internal func isEnabled(_ command: BrowserCommand) -> Bool {
		if command == .closeWindow, let window = NSApplication.shared.keyWindow, Self.ownsItsKeys(window) {
			return NSApplication.shared.modalWindow == nil && window.styleMask.contains(.closable)
		}
		guard
			NSApplication.shared.modalWindow == nil,
			store.settings.recordingCommand == nil,
			let context = store.state.commandContext(for: target)
		else { return false }

		// Page PiP's open address bar takes ⌘K and Copy URL, as CommandRouting sends them (DEV-1124).
		if store.state.pagePictureInPictureAddressBarAction(for: command, target: target) != nil { return true }

		return command.isEnabled(in: context)
	}

	/// Whether `command`, a Select Tab command, moves Page PiP's tab to a space now (DEV-1184).
	private func movesPagePictureInPictureToSpace(_ command: BrowserCommand) -> Bool {
		NSApplication.shared.modalWindow == nil
		&& store.settings.recordingCommand == nil
		&& store.state.pagePictureInPictureSpaceShortcut(for: command, target: target) != nil
	}

	internal func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		if menuItem.action == #selector(showAbout(_:)) { return true }
		if menuItem.action == #selector(undo(_:)) {
			switch UndoRoute.current(windowCanUndo: isEnabled(.undoOrganization)) {
			case .window: return true
			case .responder: return responderCanUndo(menuItem)
			}
		}
		if menuItem.action == #selector(useSelectionForFind(_:)) {
			return selectionFindResponder(for: menuItem) != nil
		}
		if menuItem.action == #selector(showKeyboardShortcuts(_:))
		|| menuItem.action == #selector(openManual(_:))
		|| menuItem.action == #selector(copyDiagnostics(_:))
		|| menuItem.action == #selector(reportProblem(_:)) {
			return NSApplication.shared.modalWindow == nil
		}
		if menuItem.action == #selector(openDockSpace(_:)) { return isEnabled(.newWindow) }
		if menuItem.action == #selector(checkForUpdates(_:)) {
			return NSApplication.shared.modalWindow == nil && store.settings.updates?.canCheck == true
		}
		if menuItem.action == #selector(moveToApplications(_:)) { return NSApplication.shared.modalWindow == nil }
		if menuItem.action == #selector(toggleKeepWindowOnTop(_:)) {
			let window = Self.browserWindow
			menuItem.state = window?.level == .floating ? .on : .off
			return NSApplication.shared.modalWindow == nil && window != nil
		}
		if menuItem.action == #selector(toggleFullURL(_:)) {
			let profile = fullURLProfile
			menuItem.state = profile?.showsWholeURL == true ? .on : .off
			return NSApplication.shared.modalWindow == nil && profile != nil
		}
		guard
			let raw = menuItem.representedObject as? String,
			let command = BrowserCommand(rawValue: raw)
		else { return false }

		return isEnabled(command)
	}

	private static let responderUndo: Selector = .init(("undo:"))

	/// Whether the responder that has Edit › Undo can undo now, by its own validation, as AppKit
	/// asks it without `ARX_WINDOW_UNDO`: an editor with nothing left to undo turns Undo off.
	private func responderCanUndo(_ menuItem: NSMenuItem) -> Bool {
		guard let target = NSApplication.shared.target(forAction: Self.responderUndo, to: nil, from: menuItem)
		else { return false }

		if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(menuItem) }
		if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(menuItem) }
		return true
	}

	/// Edit › Undo with `ARX_WINDOW_UNDO`, AppKit's standard `undo:` (DEV-1030). The focused text
	/// keeps it; elsewhere it runs Undo Organization Change for the window. It's sent here rather
	/// than down the responder chain because a page's view answers `undo:` even with nothing
	/// editable focused.
	@objc
	private func undo(_ sender: NSMenuItem) {
		switch UndoRoute.current(windowCanUndo: isEnabled(.undoOrganization)) {
		case .window: perform(.undoOrganization)
		case .responder: NSApplication.shared.sendAction(Self.responderUndo, to: nil, from: sender)
		}
	}

	@objc
	private func showAbout(_ sender: NSMenuItem) {
		AboutPanel.show()
	}

	/// Window ▸ Keep Window on Top (DEV-921): the front browser window floats above other apps'
	/// windows until it's turned off again. Not kept across launches.
	@objc
	private func toggleKeepWindowOnTop(_ sender: NSMenuItem) {
		guard let window = Self.browserWindow else { return }
		window.level = window.level == .floating ? .normal : .floating
	}

	/// The windows whose keys go to their own content before any command: DevTools', and an
	/// extension's popup window (DEV-1316). Close Window closes them; no command reaches a page
	/// behind them.
	private static func ownsItsKeys(_ window: NSWindow?) -> Bool {
		let identifier = window?.identifier?.rawValue
		return identifier == "ArxDeveloperTools" || identifier == ExtensionPopupPanel.identifier
	}

	/// The front titled browser window, not a panel or sheet.
	private static var browserWindow: NSWindow? {
		guard
			let window = NSApplication.shared.mainWindow,
			!(window is NSPanel),
			window.styleMask.contains(.titled),
			window.identifier?.rawValue != "ArxDeveloperTools"
		else { return nil }

		return window
	}

	/// View ▸ Always Show Full URL (DEV-921): the profile setting in Settings › Profiles, for the
	/// front window's profile.
	@objc
	private func toggleFullURL(_ sender: NSMenuItem) {
		guard let profile = fullURLProfile else { return }
		store.send(.settings(.delegate(.changeOrganization(.setShowsFullURL(profile.id, !profile.showsWholeURL)))))
	}

	private var fullURLProfile: Profile? {
		let state = store.state
		let id = state.focusedWindowID ?? (state.windowIsOpen ? state.main.id : nil)
		guard
			let id,
			let window = id == state.main.id ? (state.windowIsOpen ? state.main : nil) : state.windows[id: id],
			!window.isPrivate
		else { return nil }

		return state.workspace.profiles[id: window.sidebar.space.profileID]
	}

	@objc
	private func checkForUpdates(_ sender: NSMenuItem) {
		store.send(.settings(.ui(.checkForUpdates)))
	}

	@objc
	private func moveToApplications(_ sender: NSMenuItem) {
		RelocationRetry.retry()
	}

	@objc
	private func invoke(_ sender: NSMenuItem) {
		guard let raw = sender.representedObject as? String, let command = BrowserCommand(rawValue: raw)
		else { return }

		perform(command)
	}

	internal func perform(_ command: BrowserCommand) {
		guard isEnabled(command) else { return }
		if command == .closeWindow, let window = NSApplication.shared.keyWindow, Self.ownsItsKeys(window) {
			window.performClose(nil)
			return
		}
		if slidesSidebar(for: command) { return }
		store.send(.ui(.command(command, target)))
	}

	/// Next Space, Previous Space and Switch to Space in a browser window slide its sidebar
	/// there as a swipe does, and the space is selected once the slide lands (DEV-1310). Sent
	/// to the store first, each press ran the whole selection before anything moved. Returns
	/// whether the sidebar took the command; it doesn't in a window without one in view.
	private func slidesSidebar(for command: BrowserCommand) -> Bool {
		guard
			case .window = target,
			let window = NSApplication.shared.keyWindow
		else { return false }

		switch command {
		case .nextSpace: return SidebarSpaceSwitch.step(by: 1, in: window)
		case .previousSpace: return SidebarSpaceSwitch.step(by: -1, in: window)
		default:
			guard let number = command.spaceNumber else { return false }
			return SidebarSpaceSwitch.select(spaceAt: number - 1, in: window)
		}
	}

	private func updateShortcuts() {
		let bindings = store.settings.keyboardShortcuts
		func update(_ menu: NSMenu) {
			for item in menu.items {
				if let identifier = item.identifier, let keys = Self.textMenuKeys[identifier] {
					Self.apply(bindings.textMenuShortcut(keys), to: item)
				}
				if let raw = item.representedObject as? String, let command = BrowserCommand(rawValue: raw) {
					let shortcut = bindings.shortcut(for: command)
					item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
					item.keyEquivalentModifierMask = shortcut?.modifiers.appKit ?? []
				}
				if let submenu = item.submenu { update(submenu) }
			}
		}
		if let menu = NSApplication.shared.mainMenu { update(menu) }
	}

	/// Edit menu items with fixed keys that give way to a command the user binds to them (DEV-795, DEV-1014).
	private static let textMenuKeys: [NSUserInterfaceItemIdentifier: BrowserCore.KeyboardShortcut] = [
		.init("pasteAndMatchStyle"): .pasteAndMatchStyle,
		.init("useSelectionForFind"): .useSelectionForFind,
		.init("jumpToSelection"): .jumpToSelection,
	]

	private func applyTextMenuKeys(
		_ keys: BrowserCore.KeyboardShortcut,
		to item: NSMenuItem
	) {
		item.identifier = Self.textMenuKeys.first { $0.value == keys }?.key
		Self.apply(store.settings.keyboardShortcuts.textMenuShortcut(keys), to: item)
	}

	private static func apply(
		_ shortcut: BrowserCore.KeyboardShortcut?,
		to item: NSMenuItem
	) {
		item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
		item.keyEquivalentModifierMask = shortcut?.modifiers.appKit ?? []
	}

	private func installMenu() {
		let menu = makeMainMenu()
		NSApplication.shared.mainMenu = menu.root
		NSApplication.shared.windowsMenu = menu.window
		NSApplication.shared.helpMenu = menu.help
	}

	/// The menu bar, and its Window and Help menus, which AppKit fills in further.
	internal struct MainMenu {
		internal let root: NSMenu
		internal let window: NSMenu
		internal let help: NSMenu
	}

	/// Builds the menu bar without installing it, so tests can read every item (DEV-1014).
	internal func makeMainMenu() -> MainMenu {
		let root = NSMenu()
		let app = submenu("Arx", in: root)
		let about = NSMenuItem(
			title: String.localized(.appUI.menu.about),
			action: #selector(showAbout(_:)),
			keyEquivalent: ""
		)
		about.target = self
		app.addItem(about)

		// Enabled only while Sparkle can check, which a Debug, unsigned or unconfigured build never can.
		let checkForUpdates = NSMenuItem(
			title: String.localized(.appUI.menu.checkForUpdates),
			action: #selector(checkForUpdates(_:)),
			keyEquivalent: ""
		)
		checkForUpdates.target = self
		app.addItem(checkForUpdates)
		app.addItem(.separator())
		add(.settings, to: app)
		add(.onboarding, to: app)
		if RelocationRetry.isOffered {
			let move = NSMenuItem(
				title: String.localized(.appUI.menu.moveToApplications),
				action: #selector(moveToApplications(_:)),
				keyEquivalent: ""
			)
			move.target = self
			app.addItem(move)
		}
		app.addItem(.separator())
		NSApplication.shared.servicesMenu = submenu(String.localized(.appUI.menu.services), in: app)
		app.addItem(.separator())
		addResponder(String.localized(.appUI.menu.hide), #selector(NSApplication.hide(_:)), key: "h", to: app)
		addResponder(
			String.localized(.appUI.menu.hideOthers),
			#selector(NSApplication.hideOtherApplications(_:)),
			key: "h",
			modifiers: [.command, .option],
			to: app
		)
		addResponder(
			String.localized(.appUI.menu.showAll),
			#selector(NSApplication.unhideAllApplications(_:)),
			to: app
		)
		app.addItem(.separator())
		add(.quit, to: app)

		let file = submenu(String.localized(.appUI.menu.file), in: root)
		add(.newTab, to: file)
		for command in [BrowserCommand.newWindow, .newPrivateWindow, .littleArx] { add(command, to: file) }
		add(.reopenLastClosedTab, to: file)
		add(.reopenClosedWindow, to: file)
		add(.openFile, to: file)
		file.addItem(.separator())
		add(.address, to: file)
		add(.commandBar, to: file)
		file.addItem(.separator())
		add(.closeTab, to: file)
		add(.closeWindow, to: file)
		add(.savePageAs, to: file)
		add(.sharePage, to: file)
		add(.castTab, to: file)
		file.addItem(.separator())
		add(.captureViewport, to: file)
		add(.captureRegion, to: file)
		file.addItem(.separator())
		add(.pageSetup, to: file)
		add(.printPage, to: file)

		let edit = submenu(String.localized(.appUI.menu.edit), in: root)
		if windowUndo {
			// Text being edited keeps ⌘Z; elsewhere it takes back the window's last step (DEV-1030).
			let undo = NSMenuItem(title: String.localized(.appUI.menu.undo), action: #selector(undo(_:)), keyEquivalent: "z")
			undo.keyEquivalentModifierMask = .command
			undo.target = self
			edit.addItem(undo)
		} else {
			addResponder(String.localized(.appUI.menu.undo), Self.responderUndo, key: "z", to: edit)
		}
		addResponder(
			String.localized(.appUI.menu.redo),
			Selector(("redo:")),
			key: "z",
			modifiers: [.command, .shift],
			to: edit
		)
		edit.addItem(.separator())
		add(.undoOrganization, to: edit)
		edit.addItem(.separator())
		for (title, selector, key) in [
			(String.localized(.appUI.menu.cut), #selector(NSText.cut(_:)), "x"),
			(String.localized(.appUI.menu.copy), #selector(NSText.copy(_:)), "c"),
			(String.localized(.appUI.menu.paste), #selector(NSText.paste(_:)), "v"),
			(String.localized(.appUI.menu.selectAll), #selector(NSText.selectAll(_:)), "a")
		] {
			addResponder(title, selector, key: key, to: edit)
		}

		// Chromium's text views take it as plain text, as Safari and Chrome do (DEV-795). Its keys
		// give way to a command the user bound to them (`updateShortcuts`).
		let pasteAndMatchStyle = NSMenuItem(
			title: String.localized(.appUI.menu.pasteAndMatchStyle),
			action: Selector(("pasteAndMatchStyle:")),
			keyEquivalent: ""
		)
		applyTextMenuKeys(.pasteAndMatchStyle, to: pasteAndMatchStyle)
		edit.addItem(pasteAndMatchStyle)
		edit.addItem(.separator())
		let find = submenu(String.localized(.appUI.menu.find), in: edit)
		for command in [BrowserCommand.findInPage, .findNext, .findPrevious] { add(command, to: find) }
		let useSelection = addAction(String.localized(.appUI.menu.useSelectionForFind), #selector(useSelectionForFind(_:)), to: find)
		applyTextMenuKeys(.useSelectionForFind, to: useSelection)
		let jumpToSelection = addResponder(
			String.localized(.appUI.menu.jumpToSelection),
			#selector(NSTextView.centerSelectionInVisibleArea(_:)),
			to: find
		)
		applyTextMenuKeys(.jumpToSelection, to: jumpToSelection)
		installTextMenus(in: edit)

		let view = submenu(String.localized(.appUI.menu.view), in: root)
		for command in [BrowserCommand.toggleSidebar, .stopLoading, .reload, .reloadBypassingCache, .clearCacheAndReload] {
			add(command, to: view)
		}
		view.addItem(.separator())
		for command in [BrowserCommand.actualSize, .zoomIn, .zoomOut] { add(command, to: view) }
		view.addItem(.separator())
		addAction(String.localized(.appUI.menu.showFullURL), #selector(toggleFullURL(_:)), to: view)
		add(.darkPage, to: view)
		view.addItem(.separator())
		add(.readingMode, to: view)
		add(.translatePage, to: view)
		add(.hideElement, to: view)
		add(.viewSource, to: view)
		add(.developerTools, to: view)
		add(.inspectElement, to: view)
		add(.javaScriptConsole, to: view)
		view.addItem(.separator())
		let splitCommands: [BrowserCommand] = [.newSplit, .focusOtherPane, .closePane, .swapPanes, .toggleSplitOrientation]
		for command in splitCommands { add(command, to: view) }

		let spaces = submenu(String.localized(.appUI.menu.spaces), in: root)
		add(.newSpace, to: spaces)
		spaces.addItem(.separator())
		add(.nextSpace, to: spaces)
		add(.previousSpace, to: spaces)
		spaces.addItem(.separator())
		for command in BrowserCommand.switchToSpace { add(command, to: spaces) }

		let tab = submenu(String.localized(.appUI.menu.tab), in: root)
		add(.newTab, to: tab)
		add(.pinTab, to: tab)
		add(.newFolder, to: tab)
		add(.duplicateTab, to: tab)
		add(.moveItems, to: tab)
		tab.addItem(.separator())
		add(.archiveSelectedTabs, to: tab)
		add(.archiveAllInSpace, to: tab)
		tab.addItem(.separator())
		add(.nextTab, to: tab)
		add(.previousTab, to: tab)
		for command in BrowserCommand.selectTab { add(command, to: tab) }
		tab.addItem(.separator())
		if nestsCopies {
			// Copy ▸ with short titles; each item keeps its command's shortcut (DEV-1162).
			let copy = submenu(String.localized(.appUI.links.copyMenu.title), in: tab)
			for (index, section) in LinkCopyMenu.sections(modes: LinkCopyMode.allCases, sharesProxy: true).enumerated() {
				if index > 0 { copy.addItem(.separator()) }
				for item in section {
					guard let command = item.command else { continue }
					add(command, to: copy, title: item.copyMenuTitle())
				}
			}
		} else {
			let linkCommands: [BrowserCommand] = [
				.copyURL,
				.copyCleanLink,
				.copyMarkdownOriginal,
				.copyProxyLink,
				.copyMarkdownProxy,
				.shareProxyLink,
			]
			for command in linkCommands { add(command, to: tab) }
		}
		add(.routeCurrentURL, to: tab)
		tab.addItem(.separator())
		add(.openFocusedLinkInPeek, to: tab)

		let archive = submenu(String.localized(.appUI.menu.archive), in: root)
		add(.goBack, to: archive)
		add(.goForward, to: archive)
		archive.addItem(.separator())
		add(.showHistory, to: archive)
		add(.openArchive, to: archive)
		archive.addItem(.separator())
		let recentlyClosed = submenu(String.localized(.appUI.menu.recentlyClosed), in: archive)
		let recentlyClosedMenu = RecentlyClosedMenu(store: store, siteIcons: siteIcons)
		recentlyClosed.delegate = recentlyClosedMenu
		self.recentlyClosedMenu = recentlyClosedMenu

		let window = submenu(String.localized(.appUI.menu.window), in: root)
		addResponder(
			String.localized(.appUI.menu.minimize),
			#selector(NSWindow.performMiniaturize(_:)),
			key: "m",
			to: window
		)
		addResponder(String.localized(.appUI.menu.zoom), #selector(NSWindow.performZoom(_:)), to: window)
		window.addItem(.separator())
		add(.toggleLibrary, to: window)
		add(.chats, to: window)
		add(.pinChatToTab, to: window)
		add(.openChatInTab, to: window)
		add(.downloads, to: window)
		add(.media, to: window)
		add(.pagePictureInPicture, to: window)
		add(.mediaPictureInPicture, to: window)
		add(.extensions, to: window)
		add(.chromeWebStore, to: window)
		add(.taskManager, to: window)
		window.addItem(.separator())
		addAction(String.localized(.appUI.menu.keepWindowOnTop), #selector(toggleKeepWindowOnTop(_:)), to: window)
		window.addItem(.separator())
		addResponder(String.localized(.appUI.menu.front), #selector(NSApplication.arrangeInFront(_:)), to: window)

		let help = submenu(String.localized(.appUI.menu.help), in: root)
		addAction(String.localized(.appUI.menu.keyboardShortcuts), #selector(showKeyboardShortcuts(_:)), to: help)
		addAction(String.localized(.appUI.menu.manual), #selector(openManual(_:)), to: help)
		help.addItem(.separator())
		add(.sendFeedback, to: help, title: String.localized(.appUI.menu.sendFeedback))
		addAction(String.localized(.appUI.menu.reportProblem), #selector(reportProblem(_:)), to: help)
		addAction(String.localized(.appUI.menu.copyDiagnostics), #selector(copyDiagnostics(_:)), to: help)
		return .init(root: root, window: window, help: help)
	}

	/// Uses Chromium's existing selection-to-find operation, or the standard AppKit
	/// find-panel action for a native text view. Neither path reads the general clipboard.
	private func selectionFindResponder(for sender: NSMenuItem) -> (target: AnyObject, item: NSMenuItem)? {
		guard NSApplication.shared.modalWindow == nil else { return nil }
		for (selector, tag) in [
			(Selector(("copyToFindPboard:")), 0),
			(#selector(NSTextView.performFindPanelAction(_:)), Int(NSFindPanelAction.setFindString.rawValue)),
		] {
			let item = NSMenuItem(title: sender.title, action: selector, keyEquivalent: "")
			item.tag = tag
			guard let target = NSApplication.shared.target(forAction: selector, to: nil, from: item) as AnyObject?
			else { continue }
			if let validator = target as? any NSMenuItemValidation {
				guard validator.validateMenuItem(item) else { continue }
			} else if let validator = target as? any NSUserInterfaceValidations {
				guard validator.validateUserInterfaceItem(item) else { continue }
			}
			return (target, item)
		}
		return nil
	}

	@objc
	private func useSelectionForFind(_ sender: NSMenuItem) {
		guard let responder = selectionFindResponder(for: sender) else { return }
		selectionCopyTask?.cancel()
		let target = self.target
		let fromChromium = responder.item.action == Selector(("copyToFindPboard:"))
		let isDeveloperTools = Self.developerToolsHaveFocus
		|| NSApplication.shared.keyWindow?.identifier?.rawValue == "ArxDeveloperTools"
		let captured = fromChromium && !isDeveloperTools ? store.state.findSelectionItem(in: target) : nil
		let pasteboard = NSPasteboard(name: .find)
		let revision = pasteboard.changeCount
		guard
			let selector = responder.item.action,
			NSApplication.shared.sendAction(selector, to: responder.target, from: responder.item)
		else { return }
		guard let captured else { return }

		// Chromium copies through renderer IPC. Wait for that specific find-pasteboard
		// update, then bind its result back to the original tab and observation generation.
		selectionCopyTask = Task { @MainActor [weak self] in
			for _ in 0 ..< 100 {
				guard !Task.isCancelled else { return }
				if pasteboard.changeCount != revision {
					guard
						let self,
						let text = pasteboard.string(forType: .string),
						let action = store.state.findSelectionAction(text, in: target, from: captured)
					else { return }
					store.send(action)
					return
				}
				do { try await Task.sleep(for: .milliseconds(20)) }
				catch { return }
			}
		}
	}

	@objc
	private func showKeyboardShortcuts(_ sender: NSMenuItem) {
		store.send(.settings(.ui(.categorySelected(.shortcuts))))
		store.send(.settings(.ui(.pagePresented(nil))))
		store.send(.ui(.openSettings))
	}

	@objc
	private func openManual(_ sender: NSMenuItem) {
		guard let url = URL(string: "https://manual.arx.capturecontext.dev") else { return }
		NSWorkspace.shared.open(url)
	}

	@objc
	private func reportProblem(_ sender: NSMenuItem) {
		store.send(.ui(.reportProblem))
	}

	@objc
	private func copyDiagnostics(_ sender: NSMenuItem) {
		let info = Bundle.main.infoDictionary ?? [:]
		let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
		let build = info["CFBundleVersion"] as? String ?? "unknown"
		#if arch(arm64)
		let architecture = "arm64"
		#else
		let architecture = "x86_64"
		#endif
		let text = "Arx \(version) (\(build))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nArchitecture: \(architecture)"
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}

	@objc
	private func openDockSpace(_ sender: NSMenuItem) {
		guard
			isEnabled(.newWindow),
			let raw = sender.representedObject as? String,
			let id = UUID(uuidString: raw)
		else { return }
		store.send(.ui(.newWindowInSpace(.init(rawValue: id))))
	}

	internal func makeDockMenu() -> NSMenu {
		let menu = NSMenu()
		for command in [BrowserCommand.newWindow, .newPrivateWindow, .littleArx] { add(command, to: menu) }
		if store.workspace.spaces.count > 1 {
			let spaces = submenu(String.localized(.appUI.menu.windowInSpace), in: menu)
			for space in store.workspace.spaces {
				let profile = store.workspace.profiles[id: space.profileID]?.name ?? ""
				let item = addAction("\(profile) / \(space.name)", #selector(openDockSpace(_:)), to: spaces)
				item.representedObject = space.id.rawValue.uuidString
			}
		}
		return menu
	}

	@discardableResult
	private func addAction(
		_ title: String,
		_ selector: Selector,
		to menu: NSMenu
	) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
		item.target = self
		menu.addItem(item)
		return item
	}

	private func installTextMenus(in edit: NSMenu) {
		let spelling = submenu(String.localized(.appUI.contextMenu.spelling), in: edit)
		for (title, action) in [
			(String.localized(.appUI.menu.showSpelling), "showGuessPanel:"),
			(String.localized(.appUI.menu.checkSpelling), "checkSpelling:"),
			(String.localized(.appUI.contextMenu.checkSpellingWhileTyping), "toggleContinuousSpellChecking:"),
			(String.localized(.appUI.menu.checkGrammar), "toggleGrammarChecking:"),
			(String.localized(.appUI.menu.correctSpelling), "toggleAutomaticSpellingCorrection:"),
		] { addResponder(title, Selector((action)), to: spelling) }
		let substitutions = submenu(String.localized(.appUI.contextMenu.substitutions), in: edit)
		for (title, action) in [
			(String.localized(.appUI.contextMenu.showSubstitutions), "orderFrontSubstitutionsPanel:"),
			(String.localized(.appUI.contextMenu.smartQuotes), "toggleAutomaticQuoteSubstitution:"),
			(String.localized(.appUI.contextMenu.smartDashes), "toggleAutomaticDashSubstitution:"),
			(String.localized(.appUI.menu.smartLinks), "toggleAutomaticLinkDetection:"),
			(String.localized(.appUI.contextMenu.textReplacement), "toggleAutomaticTextReplacement:"),
		] { addResponder(title, Selector((action)), to: substitutions) }
		let transformations = submenu(String.localized(.appUI.menu.transformations), in: edit)
		for (title, action) in [
			(String.localized(.appUI.menu.uppercase), "uppercaseWord:"),
			(String.localized(.appUI.menu.lowercase), "lowercaseWord:"),
			(String.localized(.appUI.menu.capitalize), "capitalizeWord:"),
		] { addResponder(title, Selector((action)), to: transformations) }
		let speech = submenu(String.localized(.appUI.contextMenu.speech), in: edit)
		addResponder(String.localized(.appUI.contextMenu.startSpeaking), #selector(NSTextView.startSpeaking(_:)), to: speech)
		addResponder(String.localized(.appUI.contextMenu.stopSpeaking), #selector(NSTextView.stopSpeaking(_:)), to: speech)
	}

	private func submenu(
		_ title: String,
		in parent: NSMenu
	) -> NSMenu {
		let item = NSMenuItem()
		let menu = NSMenu(title: title)
		item.title = title
		item.submenu = menu
		parent.addItem(item)
		return menu
	}

	/// - Parameters:
	///   - title: the item's title where its menu already says part of it, as Copy ▸ does.
	private func add(
		_ command: BrowserCommand,
		to menu: NSMenu,
		title: String? = nil
	) {
		// A command whose feature flag is off has no item (`BrowserCommand.leftOutOfMenu`).
		guard !BrowserCommand.leftOutOfMenu(in: store.state).contains(command) else { return }

		let item = NSMenuItem(
			title: title ?? command.title,
			action: #selector(invoke(_:)),
			keyEquivalent: store.settings.keyboardShortcuts.shortcut(for: command)?.menuKeyEquivalent ?? ""
		)
		item.keyEquivalentModifierMask = store.settings.keyboardShortcuts.shortcut(for: command)?.modifiers.appKit ?? []
		item.representedObject = command.rawValue
		item.target = self
		menu.addItem(item)
	}

	@discardableResult
	private func addResponder(
		_ title: String,
		_ selector: Selector,
		key: String = "",
		modifiers: NSEvent.ModifierFlags = .command,
		to menu: NSMenu
	) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
		item.keyEquivalentModifierMask = modifiers
		menu.addItem(item)
		return item
	}
}

extension BrowserCore.KeyboardShortcut.Modifiers {
	internal init(_ flags: NSEvent.ModifierFlags) {
		self = []
		if flags.contains(.command) { insert(.command) }
		if flags.contains(.option) { insert(.option) }
		if flags.contains(.shift) { insert(.shift) }
		if flags.contains(.control) { insert(.control) }
	}

	internal var appKit: NSEvent.ModifierFlags {
		var flags: NSEvent.ModifierFlags = []
		if contains(.command) { flags.insert(.command) }
		if contains(.option) { flags.insert(.option) }
		if contains(.shift) { flags.insert(.shift) }
		if contains(.control) { flags.insert(.control) }
		return flags
	}
}

extension BrowserCommand {
	/// The commands whose feature flag is off: the menu bar leaves them out, and the app smoke's
	/// menu check skips them. Reading Mode without `ARX_READING_MODE` (DEV-1028), Hide Element
	/// without `ARX_HIDE_ELEMENT` (DEV-1019) and Dark Page without its dark pages flag (DEV-1020).
	/// The flags are read at launch; a new flagged command adds itself here.
	internal static func leftOutOfMenu(in state: AppFeature.State) -> Set<BrowserCommand> {
		var commands: Set<BrowserCommand> = []
		if !ReadingMode.isOn { commands.insert(.readingMode) }
		if !state.hideElementEnabled { commands.insert(.hideElement) }
		if !DarkPagesFeatureFlag.isEnabled() { commands.insert(.darkPage) }
		return commands
	}
}
