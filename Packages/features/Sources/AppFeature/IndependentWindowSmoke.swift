#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import MainFeature
import _ComposableArchitecture

/// ⌘N opens an independent window (DEV-822), with real windows and Chromium pages: the new window
/// starts with no open tabs of its own, a page opened there shows only there, choosing a main-window
/// tab from it brings the main window forward, and closing it hands its page, still loaded, to the
/// main window.
internal enum IndependentWindowSmoke {
	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		baseURL: URL
	) async throws {
		guard store.independentWindows else { throw Failure.featureFlagOff }
		let original = store.main.viewer.item.tab?.id
		guard let mainTab = store.main.sidebar.windowOpenTabs.first(where: { engine.client.snapshot($0) != nil })
		?? store.main.viewer.item.tab?.id
		else { throw Failure.missingSource }

		let before = Set(store.windows.ids)
		store.send(.ui(.newWindow))
		try await wait("The new window did not open") { store.windows.ids.contains { !before.contains($0) } }
		guard let windowID = store.windows.ids.first(where: { !before.contains($0) })
		else { throw Failure.missingSource }
		guard
			let window = store.windows[id: windowID],
			window.sidebar.windowOpenTabs.isEmpty,
			window.sidebar.selectedTab == nil
		else { throw Failure.notIndependent("The new window started with open tabs") }

		let url = baseURL.appending(queryItems: [.init(name: "arx_independent_window_smoke", value: "1")])
		store.send(.windows(.element(id: windowID, action: .ui(.openInNewTab(url)))))
		try await wait("The page did not load in the new window") {
			guard let tab = store.windows[id: windowID]?.viewer.item.tab else { return false }
			return engine.isAttached(tab.id) && engine.client.snapshot(tab.id)?.navigation.url == url
		}
		guard let opened = store.windows[id: windowID]?.viewer.item.tab?.id
		else { throw Failure.missingSource }
		guard
			store.windowTabOwners[opened] == windowID,
			store.windows[id: windowID]?.sidebar.windowOpenTabs == [opened],
			!store.main.sidebar.windowOpenTabs.contains(opened),
			engine.hostView(opened)?.window != nil
		else { throw Failure.notIndependent("The page showed outside its window") }

		// A main-window tab chosen in the new window shows in the main window.
		store.send(.windows(.element(id: windowID, action: .ui(.selectTab(mainTab)))))
		try await wait("The main window did not come forward with its tab") {
			store.focusedWindowID == store.main.id
			&& store.main.sidebar.selectedTab?.id == mainTab
			&& store.windows[id: windowID]?.viewer.item.tab?.id == opened
		}

		store.send(.ui(.closeAdditionalWindow(windowID)))
		try await wait("The window's page did not go to the main window") {
			store.windows[id: windowID] == nil
			&& store.windowTabOwners[opened] == nil
			&& store.main.sidebar.windowOpenTabs.contains(opened)
		}

		// Handed over as it was, not archived and not reloaded.
		guard engine.client.snapshot(opened)?.navigation.url == url
		else { throw Failure.notIndependent("The page did not stay loaded") }

		// The stages after this one start from the main window's page as it was.
		if let original, original != mainTab {
			store.send(.main(.ui(.selectTab(original))))
			try await wait("The main window did not show its page again") { store.main.viewer.item.tab?.id == original }
		}
		print("ARX_INDEPENDENT_WINDOW_SMOKE_SUCCESS")
	}

	@MainActor
	private static func wait(
		_ message: String,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<150 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut(message)
	}

	private enum Failure: Error {
		case featureFlagOff
		case missingSource
		case notIndependent(String)
		case timedOut(String)
	}
}
#endif
