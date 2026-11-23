#if DEBUG
import AppKit
import AppUI
import BrowserCaptureClient
import BrowserCore
import ChromiumBrowserEngine
import CryptoKit
import Foundation
import LocalUIExtensions
import PageCaptureFeature
import PeekFeature
import _ComposableArchitecture

/// The app's own menus on the ABI48 engine (DEV-815, DEV-819), in the owned app fixture.
///
/// - Link menu: a real right click on a link in the main window's page reaches the engine,
///   which reports the link back; the app's menu has Open Link in New Window, Open Link in
///   Private Window, Download Linked File and Share…. Open Link in New Window is chosen
///   through the item's own action and opens the link in a new window of the source's space.
/// - Save Page As: on a PDF that's still loading, the app offers only PDF and writes the
///   PDF's own bytes, through the app's `PageDocuments` with only the Save panel replaced.
@MainActor
internal enum PageMenusSmoke {
	internal enum Failure: Error {
		case invalidFixture
		case timedOut(String)
		case wrongMenu([String])
		case wrongWindow
		case notLoading
		case wrongFormats([PageSaveFormat])
		case wrongBytes(Int)

		/// The alert shown, and the error behind it.
		case failed(String, cause: String)
	}

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		capture: BrowserCaptureClient,
		source: PeekFeature.Source,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let sourceTab = source.tabID,
			let digest = ProcessInfo.processInfo.environment["ARX_SAVE_PAGE_SMOKE_PDF_SHA256"],
			let originalURL = engine.client.snapshot(sourceTab)?.navigation.url
		else { throw Failure.invalidFixture }

		let directory = baseURL.deletingLastPathComponent()
		func navigate(_ url: URL) {
			store.send(.main(.viewer(.command(.navigate(url), in: source.paneID, tabID: sourceTab))))
		}

		try await linkMenu(
			store: store,
			engine: engine,
			source: source,
			sourceTab: sourceTab,
			window: window,
			directory: directory,
			navigate: navigate
		)
		try await savePage(
			store: store,
			engine: engine,
			capture: capture,
			source: source,
			sourceTab: sourceTab,
			directory: directory,
			digest: digest,
			navigate: navigate
		)

