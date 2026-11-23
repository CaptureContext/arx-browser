import AppKit
import ChromiumEngine

/// DEV-956: the fixture in a private window its profile opened. Allowed in private windows,
/// its action opens its popup there, and the popup's usual `{active: true, currentWindow:
/// true}` query finds the private page. Its worker sees the private window too, as
/// incognito (DEV-973). Its link item shows on the private page and reaches it
/// through the tabs API, which lists the page as incognito. Disallowed again, the action is
/// refused and the item is gone.
@MainActor
internal enum ExtensionPrivateSmoke {
	private enum Failure: Error, CustomStringConvertible {
		case source
		case action(String)
		case menu(String)
		case timedOut(String)

		var description: String {
			switch self {
			case .source: "source"
			case let .action(detail): "action \(detail)"
			case let .menu(detail): "menu \(detail)"
			case let .timedOut(detail): "timed-out \(detail)"
			}
		}
	}

	/// The link contexts a right click brought, in order.
	@MainActor
	private final class Received {
		internal var contexts: [ChromiumLinkContext]

		internal init() {
			self.contexts = []
		}
	}

	private static let itemTitle: String = "Arx fixture item"

	/// `page` is a private page whose opener allows the fixture in private windows, shown in
	/// its own window and loaded with the fixture's content script.
	internal static func runAllowed(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		url: URL,
		extensionID: String
	) async throws {
		try await openPopup(runtime: runtime, page: page, extensionID: extensionID)
		try await queryFromPopup(runtime: runtime, page: page, url: url, extensionID: extensionID)

		try page.navigate(to: url)
		try await wait("ready") {
			page.navigation.title.hasPrefix("ARX_EXTENSION_READY:worker=true:dnr=true:count=")
			&& !page.navigation.isLoading
		}

		let item = "ARX_EXTENSION_MENU:\(extensionID):incognito=true:query=true"
		try await chooseItem(runtime: runtime, page: page) { menu in
			guard let index = menu.items.firstIndex(where: { $0.title == itemTitle })
			else { throw Failure.menu("item missing in [\(menu.items.map(\.title).joined(separator: "|"))]") }

			menu.performActionForItem(at: index)
		}
		try await wait("menu-title") { page.navigation.title == item }
	}

	/// The same page after its opener disallowed the fixture in private windows.
	internal static func runDisallowed(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		extensionID: String
	) async throws {
		try withContentHosting(runtime: runtime, page: page) {
			do {
				_ = try runtime.runExtensionAction(extensionID, on: page, at: try anchor(of: page))
				throw Failure.action("ran while disallowed")
			} catch ChromiumExtensionActionFailure.invalid {
				// Not one the opener allows in private windows any more.
			}
		}
		try await chooseItem(runtime: runtime, page: page) { menu in
			guard !menu.items.contains(where: { $0.title == itemTitle })
			else { throw Failure.menu("item shown while disallowed") }
		}
	}

	private static func openPopup(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		extensionID: String
	) async throws {
		guard let window = page.view.window
		else { throw Failure.source }

		window.makeKeyAndOrderFront(nil)
		try runtime.configureContentHosting(on: page, enabled: true)

		// A failing phase still releases its owned host before runtime teardown.
		defer { try? runtime.configureContentHosting(on: page, enabled: false) }
		try await ExtensionActionSmoke.waitForKeyHost(in: page.view, window: window)

		guard try runtime.runExtensionAction(extensionID, on: page, at: try anchor(of: page)) == .popup
		else { throw Failure.action("no popup") }
		try await wait("popup") { ExtensionActionSmoke.popupWindow(extensionID: extensionID) != nil }

		try runtime.configureContentHosting(on: page, enabled: false)
		try await wait("popup-closed") { !ExtensionActionSmoke.popupVisible(extensionID: extensionID) }
	}

