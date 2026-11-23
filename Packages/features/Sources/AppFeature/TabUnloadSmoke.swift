#if DEBUG
import AppKit
import BrowserCore
import BrowserEngineClient
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// DEV-873. Runs only with `ARX_TAB_UNLOAD_SMOKE` and a disposable `ARX_ENGINE_PROFILE`.
///
/// The launch tab opens `ARX_ENGINE_URL` and goes on to `ARX_TAB_UNLOAD_SECOND_URL`, so it has a
/// back entry. A second tab (`ARX_TAB_UNLOAD_OTHER_URL`) hides it, and the engine unloads it as
/// critical memory pressure would. The unloaded tab keeps its address, title and history, its
/// sidebar row looks unloaded, and selecting it loads it again; Back then reaches the first
/// page. The fixture server serves every page with `no-store`, so the runner can tell the
/// second page was requested again.
///
/// DEV-879: with `ARX_TAB_UNLOAD_LIVE_URL`, a page that opens a WebSocket is pushed out of the
/// five most recently used tabs, where infinite tabs freezing would freeze it. Over
/// `ARX_TAB_UNLOAD_LIVE_WAIT` seconds, past Chromium's 5-minute freeze delay and a periodic
/// unfreeze, it must keep its title
/// (`ARX_TAB_UNLOAD_LIVE_TITLE`, which a closed socket replaces), and the engine must then refuse
/// to unload it. The runner checks the server never saw it reconnect.
///
/// DEV-1326: with `ARX_TAB_UNLOAD_ARCHIVE`, the tab goes forward to the second page, is hidden and
/// unloaded again, and is archived unloaded, as a tab left unviewed is after it unloads. Restored
/// from the Tab Archive, it shows the second page with the first as its back entry.
///
/// DEV-1107: with `ARX_TAB_UNLOAD_ASK_URL`, a page whose before-unload asks while its text area
/// holds text gets a click and a typed letter, as a person's. Closing the main window then asks it
/// while the window stays open: Stay keeps the window and the page; a second close and Leave
/// close the window and unload the page. It needs the screen, so it runs last.
internal enum TabUnloadSmoke {
	internal enum Failure: String, Error {
		case missingConfiguration
		case missingPage
		case unavailable
		case notHidden
		case notUnloaded
		case lostState
		case notMarked
		case notReloaded
		case historyLost
		case liveConnectionNotOpened
		case liveConnectionLost
		case liveConnectionUnloaded
		case askPageNotTyped
		case askPageNotReported
		case askNotShown
		case stayClosedTheWindow
		case leaveKeptTheWindow
		case leaveKeptThePage
		case notArchived
		case notRestored
	}

