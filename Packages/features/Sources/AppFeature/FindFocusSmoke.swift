#if DEBUG
import AppKit
import AppUI
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// The find refocus ticket's hand check (DEV-1222), in the app's own window.
///
/// Find opens on an article page with a query. Focus then goes to the page (a click in it), to
/// the URL bar (⌘L) and to the sidebar (a click in it), and after each ⌘F must give the find
/// field the keyboard back with its whole query selected, the query kept. Then the same in
/// reading mode, where the page is the reader's article.
@MainActor
internal enum FindFocusSmoke {
	/// Where focus goes before ⌘F.
	internal enum Elsewhere: String, CaseIterable, Sendable {
		case page
		case addressBar = "address-bar"
		case sidebar
	}

	internal static let query: String = "Arx"

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		window: NSWindow,
		baseURL: URL
	) async throws {
		let article = baseURL.deletingLastPathComponent().appending(path: "article.html")
		window.makeKeyAndOrderFront(nil)
		store.send(.ui(.openURLInSpace(article, store.main.sidebar.spaceID, .mainBrowser)))
		try await HandCheckSmoke.wait("article page") {
			let navigation = store.main.viewer.item.navigation
			return navigation.url == article && !navigation.isLoading && store.main.viewer.item.tab != nil
		}
		guard let tab = store.main.viewer.item.tab?.id else { throw HandCheckSmoke.Failure("no article tab") }

		try await openFind(store: store, window: window)
		for elsewhere in Elsewhere.allCases {
			try await check(elsewhere, reading: false, store: store, engine: engine, tab: tab, window: window)
		}
		try await closeFind(store: store, window: window)

		// Reading mode: the reader's article is the page.
		try HandCheckSmoke.press(.readingMode, store: store, window: window)
		try await HandCheckSmoke.wait("reading mode", seconds: 20, context: { "\(String(describing: store.main.viewer.item.reader))" }) {
			if case .article = store.main.viewer.item.reader { return true }
			return false
		}
		try await openFind(store: store, window: window)
		for elsewhere in Elsewhere.allCases {
			try await check(elsewhere, reading: true, store: store, engine: engine, tab: tab, window: window)
		}
		try await closeFind(store: store, window: window)
		try HandCheckSmoke.press(.readingMode, store: store, window: window)
		try await HandCheckSmoke.wait("reading mode closed") { store.main.viewer.item.reader == nil }

		print(HandCheckSmoke.Phase.find.successMarker)
	}

	/// Whether the field editor shows the find query, all of it selected.
	internal static func selectsWholeQuery(
		text: String,
		selection: NSRange,
		query: String
	) -> Bool {
		text == query && selection == NSRange(location: 0, length: (query as NSString).length)
	}

	/// ⌘F opens Find; the query is typed into its field.
	private static func openFind(
		store: StoreOf<AppFeature>,
		window: NSWindow
	) async throws {
		try HandCheckSmoke.press(.findInPage, store: store, window: window)
		try await HandCheckSmoke.wait("find field focused", context: { focus(in: window) }) {
			findEditor(in: window) != nil
		}

		// A query left from earlier is replaced: ⌘A, then the query.
		try HandCheckSmoke.key("a", code: 0, modifiers: .command, in: window)
		try await HandCheckSmoke.typeText(query, in: window)

		// The store's query and the field's own text both: a field left behind the store would
		// hand ⌘F a stale query to select.
		try await HandCheckSmoke.wait("find query typed", context: {
			"query=\(store.main.viewer.item.findQuery ?? "nil") field=\(findEditor(in: window)?.string ?? "none")"
		}) {
			store.main.viewer.item.findQuery == query && findEditor(in: window)?.string == query
		}
	}

	/// Escape in the focused field closes the bar and the keyboard leaves it (DEV-1297): ⌘F
	/// first, so the field has it.
	private static func closeFind(
		store: StoreOf<AppFeature>,
		window: NSWindow
	) async throws {
		try HandCheckSmoke.press(.findInPage, store: store, window: window)
		try await HandCheckSmoke.wait("find field focused before Escape", context: { focus(in: window) }) {
			findEditor(in: window) != nil
		}

		// After the menu bar's flash for ⌘F: an Escape queued while the menu title is still lit
		// was lost four runs in ten (23 Nov), with Arx active, the window key and the field
		// editing. A person's Escape comes later than that.
		try await Task.sleep(for: .milliseconds(400))
		try HandCheckSmoke.key("\u{1b}", code: 53, throughApp: true, in: window)
		try await HandCheckSmoke.wait("Escape closed find", context: {
			"query=\(store.main.viewer.item.findQuery ?? "nil") responder=\(HandCheckSmoke.responder(in: window)) "
				+ "active=\(NSApplication.shared.isActive) key=\(window.isKeyWindow)"
		}) {
			store.main.viewer.item.findQuery == nil && findEditor(in: window) == nil
		}
	}

	private static func check(
		_ elsewhere: Elsewhere,
		reading: Bool,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab.ID,
		window: NSWindow
	) async throws {
		let label = "\(reading ? "reader-" : "")\(elsewhere.rawValue)"
		switch elsewhere {
		case .page:
			try await clickPage(reading: reading, engine: engine, tab: tab, window: window)

		case .addressBar:
			try HandCheckSmoke.press(.address, store: store, window: window)
			try await HandCheckSmoke.wait("\(label): URL bar focused", context: { HandCheckSmoke.responder(in: window) }) {
				HandCheckSmoke.editedField(in: window)?.field.accessibilityIdentifier() == "command-bar-input"
			}

		case .sidebar:
			// From the page, so the sidebar click is what ⌘F follows even if the sidebar takes no
			// keyboard focus itself.
			try await clickPage(reading: reading, engine: engine, tab: tab, window: window)
			guard store.main.sidebar.sidebarIsVisible else { throw HandCheckSmoke.Failure("\(label): the sidebar is hidden") }
			let point = NSPoint(x: 40, y: window.contentLayoutRect.height * 0.3)
			let target = HandCheckSmoke.hit(at: point, in: window)
			if let page = engine.contentHostFixtureView(tab), let target, target === page || target.isDescendant(of: page) {
				throw HandCheckSmoke.Failure("\(label): the sidebar point hits the page")
			}
			try HandCheckSmoke.click(at: point, in: window)
			try await Task.sleep(for: .milliseconds(300))
		}
		let before = HandCheckSmoke.responder(in: window)
		guard findEditor(in: window) == nil
		else { throw HandCheckSmoke.Failure("\(label): the find field kept focus, so ⌘F proves nothing") }

		try HandCheckSmoke.press(.findInPage, store: store, window: window)
		try await HandCheckSmoke.wait("\(label): ⌘F refocused the find field with its text selected", context: {
			let selection = findEditor(in: window).map { "\($0.string)@\(NSStringFromRange($0.selectedRange()))" } ?? "none"
			return "responder=\(HandCheckSmoke.responder(in: window)) find=\(selection)"
		}) {
			guard let editor = findEditor(in: window) else { return false }
			return selectsWholeQuery(text: editor.string, selection: editor.selectedRange(), query: query)
		}
		guard store.main.viewer.item.findQuery == query
		else { throw HandCheckSmoke.Failure("\(label): ⌘F changed the query") }

		print("ARX_HAND_CHECK_FIND_\(label.uppercased().replacingOccurrences(of: "-", with: "_")) from=\(before)")
	}

	/// A click in the page, or in reading mode in the reader's article.
	private static func clickPage(
		reading: Bool,
		engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab.ID,
		window: NSWindow
	) async throws {
		let view: NSView?
		if reading {
			view = window.contentView.flatMap { root in
				HandCheckSmoke.views(under: root).first { String(describing: type(of: $0)) == "ReaderPageView" }
			}
		} else {
			view = engine.contentHostFixtureView(tab)
		}
		guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor
		else { throw HandCheckSmoke.Failure("no \(reading ? "reader" : "page") view") }

		// Low in the page, away from the find bar at its top right and the reader's controls.
		let point = view.convert(NSPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.height * 0.75 : view.bounds.height * 0.25), to: nil)
		guard let target = HandCheckSmoke.hit(at: point, in: window), target === view || target.isDescendant(of: view)
		else { throw HandCheckSmoke.Failure("the page click hits \(HandCheckSmoke.hit(at: point, in: window).map { String(describing: type(of: $0)) } ?? "nothing")") }

		try HandCheckSmoke.click(at: point, in: window)
		try await HandCheckSmoke.wait("focus left the find field after a click in the \(reading ? "reader" : "page")", context: { HandCheckSmoke.responder(in: window) }) {
			findEditor(in: window) == nil
		}
	}

	/// The field editor while it edits the find field.
	private static func findEditor(in window: NSWindow) -> NSTextView? {
		guard
			let (field, editor) = HandCheckSmoke.editedField(in: window),
			ArxFloatingGlass.isEscapableSearchField(field)
		else { return nil }
		return editor
	}

	/// The focused view, and what the field being edited, if any, is known by.
	private static func focus(in window: NSWindow) -> String {
		guard let (field, _) = HandCheckSmoke.editedField(in: window) else { return HandCheckSmoke.responder(in: window) }
		return "\(HandCheckSmoke.responder(in: window)) identifier=\(field.accessibilityIdentifier())"
			+ " placeholder=\(field.placeholderString ?? "nil") escapable=\(ArxFloatingGlass.isEscapableSearchField(field))"
	}
}
#endif