	/// The fixture's armed page: its first action click sets a popup that queries the active tab
	/// of its current window and messages it, which must be this private page.
	private static func queryFromPopup(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		url: URL,
		extensionID: String
	) async throws {
		guard
			let window = page.view.window,
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		else { throw Failure.source }

		components.queryItems = [.init(name: "tabs_action", value: "1")]
		guard let armedURL = components.url
		else { throw Failure.source }

		try page.navigate(to: armedURL)
		try await wait("armed") { page.navigation.title == "ARX_EXTENSION_TABS_ARMED:\(extensionID)" }

		window.makeKeyAndOrderFront(nil)
		try runtime.configureContentHosting(on: page, enabled: true)
		defer { try? runtime.configureContentHosting(on: page, enabled: false) }
		try await ExtensionActionSmoke.waitForKeyHost(in: page.view, window: window)

		guard try runtime.runExtensionAction(extensionID, on: page, at: try anchor(of: page)) == .clicked
		else { throw Failure.action("armed action opened a popup") }

		// DEV-973: from its worker the extension sees this private window, its current and
		// last focused one, as incognito, and its one tab.
		let windowFacts = [
			"index=0",
			"active=true",
			"window=1/0",
			"indexed=true",
			"current=0",
			"focused=true",
			"windows=1/1",
			"fetched=true",
			"own=true",
			"incognito=true",
		].joined(separator: ":")
		try await wait("tabs-action \(windowFacts)") {
			page.navigation.title.hasPrefix("ARX_EXTENSION_TABS:action:\(extensionID):")
			&& page.navigation.title.hasSuffix(":\(windowFacts)")
		}

		try await ExtensionActionSmoke.waitForKeyHost(in: page.view, window: window)
		guard try runtime.runExtensionAction(extensionID, on: page, at: try anchor(of: page)) == .popup
		else { throw Failure.action("no tabs popup") }
		let found = "ARX_EXTENSION_TABS:popup:\(extensionID):active=1:window=true:index=0:highlighted=true"
		try await wait("popup-query \(found)") { page.navigation.title == found }
	}

	private static func withContentHosting(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		_ body: () throws -> Void
	) throws {
		try runtime.configureContentHosting(on: page, enabled: true)
		defer { try? runtime.configureContentHosting(on: page, enabled: false) }
		try body()
	}

	/// Right-clicks the fixture's link at the page's top left, adds the extensions' items to a
	/// menu as the app's link menu does, and hands it to `choose`.
	private static func chooseItem(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		choose: (NSMenu) throws -> Void
	) async throws {
		guard let window = page.view.window
		else { throw Failure.source }

		window.makeKeyAndOrderFront(nil)
		let events = runtime.linkContextEvents()
		let received: Received = .init()
		let observation = Task { @MainActor in
			for await context in events { received.contexts.append(context) }
		}
		defer { observation.cancel() }
		let local = NSPoint(x: 20, y: page.view.isFlipped ? 20 : page.view.bounds.height - 20)
		let point = page.view.convert(local, to: nil)
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
			else { throw Failure.source }

			window.sendEvent(event)
		}

		try await wait("link-context") { !received.contexts.isEmpty }
		guard let context = received.contexts.first, context.pageID == page.identifier
		else { throw Failure.menu("link context for another page") }

		defer { runtime.dismissLinkContext(page: page.identifier, token: context.token) }
		let menu = NSMenu()
		_ = runtime.appendLinkExtensionItems(context, on: page, to: menu)
		try choose(menu)
	}

	/// Near the window's top left, where a site menu tile would be, in screen coordinates.
	private static func anchor(of page: ChromiumPage) throws -> CGPoint {
		guard let window = page.view.window
		else { throw Failure.source }

		return CGPoint(x: window.frame.minX + 80, y: window.frame.maxY - 60)
	}

	private static func wait(
		_ name: String,
		until condition: () -> Bool
	) async throws {
		for _ in 0..<300 {
			try Task.checkCancellation()
			if condition() { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.timedOut(name)
	}
}
