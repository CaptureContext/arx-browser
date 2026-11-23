#if DEBUG
import AppKit
import BrowserCore
import BrowserMediaClient
import BrowserSurfaceClient
import ChromiumBrowserEngine
import Foundation
import SwiftUI
import _ComposableArchitecture

/// DEV-949's window smoke: a page's `requestFullscreen()` on a `<video>` and on a `<div>` fills
/// the screen, Escape and another tab end it, and the window is where it was afterwards. A window
/// already in macOS full screen stays there.
///
/// DEV-991 adds: the video plays as it goes full screen and stays there through the window's
/// Space transition, never inline and never in automatic Picture in Picture; the page's own
/// `document.exitFullscreen()` puts the window back too; and ⌘S in a full-screen window shows
/// the sidebar beside the page, which keeps filling the rest, and hides it again.
///
/// It uses a disposable page, a separate store and its own window, as BrowserWindow drives the
/// app's: the store's page full screen, its media with automatic PiP on, the window's full-screen
/// transitions and `PageFullScreenWindows`. The engine's report reaches this store for the smoke
/// only; the app's handler is put back afterwards.
@MainActor
internal enum PageFullScreenSmoke {
	internal static func run(
		engine: ChromiumBrowserEngine,
		baseURL: URL,
		profileID: Profile.ID
	) async throws {
		let root = baseURL.deletingLastPathComponent()
		let pageURL = root.appending(path: "media/full-screen.html")
		let spareURL = root.appending(path: "media/manual-only.html")
		func tab(
			_ title: String,
			_ url: URL
		) -> BrowserCore.Tab {
			.init(id: .init(rawValue: UUID()), profileID: profileID, restoration: .init(title: title, url: url))
		}
		let page = tab("Owned full-screen page", pageURL)
		let spare = tab("Owned spare page", spareURL)
		let space = Space(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			name: "Owned page full-screen acceptance",
			unpinnedTabs: [page.id, spare.id],
			selectedTabID: page.id
		)
		let organization = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Owned page full-screen acceptance")],
			spaces: [space],
			tabs: [page, spare]
		)
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		initial.main.viewer.item.tab = page
		let media = try engine.media()
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine = engine.client
			$0.browserSurface = engine.surface
			$0.browserMedia = media
		}

		guard
			let screen = NSScreen.main,
			screen.visibleFrame.width >= 760,
			screen.visibleFrame.height >= 560
		else { throw Failure.invalidFixture }

		let previousWindow = NSApp.keyWindow
		let previousHandler = engine.onPageFullScreen
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 720, height: 500),
			styleMask: [.titled, .resizable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.title = "Arx owned page full-screen acceptance"
		window.collectionBehavior = [.fullScreenPrimary]
		let host = NSHostingView(rootView: Host(store: store, surface: engine.surface))
		window.contentView = host
		window.setFrameOrigin(.init(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
		let windows = PageFullScreenWindows()

		// AppKit ignores a full-screen toggle during another one, so the window's transitions are
		// tracked as BrowserWindow's delegate does; otherwise a page leaving while the window is
		// still entering full screen leaves it there (DEV-965). The store hears of them as the
		// app's does, so automatic PiP waits them out (DEV-991).
		let transitions = FullScreenTransitions(window: window) { isTransitioning in
			store.send(.event(.windowFullScreenTransition(store.main.id, isTransitioning: isTransitioning)))
		}
		let reconcile = {
			windows.update(
				target: store.pageFullScreen?.windowID,
				browserWindow: { $0 == store.main.id ? window : nil },
				littleWindows: [:],
				isTransitioning: { _ in transitions.isTransitioning }
			)
		}

		// BrowserWindow reconciles on every store change; the smoke polls.
		let reconciling = Task { @MainActor in
			while !Task.isCancelled {
				reconcile()
				try? await Task.sleep(for: .milliseconds(25))
			}
		}
		var phase = "opening"

		engine.onPageFullScreen = { tabID, isFullScreen in
			store.send(.event(.pageFullScreenChanged(tabID, isFullScreen)))
		}
		defer {
			if phase != "complete" {
				let evidence = try? evidence(engine: engine, tab: page.id, url: pageURL)
				let fields: [String] = [
					"phase=\(phase)",
					"pageFullScreen=\(String(describing: store.pageFullScreen))",
					"element=\(String(describing: evidence?.element))",
					"size=\(evidence.map { "\($0.width)x\($0.height)" } ?? "-")",
					"error=\(String(describing: evidence?.error))",
					"requests=\(String(describing: evidence?.requests))",
					"pageEntered=\(String(describing: evidence?.entered))",
					"pageLeft=\(String(describing: evidence?.left))",
					"displayMode=\(String(describing: evidence?.displayMode))",
					"reports=\(String(describing: evidence?.reports))",
					"pageView=\(engine.pageViewSize(page.id).map { "\(Int($0.width))x\(Int($0.height))" } ?? "-")",
					"windowFullScreen=\(window.styleMask.contains(.fullScreen))",
					"frame=\(window.frame)",
					"entered=\(windows.enteredWindowIDs.count)",
					"playing=\(String(describing: evidence?.playing))",
					"pipEntries=\(String(describing: evidence?.pipEntries))",
					"owed=\(store.media.automaticEntry.owed.count)",
					"transitioning=\(transitions.isTransitioning)",
					"log=\(transitions.log.joined(separator: ","))",
				]
				FileHandle.standardError.write(Data(("ARX_PAGE_FULL_SCREEN_DIAGNOSTIC " + fields.joined(separator: " ") + "\n").utf8))
			}
			reconciling.cancel()
			transitions.stop()
			store.send(.media(.ui(.dismissed)))
			engine.onPageFullScreen = previousHandler
			store.send(.main(.viewer(.suspend)))
			window.contentView = nil
			window.close()
			engine.client.close(page.id)
			engine.client.close(spare.id)
			previousWindow?.makeKeyAndOrderFront(nil)
		}

		try await engine.client.open(page)
		try await engine.client.open(spare)
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		store.send(.configureMedia)
		let windowed = window.frame

		// 1. The video plays and fills the screen, and the window enters macOS full screen for it.
		phase = "video"
		try await waitForPage(page, url: pageURL, window: window, store: store, engine: engine)
		let watch = FullScreenWatch()
		let watching = Task { @MainActor in
			while !Task.isCancelled {
				watch.observe(try? evidence(engine: engine, tab: page.id, url: pageURL), tab: page.id, store: store)
				try? await Task.sleep(for: .milliseconds(25))
			}
		}
		defer { watching.cancel() }
		try await clickUntilCounted(window: window, host: host, page: page, url: pageURL, engine: engine)
		try await waitForFullScreen(
			"video",
			page: page,
			url: pageURL,
			window: window,
			screen: screen,
			store: store,
			engine: engine,
			transitions: transitions
		)
		print("ARX_PAGE_FULL_SCREEN_VIDEO_SUCCESS")

		// 2. DEV-991: it stays full screen through the transition and after it, playing, with no
		// automatic PiP: the window's Space moving never reads as the video's tab being left.
		phase = "stays"
		try await wait {
			store.media.visibleSources.contains { $0.id.tabID == page.id && $0.playback == .playing }
		}
		try await Task.sleep(for: .seconds(2))
		watching.cancel()
		let stayed = try evidence(engine: engine, tab: page.id, url: pageURL)
		guard
			!watch.leftFullScreen,
			!watch.sawPictureInPicture,
			!watch.sawHidden,
			stayed?.element == "video",
			stayed?.playing == true,
			stayed?.pipEntries == 0,
			store.pageFullScreen?.tabID == page.id,
			window.styleMask.contains(.fullScreen),
			!store.media.visibleSources.contains(where: { $0.id.tabID == page.id && $0.isInPictureInPicture }),
			store.media.automaticEntry.owed.isEmpty
		else { throw Failure.unexpectedState }
		print("ARX_PAGE_FULL_SCREEN_STAYS_SUCCESS")

		// 3. Escape leaves, and the window is back where it was.
		phase = "escape"
		try pressEscape(in: window)
		try await waitForWindowed(page: page, url: pageURL, window: window, frame: windowed, store: store, engine: engine, transitions: transitions)
		print("ARX_PAGE_FULL_SCREEN_ESCAPE_SUCCESS")

		// 4. A <div> fills the screen too.
		phase = "element"
		try await waitForPage(page, url: pageURL, window: window, store: store, engine: engine)
		try await clickUntilCounted(window: window, host: host, page: page, url: pageURL, engine: engine)
		try await waitForFullScreen(
			"box",
			page: page,
			url: pageURL,
			window: window,
			screen: screen,
			store: store,
			engine: engine,
			transitions: transitions
		)
		print("ARX_PAGE_FULL_SCREEN_ELEMENT_SUCCESS")

		// 5. The page's own `document.exitFullscreen()` leaves, and the window is back too.
		phase = "page-exit"
		try await Task.sleep(for: .seconds(1))
		try press("x", keyCode: 7, in: window)
		try await waitForWindowed(page: page, url: pageURL, window: window, frame: windowed, store: store, engine: engine, transitions: transitions)
		print("ARX_PAGE_FULL_SCREEN_PAGE_EXIT_SUCCESS")

		// 6. Another tab in the window takes the page out of full screen.
		phase = "tab-switch"
		try await waitForPage(page, url: pageURL, window: window, store: store, engine: engine)
		try await clickUntilCounted(window: window, host: host, page: page, url: pageURL, engine: engine)
		try await waitForFullScreen(
			"video",
			page: page,
			url: pageURL,
			window: window,
			screen: screen,
			store: store,
			engine: engine,
			transitions: transitions
		)
		store.send(.main(.viewer(.show(spare, in: store.main.viewer.activePaneID))))
		try await wait {
			let evidence = try evidence(engine: engine, tab: page.id, url: pageURL)
			return evidence?.element == nil
			&& store.pageFullScreen == nil
			&& !window.styleMask.contains(.fullScreen)
		}
		try await wait(seconds: 5) { window.frame == windowed }
		print("ARX_PAGE_FULL_SCREEN_TAB_SWITCH_SUCCESS")

		// 7. A window the person put in macOS full screen stays there when the page leaves.
		phase = "keeps-window"
		store.send(.main(.viewer(.show(page, in: store.main.viewer.activePaneID))))

		// The style mask says full screen as the animation starts; Escape during it cancels the
		// entry, so the step waits for it to finish. Right after the previous step's exit AppKit
		// sometimes refuses the entry outright, with no notification, so the step settles first
		// and tries again when an entry never finishes (DEV-965).
		try await enterFullScreen(window, transitions: transitions)
		try await waitForPage(page, url: pageURL, window: window, store: store, engine: engine)
		try await clickUntilCounted(window: window, host: host, page: page, url: pageURL, engine: engine)
		try await wait {
			try evidence(engine: engine, tab: page.id, url: pageURL)?.element != nil
			&& store.pageFullScreen != nil
		}

		// 8. DEV-991: ⌘S shows the sidebar beside the page, which keeps filling the rest of the
		// window, and ⌘S again hides it. The window's own sidebar setting doesn't change.
		phase = "sidebar"

		// The page first fills the window it moved into, so ⌘S's size isn't asked for while the
		// page is still taking the previous one (DEV-1183).
		try await waitForPageSize(showsSidebar: false, page: page, url: pageURL, window: window, store: store, engine: engine)
		try await Task.sleep(for: .seconds(1))
		let sidebarWasVisible = store.main.sidebar.sidebarIsVisible
		store.send(.ui(.command(.toggleSidebar, .window(store.main.id, paneID: nil))))
		try await waitForPageSize(showsSidebar: true, page: page, url: pageURL, window: window, store: store, engine: engine)
		guard
			store.pageFullScreen?.showsSidebar == true,
			store.main.sidebar.sidebarIsVisible == sidebarWasVisible
		else { throw Failure.unexpectedState }

		store.send(.ui(.command(.toggleSidebar, .window(store.main.id, paneID: nil))))
		try await waitForPageSize(showsSidebar: false, page: page, url: pageURL, window: window, store: store, engine: engine)
		guard
			store.pageFullScreen?.showsSidebar == false,
			store.main.sidebar.sidebarIsVisible == sidebarWasVisible,
			window.styleMask.contains(.fullScreen)
		else { throw Failure.unexpectedState }
		print("ARX_PAGE_FULL_SCREEN_SIDEBAR_SUCCESS")

		phase = "keeps-window"

		// An Escape that arrives while the page is still going full screen can be lost, and a
		// second one would take the window itself out of macOS full screen, which is what this
		// step checks doesn't happen. So the page settles first and Escape is pressed once (DEV-965).
		try await Task.sleep(for: .seconds(1))
		try pressEscape(in: window)
		try await wait {
			try evidence(engine: engine, tab: page.id, url: pageURL)?.element == nil
			&& store.pageFullScreen == nil
		}

		// Give AppKit a moment: nothing may start taking the window out.
		try await Task.sleep(for: .seconds(1))
		guard window.styleMask.contains(.fullScreen), windows.enteredWindowIDs.isEmpty
		else { throw Failure.unexpectedState }
		print("ARX_PAGE_FULL_SCREEN_KEEPS_WINDOW_SUCCESS")
		window.toggleFullScreen(nil)
		try await wait(seconds: 20) { !window.styleMask.contains(.fullScreen) && !transitions.isTransitioning }

		phase = "complete"
		print("ARX_PAGE_FULL_SCREEN_SMOKE_SUCCESS")
	}

	/// DEV-991 in the app's own main window, as a person meets it: BrowserWindow drives macOS
	/// full screen, the store has the app's media, activity and sidebar, and ⌘S is the app's.
	/// The window's tab shows the fixture page, whose video plays as it goes full screen; it
	/// stays full screen through the Space transition with no PiP, ⌘S shows the real sidebar
	/// beside it and hides it, and Escape puts the window back as it was. The tab goes back to
	/// its page afterwards.
	internal static func runInBrowserWindow(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		window: NSWindow,
		baseURL: URL
	) async throws {
		let pageURL = baseURL.deletingLastPathComponent().appending(path: "media/full-screen.html")
		guard
			let tab = store.main.viewer.item.tab?.id,
			let originalURL = engine.client.snapshot(tab)?.navigation.url,
			!window.styleMask.contains(.fullScreen)
		else { throw Failure.invalidFixture }

		let paneID = store.main.viewer.activePaneID
		let navigate = { (url: URL) in
			_ = store.send(.main(.viewer(.command(.navigate(url), in: paneID, tabID: tab))))
		}
		var phase = "app-window-opening"
		var watchLog: [String] = []
		defer {
			if phase != "complete" {
				let evidence = try? evidence(engine: engine, tab: tab, url: pageURL)
				let fields: [String] = [
					"phase=\(phase)",
					"pageFullScreen=\(String(describing: store.pageFullScreen))",
					"element=\(String(describing: evidence?.element))",
					"size=\(evidence.map { "\($0.width)x\($0.height)" } ?? "-")",
					"playing=\(String(describing: evidence?.playing))",
					"pipEntries=\(String(describing: evidence?.pipEntries))",
					"windowFullScreen=\(window.styleMask.contains(.fullScreen))",
					"frame=\(window.frame)",
					"appActive=\(NSApp.isActive)",
					"key=\(window.isKeyWindow)",
				]
				FileHandle.standardError.write(Data(("ARX_PAGE_FULL_SCREEN_APP_DIAGNOSTIC " + fields.joined(separator: " ") + "\n").utf8))
				for line in watchLog { FileHandle.standardError.write(Data("ARX_PAGE_FULL_SCREEN_APP_TIMELINE \(line)\n".utf8)) }
				if store.pageFullScreen != nil { store.send(.ui(.exitPageFullScreen)) }
				navigate(originalURL)
			}
		}

		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		navigate(pageURL)
		try await wait {
			try evidence(engine: engine, tab: tab, url: pageURL)?.ready == true
			&& engine.contentHostFixtureView(tab)?.window === window
			&& window.occlusionState.contains(.visible)
			&& NSApp.isActive
		}
		let windowed = window.frame
		let sidebarWasVisible = store.main.sidebar.sidebarIsVisible

		// 1. The video plays and fills the screen; through the Space transition and after it,
		// it stays there, never inline and never in PiP.
		phase = "app-window-stays"
		guard let host = engine.contentHostFixtureView(tab) else { throw Failure.invalidFixture }
		let watch = FullScreenWatch()
		let watching = Task { @MainActor in
			while !Task.isCancelled {
				watch.observe(try? evidence(engine: engine, tab: tab, url: pageURL), tab: tab, store: store)
				try? await Task.sleep(for: .milliseconds(25))
			}
		}
		defer {
			watching.cancel()
			watchLog = watch.log
		}

		// A page that has just loaded can miss the first click; it's tried again until the page
		// counts one, which is safe because only its first click plays and asks for full screen.
		for _ in 1...5 {
			try clickStart(in: host, window: window)
			let counted = try await becomes(within: 2) {
				((try? evidence(engine: engine, tab: tab, url: pageURL))?.requests ?? 0) > 0
			}
			if counted { break }
		}
		try await wait(seconds: 20) {
			guard
				let evidence = try evidence(engine: engine, tab: tab, url: pageURL),
				evidence.element == "video",
				store.pageFullScreen?.tabID == tab,
				window.styleMask.contains(.fullScreen),
				let frame = window.screen.flatMap({ fullScreenFrame(on: $0) })
			else { return false }

			return window.frame == frame
			&& abs(Double(evidence.width) - frame.width) <= 1
			&& abs(Double(evidence.height) - frame.height) <= 1
		}
		try await wait {
			store.media.visibleSources.contains { $0.id.tabID == tab && $0.playback == .playing }
		}
		try await Task.sleep(for: .seconds(2))
		watching.cancel()
		let stayed = try evidence(engine: engine, tab: tab, url: pageURL)
		guard
			!watch.leftFullScreen,
			!watch.sawPictureInPicture,
			!watch.sawHidden,
			stayed?.element == "video",
			stayed?.playing == true,
			stayed?.pipEntries == 0,
			window.styleMask.contains(.fullScreen),
			!store.media.visibleSources.contains(where: { $0.id.tabID == tab && $0.isInPictureInPicture })
		else { throw Failure.unexpectedState }
		print("ARX_PAGE_FULL_SCREEN_APP_WINDOW_STAYS_SUCCESS")

		// 2. ⌘S shows the window's own sidebar beside the page, which fills the rest; ⌘S hides it.
		phase = "app-window-sidebar"
		let screenWidth = window.frame.width
		let sidebarWidth = store.main.sidebarWidth
		store.send(.ui(.command(.toggleSidebar, .window(store.main.id, paneID: nil))))
		try await wait {
			guard let evidence = try evidence(engine: engine, tab: tab, url: pageURL), evidence.element == "video"
			else { return false }

			return abs(Double(evidence.width) - (screenWidth - sidebarWidth)) <= 1
		}
		guard
			store.pageFullScreen?.showsSidebar == true,
			store.main.sidebar.sidebarIsVisible == sidebarWasVisible,
			sidebarTakesClicks(in: window, width: sidebarWidth, edge: store.settings.general.sidebarPosition)
		else { throw Failure.unexpectedState }

		store.send(.ui(.command(.toggleSidebar, .window(store.main.id, paneID: nil))))
		try await wait {
			guard let evidence = try evidence(engine: engine, tab: tab, url: pageURL), evidence.element == "video"
			else { return false }

			return abs(Double(evidence.width) - screenWidth) <= 1
		}
		guard
			store.pageFullScreen?.showsSidebar == false,
			store.main.sidebar.sidebarIsVisible == sidebarWasVisible,
			window.styleMask.contains(.fullScreen)
		else { throw Failure.unexpectedState }
		print("ARX_PAGE_FULL_SCREEN_APP_WINDOW_SIDEBAR_SUCCESS")

		// 3. Escape leaves, and the window is back at its size, out of macOS full screen.
		phase = "app-window-restore"
		try pressEscape(in: window)
		try await wait(seconds: 20) {
			try evidence(engine: engine, tab: tab, url: pageURL)?.element == nil
			&& store.pageFullScreen == nil
			&& !window.styleMask.contains(.fullScreen)
			&& window.frame == windowed
		}
		print("ARX_PAGE_FULL_SCREEN_APP_WINDOW_RESTORE_SUCCESS")

		// 4. The tab is back at its page before the next stage starts, so this navigation can't
		// replace one the next stage makes (the overnight WebKit fallback stage lost its own to it).
		phase = "app-window-return"
		navigate(originalURL)
		try await wait {
			guard let navigation = engine.client.snapshot(tab)?.navigation else { return false }
			return navigation.url == originalURL && !navigation.isLoading
		}
		phase = "complete"
	}

	/// Whether a click in the middle of the sidebar's strip reaches the window's own views
	/// rather than the full-screen page over them.
	private static func sidebarTakesClicks(
		in window: NSWindow,
		width: CGFloat,
		edge: SidebarPosition
	) -> Bool {
		guard let content = window.contentView else { return false }

		let x = edge == .right ? content.bounds.width - width / 2 : width / 2
		let point = NSPoint(x: x, y: content.bounds.midY)
		guard let hit = content.hitTest(point) else { return false }

		let pageHosts = sequence(first: hit, next: \.superview).contains { $0.className.contains("SurfaceHost") }
		return !pageHosts
	}

	/// A trusted click on the fixture's Start button, at CSS points (16, 286, 200, 44) of the page.
	private static func clickStart(
		in view: NSView,
		window: NSWindow
	) throws {
		let local = NSPoint(x: 116, y: view.isFlipped ? 308 : view.bounds.height - 308)
		let location = view.convert(local, to: nil)
		try post([.leftMouseDown, .leftMouseUp], in: window) { type, timestamp, index in
			NSEvent.mouseEvent(
				with: type,
				location: location,
				modifierFlags: [],
				timestamp: timestamp,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: index + 1,
				clickCount: 1,
				pressure: type == .leftMouseDown ? 1 : 0
			)
		}
	}

	// MARK: - Steps

	/// Puts `window` in macOS full screen the way a person would, retrying an entry AppKit drops.
	private static func enterFullScreen(
		_ window: NSWindow,
		transitions: FullScreenTransitions
	) async throws {
		for attempt in 1...3 {
			try await Task.sleep(for: .seconds(1))
			if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
			let entered = try await becomes(within: 8) {
				window.styleMask.contains(.fullScreen) && window.isOnActiveSpace && !transitions.isTransitioning
			}
			if entered { return }
			FileHandle.standardError.write(Data(
				"ARX_PAGE_FULL_SCREEN_ENTRY_RETRY attempt=\(attempt) log=\(transitions.log.joined(separator: ","))\n".utf8
			))

			// An entry AppKit dropped leaves no notification behind.
			if !window.styleMask.contains(.fullScreen) { transitions.reset() }
		}
		throw Failure.unexpectedState
	}

	/// Polls `condition` for up to `seconds`, without failing.
	private static func becomes(
		within seconds: Int,
		_ condition: () -> Bool
	) async throws -> Bool {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while ContinuousClock.now < deadline {
			try Task.checkCancellation()
			if condition() { return true }
			try await Task.sleep(for: .milliseconds(25))
		}
		return condition()
	}

	private static func waitForPage(
		_ tab: BrowserCore.Tab,
		url: URL,
		window: NSWindow,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine
	) async throws {
		try await wait {
			try evidence(engine: engine, tab: tab.id, url: url)?.ready == true
			&& store.main.viewer.item.tab?.id == tab.id
			&& engine.isAttached(tab.id)
			&& window.occlusionState.contains(.visible)
		}
	}

	/// Waits for a page's full screen in the order it happens, each step for what settles it: the
	/// page enters (its `fullscreenchange`), the engine tells the store, the window's macOS full
	/// screen transition finishes (`didEnterFullScreen`, the window on its screen's frame), and
	/// the page takes the screen's size. A timeout names the step that stalled and what the page,
	/// the store, the window and the engine last said (DEV-1183).
	private static func waitForFullScreen(
		_ element: String,
		page: BrowserCore.Tab,
		url: URL,
		window: NSWindow,
		screen: NSScreen,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		transitions: FullScreenTransitions
	) async throws {
		let state = {
			fullScreenState(page: page, url: url, window: window, store: store, engine: engine, transitions: transitions)
		}
		try await wait(seconds: 10, state: { "step=page-enters " + state() }) {
			let evidence = try evidence(engine: engine, tab: page.id, url: url)
			return evidence?.element == element && evidence?.displayMode == "fullscreen"
		}
		try await wait(seconds: 5, state: { "step=store-hears " + state() }) {
			store.pageFullScreen == .init(tabID: page.id, windowID: store.main.id)
		}
		try await wait(seconds: 20, state: { "step=window-transition " + state() }) {
			window.styleMask.contains(.fullScreen)
			&& !transitions.isTransitioning
			&& window.screen.map { window.frame == fullScreenFrame(on: $0) } == true
		}
		try await wait(seconds: 10, state: { "step=page-size " + state() }) {
			guard
				let evidence = try evidence(engine: engine, tab: page.id, url: url),
				evidence.element == element,
				let frame = window.screen.map({ fullScreenFrame(on: $0) })
			else { return false }

			return abs(Double(evidence.width) - frame.width) <= 1
			&& abs(Double(evidence.height) - frame.height) <= 1
		}
	}

	/// The frame a full-screen window takes on `screen`: all of it, except on a display with a
	/// camera housing, where macOS keeps the window below the menu bar's band around it.
	internal static func fullScreenFrame(on screen: NSScreen) -> NSRect {
		fullScreenFrame(screen: screen.frame, visible: screen.visibleFrame, housing: screen.safeAreaInsets.top)
	}

	internal static func fullScreenFrame(screen: NSRect, visible: NSRect, housing: CGFloat) -> NSRect {
		guard housing > 0 else { return screen }

		var frame = screen
		frame.size.height = visible.maxY - screen.minY
		return frame
	}

	/// What the page, the store, the window and the engine say now, for a timeout.
	private static func fullScreenState(
		page: BrowserCore.Tab,
		url: URL,
		window: NSWindow,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		transitions: FullScreenTransitions
	) -> String {
		let evidence = try? evidence(engine: engine, tab: page.id, url: url)
		let pageState = evidence.map {
			"element=\($0.element ?? "nil") mode=\($0.displayMode ?? "nil") size=\($0.width)x\($0.height) requests=\($0.requests) entered=\($0.entered) left=\($0.left) error=\($0.error ?? "nil") reports=\($0.reports.map(String.init) ?? "-")"
		} ?? "unreadable"
		let screen = window.screen.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-"
		let pageView = engine.pageViewSize(page.id).map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
		return [
			"page=(\(pageState))",
			"store=\(store.pageFullScreen.map { "tab:\($0.tabID == page.id) window:\($0.windowID == store.main.id)" } ?? "nil")",
			"window=(fullScreen=\(window.styleMask.contains(.fullScreen)) frame=\(window.frame) screen=\(screen) key=\(window.isKeyWindow) onActiveSpace=\(window.isOnActiveSpace))",
			"transitions=(\(transitions.isTransitioning ? "transitioning" : "settled") log=\(transitions.log.suffix(8).joined(separator: ",")))",
			"engine=(attached=\(engine.isAttached(page.id)) pageView=\(pageView))",
		].joined(separator: " ")
	}

	/// Waits for the page in full screen to report the size the window's layout gives it now:
	/// the window, less the sidebar beside it while it shows (DEV-1096). Each look reads the window,
	/// the sidebar and the page afresh, as the layout does, rather than an expectation taken before
	/// ⌘S, and the sidebar must be the one asked for. A timeout says what each side last was and
	/// which one is behind (DEV-1183): the store's sidebar, the window, the layout of the page's
	/// view, the page's title, or the page itself.
	private static func waitForPageSize(
		showsSidebar: Bool,
		page: BrowserCore.Tab,
		url: URL,
		window: NSWindow,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine
	) async throws {
		var last: PageFullScreenSizeCheck?

		// When the page's report count last went up, so a title that stops changing shows.
		var lastReport: (count: Int, at: ContinuousClock.Instant)?
		try await wait(state: {
			guard let last else { return "no look yet" }
			return "\(last) behind=\(last.lag(showingSidebar: showsSidebar)?.rawValue ?? "nothing")"
		}) {
			let evidence = try evidence(engine: engine, tab: page.id, url: url)
			let now = ContinuousClock.now
			if let count = evidence?.reports, lastReport?.count != count { lastReport = (count, now) }
			let sinceLastReport: TimeInterval? = lastReport.map { report in
				let elapsed = report.at.duration(to: now).components
				return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
			}
			let check = PageFullScreenSizeCheck(
				window: window.frame.size,
				showsSidebar: store.pageFullScreen?.showsSidebar,
				sidebarWidth: store.main.sidebarWidth,
				reported: evidence.flatMap { $0.element == nil ? nil : CGSize(width: $0.width, height: $0.height) },
				pageView: engine.pageViewSize(page.id),
				sinceLastReport: sinceLastReport,
				windowIsVisible: window.occlusionState.contains(.visible)
			)
			last = check
			return check.isSettled(showingSidebar: showsSidebar)
		}
	}

	/// Waits for a page's full screen to end in the order it happens: the page leaves, the store
	/// hears, the window's transition out finishes (`didExitFullScreen`), and the window is back
	/// where it was. A timeout names the step that stalled (DEV-1183).
	private static func waitForWindowed(
		page: BrowserCore.Tab,
		url: URL,
		window: NSWindow,
		frame: NSRect,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		transitions: FullScreenTransitions
	) async throws {
		let state = {
			"expected=\(frame) "
			+ fullScreenState(page: page, url: url, window: window, store: store, engine: engine, transitions: transitions)
		}
		try await wait(seconds: 10, state: { "step=page-leaves " + state() }) {
			let evidence = try evidence(engine: engine, tab: page.id, url: url)
			return evidence != nil && evidence?.element == nil
		}
		try await wait(seconds: 5, state: { "step=store-hears " + state() }) {
			store.pageFullScreen == nil
		}
		try await wait(seconds: 20, state: { "step=window-transition " + state() }) {
			!window.styleMask.contains(.fullScreen) && !transitions.isTransitioning
		}
		try await wait(seconds: 5, state: { "step=window-frame " + state() }) {
			window.frame == frame
		}
	}

	/// Clicks the fixture's Start button until the page counts the click, as a page that has just
	/// loaded can miss the first. Each counted click asks the page's next target for full screen,
	/// so it's clicked again only while the last one went uncounted, and a click counted twice
	/// fails rather than asking for the wrong one (DEV-1183).
	private static func clickUntilCounted(
		window: NSWindow,
		host: NSView,
		page: BrowserCore.Tab,
		url: URL,
		engine: ChromiumBrowserEngine
	) async throws {
		let before = try evidence(engine: engine, tab: page.id, url: url)?.requests ?? 0
		var requests: Int { (try? evidence(engine: engine, tab: page.id, url: url))?.requests ?? before }
		for attempt in 1...5 {
			try click(window: window, host: host)
			if try await becomes(within: 3, { requests > before }) {
				guard requests == before + 1 else {
					throw SmokeDiagnostics.timeout(
						site: "\(#fileID):\(#line) clickUntilCounted",
						since: .now,
						state: "step=click counted=\(requests - before) attempts=\(attempt)"
					)
				}
				return
			}
			FileHandle.standardError.write(Data("ARX_PAGE_FULL_SCREEN_CLICK_RETRY attempt=\(attempt) requests=\(requests)\n".utf8))
		}
		throw SmokeDiagnostics.timeout(
			site: "\(#fileID):\(#line) clickUntilCounted",
			since: .now,
			state: "step=click the page counted none of 5 clicks requests=\(requests) attached=\(engine.isAttached(page.id)) key=\(window.isKeyWindow)"
		)
	}

	/// A trusted click on the fixture's Start button, at CSS points (16, 286, 200, 44) of the page.
	private static func click(
		window: NSWindow,
		host: NSView
	) throws {
		guard window.isVisible, window.windowNumber > 0
		else { throw Failure.invalidFixture }

		let inset = Host.inset
		let point = CGPoint(
			x: inset + 116,
			y: host.isFlipped ? inset + 308 : host.bounds.height - inset - 308
		)
		try post([.leftMouseDown, .leftMouseUp], in: window) { type, timestamp, index in
			NSEvent.mouseEvent(
				with: type,
				location: host.convert(point, to: nil),
				modifierFlags: [],
				timestamp: timestamp,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: index + 1,
				clickCount: 1,
				pressure: type == .leftMouseDown ? 1 : 0
			)
		}
	}

	private static func pressEscape(in window: NSWindow) throws {
		try press("\u{1B}", keyCode: 53, in: window)
	}

	private static func press(
		_ characters: String,
		keyCode: UInt16,
		in window: NSWindow
	) throws {
		try post([.keyDown, .keyUp], in: window) { type, timestamp, _ in
			NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: [],
				timestamp: timestamp,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: keyCode
			)
		}
	}

	private static func post(
		_ types: [NSEvent.EventType],
		in window: NSWindow,
		event: (NSEvent.EventType, TimeInterval, Int) -> NSEvent?
	) throws {
		let timestamp = ProcessInfo.processInfo.systemUptime
		for (index, type) in types.enumerated() {
			guard let event = event(type, timestamp + Double(index) * 0.001, index)
			else { throw Failure.invalidFixture }

			window.sendEvent(event)
		}
	}

	// MARK: - Reading state

	private static func evidence(
		engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab.ID,
		url: URL
	) throws -> Evidence? {
		guard
			let navigation = engine.client.snapshot(tab)?.navigation,
			navigation.url == url,
			navigation.errorCode == nil,
			navigation.title.hasPrefix(Evidence.prefix + "{")
		else { return nil }

		return try Evidence(title: navigation.title)
	}

	private static func wait(
		seconds: Int = 15,
		file: StaticString = #fileID,
		line: Int = #line,
		function: StaticString = #function,
		state: () -> String = { "condition still false" },
		_ condition: () throws -> Bool
	) async throws {
		let start = ContinuousClock.now
		let deadline = start.advanced(by: .seconds(seconds))
		while ContinuousClock.now < deadline {
			try Task.checkCancellation()
			if try condition() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		throw SmokeDiagnostics.timeout(
			site: "\(file):\(line) \(function)",
			since: start,
			state: state()
		)
	}

	/// The page inset from the window, as a page card is, so filling the window is a change.
	private struct Host: View {
		internal static let inset: CGFloat = 40

		internal let store: StoreOf<AppFeature>
		internal let surface: BrowserSurfaceClient

		internal var body: some View {
			Group {
				if let tab = store.main.viewer.item.tab {
					BrowserSurface(tabID: tab.id, client: surface)
				}
			}
			.padding(Self.inset)
			.frame(maxWidth: .infinity, maxHeight: .infinity)

			// What AppMainView reports, so automatic PiP sees the page as the app's would.
			.environment(\.browserSurfaceVisibilityObserver, .init { report in
				store.send(.event(.mediaSurfaceVisibility(store.main.id, report)))
			})
			.modifier(PageFullScreenHostPresentation(store: store, windowID: store.main.id, surface: surface))
		}
	}

	private struct Evidence: Decodable {
		internal static let prefix: String = "Arx full screen "

		internal let ready: Bool
		internal let element: String?
		internal let width: Int
		internal let height: Int
		internal let displayMode: String?
		internal let error: String?
		internal let playing: Bool
		internal let pip: Bool
		internal let pipEntries: Int
		internal let requests: Int
		internal let entered: Int
		internal let left: Int

		/// How many times the page has written its title (DEV-1183); nil from an older fixture.
		internal let reports: Int?

		internal init(title: String) throws {
			guard title.utf8.count <= 2048, title.hasPrefix(Self.prefix)
			else { throw Failure.invalidFixture }

			let payload = Data(title.dropFirst(Self.prefix.count).utf8)
			self = try JSONDecoder().decode(Self.self, from: payload)
		}
	}

	private enum Failure: Error {
		case invalidFixture
		case unexpectedState
	}

	/// What the video did while it was meant to stay in full screen (DEV-991): left it after
	/// entering, floated in Picture in Picture or was owed an automatic entry, or read as hidden,
	/// which is what lets automatic PiP take it.
	@MainActor
	private final class FullScreenWatch {
		private(set) var leftFullScreen = false
		private(set) var sawPictureInPicture = false
		private(set) var sawHidden = false

		/// What changed and when, for the failure diagnostic.
		private(set) var log: [String] = []
		private var entered: Bool = false
		private var last: String = ""
		private let start: ContinuousClock.Instant = .now

		internal func observe(
			_ evidence: Evidence?,
			tab: BrowserCore.Tab.ID,
			store: StoreOf<AppFeature>
		) {
			guard let evidence else { return }
			if store.mediaSourceVisibility.contains(where: { $0.key.tabID == tab && !$0.value }) { sawHidden = true }
			let visibility = store.mediaSourceVisibility.values.map(String.init(describing:)).joined(separator: "/")
			let line = "el=\(evidence.element ?? "-") req=\(evidence.requests) in=\(evidence.entered) out=\(evidence.left)"
			+ " play=\(evidence.playing) pip=\(evidence.pip) store=\(store.pageFullScreen != nil)"
			+ " vis=\(visibility) owed=\(store.media.automaticEntry.owed.count) pending=\(store.media.pending != nil)"
			+ " active=\(store.media.automaticEntry.isApplicationActive) key=\(NSApp.keyWindow?.title ?? "-")"
			if line != last {
				last = line
				log.append("\(Int((ContinuousClock.now - start) / .milliseconds(1)))ms \(line)")
			}
			if evidence.element == "video", store.pageFullScreen != nil { entered = true }
			if entered, evidence.element == nil || store.pageFullScreen == nil { leftFullScreen = true }
			if evidence.pip || evidence.pipEntries > 0 { sawPictureInPicture = true }

			// Owing the video an automatic entry is the failure, whether or not Chromium takes it.
			let automatic = store.media.automaticEntry
			if !automatic.owed.isEmpty || automatic.pendingTrigger != nil { sawPictureInPicture = true }
		}
	}

	/// Whether `window` is in a macOS full-screen transition, from its notifications.
	@MainActor
	private final class FullScreenTransitions {
		private(set) var isTransitioning = false {
			didSet {
				if isTransitioning != oldValue { onChange(isTransitioning) }
			}
		}

		/// The notifications seen, in order, for the failure diagnostic.
		private(set) var log: [String] = []
		private var observers: [any NSObjectProtocol] = []
		private let onChange: @MainActor (Bool) -> Void

		internal init(
			window: NSWindow,
			onChange: @escaping @MainActor (Bool) -> Void
		) {
			self.onChange = onChange
			let center = NotificationCenter.default
			for (name, transitioning) in [
				(NSWindow.willEnterFullScreenNotification, true),
				(NSWindow.willExitFullScreenNotification, true),
				(NSWindow.didEnterFullScreenNotification, false),
				(NSWindow.didExitFullScreenNotification, false),
			] {
				observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated {
						self?.isTransitioning = transitioning
						self?.log.append(name.rawValue.replacingOccurrences(of: "NSWindow", with: "").replacingOccurrences(of: "FullScreenNotification", with: ""))
					}
				})
			}
		}

		/// Forgets a transition AppKit ended without telling, such as a refused entry.
		internal func reset() {
			isTransitioning = false
			log.append("Reset")
		}

		internal func stop() {
			observers.forEach(NotificationCenter.default.removeObserver)
			observers = []
		}
	}
}
#endif
