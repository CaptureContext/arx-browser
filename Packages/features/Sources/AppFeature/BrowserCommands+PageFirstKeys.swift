import AppKit
import BrowserCore
import Carbon.HIToolbox
import _ComposableArchitecture

/// The keys a site may take before Arx (DEV-1264, DEV-1073, DEV-1332), from the key monitor's side.
///
/// A key in `PageFirstKey` pressed while an Arx page has keyboard focus goes to the page instead of
/// the menu. The engine then reports whether the page used it (`receivePageKey`): a key it left
/// runs Arx's command at once, inside the engine's call; a key it used stays the page's, and
/// `SiteShortcuts` decides on the toast and the second press. A Delayed key (DEV-1332) is held
/// here instead, and given to the page when `SiteShortcuts` releases it, or dropped.
extension BrowserCommands {
	/// - Returns: `nil` when the key isn't one a page takes first, or no page has focus; `false` to
	///   let the key through to the page; `true` when Arx ran its command (the second press).
	internal func offerToPage(_ event: NSEvent) -> Bool? {
		guard
			let pageContaining,
			event.type == .keyDown,
			// An older engine follows ⌘ keys only, and a shortcut without ⌘ stays Arx's; one that
			// follows every key Arx can bind takes ⌃ keys and F-keys too (DEV-1332).
			event.modifierFlags.contains(.command) || store.settings.followsAllShortcutKeys,
			!Self.developerToolsHaveFocus,
			let window = NSApplication.shared.keyWindow,
			let responder = window.firstResponder as? NSView,
			let page = pageContaining(responder),
			let action = pageFirstKey(for: event, responder: responder)
		else { return nil }

		// A held key repeats where its press went: to the page, or to Arx's command. A Delayed press
		// being held swallows its repeats.
		if event.isARepeat {
			guard let held = heldPageFirstKey, held.matches(event) else { return nil }
			if held.isHeldByArx { return true }
			return held.wentToPage ? false : performKeyEquivalent(with: event)
		}
		let press: SiteShortcutState.Press = .init(
			key: Self.key(for: event),
			action: action,
			page: Self.page(page),
			// Page PiP's panel has no toast; the second press works the same.
			windowID: window.identifier?.rawValue == PagePictureInPicturePanel.identifier ? nil : store.focusedWindowID,
			// The keys pressed, which may be a command's second binding.
			shortcut: Self.shortcut(for: event)?.display ?? shortcutText(for: action),
			resolution: resolution(for: action, event: event),
			url: pageURL?(page)
		)
		store.send(.ui(.pageFirstKeyPressed(press)))

		// Delayed: Arx keeps the press until the window ends, or the second press (DEV-1332).
		if store.siteShortcuts.holds(press.key) {
			let shortcuts = store.siteShortcuts
			heldEvents = heldEvents.filter { entry in
				shortcuts.holds(entry.key) || shortcuts.release.contains { $0.key == entry.key }
			}
			heldEvents[press.key] = event
			heldPageFirstKey = .init(event, wentToPage: false, isHeldByArx: true)
			return true
		}
		if store.siteShortcuts.letsThrough(press.key) {
			offeredEvents = offeredEvents.filter { store.siteShortcuts.letsThrough($0.key) }
			offeredEvents[press.key] = event
			heldPageFirstKey = .init(event, wentToPage: true)
			return false
		}
		heldPageFirstKey = .init(event, wentToPage: false)
		return performKeyEquivalent(with: event)
	}

	/// The engine's report on a key a page received, for the installed commands.
	internal static func receivePageKey(_ key: SiteShortcutState.Key, consumed: Bool) -> Bool {
		installed?.receivePageKey(key, consumed: consumed) ?? false
	}

	/// The engine's report on a key a page received (ABI62). A key the page left runs Arx's command
	/// now, and the return says so.
	internal func receivePageKey(_ key: SiteShortcutState.Key, consumed: Bool) -> Bool {
		guard store.siteShortcuts.letsThrough(key) else { return false }

		let event = offeredEvents.removeValue(forKey: key)
		if consumed {
			store.send(.ui(.pageUsedKey(key)))
			return false
		}
		store.send(.ui(.pageLeftKey(key)))
		guard let event else { return false }

		// Only the latest press decides where a held key's repeats go.
		if heldPageFirstKey?.timestamp == event.timestamp {
			heldPageFirstKey = .init(event, wentToPage: false)
		}
		return performKeyEquivalent(with: event)
	}

	/// Which page-first key the event is, if any: a command whose Conflict resolution is Site or
	/// Both (DEV-1332), by its current shortcut, or ⌘Z and ⇧⌘Z while no text is being edited in
	/// the page.
	private func pageFirstKey(for event: NSEvent, responder: NSView) -> PageFirstKey? {
		guard let shortcut = Self.shortcut(for: event) else { return nil }

		if let command = command(for: event) {
			let resolution = store.settings.shortcutConflictChoices.resolution(
				for: command,
				shortcut: shortcut,
				followsAllKeys: store.settings.followsAllShortcutKeys
			)
			return resolution != .arx && isEnabled(command) ? .command(command) : nil
		}
		let isUndo = shortcut == .init(key: "z")
		let isRedo = shortcut == .init(key: "z", modifiers: [.command, .shift])
		guard isUndo || isRedo else { return nil }

		// Text being edited keeps its own undo, as before (DEV-1030): a page's view has an input
		// context only while a text field or an editable element has focus. A password field turns
		// secure input on.
		if IsSecureEventInputEnabled() { return nil }
		if responder is NSTextInputClient, responder.inputContext != nil { return nil }
		return isUndo ? .undo : .redo
	}

