#if DEBUG
import AppKit
import AppUI
import BrowserCore
import BrowserSurfaceClient
import ChromiumBrowserEngine
import Foundation
import SwiftUI
import _ComposableArchitecture

/// DEV-950's window smoke: a page with a counter and a text field floats in Page PiP, takes a
/// click and typing there, and goes back to its tab without reloading. DEV-1247 drags Page PiP
/// and a Little Arx window by the URL bar and by a button: each window moves, the control does
/// nothing, and a click without movement still works. Its drags warp the pointer, so it needs an
/// idle Mac.
///
/// It uses a disposable page, a separate store and its own window, and drives
/// `PagePictureInPictureWindows` as BrowserWindow does for the app's store.
@MainActor
internal enum PagePictureInPictureSmoke {
	internal static func run(
		engine: ChromiumBrowserEngine,
		baseURL: URL,
		profileID: Profile.ID
	) async throws {
		let pageURL = baseURL.deletingLastPathComponent().appending(path: "media/page-picture.html")
		let page = BrowserCore.Tab(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "Owned Page PiP page", url: pageURL)
		)
		let space = Space(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			name: "Owned Page PiP acceptance",
			unpinnedTabs: [page.id],
			selectedTabID: page.id
		)
		let organization = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Owned Page PiP acceptance")],
			spaces: [space],
			tabs: [page]
		)
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		initial.main.viewer.item.tab = page
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine = engine.client
			$0.browserSurface = engine.surface
		}

		guard let screen = NSScreen.main, screen.visibleFrame.width >= 700
		else { throw Failure.invalidFixture }

		let previousWindow = NSApp.keyWindow
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 420),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.title = "Arx owned Page PiP acceptance"
		window.contentView = NSHostingView(rootView: Host(store: store, surface: engine.surface))
		window.setFrameOrigin(.init(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
		let windows = PagePictureInPictureWindows()

		// BrowserWindow updates on every store change; the smoke polls.
		let updating = Task { @MainActor in
			while !Task.isCancelled {
				windows.update(store: store, surface: engine.surface) { _ in window }
				try? await Task.sleep(for: .milliseconds(25))
			}
		}
		var phase = "opening"
		defer {
			if phase != "complete" {
				let evidence = try? evidence(engine: engine, tab: page.id, url: pageURL)
				let fields: [String] = [
					"phase=\(phase)",
					"state=\(String(describing: store.pagePictureInPicture))",
					"clicks=\(String(describing: evidence?.clicks))",
					"text=\(String(describing: evidence?.text))",
					"panel=\(String(describing: windows.current?.panel.frame))",
				]
				FileHandle.standardError.write(Data(("ARX_PAGE_PICTURE_DIAGNOSTIC " + fields.joined(separator: " ") + "\n").utf8))
			}
			updating.cancel()
			store.send(.ui(.closePagePictureInPicture(focusesTab: false)))
			windows.current?.panel.close()
			store.send(.main(.viewer(.suspend)))
			window.contentView = nil
			window.close()
			engine.client.close(page.id)
			previousWindow?.makeKeyAndOrderFront(nil)
		}

		try await engine.client.open(page)
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		try await wait {
			try evidence(engine: engine, tab: page.id, url: pageURL)?.ready == true
			&& engine.isAttached(page.id)
		}
		let load = try require(try evidence(engine: engine, tab: page.id, url: pageURL)).load

		// 1. It floats, and a click on the counter reaches the page there.
		phase = "click"
		store.send(.ui(.openPagePictureInPicture(page.id)))
		try await wait {
			guard let panel = windows.current?.panel else { return false }
			return panel.isVisible && engine.isAttached(page.id) && store.pagePictureInPicture?.isFloating == true
		}
		let panel = try require(windows.current?.panel)
		guard
			panel.collectionBehavior.contains(.canJoinAllSpaces),
			panel.collectionBehavior.contains(.fullScreenAuxiliary),
			panel.level == .floating
		else { throw Failure.unexpectedState }
		try click(at: .init(x: 116, y: 38), in: panel)

		// A click sent just as the panel appears sometimes doesn't reach the page; with none
		// counted after a few seconds, it's sent once more, and then a late first one may count
		// too (DEV-965).
		var retried = false
		for _ in 0..<30 where (try evidence(engine: engine, tab: page.id, url: pageURL)?.clicks ?? 0) == 0 {
			try await Task.sleep(for: .milliseconds(100))
		}
		if (try evidence(engine: engine, tab: page.id, url: pageURL)?.clicks ?? 0) == 0 {
			FileHandle.standardError.write(Data("ARX_PAGE_PICTURE_CLICK_RETRY\n".utf8))
			try click(at: .init(x: 116, y: 38), in: panel)
			retried = true
		}
		try await wait {
			let clicks = try evidence(engine: engine, tab: page.id, url: pageURL)?.clicks ?? 0
			return retried ? clicks >= 1 : clicks == 1
		}

		// The return check compares against this, so a late first click after a retry counts once.
		let clicks = try evidence(engine: engine, tab: page.id, url: pageURL)?.clicks ?? 0
		print("ARX_PAGE_PICTURE_CLICK_SUCCESS")

		// 2. Typing in its text field reaches the page.
		phase = "typing"
		try click(at: .init(x: 116, y: 92), in: panel)
		try type("arx", in: panel)
		try await wait { try evidence(engine: engine, tab: page.id, url: pageURL)?.text == "arx" }
		print("ARX_PAGE_PICTURE_TYPING_SUCCESS")

		// 3. DEV-1247: a drag from the URL bar moves the window across the screen, to another
		// corner, and doesn't open the address; a click there still does.
		phase = "drag-address"
		let address = CGPoint(x: panel.frame.width / 2, y: BrowserMetrics.LittleArx.toolbarHeight / 2)
		var before = panel.frame.origin
		try drag(from: address, across: screen, in: panel)
		try await rests(panel, awayFrom: before)
		guard store.pagePictureInPicture?.commandBar.isPresented == false
		else { throw Failure.controlTriggered }
		try click(header: address, in: panel)
		try await wait { store.pagePictureInPicture?.commandBar.isPresented == true }
		store.send(.pagePictureInPictureCommandBar(.ui(.dismissed)))
		try await wait { store.pagePictureInPicture?.commandBar.isPresented == false }
		print("ARX_PAGE_PICTURE_DRAG_ADDRESS_SUCCESS")

		// 4. The same from Return to Tab: the window moves and the page stays floating.
		phase = "drag-button"
		let returnToTab = headerPoint(of: "page-picture-return-to-tab", in: panel) ?? headerButton(.leading, in: panel)
		before = panel.frame.origin
		try drag(from: returnToTab, across: screen, in: panel)
		try await rests(panel, awayFrom: before)
		guard store.pagePictureInPicture?.isFloating == true, windows.current?.panel === panel
		else { throw Failure.controlTriggered }
		print("ARX_PAGE_PICTURE_DRAG_BUTTON_SUCCESS")

		// 5. Little Arx's window, with its real header, behaves the same.
		phase = "little-arx-drag"
		try await LittleArxDrag.run(engine: engine, url: pageURL, profileID: profileID, on: screen)

		// 6. Back in its tab, with the same document: nothing reloaded. Return to Tab clicked
		// without moving still works.
		phase = "return"
		try click(
			header: headerPoint(of: "page-picture-return-to-tab", in: panel) ?? headerButton(.leading, in: panel),
			in: panel
		)
		try await wait {
			store.pagePictureInPicture == nil
			&& windows.current == nil
			&& engine.isAttached(page.id)
		}
		guard
			let after = try evidence(engine: engine, tab: page.id, url: pageURL),
			after.load == load,
			after.clicks == clicks,
			after.text == "arx"
		else { throw Failure.unexpectedState }
		print("ARX_PAGE_PICTURE_RETURN_SUCCESS")

		phase = "complete"
		print("ARX_PAGE_PICTURE_SMOKE_SUCCESS")
	}

	// MARK: - Input

	/// A press at `point`, from the window's top left, dragged to the middle of the screen's
	/// other half, then released: far enough to land at another corner. The pointer is warped
	/// there first, since a window's move follows the pointer; the rest of the drag is queued
	/// behind the press, as the window's move loop reads it.
	internal static func drag(
		from point: CGPoint,
		across screen: NSScreen,
		in window: NSWindow
	) throws {
		let start = window.convertPoint(toScreen: try windowPoint(point, in: window))
		let visible = screen.visibleFrame
		let end = CGPoint(
			x: start.x < visible.midX ? visible.maxX - visible.width / 4 : visible.minX + visible.width / 4,
			y: start.y < visible.midY ? visible.maxY - visible.height / 4 : visible.minY + visible.height / 4
		)
		let primary = NSScreen.screens.first?.frame.height ?? visible.maxY
		CGWarpMouseCursorPosition(.init(x: start.x, y: primary - start.y))
		let timestamp = ProcessInfo.processInfo.systemUptime
		let press = try mouse(.leftMouseDown, at: start, in: window, timestamp: timestamp)
		window.sendEvent(press)

		CGWarpMouseCursorPosition(.init(x: end.x, y: primary - end.y))
		let steps = 8
		var events: [NSEvent] = []
		for step in 1...steps {
			let fraction = CGFloat(step) / CGFloat(steps)
			let location = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
			events.append(try mouse(.leftMouseDragged, at: location, in: window, timestamp: timestamp + Double(step) * 0.016))
		}
		events.append(try mouse(.leftMouseUp, at: end, in: window, timestamp: timestamp + Double(steps + 1) * 0.016))
		for event in events.dropFirst() { NSApp.postEvent(event, atStart: false) }
		window.sendEvent(events[0])
	}

	/// A press and release at `point`, from the window's top left, without moving.
	internal static func click(
		header point: CGPoint,
		in window: NSWindow
	) throws {
		let location = window.convertPoint(toScreen: try windowPoint(point, in: window))
		let primary = NSScreen.screens.first?.frame.height ?? location.y
		CGWarpMouseCursorPosition(.init(x: location.x, y: primary - location.y))
		let timestamp = ProcessInfo.processInfo.systemUptime
		window.sendEvent(try mouse(.leftMouseDown, at: location, in: window, timestamp: timestamp))
		window.sendEvent(try mouse(.leftMouseUp, at: location, in: window, timestamp: timestamp + 0.05))
	}

	internal static func mouse(
		_ type: NSEvent.EventType,
		at screenPoint: CGPoint,
		in window: NSWindow,
		timestamp: TimeInterval
	) throws -> NSEvent {
		guard let event = NSEvent.mouseEvent(
			with: type,
			location: window.convertPoint(fromScreen: screenPoint),
			modifierFlags: [],
			timestamp: timestamp,
			windowNumber: window.windowNumber,
			context: nil,
			eventNumber: 0,
			clickCount: 1,
			pressure: type == .leftMouseUp ? 0 : 1
		)
		else { throw Failure.invalidFixture }

		return event
	}

	/// `point`, from the content's top left, in the window's coordinates.
	internal static func windowPoint(
		_ point: CGPoint,
		in window: NSWindow
	) throws -> CGPoint {
		guard let content = window.contentView, window.windowNumber > 0 else { throw Failure.invalidFixture }

		let local = CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
		return content.convert(local, to: nil)
	}

	/// The middle of the header control with this accessibility identifier, from the content's
	/// top left.
	internal static func headerPoint(
		of identifier: String,
		in window: NSWindow
	) -> CGPoint? {
		func find(_ element: Any, depth: Int) -> NSRect? {
			guard depth < 40, let node = element as? any NSAccessibilityProtocol else { return nil }
			if node.accessibilityIdentifier() == identifier { return node.accessibilityFrame() }
			for child in node.accessibilityChildren() ?? [] {
				if let frame = find(child, depth: depth + 1) { return frame }
			}
			return nil
		}
		guard let content = window.contentView, let frame = find(content, depth: 0) else { return nil }

		let local = content.convert(window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY)), from: nil)
		return .init(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
	}

	internal enum HeaderEdge {
		case leading
		case trailing
	}

	/// The middle of the header's first or last button, from the content's top left, by the
	/// header's layout: `LittleWindowHeader` insets its row by 8 points and its buttons are
	/// `BrowserMetrics.Toolbar.buttonSize` square. For when the accessibility tree, which a
	/// hosting view may not build without an assistive client, doesn't name the control.
	internal static func headerButton(
		_ edge: HeaderEdge,
		in window: NSWindow
	) -> CGPoint {
		let inset = 8 + BrowserMetrics.Toolbar.buttonSize / 2
		let width = window.contentView?.bounds.width ?? window.frame.width
		return .init(
			x: edge == .leading ? inset : width - inset,
			y: BrowserMetrics.LittleArx.toolbarHeight / 2
		)
	}

	/// Waits until the window has left `before` and stopped springing to its corner.
	internal static func rests(
		_ window: NSWindow,
		awayFrom before: CGPoint
	) async throws {
		var last = window.frame
		for _ in 0..<100 {
			try await Task.sleep(for: .milliseconds(100))
			if window.frame == last, window.frame.origin != before { return }
			last = window.frame
		}
		FileHandle.standardError.write(Data(
			"ARX_PAGE_PICTURE_DRAG_DIAGNOSTIC stayed before=\(before) frame=\(window.frame)\n".utf8
		))
		throw Failure.unexpectedState
	}

	/// A trusted click at a CSS point from the page's top left; the page sits under Little Arx's
	/// header, inset as its page card (DEV-1105).
	private static func click(
		at point: CGPoint,
		in panel: NSWindow
	) throws {
		guard let content = panel.contentView, panel.windowNumber > 0
		else { throw Failure.invalidFixture }

		let page = CGPoint(
			x: point.x + BrowserMetrics.LittleArx.pageInset,
			y: point.y + BrowserMetrics.LittleArx.toolbarHeight
		)
		let local = CGPoint(x: page.x, y: content.isFlipped ? page.y : content.bounds.height - page.y)
		let timestamp = ProcessInfo.processInfo.systemUptime
		for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: content.convert(local, to: nil),
				modifierFlags: [],
				timestamp: timestamp + Double(index) * 0.001,
				windowNumber: panel.windowNumber,
				context: nil,
				eventNumber: index + 1,
				clickCount: 1,
				pressure: type == .leftMouseDown ? 1 : 0
			)
			else { throw Failure.invalidFixture }

			panel.sendEvent(event)
		}
	}

	private static func type(
		_ text: String,
		in panel: NSWindow
	) throws {
		let timestamp = ProcessInfo.processInfo.systemUptime
		for (index, character) in text.enumerated() {
			for type in [NSEvent.EventType.keyDown, .keyUp] {
				guard let event = NSEvent.keyEvent(
					with: type,
					location: .zero,
					modifierFlags: [],
					timestamp: timestamp + Double(index) * 0.01,
					windowNumber: panel.windowNumber,
					context: nil,
					characters: String(character),
					charactersIgnoringModifiers: String(character),
					isARepeat: false,
					keyCode: 0
				)
				else { throw Failure.invalidFixture }

				panel.sendEvent(event)
			}
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

	private static func require<Value>(_ value: Value?) throws -> Value {
		guard let value else { throw Failure.unexpectedState }
		return value
	}

	private static func wait(
		seconds: Int = 15,
		file: StaticString = #fileID,
		line: Int = #line,
		function: StaticString = #function,
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
			state: "condition still false"
		)
	}

	/// The tab's window, which suppresses the page while it floats, as the app's windows do.
	private struct Host: View {
		internal let store: StoreOf<AppFeature>
		internal let surface: BrowserSurfaceClient

		internal var body: some View {
			Group {
				if let tab = store.main.viewer.item.tab {
					BrowserSurface(tabID: tab.id, client: surface)
				}
			}
			.frame(width: 640, height: 420)
			.modifier(PagePictureInPictureHostPresentation(store: store))
		}
	}

	private struct Evidence: Decodable {
		internal static let prefix: String = "Arx page picture "

		internal let ready: Bool
		internal let load: String
		internal let clicks: Int
		internal let text: String

		internal init(title: String) throws {
			guard title.utf8.count <= 2048, title.hasPrefix(Self.prefix)
			else { throw Failure.invalidFixture }

			let payload = Data(title.dropFirst(Self.prefix.count).utf8)
			self = try JSONDecoder().decode(Self.self, from: payload)
		}
	}

	internal enum Failure: Error {
		case invalidFixture
		case unexpectedState

		/// A drag that started on a control triggered it (DEV-1247).
		case controlTriggered
	}
}
#endif
