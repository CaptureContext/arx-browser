#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// Runs only with `ARX_DEVTOOLS_SMOKE` and a disposable `ARX_ENGINE_PROFILE`.
/// Checks gating, docked hosting (DEV-733), binding across navigation, exact
/// binding for a Split View pane, Peek, Little Arx and a private window, a
/// cross-site localhost navigation, a WebSocket live reload, renderer
/// recovery and closing with the inspected page. A docked inspector shares its
/// page's host and sits behind it, filling the host, which ties it to its page.
/// Frontend panels and the Dock side menu need manual acceptance.
internal enum DeveloperToolsSmoke {
	internal static let title: String = "Arx developer fixture"
	internal static let secondTitle: String = "Arx developer fixture 2"
	internal static let liveTitle: String = "Arx live fixture"
	internal static let localHost: String = "localhost"

	internal enum Failure: String, Error {
		case missingPage
		case notGated
		case notOpened
		case rebound
		case staleInspector
		case timedOut
		case invalidFixture
		case wrongTarget
		case rendererNotStopped
	}

	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		environment: [String: String]
	) async throws {
		guard
			let raw = environment["ARX_DEVTOOLS_LOCAL_URL"],
			let local = URL(string: raw),
			local.host() == localHost
		else { throw Failure.invalidFixture }

		try await wait { store.main.viewer.item.navigation.title == title && !store.main.viewer.item.navigation.isLoading }
		guard let tab = store.main.viewer.item.tab, let url = store.main.viewer.item.navigation.url
		else { throw Failure.missingPage }
		let target = store.state.commandTarget(in: store.main.id)
		guard
			engine.supportsDeveloperTools,
			let context = store.state.commandContext(for: target),
			!BrowserCommand.developerTools.isEnabled(in: context)
		else { throw Failure.notGated }
		emit("ARX_DEVTOOLS_PHASE_GATED")

		store.send(.settings(.ui(.developerModeEnabled(true))))
		try await wait { store.state.commandContext(for: target).map(BrowserCommand.developerTools.isEnabled) == true }
		store.send(.ui(.command(.developerTools, target)))
		try await wait { engine.developerToolsAreOpen(tab.id) && inspectors.count == 1 }
		guard
			let inspector = inspectors.first,
			let window = inspector.window
		else { throw Failure.notOpened }

		// Loaded counts only once the frontend attached to its page's target (its readyForTest);
		// an inspector whose panels stay empty never gets there (DEV-785).
		try await wait { engine.developerToolsFrontendLoaded(tab.id) }

		// Docked beside the page: the frontend reports the page's bounds once it lays out.
		try await wait { isDocked(inspector, for: tab.id, engine: engine) && pageIsBeside(inspector, tab: tab.id, engine: engine) }
		emit("ARX_DEVTOOLS_WINDOW \(window.windowNumber)")
		emit("ARX_DEVTOOLS_PHASE_FRONTEND_LOADED")

		let second = url.deletingLastPathComponent().appendingPathComponent("second.html")
		try await engine.client.command(tab.id, .navigate(second))
		try await wait { store.main.viewer.item.navigation.title == secondTitle && !store.main.viewer.item.navigation.isLoading }
		guard
			engine.developerToolsAreOpen(tab.id),
			inspectors.count == 1,
			inspectors.first === inspector,
			isDocked(inspector, for: tab.id, engine: engine)
		else { throw Failure.rebound }
		try await engine.client.command(tab.id, .reloadBypassingCache)
		try await wait { !store.main.viewer.item.navigation.isLoading && store.main.viewer.item.navigation.title == secondTitle }
		emit("ARX_DEVTOOLS_PHASE_NAVIGATED")

		// Every other host gets its own inspector; the main page's stays where it is.
		let main = MainBinding(tab: tab.id, inspector: inspector)
		try await checkSplitPane(store: store, engine: engine, local: local, main: main)
		emit("ARX_DEVTOOLS_PHASE_SPLIT_BOUND")
		try await checkPeek(store: store, engine: engine, local: local, main: main)
		emit("ARX_DEVTOOLS_PHASE_PEEK_BOUND")
		try await checkLittleArx(store: store, engine: engine, local: local, main: main)
		emit("ARX_DEVTOOLS_PHASE_LITTLE_BOUND")
		try await checkPrivateWindow(store: store, engine: engine, local: local, main: main)
		emit("ARX_DEVTOOLS_PHASE_PRIVATE_BOUND")

		// A cross-site navigation to an explicit port keeps the same inspector and retitles it.
		try await engine.client.command(tab.id, .navigate(local.appendingPathComponent("live.html")))
		try await wait { store.main.viewer.item.navigation.title == "\(liveTitle) 1 connected" }
		guard
			engine.developerToolsAreOpen(tab.id),
			inspectors.count == 1,
			inspectors.first === inspector
		else { throw Failure.rebound }
		try await wait { isDocked(inspector, for: tab.id, engine: engine) }
		emit("ARX_DEVTOOLS_PHASE_LOCALHOST_BOUND")

		// The fixture server answers this request by telling the page's socket to reload.
		emit("ARX_DEVTOOLS_LIVE_RELOAD_REQUEST")
		try await wait { store.main.viewer.item.navigation.title == "\(liveTitle) 2 connected" }
		guard
			engine.developerToolsAreOpen(tab.id),
			inspectors.count == 1,
			inspectors.first === inspector,
			isDocked(inspector, for: tab.id, engine: engine)
		else { throw Failure.rebound }
		emit("ARX_DEVTOOLS_PHASE_LIVE_RELOADED")

		try await checkRendererRecovery(store: store, engine: engine, tab: tab.id)
		emit("ARX_DEVTOOLS_PHASE_RENDERER_RECOVERED")

		try await checkDeveloperHeader(store: store, engine: engine, tab: tab.id)
		emit("ARX_DEVTOOLS_PHASE_HEADER")

		engine.client.close(tab.id)
		try await wait { inspectors.isEmpty }
		guard !engine.developerToolsAreOpen(tab.id) else { throw Failure.staleInspector }
		emit("ARX_DEVTOOLS_SMOKE_SUCCESS")
	}

	/// The main page and its inspector, which every binding phase must leave untouched.
	private struct MainBinding {
		internal let tab: BrowserCore.Tab.ID
		internal let inspector: NSView

		internal init(
			tab: BrowserCore.Tab.ID,
			inspector: NSView
		) {
			self.tab = tab
			self.inspector = inspector
		}
	}

	@MainActor
	private static func checkSplitPane(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		local: URL,
		main: MainBinding
	) async throws {
		let firstPaneID = store.main.viewer.activePaneID
		store.send(.main(.ui(.splitURL(local.appendingPathComponent("pane.html")))))
		try await wait {
			store.main.viewer.panes.count == 2 && store.main.viewer.panes.contains { pane in
				pane.id != firstPaneID && pane.item.tab.map { loaded($0.id, title: "Arx developer pane", engine: engine) } == true
			}
		}
		guard
			let pane = store.main.viewer.panes.first(where: { $0.id != firstPaneID }),
			let paneTab = pane.item.tab,
			!engine.developerToolsAreOpen(paneTab.id)
		else { throw Failure.wrongTarget }

		store.send(.ui(.command(.developerTools, .window(store.main.id, paneID: pane.id))))
		_ = try await openedInspector(for: paneTab.id, engine: engine, main: main)
		try await close(tab: paneTab.id, engine: engine, main: main)

		store.send(.main(.viewer(.ui(.closePane(pane.id)))))
		try await wait { store.main.viewer.panes.count == 1 && store.main.viewer.item.tab?.id == main.tab }
	}

	@MainActor
	private static func checkPeek(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		local: URL,
		main: MainBinding
	) async throws {
		let paneID = store.main.viewer.activePaneID
		store.send(.ui(.peekURL(local.appendingPathComponent("peek.html"), sourceWindowID: store.main.id, sourcePaneID: paneID)))
		try await wait {
			store.peeks.first.map { loaded($0.tab.id, title: "Arx developer peek", engine: engine) } == true
		}
		guard let peek = store.peeks.first, !engine.developerToolsAreOpen(peek.tab.id)
		else { throw Failure.wrongTarget }

		store.send(.ui(.command(.developerTools, .peek(peek.id))))
		_ = try await openedInspector(for: peek.tab.id, engine: engine, main: main)

		// Closing Peek destroys its page, which must close only that page's inspector.
		store.send(.peeks(.element(id: peek.id, action: .ui(.close))))
		try await wait { store.peeks.isEmpty && inspectors.count == 1 }
		try checkMain(main, engine: engine)
	}

	@MainActor
	private static func checkLittleArx(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		local: URL,
		main: MainBinding
	) async throws {
		store.send(.ui(.openLittleArx(store.main.sidebar.spaceID, local.appendingPathComponent("little.html"))))
		try await wait {
			store.littleWindows.first.map { little in
				little.viewer.navigation.title == "Arx developer little"
				&& !little.viewer.navigation.isLoading
				&& engine.isAttached(little.tab.id)
			} == true
		}
		guard let little = store.littleWindows.first, !engine.developerToolsAreOpen(little.tab.id)
		else { throw Failure.wrongTarget }

		store.send(.ui(.command(.developerTools, .window(little.id))))
		_ = try await openedInspector(for: little.tab.id, engine: engine, main: main)
		try await close(tab: little.tab.id, engine: engine, main: main)

		store.send(.littleWindows(.element(id: little.id, action: .ui(.close))))
		try await wait { store.littleWindows.isEmpty }
		try checkMain(main, engine: engine)
	}

	@MainActor
	private static func checkPrivateWindow(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		local: URL,
		main: MainBinding
	) async throws {
		let preparation = store.send(.ui(.newPrivateWindow))
		try await wait { store.windows.contains(where: \.isPrivate) }
		guard let window = store.windows.first(where: \.isPrivate)
		else { throw Failure.missingPage }
		try await wait { store.windows[id: window.id]?.commandBar.isPresented == true }
		let page = local.appendingPathComponent("private.html")
		store.send(.windows(.element(id: window.id, action: .commandBar(.ui(.queryChanged(page.absoluteString))))))
		store.send(.windows(.element(id: window.id, action: .commandBar(.ui(.selected("destination"))))))
		try await wait {
			store.windows[id: window.id]?.viewer.item.tab.map { loaded($0.id, title: "Arx developer private", engine: engine) } == true
		}
		guard
			let privateTab = store.windows[id: window.id]?.viewer.item.tab,
			let paneID = store.windows[id: window.id]?.viewer.activePaneID,
			!engine.developerToolsAreOpen(privateTab.id)
		else { throw Failure.wrongTarget }

		store.send(.ui(.command(.developerTools, .window(window.id, paneID: paneID))))
		_ = try await openedInspector(for: privateTab.id, engine: engine, main: main)

		// Retiring the private context destroys its page and must close its inspector with it.
		// A docked inspector leaves with the window, before the page is destroyed.
		preparation.cancel()
		store.send(.ui(.requestClosePrivateWindow(window.id)))
		try await wait { store.windows[id: window.id] == nil && inspectors.count == 1 }
		do {
			try await wait { !engine.developerToolsAreOpen(privateTab.id) }
		} catch Failure.timedOut {
			throw Failure.staleInspector
		}
		try checkMain(main, engine: engine)
	}

	/// Terminating every renderer also ends the frontend's, which closes the
	/// inspector. Recovery must not reopen one anywhere; reopening binds the
	/// recovered page.
	@MainActor
	private static func checkRendererRecovery(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab.ID
	) async throws {
		emit("ARX_DEVTOOLS_CRASH_REQUEST")
		do {
			try await wait {
				store.main.viewer.item.navigation.failure == .rendererStopped
				&& inspectors.isEmpty
				&& !engine.developerToolsAreOpen(tab)
			}
		} catch Failure.timedOut {
			throw Failure.rendererNotStopped
		}

		store.send(.main(.viewer(.item(.ui(.retry)))))
		try await wait {
			let navigation = store.main.viewer.item.navigation
			return navigation.title.hasPrefix(liveTitle) && navigation.title.hasSuffix(" connected")
			&& navigation.errorCode == nil && engine.isAttached(tab)
		}
		guard inspectors.isEmpty, !engine.developerToolsAreOpen(tab)
		else { throw Failure.staleInspector }

		store.send(.ui(.command(.developerTools, store.state.commandTarget(in: store.main.id))))
		try await wait { engine.developerToolsAreOpen(tab) && inspectors.count == 1 }
		try await wait { engine.developerToolsFrontendLoaded(tab) }
		guard let inspector = inspectors.first, isDocked(inspector, for: tab, engine: engine)
		else { throw Failure.wrongTarget }
	}

	/// The loopback page shows the developer header (DEV-733); its DevTools button closes
	/// and its Console button reopens the docked inspector, and the setting hides it.
	@MainActor
	private static func checkDeveloperHeader(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab.ID
	) async throws {
		let paneID = store.main.viewer.activePaneID
		guard
			store.main.showsDeveloperHeader,
			LocalDevelopment.isLocal(store.main.viewer.item.navigation.url),
			engine.developerToolsAreOpen(tab)
		else { throw Failure.notOpened }

		store.send(.main(.ui(.developerHeader(.toggleDeveloperTools, paneID))))
		try await wait { !engine.developerToolsAreOpen(tab) && inspectors.isEmpty }
		store.send(.main(.ui(.developerHeader(.console, paneID))))
		try await wait { engine.developerToolsAreOpen(tab) && inspectors.count == 1 }
		try await wait { engine.developerToolsFrontendLoaded(tab) }
		guard let inspector = inspectors.first, isDocked(inspector, for: tab, engine: engine)
		else { throw Failure.wrongTarget }

		store.send(.settings(.ui(.developerHeaderEnabled(false))))
		try await wait { !store.main.showsDeveloperHeader }
		store.send(.settings(.ui(.developerHeaderEnabled(true))))
		try await wait { store.main.showsDeveloperHeader }
	}

	/// Waits for exactly one new inspector, docked with `tab`, beside the main one.
	@MainActor
	private static func openedInspector(
		for tab: BrowserCore.Tab.ID,
		engine: ChromiumBrowserEngine,
		main: MainBinding
	) async throws -> NSView {
		try await wait { engine.developerToolsAreOpen(tab) && inspectors.count == 2 }
		try await wait { engine.developerToolsFrontendLoaded(tab) }
		try checkMain(main, engine: engine)
		guard
			let inspector = inspectors.first(where: { $0 !== main.inspector }),
			isDocked(inspector, for: tab, engine: engine)
		else { throw Failure.wrongTarget }

		return inspector
	}

	/// Closes an inspector as Developer Tools' toggle does; its page and the main binding stay.
	@MainActor
	private static func close(
		tab: BrowserCore.Tab.ID,
		engine: ChromiumBrowserEngine,
		main: MainBinding
	) async throws {
		try await engine.client.command(tab, .toggleDeveloperTools)
		try await wait { !engine.developerToolsAreOpen(tab) && inspectors.count == 1 }
		guard engine.isAttached(tab) else { throw Failure.missingPage }
		try checkMain(main, engine: engine)
	}

	@MainActor
	private static func checkMain(
		_ main: MainBinding,
		engine: ChromiumBrowserEngine
	) throws {
		guard
			engine.developerToolsAreOpen(main.tab),
			inspectors.contains(where: { $0 === main.inspector }),
			isDocked(main.inspector, for: main.tab, engine: engine)
		else { throw Failure.rebound }
	}

	@MainActor
	private static func loaded(
		_ id: BrowserCore.Tab.ID,
		title: String,
		engine: ChromiumBrowserEngine
	) -> Bool {
		guard let navigation = engine.client.snapshot(id)?.navigation else { return false }
		return navigation.title == title && !navigation.isLoading && navigation.errorCode == nil && engine.isAttached(id)
	}

	/// The tab's docked inspector, in its page's host behind the page and filling it.
	@MainActor
	private static func isDocked(
		_ inspector: NSView,
		for tab: BrowserCore.Tab.ID,
		engine: ChromiumBrowserEngine
	) -> Bool {
		guard
			engine.dockedDeveloperToolsView(tab) === inspector,
			let page = engine.hostView(tab),
			let host = page.superview,
			inspector.superview === host,
			let pageIndex = host.subviews.firstIndex(of: page),
			let inspectorIndex = host.subviews.firstIndex(of: inspector)
		else { return false }

		return inspectorIndex < pageIndex && fills(inspector.frame, host.bounds)
	}

	/// AppKit's autoresizing leaves a fraction of a point of drift after the host
	/// resizes (a closed Split View pane, for one), so filling allows less than a point.
	private static func fills(
		_ frame: NSRect,
		_ bounds: NSRect
	) -> Bool {
		abs(frame.minX - bounds.minX) < 1 && abs(frame.minY - bounds.minY) < 1
		&& abs(frame.width - bounds.width) < 1 && abs(frame.height - bounds.height) < 1
	}

	/// The frontend gave the page part of the host, leaving DevTools the rest.
	@MainActor
	private static func pageIsBeside(
		_ inspector: NSView,
		tab: BrowserCore.Tab.ID,
		engine: ChromiumBrowserEngine
	) -> Bool {
		guard let page = engine.hostView(tab) else { return false }
		return page.frame.width > 0 && page.frame.height > 0 && page.frame != inspector.frame
	}

	/// Docked inspectors shown in a window, then any undocked inspector windows.
	@MainActor
	private static var inspectors: [NSView] {
		var views: [NSView] = []
		func collect(_ view: NSView) {
			if view.identifier?.rawValue == "ArxDockedDeveloperTools" {
				if !view.isHiddenOrHasHiddenAncestor { views.append(view) }
				return
			}
			view.subviews.forEach(collect)
		}
		for window in NSApplication.shared.windows where window.isVisible {
			if window.identifier?.rawValue == "ArxDeveloperTools", let content = window.contentView {
				views.append(content)
			} else if let content = window.contentView {
				collect(content)
			}
		}
		return views
	}

	/// The runner reacts to some markers while the app keeps running, so each line is flushed.
	@MainActor
	private static func emit(_ line: String) {
		print(line)
		fflush(stdout)
	}

	@MainActor
	private static func wait(_ condition: @MainActor () -> Bool) async throws {
		let end = ContinuousClock.now.advanced(by: .seconds(30))
		while !condition() {
			guard ContinuousClock.now < end else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}
#endif
