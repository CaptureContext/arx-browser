#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// The keys a site may take before Arx (DEV-1264, DEV-1073), on the new engine (ABI62).
///
/// Real ⌘K and ⌘Z presses go through the app's event queue, so the key monitor sees them as it
/// sees a person's: a page that uses ⌘K keeps the first press and the toast shows, the second
/// press opens the command bar; a page that leaves ⌘K gets the command bar at once; ⌘Z after more
/// than two seconds on a page that uses it stays the page's, with no toast.
///
/// Conflict resolution (DEV-1332): ⌘F set to Delayed is held with the toast and reaches the page
/// when the window ends; pressed twice, it opens Arx's find bar and the page sees neither press.
/// With an engine that follows every key Arx can bind, ⌃1 (Switch to Space 1, Site by default)
/// goes to a page that uses it, and Arx stays in its space.
@MainActor
internal enum SiteShortcutsSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		source: BrowserCore.Tab.ID,
		window: NSWindow,
		baseURL: URL
	) async throws {
		let fixture = baseURL.deletingLastPathComponent().appending(path: "site-shortcuts.html")

		// A page that uses ⌘K and ⌘Z.
		try await open(fixture, phase: "take", tab: source, engine: engine, window: window)
		try press("k", window: window)
		try await wait { title(source, engine) == "Arx Site Shortcuts take:k1:z0" }
		try await wait { store.siteShortcuts.notice?.action == .command(.commandBar) }
		guard !store.main.commandBar.isPresented else { throw Failure.arxTookThePagesKey }

		try press("k", window: window)
		try await wait { store.main.commandBar.isPresented }
		guard title(source, engine) == "Arx Site Shortcuts take:k1:z0" else { throw Failure.pageSawTheSecondPress }

		store.send(.main(.commandBar(.ui(.dismissed))))
		try await wait { !store.main.commandBar.isPresented }

		// The bar asks for its field's focus asynchronously when it opens; closed this soon, that
		// request lands after the close and focus passes through the field back to the page. A
		// person's focus returning from the bar is an arrival, so let the bar finish going first.
		try await waitForSteadyResponder(in: window)
		engine.surface.focus(source)

		// The page's focus comes back after the command bar goes, and the two seconds count from
		// when Arx sees it arrive: wait for that, then stay on the page.
		try await wait {
			hasFocus(source, engine: engine, window: window) && store.siteShortcuts.focus != nil
		}

		// More than two seconds on the page: ⌘Z is the page's, every time, with no toast.
		try await settle(on: source, store: store, engine: engine, window: window)
		store.send(.ui(.dismissSiteShortcutNotice))
		try press("z", window: window)
		try press("z", window: window)
		try await wait(context: { "title=\(title(source, engine) ?? "nil")" }) {
			title(source, engine) == "Arx Site Shortcuts take:k1:z2"
		}
		guard store.siteShortcuts.notice == nil else { throw Failure.toastAfterSettling }

		// A page that leaves ⌘K: the command bar opens at once, with no toast.
		try await open(fixture, phase: "leave", tab: source, engine: engine, window: window)
		try press("k", window: window)
		try await wait { store.main.commandBar.isPresented }
		guard store.siteShortcuts.notice == nil else { throw Failure.toastForALeftKey }

		store.send(.main(.commandBar(.ui(.dismissed))))
		try await wait { !store.main.commandBar.isPresented }
		try await waitForSteadyResponder(in: window)

		try await conflictResolution(store: store, engine: engine, source: source, window: window, fixture: fixture)
		print("ARX_SITE_SHORTCUTS_SMOKE_SUCCESS")
	}

	/// Delayed on ⌘F, and ⌃1 when the engine follows it (DEV-1332).
	private static func conflictResolution(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		source: BrowserCore.Tab.ID,
		window: NSWindow,
		fixture: URL
	) async throws {
		let previous = store.settings.shortcutConflictChoices
		store.send(.settings(.ui(.shortcutConflictResolutionChanged(.findInPage, .delayed))))
		defer { store.settings.$shortcutConflictChoices.withLock { $0 = previous } }

		let keys = fixture.appending(queryItems: [.init(name: "phase", value: "keys")])
		try await engine.client.command(source, .navigate(keys))
		try await wait { title(source, engine) == "Arx Site Shortcuts keys:f0:c0" }
		window.makeKeyAndOrderFront(nil)
		engine.surface.focus(source)
		try await wait { hasFocus(source, engine: engine, window: window) }

		// One press: held, with the toast, and the page gets it when the window ends.
		try press("f", window: window)
		try await wait { store.siteShortcuts.held != nil && store.siteShortcuts.notice != nil }
		guard title(source, engine) == "Arx Site Shortcuts keys:f0:c0" else { throw Failure.pageGotAHeldKey }
		try await wait { title(source, engine) == "Arx Site Shortcuts keys:f1:c0" }
		guard store.main.viewer.item.findQuery == nil else { throw Failure.arxTookThePagesKey }

		// Two presses: Arx's find bar, and the page sees neither.
		try press("f", window: window)
		try await wait { store.siteShortcuts.held != nil }
		try press("f", window: window)
		try await wait { store.main.viewer.item.findQuery != nil }
		try await Task.sleep(for: .milliseconds(2_500))
		guard title(source, engine) == "Arx Site Shortcuts keys:f1:c0" else { throw Failure.pageSawTheSecondPress }
		store.send(.main(.viewer(.item(.ui(.findDismissed)))))

		// ⌃1 needs an engine that follows keys without ⌘.
		guard store.settings.followsAllShortcutKeys else {
			print("ARX_SITE_SHORTCUTS_SMOKE_CONTROL_SKIPPED engine follows ⌘ keys only")
			return
		}
		engine.surface.focus(source)
		try await wait { hasFocus(source, engine: engine, window: window) }
		let space = store.main.sidebar.spaceID
		try press("1", modifiers: .control, window: window)
		try await wait { title(source, engine) == "Arx Site Shortcuts keys:f1:c1" }
		guard store.main.sidebar.spaceID == space else { throw Failure.arxTookThePagesKey }
	}

	private static func open(
		_ fixture: URL,
		phase: String,
		tab: BrowserCore.Tab.ID,
		engine: ChromiumBrowserEngine,
		window: NSWindow
	) async throws {
		let url = fixture.appending(queryItems: [.init(name: "phase", value: phase)])
		try await engine.client.command(tab, .navigate(url))
		try await wait { title(tab, engine) == "Arx Site Shortcuts \(phase):k0:z0" }
		window.makeKeyAndOrderFront(nil)
		engine.surface.focus(tab)
		try await wait { hasFocus(tab, engine: engine, window: window) }
	}

	/// Stays on the page for more than two seconds from when its focus last arrived. A late
	/// arrival (focus coming back once the command bar has gone) starts the wait again; each is
	/// logged with what held focus.
	private static func settle(
		on tab: BrowserCore.Tab.ID,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		window: NSWindow
	) async throws {
		// Every change of the window's first responder meanwhile, to find what takes focus.
		let start = Date()
		let observation = window.observe(\.firstResponder, options: [.old, .new]) { window, change in
			MainActor.assumeIsolated {
				print(
					"ARX_SITE_SHORTCUTS_SMOKE_RESPONDER"
					+ String(format: " t=%.2f", Date().timeIntervalSince(start))
					+ " old=\(chain(change.oldValue ?? nil)) new=\(chain(change.newValue ?? nil))"
					+ " key=\(window.isKeyWindow) appKey=\(NSApp.keyWindow === window) active=\(NSApp.isActive)"
					+ " front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
					+ " mouse=\(NSEvent.mouseLocation)"
				)
			}
		}
		defer { observation.invalidate() }
		for attempt in 0..<1 {
			let focus = store.siteShortcuts.focus
			try await Task.sleep(for: .milliseconds(2_300))
			if store.siteShortcuts.focus == focus, hasFocus(tab, engine: engine, window: window) { return }

			let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
			let moved = store.siteShortcuts.focus.map { focus in
				String(format: "%.2f", Date().timeIntervalSince(focus.since))
			} ?? "nil"
			print(
				"ARX_SITE_SHORTCUTS_SMOKE_FOCUS_MOVED attempt=\(attempt) arrivedAgo=\(moved) responder=\(responder)"
				+ " key=\(window.isKeyWindow) active=\(NSApp.isActive)"
				+ " front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
			)
		}
		throw Failure.focusMoved
	}

	/// Waits until the window's first responder has stayed the same for half a second.
	private static func waitForSteadyResponder(in window: NSWindow) async throws {
		var last = window.firstResponder.map(ObjectIdentifier.init)
		var steady = 0
		for _ in 0..<50 {
			try await Task.sleep(for: .milliseconds(100))
			let current = window.firstResponder.map(ObjectIdentifier.init)
			steady = current == last ? steady + 1 : 0
			last = current
			if steady >= 5 { return }
		}
		throw Failure.timedOut
	}

	/// A responder's class and its superviews', innermost first: never an address or a title.
	private static func chain(_ responder: NSResponder?) -> String {
		guard let responder else { return "nil" }

		var names = [String(describing: type(of: responder))]
		var view = (responder as? NSView)?.superview
		while let current = view, names.count < 6 {
			names.append(String(describing: type(of: current)))
			view = current.superview
		}
		return names.joined(separator: "<")
	}

	private static func hasFocus(
		_ tab: BrowserCore.Tab.ID,
		engine: ChromiumBrowserEngine,
		window: NSWindow
	) -> Bool {
		guard
			window.isKeyWindow,
			let view = engine.contentHostFixtureView(tab),
			let responder = window.firstResponder as? NSView
		else { return false }

		return responder.isDescendant(of: view)
	}

	private static func title(_ tab: BrowserCore.Tab.ID, _ engine: ChromiumBrowserEngine) -> String? {
		engine.client.snapshot(tab)?.navigation.title
	}

	/// Posts the key to the app's queue, as the keyboard does, so local monitors see it.
	private static func press(
		_ key: String,
		modifiers: NSEvent.ModifierFlags = .command,
		window: NSWindow
	) throws {
		let codes: [String: UInt16] = ["k": 40, "z": 6, "f": 3, "1": 18]
		guard let code = codes[key] else { throw Failure.unknownKey }

		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: modifiers,
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: key,
				charactersIgnoringModifiers: key,
				isARepeat: false,
				keyCode: code
			)
			else { throw Failure.unknownKey }

			NSApp.postEvent(event, atStart: false)
		}
	}

	private static func wait(
		line: UInt = #line,
		context: () -> String = { "" },
		until ready: () -> Bool
	) async throws {
		for _ in 0..<100 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		FileHandle.standardError.write(Data("ARX_SITE_SHORTCUTS_SMOKE_TIMEOUT line=\(line) \(context())\n".utf8))
		throw Failure.timedOut
	}

	private enum Failure: Error {
		case unknownKey
		case arxTookThePagesKey
		case pageSawTheSecondPress
		case toastAfterSettling
		case toastForALeftKey
		case pageGotAHeldKey
		case focusMoved
		case timedOut
	}
}
#endif
