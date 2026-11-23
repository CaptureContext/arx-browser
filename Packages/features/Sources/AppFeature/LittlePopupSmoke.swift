#if DEBUG
import AppKit
import AppUI
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// A sign-in popup from Little Arx (DEV-855). An owned loopback page in Little Arx opens a
/// popup with a real click; the popup messages its opener, the opener answers, and the popup
/// closes itself. The popup must have run in a new Little Arx with its opener link, the
/// opener must have got its message, and no main-window tab or window may have appeared.
/// Its self-close needs an ABI49 engine (`page_close_requested`).
@MainActor
internal enum LittlePopupSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		windowID: UUID,
		littleWindow: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			parts.path == "/index.html",
			let little = store.littleWindows[id: windowID],
			let original = engine.client.snapshot(little.tab.id)?.navigation.url
		else { throw Failure.invalidFixture }

		let sourceTab = little.tab.id
		let page = baseURL.deletingLastPathComponent().appending(path: "little-popup.html")
		try await engine.client.command(sourceTab, .navigate(page))
		try await wait { engine.client.snapshot(sourceTab)?.navigation.title == "Arx Little Popup ready" }

		let workspaceTabs = store.workspace.tabs.ids
		let windows = store.windows.ids
		let mainTab = store.main.viewer.item.tab?.id
		let littleWindows = Set(store.littleWindows.ids)
		guard let view = engine.contentHostFixtureView(sourceTab), view.window === littleWindow
		else { throw Failure.missingSource }

		littleWindow.makeKeyAndOrderFront(nil)
		engine.surface.focus(sourceTab)
		try await wait { littleWindow.isKeyWindow }
		try click(view: view, window: littleWindow)

		// A click sent just as the window becomes key sometimes doesn't reach the page. With no
		// new Little Arx after a few seconds, it's sent once more; one that did open a popup is
		// never repeated (DEV-965).
		for _ in 0..<40 where store.littleWindows.allSatisfy({ littleWindows.contains($0.id) }) {
			try await Task.sleep(for: .milliseconds(100))
		}
		if store.littleWindows.allSatisfy({ littleWindows.contains($0.id) }) {
			FileHandle.standardError.write(Data("ARX_LITTLE_POPUP_SMOKE_CLICK_RETRY\n".utf8))
			try click(view: view, window: littleWindow)
		}

		// The popup runs in a new Little Arx, reaches its opener and hears back from it.
		var popupID: UUID?
		try await wait(context: { "littleWindows=\(store.littleWindows.count)" }) {
			guard let popup = store.littleWindows.first(where: { !littleWindows.contains($0.id) })
			else { return false }

			popupID = popup.id
			return popup.openerWindowID == windowID
			&& popup.tab.profileID == little.tab.profileID
			&& engine.client.snapshot(popup.tab.id)?.navigation.title == "Arx Little Popup child acked"
		}

		// It closes itself: its Little Arx goes, and the opener keeps the keyboard.
		try await wait(context: {
			"popupOpen=\(popupID.map { store.littleWindows[id: $0] != nil } ?? false) "
			+ "focused=\(String(describing: store.focusedWindowID)) "
			+ "opener=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")"
		}) {
			guard let popupID else { return false }

			return store.littleWindows[id: popupID] == nil
			&& store.focusedWindowID == windowID
			&& engine.client.snapshot(sourceTab)?.navigation.title == "Arx Little Popup received"
		}

		guard
			store.workspace.tabs.ids == workspaceTabs,
			store.windows.ids == windows,
			store.main.viewer.item.tab?.id == mainTab,
			Set(store.littleWindows.ids) == littleWindows
		else { throw Failure.reachedMainWindow }

		// Back to the page it had, settled, so promotion after this phase moves the same tab.
		try await engine.client.command(sourceTab, .navigate(original))
		try await wait {
			guard
				let navigation = engine.client.snapshot(sourceTab)?.navigation,
				let restoration = store.littleWindows[id: windowID]?.tab.restoration
			else { return false }

			return navigation.url == original
			&& !navigation.isLoading
			&& restoration.url == original
			&& (navigation.title.isEmpty || restoration.title == navigation.title)
		}
		print("ARX_LITTLE_POPUP_SMOKE_SUCCESS")
	}

	/// A sign-in popup from a main window (DEV-1186). The same owned page, in the window's
	/// selected tab, opens its popup with a real click: it must run in a new Little Arx with its
	/// opener link, never in a new main window or a tab of the space, reach its opener, close
	/// itself and give the keyboard back to the window.
	internal static func runFromWindow(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		windowID: UUID,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			parts.path == "/index.html",
			store.main.id == windowID,
			store.peeks.isEmpty,
			let sourceTab = store.main.viewer.item.tab?.id,
			let original = engine.client.snapshot(sourceTab)?.navigation.url
		else { throw Failure.invalidFixture }

		let page = baseURL.deletingLastPathComponent().appending(path: "little-popup.html")
		try await engine.client.command(sourceTab, .navigate(page))
		try await wait { engine.client.snapshot(sourceTab)?.navigation.title == "Arx Little Popup ready" }

		let workspaceTabs = store.workspace.tabs.ids
		let windows = store.windows.ids
		let littleWindows = Set(store.littleWindows.ids)
		guard let view = engine.contentHostFixtureView(sourceTab), view.window === window
		else { throw Failure.missingSource }

		window.makeKeyAndOrderFront(nil)
		engine.surface.focus(sourceTab)
		try await wait { window.isKeyWindow }
		try click(view: view, window: window)

		// As from Little Arx: one more click only when the first opened nothing (DEV-965).
		for _ in 0..<40 where store.littleWindows.allSatisfy({ littleWindows.contains($0.id) }) && store.windows.ids == windows {
			try await Task.sleep(for: .milliseconds(100))
		}
		if store.littleWindows.allSatisfy({ littleWindows.contains($0.id) }) && store.windows.ids == windows {
			FileHandle.standardError.write(Data("ARX_WINDOW_POPUP_SMOKE_CLICK_RETRY\n".utf8))
			try click(view: view, window: window)
		}

		var popupID: UUID?
		try await wait(context: {
			"littleWindows=\(store.littleWindows.count) windows=\(store.windows.count) "
			+ "tabs=\(store.workspace.tabs.count)"
		}) {
			guard store.windows.ids == windows, store.workspace.tabs.ids == workspaceTabs
			else { return true }
			guard let popup = store.littleWindows.first(where: { !littleWindows.contains($0.id) })
			else { return false }

			popupID = popup.id
			return popup.openerWindowID == windowID
			&& engine.client.snapshot(popup.tab.id)?.navigation.title == "Arx Little Popup child acked"
		}
		guard
			store.windows.ids == windows,
			store.workspace.tabs.ids == workspaceTabs,
			let popupID,
			let popup = store.littleWindows[id: popupID],
			popup.tab.profileID == store.workspace.tabs[id: sourceTab]?.profileID
		else { throw Failure.reachedMainWindow }

		try await wait(context: {
			"popupOpen=\(store.littleWindows[id: popupID] != nil) "
			+ "focused=\(String(describing: store.focusedWindowID)) "
			+ "opener=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")"
		}) {
			store.littleWindows[id: popupID] == nil
			&& store.focusedWindowID == windowID
			&& engine.client.snapshot(sourceTab)?.navigation.title == "Arx Little Popup received"
		}

		guard
			store.workspace.tabs.ids == workspaceTabs,
			store.windows.ids == windows,
			store.main.viewer.item.tab?.id == sourceTab,
			Set(store.littleWindows.ids) == littleWindows
		else { throw Failure.reachedMainWindow }

		try await engine.client.command(sourceTab, .navigate(original))
		try await wait {
			guard let navigation = engine.client.snapshot(sourceTab)?.navigation else { return false }
			return navigation.url == original && !navigation.isLoading
		}
		print("ARX_WINDOW_POPUP_SMOKE_SUCCESS")
	}

	/// A page's new tab from a Favorite (DEV-1312). The same owned page, made a Favorite, opens
	/// a `target="_blank"` link with a real plain click, as Gmail's account switch does. With
	/// Settings sending a Favorite's links to Peek, the new page must open in a Peek over the
	/// Favorite, as the engine's own page with its opener: it messages the Favorite and hears
	/// back. No tab, window or Little Arx may appear. The Peek closes and the tab goes back.
	internal static func runFromFavorite(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		windowID: UUID,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			parts.path == "/index.html",
			store.main.id == windowID,
			store.peeks.isEmpty,
			store.settings.linkClicks.crossSiteLinkFromFavorites == .peek,
			let source = store.main.viewer.item.tab,
			let original = engine.client.snapshot(source.id)?.navigation.url
		else { throw Failure.invalidFixture }

		let sourceTab = source.id
		let sourceSpace = store.main.sidebar.spaceID
		let item = SidebarItem.ID.tab(sourceTab.rawValue)
		store.send(.main(.sidebar(.ui(.move(item, .favoritesRoot, sourceSpace)))))
		try await wait {
			store.workspace.profiles[id: source.profileID]?.favorites.contains(sourceTab) == true
			&& store.main.viewer.item.tab?.id == sourceTab
		}

		let page = baseURL.deletingLastPathComponent().appending(path: "favorite-new-tab.html")
		try await engine.client.command(sourceTab, .navigate(page))
		try await wait { engine.client.snapshot(sourceTab)?.navigation.title == "Arx Favorite new tab ready" }

		let workspaceTabs = store.workspace.tabs.ids
		let windows = store.windows.ids
		let littleWindows = Set(store.littleWindows.ids)
		guard let view = engine.contentHostFixtureView(sourceTab), view.window === window
		else { throw Failure.missingSource }

		window.makeKeyAndOrderFront(nil)
		engine.surface.focus(sourceTab)
		try await wait { window.isKeyWindow }
		try click(view: view, window: window)

		// One more click only when the first opened nothing (DEV-965).
		for _ in 0..<40 where store.peeks.isEmpty && store.workspace.tabs.ids == workspaceTabs {
			try await Task.sleep(for: .milliseconds(100))
		}
		if store.peeks.isEmpty && store.workspace.tabs.ids == workspaceTabs {
			FileHandle.standardError.write(Data("ARX_FAVORITE_NEW_TAB_SMOKE_CLICK_RETRY\n".utf8))
			try click(view: view, window: window)
		}

		// The new page runs in a Peek over the Favorite and reaches its opener.
		try await wait(context: {
			"peeks=\(store.peeks.count) tabs=\(store.workspace.tabs.count) "
			+ "windows=\(store.windows.count) little=\(store.littleWindows.count) "
			+ "opener=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")"
		}) {
			guard
				store.workspace.tabs.ids == workspaceTabs,
				store.windows.ids == windows,
				Set(store.littleWindows.ids) == littleWindows
			else { return true }
			guard let peek = store.peeks.first else { return false }

			return peek.isTemporary
			&& peek.source.windowID == windowID
			&& peek.source.tabID == sourceTab
			&& engine.client.snapshot(peek.tab.id)?.navigation.title == "Arx Favorite new tab child acked"
			&& engine.client.snapshot(sourceTab)?.navigation.title == "Arx Favorite new tab received"
		}
		guard
			store.workspace.tabs.ids == workspaceTabs,
			store.windows.ids == windows,
			Set(store.littleWindows.ids) == littleWindows,
			store.main.viewer.item.tab?.id == sourceTab,
			let peek = store.peeks.first
		else { throw Failure.reachedMainWindow }

		store.send(.ui(.dismissPeek(windowID: windowID)))
		try await wait {
			store.peeks.isEmpty && engine.client.snapshot(peek.tab.id) == nil
		}

		try await engine.client.command(sourceTab, .navigate(original))
		try await wait {
			guard let navigation = engine.client.snapshot(sourceTab)?.navigation else { return false }
			return navigation.url == original && !navigation.isLoading
		}
		store.send(.main(.sidebar(.ui(.move(item, .unpinnedRoot, sourceSpace)))))
		try await wait {
			store.workspace.profiles[id: source.profileID]?.favorites.contains(sourceTab) == false
			&& store.main.viewer.item.tab?.id == sourceTab
		}
		print("ARX_FAVORITE_NEW_TAB_SMOKE_SUCCESS")
	}

	private static func click(
		view: NSView,
		window: NSWindow
	) throws {
		guard
			view.window === window,
			window.isKeyWindow,
			window.isVisible,
			!window.isMiniaturized,
			!view.isHiddenOrHasHiddenAncestor,
			view.bounds.width >= 232,
			view.bounds.height >= 88
		else { throw Failure.missingSource }

		let point = view.convert(
			.init(x: 116, y: view.isFlipped ? 38 : view.bounds.height - 38),
			to: nil
		)
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 1,
				clickCount: 1,
				pressure: type == .leftMouseDown ? 1 : 0
			) else { throw Failure.missingSource }

			window.sendEvent(event)
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

		let message = "ARX_LITTLE_POPUP_SMOKE_TIMEOUT line=\(line) active=\(NSApp.isActive) \(context())\n"
		FileHandle.standardError.write(Data(message.utf8))
		throw Failure.timedOut
	}

	private enum Failure: Error {
		case invalidFixture
		case missingSource
		case reachedMainWindow
		case timedOut
	}
}
#endif
