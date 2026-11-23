import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import Foundation
@testable import MainFeature
import SwiftUI
import Testing
@testable import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// The find bar's keys and buttons in the page's own view, as the main window, a Split View
/// pane, Peek and Little Arx all draw it (DEV-1297): Escape in the focused field closes the bar,
/// clears the page's highlights and gives the keyboard back to the page; Previous and Next step
/// through the matches as ⇧Return and Return do, and wait for a match.
@MainActor
@Suite(.renderTurn, .dependencies, .serialized)
internal struct FindEscapeTests {
	/// The key goes in as a key press does, through the app, before the window dispatches it: on
	/// `main` the bar answered Escape only once the window had handed it to the field's editor.
	@Test
	internal func escapeInTheFocusedFieldClosesTheBar() async throws {
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let focused = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = await Self.openBar(query: "arx", sent: sent)
		let window = Self.host(ViewerItemView(store: store, surface: Self.surface(focused: focused), showsLoading: false))
		defer { Self.close(window) }
		Self.waitUntil("the find field has focus") { Self.findEditor(in: window) != nil }

		try Self.pressEscape(in: window)
		Self.waitUntil("the find bar closed: query=\(store.findQuery ?? "nil")") { store.findQuery == nil }
		try await Self.waitForEffects("the page's highlights cleared: \(sent.value)") { sent.value.last == .stopFind }
		#expect(focused.value.last == store.tab?.id, "the keyboard went back to the page")
	}

	/// The same in the main window as it's built: its sidebar, pager and Library around the page.
	@Test
	internal func escapeInTheFocusedFieldClosesTheBarInTheMainWindow() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let active = organization.tabs[0]
		state.viewer.item = .init(tab: active, navigation: .init(url: active.restoration.url), generation: 1)
		let store = Store(initialState: state) { MainFeature() } withDependencies: {
			$0.continuousClock = TestClock()
			$0.browserEngine.command = { _, _ in }
		}
		let window = Self.host(MainView(store: store, surface: Self.surface(focused: .init([]))))
		defer { Self.close(window) }
		store.send(.viewer(.item(.ui(.findPresented))))
		store.send(.viewer(.item(.ui(.findChanged("arx")))))
		Self.waitUntil("the find field has focus: \(String(describing: window.firstResponder))") {
			Self.findEditor(in: window) != nil
		}

		try Self.pressEscape(in: window)
		Self.waitUntil("the find bar closed: query=\(store.viewer.item.findQuery ?? "nil")") {
			store.viewer.item.findQuery == nil
		}
	}

	/// Escape with a modifier isn't the field's.
	@Test
	internal func escapeWithAModifierLeavesTheBarOpen() async throws {
		let store = await Self.openBar(query: "arx", sent: .init([]))
		let window = Self.host(ViewerItemView(store: store, surface: Self.surface(focused: .init([])), showsLoading: false))
		defer { Self.close(window) }
		Self.waitUntil("the find field has focus") { Self.findEditor(in: window) != nil }

		try Self.pressEscape(modifiers: .option, in: window)
		Self.settle()
		#expect(store.findQuery == "arx")
	}

	/// The arrows do what ⇧Return and Return do: the previous match, then the next.
	@Test
	internal func previousAndNextStepAsShiftReturnAndReturnDo() {
		var steps: [Bool] = []
		let bar = FindInPageBar(
			query: "arx",
			result: .init(matches: 4, active: 1),
			onChange: { _ in },
			onStep: { steps.append($0) },
			onDismiss: {}
		)
		bar.step(.findPrevious)
		bar.step(.findNext)
		#expect(steps == [false, true])
	}

	@Test
	internal func previousAndNextWaitForAMatch() {
		#expect(FindInPageBar.canStep(query: "", result: nil) == false)
		#expect(FindInPageBar.canStep(query: "arx", result: nil) == false)
		#expect(FindInPageBar.canStep(query: "arx", result: .init(matches: 0, active: 0)) == false)
		#expect(FindInPageBar.canStep(query: "", result: .init(matches: 3, active: 1)) == false)
		#expect(FindInPageBar.canStep(query: "arx", result: .init(matches: 3, active: 1)) == true)
	}

	// MARK: - Hosting

	private static func openBar(
		query: String,
		sent: LockIsolated<[BrowserEngineClient.Command]>
	) async -> StoreOf<ViewerItemFeature> {
		let organization = IntegrationFeatureTests().fixture()
		let store = Store(initialState: ViewerItemFeature.State(tab: organization.tabs[0])) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.command = { _, command in sent.withValue { $0.append(command) } }
		}
		await store.send(.ui(.findPresented)).finish()
		await store.send(.ui(.findChanged(query))).finish()
		return store
	}

	private static func surface(focused: LockIsolated<[BrowserCore.Tab.ID]>) -> BrowserSurfaceClient {
		BrowserSurfaceClient(attach: { _, _ in }, detach: { _ in }, focus: { id in focused.withValue { $0.append(id) } })
	}

	/// The view in a window kept off every screen and never made key.
	private static func host(_ view: some View) -> NSWindow {
		let size: CGSize = .init(width: 800, height: 500)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		host.layoutSubtreeIfNeeded()
		settle()
		return window
	}

	private static func close(_ window: NSWindow) {
		window.contentView = nil
		window.close()
	}

	/// The find field's editor, when it's the window's first responder.
	private static func findEditor(in window: NSWindow) -> NSTextView? {
		guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
		return editor
	}

	/// Escape as the app receives a key press: `sendEvent` runs its key monitors before the window.
	private static func pressEscape(
		modifiers: NSEvent.ModifierFlags = [],
		in window: NSWindow
	) throws {
		let event = try #require(NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: window.windowNumber,
			context: nil,
			characters: "\u{1b}",
			charactersIgnoringModifiers: "\u{1b}",
			isARepeat: false,
			keyCode: 53
		))
		NSApplication.shared.sendEvent(event)
	}

	/// Waits for the store's effects, which run once this test awaits.
	private static func waitForEffects(
		_ what: @autoclosure () -> String,
		_ condition: () -> Bool
	) async throws {
		await waitWhile { !condition() }
		#expect(condition(), "\(what())")
	}

	private static func settle() {
		for _ in 0..<4 {
			RunLoop.main.run(until: .now.addingTimeInterval(0.025))
		}
	}

	/// Lets the run loop turn, as a window's does, until `condition` holds or about a second passes.
	private static func waitUntil(
		_ what: @autoclosure () -> String,
		_ condition: () -> Bool
	) {
		// Until a deadline rather than a fixed number of spins, which a busy Mac used up first.
		let deadline: Date = .now.addingTimeInterval(30)
		while !condition(), Date.now < deadline {
			RunLoop.main.run(until: .now.addingTimeInterval(0.025))
		}
		#expect(condition(), "\(what())")
	}
}