		navigate(originalURL)
		try await wait("restore") {
			let navigation = engine.client.snapshot(sourceTab)?.navigation
			return navigation?.url == originalURL && navigation?.isLoading == false
		}
	}

	// MARK: - Link menu

	private static func linkMenu(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		source: PeekFeature.Source,
		sourceTab: BrowserCore.Tab.ID,
		window: NSWindow,
		directory: URL,
		navigate: (URL) -> Void
	) async throws {
		let page = directory.appending(path: "page-menus.html")

		// The engine gives the app only links on their scheme's default port; nothing listens
		// there, so the new window is checked by the address its tab opened, not the page.
		guard let target = URL(string: "http://127.0.0.1/page-menus-target.html")
		else { throw Failure.invalidFixture }
		navigate(page)
		try await wait("link page") {
			let navigation = engine.client.snapshot(sourceTab)?.navigation
			return navigation?.title == "Arx page menus" && navigation?.isLoading == false
		}
		guard let view = engine.contentHostFixtureView(sourceTab), view.window === window
		else { throw Failure.invalidFixture }

		let openInNewTab = String.localized(.appUI.links.openInNewTab)
		let openInNewWindow = String.localized(.appUI.links.openInNewWindow)
		let required = [
			openInNewTab,
			openInNewWindow,
			String.localized(.appUI.links.openInPrivateWindow),
			String.localized(.appUI.links.downloadLinkedFile),
			String.localized(.appUI.links.share),
		]

		// No proxy link rule matches 127.0.0.1, so the menu leaves the proxy items out (DEV-1262).
		let leftOut = [
			String.localized(.appUI.links.shareProxy),
			String.localized(.appUI.links.copyProxy),
			String.localized(.appUI.links.copyMenu.proxy),
		]

		// The link menu is the app's own NSMenu; read it and choose as a click would.
		var titles: [String]?
		var seen: [[String]] = []
		let observer = NotificationCenter.default.addObserver(
			forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
		) { notification in
			nonisolated(unsafe) let object = notification.object
			MainActor.assumeIsolated {
				guard let menu = object as? NSMenu, menu.supermenu == nil else { return }
				seen.append(menu.items.filter { !$0.isSeparatorItem }.map(\.title))
				guard menu.items.contains(where: { $0.title == openInNewTab }) else {
					// Not the link menu: close it so the run can report what it was.
					RunLoop.main.perform(inModes: [.eventTracking, .default]) { menu.cancelTracking() }
					return
				}

				// Copy ▸'s items count as the menu's own (DEV-1162).
				titles = menu.items.flatMap { [$0] + ($0.submenu?.items ?? []) }
					.filter { !$0.isSeparatorItem }
					.map(\.title)
				RunLoop.main.perform(inModes: [.eventTracking, .default]) {
					if let index = menu.items.firstIndex(where: { $0.title == openInNewWindow }) {
						menu.performActionForItem(at: index)
					}
					menu.cancelTracking()
				}
			}
		}
		defer { NotificationCenter.default.removeObserver(observer) }

		let originalWindows = Set(store.windows.ids)

		// Fixture windows aren't always key; the menu needs only a visible window.
		window.makeKeyAndOrderFront(nil)
		try await Task.sleep(for: .milliseconds(250))

		// The link's box is at (40, 160)–(440, 280) in the page, clear of the window's edges.
		let local = NSPoint(x: 200, y: view.isFlipped ? 220 : view.bounds.height - 220)
		let point = view.convert(local, to: nil)
		let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
		for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: 1
			)
			else { throw Failure.invalidFixture }
			window.sendEvent(event)
		}
		do {
			try await wait("link menu") { titles != nil }
		} catch {
			// Where the click went, for a menu that never opened.
			var chain: [String] = []
			var current = hit
			while let next = current, chain.count < 8 {
				chain.append(String(describing: type(of: next)))
				current = next.superview
			}
			let evidence = "ARX_PAGE_MENUS_SMOKE_LINK_NO_MENU key=\(window.isKeyWindow) "
				+ "view=\(view.bounds.size) flipped=\(view.isFlipped) inside=\(hit.map { $0 === view || $0.isDescendant(of: view) } ?? false) "
				+ "hit=\(chain.joined(separator: "<")) menus=\(seen)\n"
			FileHandle.standardError.write(Data(evidence.utf8))
			throw error
		}
		let shown = titles ?? []
		guard required.allSatisfy(shown.contains), !leftOut.contains(where: shown.contains)
		else { throw Failure.wrongMenu(shown) }
		print("ARX_PAGE_MENUS_SMOKE_LINK_ITEMS")

		// Open Link in New Window: a new window in the source's space shows the link.
		try await wait("new window") {
			store.windows.contains { candidate in
				guard
					!originalWindows.contains(candidate.id),
					let tab = candidate.viewer.item.tab
				else { return false }
				return store.workspace.tabs[id: tab.id]?.restoration.url == target
				|| engine.client.snapshot(tab.id)?.navigation.url == target
			}
		}
		guard
			let opened = store.windows.first(where: { !originalWindows.contains($0.id) }),
			opened.sidebar.spaceID == source.spaceID,
			let tab = opened.viewer.item.tab,
			tab.profileID == source.profileID
		else { throw Failure.wrongWindow }

		store.send(.windows(.element(id: opened.id, action: .ui(.closeTab))))
		try await wait("new window's tab closed") {
			!store.workspace.tabs.ids.contains(tab.id) && engine.client.snapshot(tab.id) == nil
		}
		store.send(.ui(.closeAdditionalWindow(opened.id)))
		try await wait("new window closed") { store.windows[id: opened.id] == nil }
		print("ARX_PAGE_MENUS_SMOKE_LINK_NEW_WINDOW")
	}

	// MARK: - Save Page As

	/// What the replaced Save panel saw and what the app wrote.
	@MainActor
	private final class Saving {
		internal var formats: [PageSaveFormat]?
		internal var written: Data?
		internal var alert: String?
		internal var error: (any Error)?
	}

	private static func savePage(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		capture: BrowserCaptureClient,
		source: PeekFeature.Source,
		sourceTab: BrowserCore.Tab.ID,
		directory: URL,
		digest: String,
		navigate: (URL) -> Void
	) async throws {
		let pdf = directory.appending(path: "inspection/slow.pdf")
		navigate(pdf)

		// The fixture sends the PDF's second half after 4 seconds: it commits as a PDF and
		// is still loading here.
		try await wait("loading PDF") {
			guard let navigation = engine.client.snapshot(sourceTab)?.navigation
			else { return false }
			return navigation.url == pdf && navigation.isLoading && engine.client.documentType(sourceTab) == .pdf
		}

		let saving = Saving()
		let destination = FileManager.default.temporaryDirectory
			.appending(path: "arx-save-page-smoke-\(UUID().uuidString).pdf")
		let documents = Store(initialState: store.state) {
			PageDocuments()
		} withDependencies: {
			$0.browserEngine = engine.client
			$0.browserCapture = capture
			$0.pageDocuments.pageLayout = { PageLayout() }
			$0.pageDocuments.chooseSaveDestination = { _, formats, _ in
				saving.formats = formats
				return formats.contains(.pdf) ? (destination, .pdf) : nil
			}
			$0.pageDocuments.write = { data, url in
				guard url == destination else { throw CocoaError(.fileWriteInvalidFileName) }
				await MainActor.run { saving.written = data }
			}
			$0.pageDocuments.alert = { saving.alert = $0 }
			$0.pageDocuments.failed = { saving.error = $0 }
		}
		guard engine.client.snapshot(sourceTab)?.navigation.isLoading == true
		else { throw Failure.notLoading }

		documents.send(.ui(.savePage(CaptureSource(
			host: .pane(windowID: source.windowID, paneID: source.paneID),
			tabID: sourceTab,
			profileID: source.profileID,
			spaceID: source.spaceID
		))))
		try await wait("Save Page As", seconds: 20) {
			saving.written != nil || saving.alert != nil || saving.formats.map { !$0.contains(.pdf) } == true
		}
		if let alert = saving.alert {
			throw Failure.failed(alert, cause: saving.error.map { String(describing: $0) } ?? "unknown")
		}
		guard saving.formats == [.pdf] else { throw Failure.wrongFormats(saving.formats ?? []) }
		guard
			let written = saving.written,
			SHA256.hash(data: written).map({ String(format: "%02x", $0) }).joined() == digest
		else { throw Failure.wrongBytes(saving.written?.count ?? -1) }
		print("ARX_PAGE_MENUS_SMOKE_SAVE_LOADING_PDF")
	}

	private static func wait(
		_ name: String,
		seconds: Int = 10,
		_ condition: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure.timedOut(name) }
			try await Task.sleep(for: .milliseconds(25))
		}
	}
}
#endif
