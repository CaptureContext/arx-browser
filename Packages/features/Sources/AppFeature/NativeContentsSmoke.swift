#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import PeekFeature
import _ComposableArchitecture

/// Owned loopback pages exercise native popup blocking and actual child adoption.
/// Native input activates the allowed request; the blocked request uses its real
/// source indicator's menu action, with no script evaluation or permission grant.
@MainActor
internal enum NativeContentsSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		source: PeekFeature.Source,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65_535).contains(parts.port ?? 0),
			parts.path == "/index.html",
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil,
			let sourceTab = source.tabID,
			let original = engine.client.snapshot(sourceTab)?.navigation
		else { throw Failure.invalidFixture }

		for phase in ["allowed", "blocked"] {
			let url = baseURL.deletingLastPathComponent().appending(path: "peek-popup.html")
				.appending(queryItems: [.init(name: "phase", value: phase)])
			let originalTabIDs = Set(store.workspace.tabs.map(\.id))
			let originalLittleWindows = Set(store.littleWindows.ids)
			store.send(.ui(.peekURLFromSource(url, source)))
			try await wait {
				guard let peek = store.peeks.first(where: { $0.source == source })
				else { return false }

				return peek.phase == .idle && engine.isAttached(peek.tab.id)
				&& engine.client.snapshot(peek.tab.id)?.navigation.title == "Arx Popup \(phase)"
			}

			guard
				let peek = store.peeks.first(where: { $0.source == source }),
				let view = engine.contentHostFixtureView(peek.tab.id),
				view.window === window,
				engine.client.snapshot(peek.tab.id)?.navigation.url == url
			else { throw Failure.missingSource }

			window.makeKeyAndOrderFront(nil)
			engine.surface.focus(peek.tab.id)
			if phase == "allowed" {
				try await waitUntilClickable(view, in: window)
				try click(view: view, window: window)
			} else {
				try await wait { blockedButton(in: view)?.isHidden == false }
				guard
					Set(store.workspace.tabs.map(\.id)) == originalTabIDs,
					let indicator = blockedButton(in: view),
					let menu = indicator.menu,
					menu.numberOfItems == 1,
					menu.item(at: 0)?.title.contains("peek-popup-child.html") == true,
					menu.item(at: 0)?.title.contains("phase=") == false
				else { throw Failure.blockingFailed }

				// Dispatch the exact owned native menu item through its normal target.
				menu.performActionForItem(at: 0)
			}

			// A popup from Peek opens in a new Little Arx with its opener (DEV-1186): never a new
			// window or a tab of the space.
			let windows = store.windows.ids
			try await wait(context: {
				let added = store.littleWindows.filter { !originalLittleWindows.contains($0.id) }
				let title = added.first.flatMap { engine.client.snapshot($0.tab.id)?.navigation.title } ?? "nil"
				return "\(phase) host=\(source.host) littleAdded=\(added.count) "
					+ "tabsAdded=\(store.workspace.tabs.count - originalTabIDs.count) "
					+ "windows=\(store.windows.count) childTitle=\(title.hasPrefix("Arx Popup") ? title : "other")"
			}) {
				let added = store.littleWindows.filter { !originalLittleWindows.contains($0.id) }
				guard added.count == 1, let child = added.first else { return false }

				return child.tab.profileID == source.profileID
				&& child.openerWindowID == source.windowID
				&& engine.client.snapshot(child.tab.id)?.navigation.title == "Arx Popup child \(phase)"
			}

			let sourceNavigation = engine.client.snapshot(sourceTab)?.navigation
			let mismatch = [
				Set(store.workspace.tabs.map(\.id)) == originalTabIDs ? nil : "tabs",
				store.windows.ids == windows ? nil : "windows",
				store.peeks[id: peek.id]?.tab.id == peek.tab.id ? nil : "peekTab",
				sourceNavigation == original ? nil : "sourceNavigation",
				store.workspace.tabs.ids.contains(peek.tab.id) ? "peekTabInWorkspace" : nil,
			].compactMap(\.self)
			if !mismatch.isEmpty {
				let detail = sourceNavigation.map { navigation in

					// Name the fields that moved, never their values: addresses stay out of logs.
					zip(Mirror(reflecting: navigation).children, Mirror(reflecting: original).children)
						.filter { String(describing: $0.value) != String(describing: $1.value) }
						.compactMap(\.0.label)
						.joined(separator: ",")
				} ?? "missing"
				print("ARX_NATIVE_CONTENTS_SMOKE_MISMATCH phase=\(phase) host=\(source.host) "
					+ "failed=\(mismatch.joined(separator: ",")) sourceFields=\(detail)")
			}
			guard
				let child = store.littleWindows.first(where: { !originalLittleWindows.contains($0.id) }),
				Set(store.workspace.tabs.map(\.id)) == originalTabIDs,
				store.windows.ids == windows,
				store.peeks[id: peek.id]?.tab.id == peek.tab.id,
				engine.client.snapshot(sourceTab)?.navigation == original,
				!store.workspace.tabs.ids.contains(peek.tab.id)
			else { throw Failure.sourceChanged }

			store.send(.littleWindows(.element(id: child.id, action: .ui(.close))))
			try await wait {
				store.littleWindows[id: child.id] == nil
				&& engine.client.snapshot(child.tab.id) == nil
			}
			if phase == "allowed" {
				let context: PageConsentSmoke.Context = switch source.host {
				case .window: .main
				case .littleArx: .little
				}
				try await PageConsentSmoke.run(
					store: store,
					tabID: peek.tab.id,
					view: view,
					window: window,
					baseURL: baseURL,
					context: context,
					navigate: { try await engine.client.command(peek.tab.id, .navigate($0)) },
					isLoaded: { engine.client.snapshot(peek.tab.id)?.navigation.title == $0 }
				)
			}

			store.send(.peeks(.element(id: peek.id, action: .ui(.close))))
			try await wait { store.peeks[id: peek.id] == nil && engine.isAttached(sourceTab) }
			guard engine.client.snapshot(sourceTab)?.navigation == original
			else { throw Failure.sourceChanged }
		}

		switch source.host {
		case .window: print("ARX_PEEK_POPUP_MAIN_SUCCESS")
		case .littleArx: print("ARX_PEEK_POPUP_LITTLE_SUCCESS")
		}
	}


	internal static func runPrivate(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		baseURL: URL,
		window: @MainActor (UUID) -> NSWindow?
	) async throws {
		guard
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65_535).contains(parts.port ?? 0),
			parts.path == "/index.html",
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil
		else { throw Failure.invalidFixture }

		let ordinary = store.workspace
		let profileID = Profile.ID(rawValue: UUID())
		let windowID = UUID()
		let spaceID = Space.ID(rawValue: UUID())
		let url = baseURL.deletingLastPathComponent().appending(path: "peek-popup.html")
			.appending(queryItems: [.init(name: "phase", value: "private")])
		let source = BrowserCore.Tab(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "Private popup source", url: url)
		)
		try engine.client.preparePrivateProfile(profileID, nil)
		store.send(.event(.privateWindowReady(windowID, profileID, spaceID, linkedOpener: nil)))
		let organization = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Private popup fixture")],
			spaces: [.init(
				id: spaceID,
				profileID: profileID,
				name: "Private popup fixture",
				unpinnedTabs: [source.id],
				selectedTabID: source.id
			)],
			tabs: [source]
		)
		store.send(.windows(.element(id: windowID, action: .reconcile(organization))))
		guard let paneID = store.windows[id: windowID]?.viewer.activePaneID
		else { throw Failure.missingSource }

		// Reconciliation keeps the window's own selection; present the source.
		store.send(.windows(.element(id: windowID, action: .present(source.id, in: paneID))))
		store.send(.windows(.element(id: windowID, action: .commandBar(.ui(.dismissed)))))
		try await wait {
			engine.isAttached(source.id)
			&& engine.client.snapshot(source.id)?.navigation.title == "Arx Popup private"
			&& window(windowID) != nil
		}

		guard
			let sourceWindow = window(windowID),
			let view = engine.contentHostFixtureView(source.id),
			view.window === sourceWindow
		else { throw Failure.missingSource }

		sourceWindow.makeKeyAndOrderFront(nil)
		engine.surface.focus(source.id)
		try await waitUntilClickable(view, in: sourceWindow)
		try click(view: view, window: sourceWindow)
		try await wait {
			store.windows.contains { host in
				host.id != windowID && host.isPrivate
				&& host.sidebar.space.profileID == profileID
				&& host.sidebar.organization.tabs.contains { tab in
					engine.client.snapshot(tab.id)?.navigation.title == "Arx Popup child private"
				}
			}
		}

		guard
			let childHost = store.windows.first(where: {
				$0.id != windowID && $0.isPrivate && $0.sidebar.space.profileID == profileID
			}),
			let child = childHost.sidebar.organization.tabs.first
		else { throw Failure.missingSource }

		try requireUnchanged(store.workspace, ordinary, check: "private.childOpened")

		store.send(.ui(.requestClosePrivateWindow(windowID)))
		try await wait {
			store.windows[id: windowID] == nil && engine.client.snapshot(source.id) == nil
		}

		guard
			store.windows[id: childHost.id]?.isPrivate == true,
			engine.client.snapshot(child.id)?.navigation.title == "Arx Popup child private"
		else { throw Failure.missingSource }

		try requireUnchanged(store.workspace, ordinary, check: "private.sourceClosed")

		guard
			let childWindow = window(childHost.id),
			let childView = engine.contentHostFixtureView(child.id),
			childView.window === childWindow
		else { throw Failure.missingSource }

		try await PageConsentSmoke.run(
			store: store,
			tabID: child.id,
			view: childView,
			window: childWindow,
			baseURL: baseURL,
			context: .privatePage,
			navigate: { try await engine.client.command(child.id, .navigate($0)) },
			isLoaded: { engine.client.snapshot(child.id)?.navigation.title == $0 }
		)
		try requireUnchanged(store.workspace, ordinary, check: "private.consent")

		store.send(.ui(.requestClosePrivateWindow(childHost.id)))
		try await wait {
			store.windows[id: childHost.id] == nil && engine.client.snapshot(child.id) == nil
		}

		try requireUnchanged(store.workspace, ordinary, check: "private.childClosed")

		print("ARX_PRIVATE_POPUP_SUCCESS")
	}

	/// Private windows must leave the ordinary workspace as it was. On a change this logs
	/// which check saw it and which tabs and fields changed, never their URLs or titles.
	private static func requireUnchanged(
		_ workspace: BrowserOrganization,
		_ ordinary: BrowserOrganization,
		check: String
	) throws {
		guard workspace != ordinary else { return }

		let changedTabs = workspace.tabs.compactMap { tab -> String? in
			guard let before = ordinary.tabs[id: tab.id] else { return "\(tab.id.rawValue):added" }
			guard before != tab else { return nil }

			let fields = SmokeDiagnostics.changes(from: before, to: tab)
			let restoration = SmokeDiagnostics.changes(from: before.restoration, to: tab.restoration)
			return "\(tab.id.rawValue):\(fields)(restoration:\(restoration))"
		}
		let removedTabs = ordinary.tabs.ids.subtracting(workspace.tabs.ids).map { "\($0.rawValue):removed" }
		let message = "ARX_NATIVE_CONTENTS_SMOKE_MISMATCH check=\(check) "
		+ "workspace=\(SmokeDiagnostics.changes(from: ordinary, to: workspace)) "
		+ "tabs=[\((changedTabs + removedTabs).joined(separator: ";"))] "
		+ "\(SmokeDiagnostics.focus())\n"
		FileHandle.standardError.write(Data(message.utf8))
		throw Failure.sourceChanged
	}

	private static func blockedButton(in view: NSView) -> NSButton? {
		if let button = view as? NSButton, button.identifier?.rawValue == "ArxBlockedPopups" {
			return button
		}

		return view.subviews.lazy.compactMap { blockedButton(in: $0) }.first
	}

	/// A real Shift-click on a page link opens Peek, with no new window or tab, and
	/// the source page stays where it was.
	internal static func shiftClick(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		source: PeekFeature.Source,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let sourceTab = source.tabID,
			let original = engine.client.snapshot(sourceTab)?.navigation,
			let originalURL = original.url,
			!original.title.isEmpty,
			store.workspace.tabs.ids.contains(sourceTab)
		else { throw Failure.invalidFixture }

		let directory = baseURL.deletingLastPathComponent()
		try await engine.client.command(sourceTab, .navigate(directory.appending(path: "shift-link.html")))
		try await wait { engine.client.snapshot(sourceTab)?.navigation.title == "Arx Shift link" }
		var ready: NSView?
		window.makeKeyAndOrderFront(nil)

		// DEV-1191: the click goes only where nothing else in the window covers the link, as AppKit
		// sends it to the view it hits and Chromium ignores one that doesn't hit the page.
		try await wait(context: {
			let view = engine.contentHostFixtureView(sourceTab)
			return "view=\(view != nil) sameWindow=\(view?.window === window) "
			+ "hidden=\(view?.isHiddenOrHasHiddenAncestor ?? true) key=\(window.isKeyWindow) "
			+ "size=\(view?.bounds.size ?? .zero) hit=\(view.map { clickHit(on: $0, in: window) } ?? .notClicked) "
			+ "cursorOverWindow=\(window.frame.contains(NSEvent.mouseLocation))"
		}) {
			ready = engine.contentHostFixtureView(sourceTab)
			guard let view = ready else { return false }

			return view.window === window && !view.isHiddenOrHasHiddenAncestor && window.isKeyWindow
			&& clickHit(on: view, in: window) == .page
		}
		guard let view = ready else { throw Failure.missingSource }

		let windows = store.windows.count
		let tabs = store.workspace.tabs.count
		let lastRequest = engine.lastNewContents?.sequence ?? 0
		var hit = clickHit(on: view, in: window)

		// Each step from the click to the Peek, so a timeout says which one is behind.
		let look: () -> ShiftClickCheck = {
			let record = engine.lastNewContents.flatMap { $0.sequence > lastRequest ? $0 : nil }
			let route = SmokeDiagnostics.lastNewContentsRoute.flatMap { last in
				last.sequence == record?.sequence ? last.route : nil
			}
			let peek = store.peeks.first(where: { $0.source == source }).map { peek in
				let navigation = engine.client.snapshot(peek.tab.id)?.navigation
				return ShiftClickCheck.Peek(
					isIdle: peek.phase == .idle,
					isLoading: navigation?.isLoading ?? true,
					page: .init(title: navigation?.title)
				)
			}
			let sourceTitle = engine.client.snapshot(sourceTab)?.navigation.title
			return ShiftClickCheck(
				hit: hit,
				source: .init(title: sourceTitle),
				pageSaw: .init(title: sourceTitle),
				request: record.map { .init($0.outcome) },
				route: route,
				peek: peek,
				windowsAdded: store.windows.count - windows,
				tabsAdded: store.workspace.tabs.count - tabs
			)
		}

		// A page that has only just been drawn can miss a click Chromium hasn't the means to route
		// to it yet: it's sent again only while the page saw no mouse-down and nothing opened, so
		// one Shift-click opens one Peek at most.
		let delivered = {
			let check = look()
			return check.pageSaw != .nothing || check.request != nil || check.peek != nil || check.source != .link
		}
		var attempts = 0
		for attempt in 1...4 {
			attempts = attempt
			hit = clickHit(on: view, in: window)
			try click(view: view, window: window, modifiers: [.shift])
			var reached = delivered()
			for _ in 0..<30 where !reached {
				try await Task.sleep(for: .milliseconds(100))

				// Looked at after each wait, the last one too, so a click that arrived during it
				// isn't sent again.
				reached = delivered()
			}
			if reached { break }
			FileHandle.standardError.write(Data(
				"ARX_SHIFT_CLICK_RETRY attempt=\(attempt) \(look()) responder=\(Self.responder(in: window))\n".utf8
			))
		}
		try await wait(context: {
			let check = look()
			let record = engine.lastNewContents.map(String.init(describing:)) ?? "none"
			return "\(check) attempts=\(attempts) responder=\(Self.responder(in: window)) "
			+ "modifiers=\(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) "
			+ "lastRequest=(\(record)) shiftClick=\(store.settings.linkClicks.shiftClickLinkAction.rawValue) "
			+ "sourceRevision=\(engine.client.snapshot(sourceTab).map { String($0.revision) } ?? "none") "
			+ "cursorOverWindow=\(window.frame.contains(NSEvent.mouseLocation)) "
			+ "behind=\(check.lag?.rawValue ?? "nothing")"
		}) {
			look().lag == nil
		}
		guard store.windows.count == windows, store.workspace.tabs.count == tabs
		else { throw Failure.sourceChanged }

		if let peek = store.peeks.first(where: { $0.source == source }) {
			store.send(.peeks(.element(id: peek.id, action: .ui(.close))))
			try await wait { store.peeks[id: peek.id] == nil && engine.isAttached(sourceTab) }
		}
		try await engine.client.command(sourceTab, .navigate(originalURL))

		// The window saves the tab's URL and title only once the load finishes, after the
		// title is back. Later smokes compare the whole workspace, so wait for that save too.
		try await wait {
			let navigation = engine.client.snapshot(sourceTab)?.navigation
			return navigation?.title == original.title
			&& navigation?.isLoading == false
			&& store.workspace.tabs[id: sourceTab]?.restoration.url == originalURL
			&& store.workspace.tabs[id: sourceTab]?.restoration.title == original.title
		}
		print("ARX_SHIFT_CLICK_PEEK_SUCCESS")
	}

	/// Real Tab and Shift-Return keys on a disposable page: a focused link, and one in a
	/// same-origin frame, each open exactly one Peek and leave the source page where it
	/// was. Shift-Return in a text field or on a button opens nothing.
	///
	/// Option-Command-Return isn't covered: Arx reads the keys physically held for it, as
	/// for Option-Command-click, and synthesized events don't hold them.
	internal static func keyboardLinks(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		source: PeekFeature.Source,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let sourceTab = source.tabID,
			let original = engine.client.snapshot(sourceTab)?.navigation,
			let originalURL = original.url,
			!original.title.isEmpty,
			store.workspace.tabs.ids.contains(sourceTab),
			store.peeks.isEmpty
		else { throw Failure.invalidFixture }

		let directory = baseURL.deletingLastPathComponent()
		let cases: [(phase: String, target: String, peek: String?)] = [
			("link", "link", "main"),
			("frame", "frame-link", "frame"),
			("field", "field", nil),
			("button", "after", nil),
		]
		for (phase, target, peekTarget) in cases {
			let page = directory.appending(path: "keyboard-link.html").appending(queryItems: [.init(name: "phase", value: phase)])
			try await engine.client.command(sourceTab, .navigate(page))
			window.makeKeyAndOrderFront(nil)
			engine.surface.focus(sourceTab)
			let prefix = "Arx Keyboard \(phase) focus:"
			try await wait(context: { "title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")" }) {
				window.isKeyWindow && engine.client.snapshot(sourceTab)?.navigation.title.hasPrefix(prefix) == true
			}

			try press(window: window, characters: "\t", code: 48)
			try await wait(context: { "title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")" }) {
				engine.client.snapshot(sourceTab)?.navigation.title == "\(prefix)\(target) returns:0"
			}

			let windows = store.windows.count
			let littleWindows = store.littleWindows.count
			let tabs = store.workspace.tabs.count
			try press(window: window, characters: "\r", code: 36, modifiers: [.shift])

			// The page saw the key, so a missing Peek isn't a lost event.
			try await wait(context: { "title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")" }) {
				engine.client.snapshot(sourceTab)?.navigation.title == "\(prefix)\(target) returns:1"
			}
			if let peekTarget {
				try await wait(context: {
					let key = NSApp.keyWindow.map { "\(type(of: $0)):\($0.title)" } ?? "nil"
					return "phase=\(phase) peeks=\(store.peeks.count) "
					+ "peekPhase=\(String(describing: store.peeks.first?.phase)) keyWindow=\(key)"
				}) {
					guard store.peeks.count == 1, let peek = store.peeks.first, peek.source == source
					else { return false }

					return peek.phase == .idle
					&& engine.client.snapshot(peek.tab.id)?.navigation.title == "Arx Keyboard target \(peekTarget)"
				}
			} else {
				// Give a stray new-window request time to arrive.
				try await Task.sleep(for: .milliseconds(700))
				guard store.peeks.isEmpty else { throw Failure.sourceChanged }
			}
			guard
				store.windows.count == windows,
				store.littleWindows.count == littleWindows,
				store.workspace.tabs.count == tabs,
				engine.client.snapshot(sourceTab)?.navigation.url == page
			else { throw Failure.sourceChanged }

			if let peek = store.peeks.first {
				store.send(.peeks(.element(id: peek.id, action: .ui(.close))))
				try await wait { store.peeks.isEmpty && engine.isAttached(sourceTab) }
			}
		}

		try await engine.client.command(sourceTab, .navigate(originalURL))
		try await wait {
			let navigation = engine.client.snapshot(sourceTab)?.navigation
			return navigation?.title == original.title
			&& navigation?.isLoading == false
			&& store.workspace.tabs[id: sourceTab]?.restoration.url == originalURL
			&& store.workspace.tabs[id: sourceTab]?.restoration.title == original.title
		}
		print("ARX_KEYBOARD_LINK_PEEK_SUCCESS")
	}

	/// Open Focused Link in Peek (DEV-713) on the keyboard-link page. A real Tab focuses
	/// the target, then the command opens exactly one Peek for a focused link in the page
	/// and in a same-origin frame, and nothing for a text field or a button. It's invoked
	/// through the main menu's default ⇧⌘P, through the command route the command bar
	/// sends, and through a shortcut rebound in Settings; the default comes back after.
	internal static func focusedLinkCommand(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		source: PeekFeature.Source,
		window: NSWindow,
		baseURL: URL
	) async throws {
		guard
			let sourceTab = source.tabID,
			let original = engine.client.snapshot(sourceTab)?.navigation,
			let originalURL = original.url,
			!original.title.isEmpty,
			store.workspace.tabs.ids.contains(sourceTab),
			store.peeks.isEmpty
		else { throw Failure.invalidFixture }

		enum Trigger {
			case menu
			case commandBar
			case rebound
		}

		let rebound = BrowserCore.KeyboardShortcut(key: "o", modifiers: [.command, .control])
		let directory = baseURL.deletingLastPathComponent()
		let cases: [(phase: String, target: String, peek: String?, trigger: Trigger)] = [
			("link", "link", "main", .menu),
			("frame", "frame-link", "frame", .commandBar),
			("link", "link", "main", .rebound),
			("field", "field", nil, .menu),
			("button", "after", nil, .menu),
		]
		for (phase, target, peekTarget, trigger) in cases {
			let page = directory.appending(path: "keyboard-link.html").appending(queryItems: [.init(name: "phase", value: phase)])
			try await engine.client.command(sourceTab, .navigate(page))
			window.makeKeyAndOrderFront(nil)
			engine.surface.focus(sourceTab)
			let prefix = "Arx Keyboard \(phase) focus:"
			try await wait(context: { "title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")" }) {
				window.isKeyWindow && engine.client.snapshot(sourceTab)?.navigation.title.hasPrefix(prefix) == true
			}
			try press(window: window, characters: "\t", code: 48)
			try await wait(context: { "title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")" }) {
				engine.client.snapshot(sourceTab)?.navigation.title == "\(prefix)\(target) returns:0"
			}

			let windows = store.windows.count
			let littleWindows = store.littleWindows.count
			let tabs = store.workspace.tabs.count
			switch trigger {
			case .menu:
				try performShortcut(BrowserCommand.openFocusedLinkInPeek.shortcut, window: window)

			case .commandBar:
				store.send(.ui(.command(.openFocusedLinkInPeek, .window(source.windowID, paneID: source.paneID))))

			case .rebound:
				store.send(.settings(.ui(.assignKeyboardShortcut(.openFocusedLinkInPeek, rebound))))
				try await wait {
					NSApp.mainMenu.flatMap { menuItem(for: .openFocusedLinkInPeek, in: $0) }.map {
						$0.keyEquivalent == rebound.key && $0.keyEquivalentModifierMask == [.command, .control]
					} == true
				}
				try performShortcut(rebound, window: window)
			}

			if let peekTarget {
				try await wait(context: {
					let key = NSApp.keyWindow.map { "\(type(of: $0)):\($0.title)" } ?? "nil"
					return "phase=\(phase) peeks=\(store.peeks.count) "
					+ "peekPhase=\(String(describing: store.peeks.first?.phase)) keyWindow=\(key)"
				}) {
					guard store.peeks.count == 1, let peek = store.peeks.first, peek.source == source
					else { return false }

					return peek.phase == .idle
					&& peek.origin == nil
					&& engine.client.snapshot(peek.tab.id)?.navigation.title == "Arx Keyboard target \(peekTarget)"
				}
			} else {
				// The engine answers within two seconds; give a stray Peek time to arrive.
				try await Task.sleep(for: .milliseconds(2_500))
				guard store.peeks.isEmpty else { throw Failure.sourceChanged }
			}

			// The command reads the link; the page never sees a key or a click.
			guard
				store.windows.count == windows,
				store.littleWindows.count == littleWindows,
				store.workspace.tabs.count == tabs,
				engine.client.snapshot(sourceTab)?.navigation.url == page,
				engine.client.snapshot(sourceTab)?.navigation.title == "\(prefix)\(target) returns:0"
			else { throw Failure.sourceChanged }

			if let peek = store.peeks.first {
				store.send(.peeks(.element(id: peek.id, action: .ui(.close))))
				try await wait { store.peeks.isEmpty && engine.isAttached(sourceTab) }
			}
			if trigger == .rebound {
				store.send(.settings(.ui(.resetKeyboardShortcut(.openFocusedLinkInPeek))))
				try await wait {
					store.settings.keyboardShortcuts.shortcut(for: .openFocusedLinkInPeek)
					== BrowserCommand.openFocusedLinkInPeek.shortcut
				}
			}
		}

		try await engine.client.command(sourceTab, .navigate(originalURL))
		try await wait {
			let navigation = engine.client.snapshot(sourceTab)?.navigation
			return navigation?.title == original.title
			&& navigation?.isLoading == false
			&& store.workspace.tabs[id: sourceTab]?.restoration.url == originalURL
			&& store.workspace.tabs[id: sourceTab]?.restoration.title == original.title
		}
		print("ARX_FOCUSED_LINK_COMMAND_PEEK_SUCCESS")
	}

	/// Sends a shortcut through the main menu, the route BrowserCommands takes for keys.
	private static func performShortcut(
		_ shortcut: BrowserCore.KeyboardShortcut?,
		window: NSWindow
	) throws {
		// ANSI key codes for the two keys this smoke binds.
		let codes: [String: UInt16] = ["p": 35, "o": 31]
		guard
			let shortcut,
			let code = codes[shortcut.key],
			window.isKeyWindow,
			let menu = NSApp.mainMenu
		else { throw Failure.missingSource }

		var flags: CGEventFlags = []
		if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
		if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
		if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
		if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }

		// The system's own translation gives the characters a keyboard sends. A hand-built
		// ⇧⌘P with a lowercase letter matches ⌘P Print instead (DEV-795).
		let source = CGEventSource(stateID: .privateState)
		guard let key = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
		else { throw Failure.missingSource }

		key.flags = flags
		guard
			let event = NSEvent(cgEvent: key),
			menu.performKeyEquivalent(with: event)
		else { throw Failure.missingSource }
	}

	private static func menuItem(
		for command: BrowserCommand,
		in menu: NSMenu
	) -> NSMenuItem? {
		for item in menu.items {
			if (item.representedObject as? String) == command.rawValue { return item }
			if let submenu = item.submenu, let found = menuItem(for: command, in: submenu) { return found }
		}
		return nil
	}

	private static func press(
		window: NSWindow,
		characters: String,
		code: UInt16,
		modifiers: NSEvent.ModifierFlags = []
	) throws {
		guard window.isKeyWindow, window.isVisible, !window.isMiniaturized
		else { throw Failure.missingSource }

		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: modifiers,
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: code
			) else { throw Failure.missingSource }

			window.sendEvent(event)
		}
	}

	/// Waits until the click's point hits the page, not a view over it (DEV-1191).
	private static func waitUntilClickable(
		_ view: NSView,
		in window: NSWindow,
		line: UInt = #line
	) async throws {
		try await wait(line: line, context: { "hit=\(clickHit(on: view, in: window))" }) {
			view.window === window && clickHit(on: view, in: window) == .page
		}
	}

	/// The point the smoke clicks in the page's view, in window coordinates: on the fixture's link
	/// or button near the page's top left.
	private static func clickPoint(in view: NSView) -> NSPoint {
		view.convert(.init(x: 116, y: view.isFlipped ? 38 : view.bounds.height - 38), to: nil)
	}

	/// What the click's point hits in the window, as AppKit picks the view for a mouse-down: the
	/// window's frame view hit-tests in window coordinates.
	/// The window's first responder, by its class and its two nearest ancestors' classes.
	private static func responder(in window: NSWindow) -> String {
		guard let responder = window.firstResponder else { return "none" }
		guard let view = responder as? NSView else { return String(describing: type(of: responder)) }

		return sequence(first: view, next: \.superview).prefix(3).map { String(describing: type(of: $0)) }.joined(separator: "<")
	}

	private static func clickHit(
		on view: NSView,
		in window: NSWindow
	) -> ShiftClickCheck.ClickHit {
		guard let frame = window.contentView?.superview ?? window.contentView
		else { return .other("noContentView") }
		guard let hit = frame.hitTest(clickPoint(in: view)) else { return .other("nothing") }
		if hit === view || hit.isDescendant(of: view) { return .page }

		let classes = sequence(first: hit, next: \.superview).prefix(3).map { String(describing: type(of: $0)) }
		return .other(classes.joined(separator: "<"))
	}

	private static func click(
		view: NSView,
		window: NSWindow,
		modifiers: NSEvent.ModifierFlags = []
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

		let point = clickPoint(in: view)
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: modifiers,
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

		let keyWindow = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
		let message = "ARX_NATIVE_CONTENTS_SMOKE_TIMEOUT line=\(line) active=\(NSApp.isActive) "
		+ "key=\(keyWindow) \(context())\n"
		FileHandle.standardError.write(Data(message.utf8))
		throw Failure.timedOut
	}

	private enum Failure: Error {
		case invalidFixture
		case missingSource
		case blockingFailed
		case sourceChanged
		case timedOut
	}
}
#endif