	/// Tabs Chromium's infinite tabs freezing never freezes (`num_protected_tabs`).
	private static let protectedTabs: Int = 5

	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		window: @escaping @MainActor () -> NSWindow? = { nil },
		environment: [String: String]
	) async throws {
		guard
			let firstURL = environment["ARX_ENGINE_URL"].flatMap(URL.init(string:)),
			let secondURL = environment["ARX_TAB_UNLOAD_SECOND_URL"].flatMap(URL.init(string:)),
			let otherURL = environment["ARX_TAB_UNLOAD_OTHER_URL"].flatMap(URL.init(string:)),
			let firstTitle = environment["ARX_TAB_UNLOAD_FIRST_TITLE"],
			let secondTitle = environment["ARX_TAB_UNLOAD_SECOND_TITLE"]
		else { throw Failure.missingConfiguration }

		let client = engine.client
		guard client.tabUnloadingIsAvailable() else { throw Failure.unavailable }

		try await wait(or: .missingPage) { shows(store, title: firstTitle) }
		guard let tab = store.main.viewer.item.tab else { throw Failure.missingPage }

		try await client.command(tab.id, .navigate(secondURL))
		try await wait(or: .missingPage) {
			shows(store, title: secondTitle) && store.main.viewer.item.navigation.canGoBack
		}
		print("ARX_TAB_UNLOAD_PHASE_HISTORY")

		// Another tab hides the first one: its page leaves the window.
		store.send(.ui(.openURLInSpace(otherURL, store.main.sidebar.spaceID, .mainBrowser)))
		try await wait(or: .notHidden) {
			store.main.viewer.item.tab.map { $0.id != tab.id } == true
			&& !store.withState { $0.tabsOnScreen.contains(tab.id) }
		}
		print("ARX_TAB_UNLOAD_PHASE_HIDDEN")

		// As a sweep under critical memory pressure asks; native visibility can lag a moment.
		try await wait(or: .notUnloaded) { client.unloadTab(tab.id, .memoryPressure) == .unloaded }
		guard
			let snapshot = client.snapshot(tab.id),
			snapshot.navigation.isUnloaded,
			snapshot.documentRevision == nil,
			snapshot.navigation.url == secondURL,
			snapshot.navigation.title == secondTitle,
			snapshot.navigation.canGoBack,
			snapshot.navigation.history.contains(where: { $0.url == firstURL })
		else { throw Failure.lostState }
		print("ARX_TAB_UNLOAD_PHASE_UNLOADED")

		store.send(.unloadIdleTabs)
		try await wait(or: .notMarked) {
			store.main.sidebar.unloadedTabs.contains(tab.id)
			&& store.main.sidebar.tabItem(tab.id)?.isUnloaded == true
		}
		print("ARX_TAB_UNLOAD_PHASE_FADED")

		store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(tab.id.rawValue)))))))
		try await wait(or: .notReloaded) {
			store.main.viewer.item.tab?.id == tab.id
			&& shows(store, title: secondTitle)
			&& store.main.viewer.item.navigation.url == secondURL
			&& client.snapshot(tab.id)?.navigation.isUnloaded == false
			&& !store.main.sidebar.unloadedTabs.contains(tab.id)
		}

		// Selecting a tab seeds the viewer with its saved address and title and no history until
		// the engine's first report for it lands, and the engine reads the unloaded state live:
		// the wait above can end in that moment. The back entries must be there once it lands.
		let reloaded = store.main.viewer.item.navigation.history
		let keepsHistory: @MainActor () -> Bool = {
			store.main.viewer.item.navigation.entries(in: .back).contains(where: { $0.url == firstURL })
		}
		if !keepsHistory() {
			print("ARX_TAB_UNLOAD_HISTORY_LATER reloaded=\(describe(reloaded))")
		}
		do {
			try await wait(or: .historyLost, seconds: 5, keepsHistory)
		} catch {
			print("ARX_TAB_UNLOAD_HISTORY viewer=\(describe(store.main.viewer.item.navigation.history))")
			print("ARX_TAB_UNLOAD_HISTORY engine=\(describe(client.snapshot(tab.id)?.navigation.history ?? []))")
			throw error
		}
		print("ARX_TAB_UNLOAD_PHASE_RELOADED")

		try await client.command(tab.id, .back)
		try await wait(or: .historyLost) { shows(store, title: firstTitle) }
		print("ARX_TAB_UNLOAD_PHASE_BACK")

		if environment["ARX_TAB_UNLOAD_ARCHIVE"] == "1" {
			try await archiveUnloadedTab(
				store: store,
				client: client,
				tab: tab.id,
				otherURL: otherURL,
				firstURL: firstURL,
				secondTitle: secondTitle
			)
		}

		if
			let liveURL = environment["ARX_TAB_UNLOAD_LIVE_URL"].flatMap(URL.init(string:)),
			let liveTitle = environment["ARX_TAB_UNLOAD_LIVE_TITLE"]
		{
			let seconds = environment["ARX_TAB_UNLOAD_LIVE_WAIT"].flatMap(Double.init) ?? 400
			try await holdLiveConnection(
				store: store,
				client: client,
				url: liveURL,
				title: liveTitle,
				otherURL: otherURL,
				seconds: seconds
			)
		}
		if
			let askURL = environment["ARX_TAB_UNLOAD_ASK_URL"].flatMap(URL.init(string:)),
			let askTitle = environment["ARX_TAB_UNLOAD_ASK_TITLE"],
			let typedTitle = environment["ARX_TAB_UNLOAD_ASK_TYPED_TITLE"]
		{
			try await askBeforeClosingTheWindow(
				store: store,
				client: client,
				window: window,
				url: askURL,
				title: askTitle,
				typedTitle: typedTitle
			)
		}
		print("ARX_TAB_UNLOAD_SMOKE_SUCCESS")
	}

	/// DEV-1326: an unloaded tab is archived and comes back from the Tab Archive with its history.
	@MainActor
	private static func archiveUnloadedTab(
		store: StoreOf<AppFeature>,
		client: BrowserEngineClient,
		tab: BrowserCore.Tab.ID,
		otherURL: URL,
		firstURL: URL,
		secondTitle: String
	) async throws {
		try await client.command(tab, .forward)
		try await wait(or: .historyLost) { shows(store, title: secondTitle) }

		store.send(.ui(.openURLInSpace(otherURL, store.main.sidebar.spaceID, .mainBrowser)))
		try await wait(or: .notHidden) {
			store.main.viewer.item.tab.map { $0.id != tab } == true
			&& !store.withState { $0.tabsOnScreen.contains(tab) }
		}
		try await wait(or: .notUnloaded) { client.unloadTab(tab, .memoryPressure) == .unloaded }
		print("ARX_TAB_UNLOAD_PHASE_ARCHIVE_UNLOADED")

		// The close an automatic archive makes, for a tab that isn't due by the clock here.
		store.send(.main(.ui(.archiveSelectedTabs([tab]))))
		try await wait(or: .notArchived) {
			store.main.sidebar.organization.tabs[id: tab] == nil
			&& store.main.sidebar.organization.archive.contains { $0.tab.id == tab }
		}
		guard let entry = store.main.sidebar.organization.archive.last(where: { $0.tab.id == tab })
		else { throw Failure.notArchived }
		print("ARX_TAB_UNLOAD_PHASE_ARCHIVED")

		store.send(.main(.ui(.reopenArchivedTab(entry.id))))
		try await wait(or: .notRestored) {
			store.main.viewer.item.tab.map { $0.id != tab } == true && shows(store, title: secondTitle)
		}
		do {
			try await wait(or: .historyLost, seconds: 10) {
				store.main.viewer.item.navigation.entries(in: .back).contains { $0.url == firstURL }
			}
		} catch {
			print("ARX_TAB_UNLOAD_ARCHIVE_HISTORY viewer=\(describe(store.main.viewer.item.navigation.history))")
			throw error
		}
		print("ARX_TAB_UNLOAD_PHASE_ARCHIVE_RESTORED")
	}

	/// DEV-879: a page holding a WebSocket stays running and loaded outside the most recent tabs.
	@MainActor
	private static func holdLiveConnection(
		store: StoreOf<AppFeature>,
		client: BrowserEngineClient,
		url: URL,
		title: String,
		otherURL: URL,
		seconds: Double
	) async throws {
		store.send(.ui(.openURLInSpace(url, store.main.sidebar.spaceID, .mainBrowser)))
		try await wait(or: .liveConnectionNotOpened) { shows(store, title: title) }
		guard let live = store.main.viewer.item.tab else { throw Failure.liveConnectionNotOpened }
		print("ARX_TAB_UNLOAD_PHASE_LIVE_OPEN")

		// Each newer tab is shown, so the live page falls out of the most recently used.
		for index in 1 ... protectedTabs {
			var components = URLComponents(url: otherURL, resolvingAgainstBaseURL: false)
			components?.queryItems = [.init(name: "recent", value: String(index))]
			guard let recent = components?.url else { throw Failure.missingConfiguration }

			store.send(.ui(.openURLInSpace(recent, store.main.sidebar.spaceID, .mainBrowser)))
			try await wait(or: .notHidden) {
				store.main.viewer.item.tab.map { $0.id != live.id } == true
				&& store.main.viewer.item.navigation.url == recent
				&& !store.main.viewer.item.navigation.isLoading
			}
		}
		guard !store.withState({ $0.tabsOnScreen.contains(live.id) })
		else { throw Failure.notHidden }
		print("ARX_TAB_UNLOAD_PHASE_LIVE_BACKGROUND")

		// A freeze ends the socket; the page notices at its next periodic unfreeze, within a minute
		// of the freeze, which comes 5 minutes after the page was last visible.
		try await Task.sleep(for: .seconds(seconds))
		guard
			let snapshot = client.snapshot(live.id),
			!snapshot.navigation.isUnloaded,
			snapshot.navigation.title == title
		else { throw Failure.liveConnectionLost }
		print("ARX_TAB_UNLOAD_PHASE_LIVE_HELD")

		// As a sweep under critical memory pressure asks; the engine keeps it.
		let outcome = client.unloadTab(live.id, .memoryPressure)
		guard outcome == .kept, client.snapshot(live.id)?.navigation.isUnloaded == false
		else { throw Failure.liveConnectionUnloaded }
		print("ARX_TAB_UNLOAD_PHASE_LIVE_KEPT")
	}

	/// DEV-1107: closing a window asks its page with unsaved input first; Stay keeps the window,
	/// Leave closes it and unloads the page.
	@MainActor
	private static func askBeforeClosingTheWindow(
		store: StoreOf<AppFeature>,
		client: BrowserEngineClient,
		window: @MainActor () -> NSWindow?,
		url: URL,
		title: String,
		typedTitle: String
	) async throws {
		store.send(.ui(.openURLInSpace(url, store.main.sidebar.spaceID, .mainBrowser)))
		try await wait(or: .missingPage) { shows(store, title: title) }
		guard let tab = store.main.viewer.item.tab, let native = window() else { throw Failure.missingPage }

		// A person's click and key: the before-unload question needs the page's user activation,
		// and Chrome's form interaction needs typed input. The text area fills the page.
		NSApplication.shared.activate()
		native.makeKeyAndOrderFront(nil)
		try await Task.sleep(for: .milliseconds(300))
		guard let content = native.contentView else { throw Failure.missingPage }
		let point = content.convert(NSPoint(x: content.bounds.maxX - 120, y: content.bounds.midY), to: nil)
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: native.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: type == .leftMouseDown ? 1 : 0
			)
			if let event { native.sendEvent(event) }
		}
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: native.windowNumber,
				context: nil,
				characters: "a",
				charactersIgnoringModifiers: "a",
				isARepeat: false,
				keyCode: 0
			)
			if let event { native.sendEvent(event) }
		}
		try await wait(or: .askPageNotTyped) { shows(store, title: typedTitle) }
		try await wait(or: .askPageNotReported) { client.tabHoldsUnsavedInput(tab.id) }
		print("ARX_TAB_UNLOAD_PHASE_ASK_TYPED")

		// Stay: the window stays open, and so does the page.
		native.performClose(nil)
		try await answerBeforeUnload(tab.id, client: client, leave: false)
		try await wait(or: .stayClosedTheWindow) {
			store.windowIsOpen && !store.main.isClosing && native.isVisible
			&& store.withState { $0.windowCloseRequests.isEmpty }
		}
		guard client.snapshot(tab.id)?.navigation.isUnloaded == false else { throw Failure.stayClosedTheWindow }
		print("ARX_TAB_UNLOAD_PHASE_ASK_STAY")

		// Leave: the window closes, and the page unloads with the others.
		native.performClose(nil)
		try await answerBeforeUnload(tab.id, client: client, leave: true)
		try await wait(or: .leaveKeptTheWindow) { !store.windowIsOpen && !native.isVisible }
		try await wait(or: .leaveKeptThePage) { client.snapshot(tab.id)?.navigation.isUnloaded == true }
		print("ARX_TAB_UNLOAD_PHASE_ASK_LEAVE")
	}

	@MainActor
	private static func answerBeforeUnload(
		_ tab: BrowserCore.Tab.ID,
		client: BrowserEngineClient,
		leave: Bool
	) async throws {
		var dialog: BrowserPageDialog?
		try await wait(or: .askNotShown) {
			dialog = client.pageDialog(tab).flatMap { $0.kind == .beforeUnload ? $0 : nil }
			return dialog != nil
		}
		guard let dialog, client.answerPageDialog(tab, dialog, leave, nil, { true }) == .answered
		else { throw Failure.askNotShown }
	}

	private static func describe(_ history: [BrowserNavigation.Entry]) -> String {
		history
			.map { "\($0.id)\($0.isCurrent ? "*" : ""):\($0.url.absoluteString)" }
			.joined(separator: " ")
	}

	@MainActor
	private static func shows(
		_ store: StoreOf<AppFeature>,
		title: String
	) -> Bool {
		let navigation = store.main.viewer.item.navigation
		return !navigation.isLoading && navigation.errorCode == nil && navigation.title == title
	}

	@MainActor
	private static func wait(
		or failure: Failure,
		seconds: Int = 20,
		_ condition: @MainActor () -> Bool
	) async throws {
		let end = ContinuousClock.now.advanced(by: .seconds(seconds))
		while !condition() {
			guard ContinuousClock.now < end else { throw failure }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}
#endif