	/// Site, Both or Delayed for a command's keys (DEV-1332); ⌘Z and ⇧⌘Z follow Both's rules.
	private func resolution(for action: PageFirstKey, event: NSEvent) -> ShortcutConflictResolution {
		guard case let .command(command) = action, let shortcut = Self.shortcut(for: event) else { return .both }

		return store.settings.shortcutConflictChoices.resolution(
			for: command,
			shortcut: shortcut,
			followsAllKeys: store.settings.followsAllShortcutKeys
		)
	}

	private func shortcutText(for action: PageFirstKey) -> String {
		switch action {
		case let .command(command):
			store.settings.keyboardShortcuts.shortcut(for: command)?.display ?? ""
		case .undo:
			BrowserCore.KeyboardShortcut(key: "z").display
		case .redo:
			BrowserCore.KeyboardShortcut(key: "z", modifiers: [.command, .shift]).display
		}
	}

	internal static func key(for event: NSEvent) -> SiteShortcutState.Key {
		.init(
			keyCode: event.keyCode,
			modifierFlags: UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue),
			timestamp: event.timestamp
		)
	}

	internal static func page(_ page: AnyObject) -> SiteShortcutState.Page {
		.init(UInt(bitPattern: ObjectIdentifier(page).hashValue))
	}

	// MARK: - Focus

	/// Tells `SiteShortcuts` when a page takes keyboard focus: its window becomes key, its tab is
	/// selected, or focus comes back from the sidebar or the command bar. ⌘Z's two seconds count
	/// from then.
	internal func followPageFocus() {
		let center: NotificationCenter = .default
		pageFocusObservers = [
			center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self, let window = NSApplication.shared.keyWindow else { return }

					self.observeResponder(of: window)
					self.notePageFocus(in: window, windowBecameKey: true)
				}
			},
		]
		if let window = NSApplication.shared.keyWindow { observeResponder(of: window) }
	}

	// MARK: - Delayed

	/// Gives each released press to its page, or drops it when the page lost focus or navigated
	/// meanwhile (DEV-1332). A posted event goes through the key monitor again, which lets it reach
	/// the page as for Site: Arx's command still runs if the page doesn't use it.
	internal func deliverReleasedKeys() {
		let released = store.siteShortcuts.release
		guard !released.isEmpty else { return }

		for press in released {
			guard let event = heldEvents.removeValue(forKey: press.key) else {
				store.send(.ui(.heldKeyDropped(press.key)))
				continue
			}
			let focused = NSApplication.shared.keyWindow.flatMap { window in
				(window.firstResponder as? NSView).flatMap { pageContaining?($0) }
			}
			guard SiteShortcutState.delivers(
				press,
				focusedPage: focused.map(Self.page),
				currentURL: focused.flatMap { pageURL?($0) }
			)
			else {
				store.send(.ui(.heldKeyDropped(press.key)))
				continue
			}
			store.send(.ui(.heldKeyDelivered(press)))
			offeredEvents[press.key] = event
			releasingEvent = event
			if heldPageFirstKey?.timestamp == event.timestamp {
				heldPageFirstKey = .init(event, wentToPage: true)
			}
			NSApplication.shared.sendEvent(event)
			releasingEvent = nil
		}
	}

	internal func stopFollowingPageFocus() {
		pageFocusObservers.forEach(NotificationCenter.default.removeObserver)
		pageFocusObservers = []
		responderObservation = nil
		pageFocusArrivals = .init()
	}

	private func observeResponder(of window: NSWindow) {
		responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
			MainActor.assumeIsolated {
				self?.notePageFocus(in: window)
			}
		}
	}

	private func notePageFocus(in window: NSWindow, windowBecameKey: Bool = false) {
		guard window.isKeyWindow else { return }

		let page = (window.firstResponder as? NSView).flatMap { responder in
			pageContaining?(responder).map(Self.page)
		}
		guard let arrived = pageFocusArrivals.note(page, windowBecameKey: windowBecameKey)
		else { return }

		store.send(.ui(.pageTookKeyFocus(arrived)))
	}
}

/// When keyboard focus arrives at a page. Chromium moves the first responder between a page's
/// own views as it focuses, and that's no arrival: the two seconds would start again while the
/// person never left the page. Focus that went elsewhere in the window (the sidebar, the command
/// bar) and came back is one, and so is the window becoming key.
internal struct PageFocusArrivals: Equatable {
	internal private(set) var page: SiteShortcutState.Page?

	internal init(page: SiteShortcutState.Page? = nil) {
		self.page = page
	}

	/// Notes the page that has focus now, nil when none does. Returns it when it just arrived.
	internal mutating func note(
		_ current: SiteShortcutState.Page?,
		windowBecameKey: Bool
	) -> SiteShortcutState.Page? {
		defer { page = current }
		guard let current, windowBecameKey || current != page else { return nil }

		return current
	}
}

/// Where the last page-first key went, so its repeats while held go there too.
internal struct HeldPageFirstKey {
	internal var keyCode: UInt16
	internal var modifierFlags: NSEvent.ModifierFlags

	/// The press's own timestamp, telling it from earlier presses of the same keys.
	internal var timestamp: TimeInterval
	internal var wentToPage: Bool

	/// A Delayed press Arx holds (DEV-1332): its repeats go nowhere.
	internal var isHeldByArx: Bool

	internal init(_ event: NSEvent, wentToPage: Bool, isHeldByArx: Bool = false) {
		self.keyCode = event.keyCode
		self.timestamp = event.timestamp
		self.modifierFlags = event.modifierFlags.intersection([.command, .option, .shift, .control])
		self.wentToPage = wentToPage
		self.isHeldByArx = isHeldByArx
	}

	internal func matches(_ event: NSEvent) -> Bool {
		event.keyCode == keyCode
		&& event.modifierFlags.intersection([.command, .option, .shift, .control]) == modifierFlags
	}
}
