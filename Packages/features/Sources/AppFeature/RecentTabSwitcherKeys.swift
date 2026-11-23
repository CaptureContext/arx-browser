import AppKit
import MainFeature
import _ComposableArchitecture

/// The keys of ⌃Tab's recent-tab switcher (DEV-544), from the first ⌃Tab until ⌃ is let go of.
///
/// `BrowserCommands` hands it ⌃Tab and ⌃⇧Tab in a window with `ARX_RECENT_TAB_SWITCHER` on, and
/// every key press while the switcher is up. Meanwhile it watches ⌃ itself: letting go of it goes
/// to the tab the switcher is on, which within the window's beat is the previous tab, before the
/// switcher ever shows. Escape goes nowhere; so does the window or the app losing the keyboard.
@MainActor
internal final class RecentTabSwitcherKeys {
	private let store: StoreOf<AppFeature>

	/// The window whose switcher is up.
	private var windowID: UUID?
	private var flagsMonitor: Any?
	private var observers: [any NSObjectProtocol] = []

	internal init(store: StoreOf<AppFeature>) {
		self.store = store
	}

	/// ⌃Tab (1) or ⌃⇧Tab (-1) in the window: begins its switcher, or moves it on.
	internal func step(
		_ step: Int,
		in windowID: UUID
	) {
		if self.windowID != windowID {
			cancel()
			begin(windowID)
		}
		store.send(.ui(.tabSwitcher(.step(step), window: windowID)))

		// Fewer than two tabs to go between: there's no switcher to watch.
		if !isUp { end() }
	}

	/// A key pressed while the switcher is up: true when the switcher took it, nil when it isn't up.
	internal func handle(keyDown event: NSEvent) -> Bool? {
		guard let windowID else { return nil }
		guard isUp else {
			end()
			return nil
		}
		let shift = event.modifierFlags.contains(.shift)
		switch event.keyCode {
		case Self.tabKey:
			guard event.modifierFlags.contains(.control) else {
				// ⌃ went up without telling us: that was the pick, and this Tab is the page's.
				finish(.commit)
				return false
			}
			store.send(.ui(.tabSwitcher(.step(shift ? -1 : 1), window: windowID)))
		case Self.escapeKey:
			finish(.cancel)
		case Self.returnKey, Self.enterKey:
			finish(.commit)
		case Self.upArrowKey, Self.leftArrowKey:
			store.send(.ui(.tabSwitcher(.step(-1), window: windowID)))
		case Self.downArrowKey, Self.rightArrowKey:
			store.send(.ui(.tabSwitcher(.step(1), window: windowID)))
		default:
			// Other keys stay out of the page while ⌃ is held for the switcher.
			break
		}
		return true
	}

	/// The modifiers changed: letting go of ⌃ goes to the tab the switcher is on.
	internal func handle(flagsChanged event: NSEvent) {
		guard windowID != nil, !event.modifierFlags.contains(.control) else { return }
		finish(.commit)
	}

	/// ⌃Tab's step for the key press, nil for any other: 1 for ⌃Tab, -1 for ⌃⇧Tab.
	internal static func step(
		keyCode: UInt16,
		modifiers: NSEvent.ModifierFlags
	) -> Int? {
		guard keyCode == tabKey else { return nil }
		switch modifiers.intersection([.command, .option, .shift, .control]) {
		case .control: return 1
		case [.control, .shift]: return -1
		default: return nil
		}
	}

	private static let tabKey: UInt16 = 48
	private static let returnKey: UInt16 = 36
	private static let enterKey: UInt16 = 76
	private static let escapeKey: UInt16 = 53
	private static let leftArrowKey: UInt16 = 123
	private static let rightArrowKey: UInt16 = 124
	private static let downArrowKey: UInt16 = 125
	private static let upArrowKey: UInt16 = 126

	private var isUp: Bool {
		guard let windowID else { return false }
		return store.state.window(windowID)?.tabSwitcher != nil
	}

	private func begin(_ windowID: UUID) {
		self.windowID = windowID
		flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
			self?.handle(flagsChanged: event)
			return event
		}
		let center = NotificationCenter.default
		let lostKeyboard: @Sendable (Notification) -> Void = { [weak self] _ in
			MainActor.assumeIsolated { self?.cancel() }
		}
		observers = [
			center.addObserver(
				forName: NSApplication.didResignActiveNotification,
				object: nil,
				queue: .main,
				using: lostKeyboard
			),
		]
		if let window = NSApplication.shared.keyWindow {
			observers.append(center.addObserver(
				forName: NSWindow.didResignKeyNotification,
				object: window,
				queue: .main,
				using: lostKeyboard
			))
		}
	}

	/// Escape's way out, for anything else that ends the switcher.
	private func cancel() {
		guard windowID != nil else { return }
		finish(.cancel)
	}

	private func finish(_ action: TabSwitcherAction) {
		guard let windowID else { return }
		end()
		store.send(.ui(.tabSwitcher(action, window: windowID)))
	}

	private func end() {
		windowID = nil
		if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
		flagsMonitor = nil
		for observer in observers {
			NotificationCenter.default.removeObserver(observer)
		}
		observers = []
	}
}
