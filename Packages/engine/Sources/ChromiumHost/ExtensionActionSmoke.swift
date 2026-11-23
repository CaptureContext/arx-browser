import AppKit
import ChromiumEngine

/// Drives only the menu attached to the exact owned compiled-fixture source.
/// It does not synthesize web user activation or claim physical input coverage.
@MainActor
internal enum ExtensionActionSmoke {
	internal static func run(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		extensionID: String,
		count: Int,
		verifyNavigationInvalidation: Bool,
		verifyOutgoingLink: Bool = false,
		invokeWithShortcut: Bool = false,
		verifyRuntimeOptionsIn profileID: UUID? = nil
	) async throws {
		guard
			let window = page.view.window,
			page.navigation.url?.scheme == "http",
			page.navigation.url?.host == "127.0.0.1",
			page.navigation.url?.port.map({ $0 > 0 }) == true,
			page.navigation.url?.path == "/index.html"
		else { throw Failure.source }

		window.makeKeyAndOrderFront(nil)
		try await waitForKeyHost(in: page.view, window: window)
		try runtime.configureContentHosting(on: page, enabled: true)

		// A failing phase still releases its owned host before runtime teardown.
		defer { cleanUp("content host") { try runtime.configureContentHosting(on: page, enabled: false) } }

		let before = page.navigation
		let menu = try ownedMenu(in: page.view, window: window)
		if invokeWithShortcut {
			try await ExtensionShortcutSmoke.focus(page, runtime: runtime)
			_ = try ExtensionShortcutSmoke.press(.action, on: page)
		} else {
			menu.performActionForItem(at: 0)
		}

		let proof = "ARX_EXTENSION_ACTION:\(extensionID):count=\(count)"
		try await wait { popupVisible(proof: proof) }

		if verifyOutgoingLink {
			guard let popup = popupView(proof: proof)
			else { throw Failure.source }

			try await ExtensionPopupLinkSmoke.run(
				runtime: runtime,
				source: page,
				popup: popup,
				extensionID: extensionID,
				count: count
			)
		}

		if let profileID {
			guard let popup = popupView(proof: proof)
			else { throw Failure.source }

			try await ExtensionPopupOptionsSmoke.run(
				runtime: runtime,
				source: page,
				profileID: profileID,
				popup: popup,
				extensionID: extensionID,
				count: count
			)
		}

		guard page.navigation == before
		else { throw Failure.sourceChanged }

		try runtime.configureContentHosting(on: page, enabled: false)
		try await wait { !popupVisible(extensionID: extensionID) }
		try runtime.configureContentHosting(on: page, enabled: true)
		window.makeKeyAndOrderFront(nil)
		try await waitForKeyHost(in: page.view, window: window)
		menu.performActionForItem(at: 0)
		try await Task.sleep(for: .milliseconds(300))

		guard !popupVisible(extensionID: extensionID)
		else { throw Failure.stale }
		guard verifyNavigationInvalidation else {
			try runtime.configureContentHosting(on: page, enabled: false)
			return
		}

		let stale = try ownedMenu(in: page.view, window: window)
		try page.reload()
		try await wait {
			!page.navigation.isLoading
			&& page.navigation.title == "ARX_EXTENSION_READY:worker=true:dnr=true:count=\(count + 1)"
		}

		window.makeKeyAndOrderFront(nil)
		try await waitForKeyHost(in: page.view, window: window)
		stale.performActionForItem(at: 0)
		try await Task.sleep(for: .milliseconds(300))

		guard !popupVisible(extensionID: extensionID)
		else { throw Failure.stale }

		try runtime.configureContentHosting(on: page, enabled: false)
	}

	/// ABI48 (DEV-828): the app's path, as the site menu's extension tile takes it. With no
	/// native menu: refused while the page hosts no content, for a private page and for an
	/// extension that isn't installed; then the popup opens anchored at the app's screen point.
	internal static func runFromApp(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		privatePage: ChromiumPage,
		extensionID: String
	) async throws {
		guard runtime.supportsExtensionActions, let window = page.view.window
		else { throw Failure.source }

		window.makeKeyAndOrderFront(nil)
		try await waitForKeyHost(in: page.view, window: window)

		// Near the window's top left, where a site menu tile would be, in screen coordinates.
		let point = CGPoint(x: window.frame.minX + 80, y: window.frame.maxY - 60)

		try runtime.configureContentHosting(on: page, enabled: false)
		try expect(.unavailable) { try runtime.runExtensionAction(extensionID, on: page, at: point) }
		try runtime.configureContentHosting(on: page, enabled: true)

		// A failing phase still releases its owned host before runtime teardown.
		defer { cleanUp("content host") { try runtime.configureContentHosting(on: page, enabled: false) } }
		window.makeKeyAndOrderFront(nil)
		try await waitForKeyHost(in: page.view, window: window)

		try expect(.unavailable) { try runtime.runExtensionAction(extensionID, on: privatePage, at: point) }
		try expect(.invalid) {
			try runtime.runExtensionAction(String(repeating: "a", count: 32), on: page, at: point)
		}
		guard !popupVisible(extensionID: extensionID)
		else { throw Failure.stale }

		let before = page.navigation
		guard try runtime.runExtensionAction(extensionID, on: page, at: point) == .popup
		else { throw Failure.menu("app action had no popup") }
		try await wait { popupWindow(extensionID: extensionID) != nil }
		guard
			let popup = popupWindow(extensionID: extensionID),
			popup.frame.insetBy(dx: -48, dy: -48).contains(point)
		else {
			throw Failure.menu("popup not at the anchor \(point) frame=\(popupWindow(extensionID: extensionID)?.frame ?? .zero)")
		}
		guard page.navigation == before
		else { throw Failure.sourceChanged }

		try runtime.configureContentHosting(on: page, enabled: false)
		try await wait { !popupVisible(extensionID: extensionID) }
	}

	private static func expect(
		_ failure: ChromiumExtensionActionFailure,
		_ run: () throws -> ChromiumExtensionActionRun
	) throws {
		do {
			_ = try run()
		} catch let error as ChromiumExtensionActionFailure {
			guard error == failure else { throw Failure.menu("app action \(error), expected \(failure)") }
			return
		}
		throw Failure.menu("app action ran, expected \(failure)")
	}

	internal static func popupWindow(extensionID: String) -> NSWindow? {
		let prefix = "ARX_EXTENSION_ACTION:\(extensionID):count="
		return NSApplication.shared.windows.first { window in
			window.isVisible && window.contentView.map { contains(prefix: prefix, in: $0) } == true
		}
	}

	internal static func waitForKeyHost(
		in view: NSView,
		window: NSWindow
	) async throws {
		for _ in 0..<150 {
			try Task.checkCancellation()

			guard
				view.window === window,
				window.isVisible,
				!window.isMiniaturized,
				!view.isHiddenOrHasHiddenAncestor
			else { throw Failure.menu("key readiness lost exact owned host") }

			if window.isKeyWindow { return }
			try await Task.sleep(for: .milliseconds(20))
		}

		throw Failure.menu(
			"key readiness timed out attached=\(view.window === window) key=\(window.isKeyWindow) "
			+ "canBecomeKey=\(window.canBecomeKey) active=\(NSApplication.shared.isActive)"
		)
	}

	private static func ownedMenu(
		in view: NSView,
		window: NSWindow
	) throws -> NSMenu {
		guard let button = button(in: view)
		else { throw Failure.menu("button=false") }

		// DEV-849: the native button only anchors; nothing of it may show over the page.
		guard
			button.isTransparent,
			!button.isBordered,
			button.title.isEmpty,
			button.toolTip == nil,
			button.frame.width <= 1,
			button.frame.height <= 1
		else {
			throw Failure.menu(
				"visible button transparent=\(button.isTransparent) bordered=\(button.isBordered) "
				+ "title=\(!button.title.isEmpty) size=\(button.frame.size)"
			)
		}

		guard
			button.window === window,
			window.isKeyWindow,
			window.isVisible,
			!window.isMiniaturized,
			!button.isHiddenOrHasHiddenAncestor,
			let menu = button.menu,
			let delegate = menu.delegate
		else {
			throw Failure.menu(
				"attached=\(button.window === window) key=\(window.isKeyWindow) "
				+ "visible=\(window.isVisible) mini=\(window.isMiniaturized) "
				+ "hidden=\(button.isHiddenOrHasHiddenAncestor) menu=\(button.menu != nil) "
				+ "delegate=\(button.menu?.delegate != nil)"
			)
		}

		delegate.menuNeedsUpdate?(menu)

		guard
			menu.numberOfItems >= 1,
			let item = menu.item(at: 0),
			item.isEnabled,
			item.title.hasPrefix("Arx Disposable Extension Fixture (")
		else {
			let hasFixtureTitle = menu.item(at: 0)?.title.hasPrefix("Arx Disposable Extension Fixture (") == true
			throw Failure.menu(
				"items=\(menu.numberOfItems) enabled=\(menu.item(at: 0)?.isEnabled == true) "
				+ "fixtureTitle=\(hasFixtureTitle)"
			)
		}

		return menu
	}

	private static func button(in view: NSView) -> NSButton? {
		if let button = view as? NSButton, button.identifier?.rawValue == "ArxExtensionActions" {
			return button
		}

		return view.subviews.lazy.compactMap { button(in: $0) }.first
	}

	private static func popupView(proof: String) -> NSView? {
		func find(in view: NSView) -> NSView? {
			if view.identifier?.rawValue == proof { return view }
			return view.subviews.lazy.compactMap { find(in: $0) }.first
		}

		return NSApplication.shared.windows.lazy
			.filter(\.isVisible)
			.compactMap { $0.contentView.flatMap { find(in: $0) } }
			.first
	}

	private static func popupVisible(proof: String) -> Bool {
		NSApplication.shared.windows.contains { window in
			window.isVisible && window.contentView.map { contains(proof: proof, in: $0) } == true
		}
	}

	internal static func popupVisible(extensionID: String) -> Bool {
		let prefix = "ARX_EXTENSION_ACTION:\(extensionID):count="
		return NSApplication.shared.windows.contains { window in
			window.isVisible && window.contentView.map { contains(prefix: prefix, in: $0) } == true
		}
	}

	private static func contains(
		proof: String,
		in view: NSView
	) -> Bool {
		view.identifier?.rawValue == proof || view.subviews.contains { contains(proof: proof, in: $0) }
	}

	private static func contains(
		prefix: String,
		in view: NSView
	) -> Bool {
		view.identifier?.rawValue.hasPrefix(prefix) == true
		|| view.subviews.contains { contains(prefix: prefix, in: $0) }
	}

	private static func wait(_ ready: () -> Bool) async throws {
		for _ in 0..<300 {
			try Task.checkCancellation()

			if ready() { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.timeout
	}

	private enum Failure: Error {
		case source
		case sourceChanged
		case stale
		case timeout
		case menu(String)
	}
}
