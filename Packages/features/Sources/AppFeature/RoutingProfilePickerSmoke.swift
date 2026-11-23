#if DEBUG
import AppKit
import BrowserCore
import Foundation
import LittleArxFeature
import _ComposableArchitecture

/// The profile picker at the pointer (DEV-858). Three links from outside ask for a destination
/// through the production queue. For each, the borderless, non-activating panel must appear
/// with the most recent profile first and nothing loaded. Esc and losing focus must close it
/// and open nothing; Return must open the link once, in Little Arx, in that profile.
@MainActor
internal enum RoutingProfilePickerSmoke {
	internal enum Failure: String, Error {
		case invalidFixture, missingPanel, wrongStyle, wrongOrder, loadedEarly, openedOnCancel
		case wrongDestination, lostToFocus, timedOut
	}

	internal static func run(
		store: StoreOf<AppFeature>,
		baseURL: URL,
		mainWindow: NSWindow?,
		panel: () -> NSWindow?,
		render: () -> Void
	) async throws {
		guard
			let mainWindow,
			store.routingInbox.picksProfileAtPointer,
			store.routingInbox.requests.isEmpty
		else { throw Failure.invalidFixture }

		let littleWindows = Set(store.littleWindows.ids)
		let workspaceTabs = Array(store.workspace.tabs.ids)
		let page = baseURL.deletingLastPathComponent()
		let urls = (1...4).map { page.appending(path: "routing-picker-\($0).html") }
		let expectedProfile = store.state.incomingSpaceID()
			.flatMap { store.workspace.spaces[id: $0]?.profileID }

		// Esc closes it, and nothing opens.
		let first = try await present(urls[0], store: store, panel: panel, render: render)
		guard first.options.first?.id == expectedProfile, first.highlightedID == expectedProfile
		else { throw Failure.wrongOrder }
		try await press(keyCode: 53, characters: "\u{1B}", panel: panel)
		try await waitClosed(after: "esc", store: store, panel: panel, render: render)
		try expectNothingOpened(store: store, littleWindows: littleWindows, workspaceTabs: workspaceTabs, urls: urls)

		// Another window taking the keyboard closes it, and nothing opens.
		_ = try await present(urls[1], store: store, panel: panel, render: render)
		mainWindow.makeKeyAndOrderFront(nil)
		try await waitClosed(after: "focusLoss", store: store, panel: panel, render: render)
		try expectNothingOpened(store: store, littleWindows: littleWindows, workspaceTabs: workspaceTabs, urls: urls)

		// Return opens the link once, in Little Arx, in the most recent profile. A second link
		// that arrived with it then asks, and keeps the keyboard while the first one opens.
		store.send(.ui(.routeURLs([urls[2], urls[3]], override: .init(scope: .ask))))
		let third = try await waitForPanel(urls[2], store: store, panel: panel, render: render)
		let option = try required(third.selection, else: .wrongOrder)
		try await press(keyCode: 36, characters: "\r", panel: panel)
		var opened: LittleArxFeature.State?
		try await wait(context: { "littleWindows=\(store.littleWindows.count)" }) {
			render()
			opened = store.littleWindows.first { !littleWindows.contains($0.id) }
			return opened != nil
		}
		guard
			let opened,
			store.littleWindows.count == littleWindows.count + 1,
			opened.tab.restoration.url == urls[2],
			opened.tab.profileID == option.id,
			opened.spaceID == option.spaceID,
			Array(store.workspace.tabs.ids) == workspaceTabs
		else { throw Failure.wrongDestination }

		_ = try await waitForPanel(urls[3], store: store, panel: panel, render: render)

		// Still asking a moment later: the new Little Arx didn't take its focus.
		try await Task.sleep(for: .milliseconds(500))
		render()
		guard store.routingInbox.picker?.url == urls[3], panel()?.isKeyWindow == true
		else { throw Failure.lostToFocus }
		try await press(keyCode: 53, characters: "\u{1B}", panel: panel)
		try await waitClosed(after: "escAfterReturn", store: store, panel: panel, render: render)
		guard
			store.routingInbox.requests.isEmpty,
			store.littleWindows.count == littleWindows.count + 1
		else { throw Failure.openedOnCancel }

		store.send(.littleWindows(.element(id: opened.id, action: .ui(.close))))
		render()
		try await wait { Set(store.littleWindows.ids) == littleWindows }
		print("ARX_ROUTING_PROFILE_PICKER_SMOKE_SUCCESS")
	}

	/// Sends a link from outside that asks, and waits for its panel.
	private static func present(
		_ url: URL,
		store: StoreOf<AppFeature>,
		panel: () -> NSWindow?,
		render: () -> Void
	) async throws -> RoutingProfilePicker {
		store.send(.ui(.routeURLs([url], override: .init(scope: .ask))))
		return try await waitForPanel(url, store: store, panel: panel, render: render)
	}

	/// Waits for the panel asking about this link, and checks it before anything is chosen.
	private static func waitForPanel(
		_ url: URL,
		store: StoreOf<AppFeature>,
		panel: () -> NSWindow?,
		render: () -> Void
	) async throws -> RoutingProfilePicker {
		try await wait(context: { "picker=\(store.routingInbox.picker != nil) panel=\(panel() != nil)" }) {
			render()
			return store.routingInbox.picker?.url == url && panel()?.isVisible == true
		}
		let picker = try required(store.routingInbox.picker, else: .missingPanel)
		let window = try required(panel(), else: .missingPanel)
		guard
			window.styleMask == [.borderless, .nonactivatingPanel],
			window.standardWindowButton(.closeButton) == nil,
			window.screen.map({ $0.visibleFrame.contains(window.frame) }) ?? false
		else { throw Failure.wrongStyle }

		// Nothing loads while it asks.
		guard
			store.routingInbox.requests.first?.status == .choosingProfile,
			store.routingInbox.requests.dropFirst().allSatisfy({ $0.status == .queued }),
			!store.littleWindows.contains(where: { $0.tab.restoration.url == url }),
			!store.workspace.tabs.contains(where: { $0.restoration.url == url })
		else { throw Failure.loadedEarly }

		let link = url.lastPathComponent
		if !window.isKeyWindow { window.makeKey() }
		try await wait(context: { "link=\(link) key=\(window.isKeyWindow)" }) { window.isKeyWindow }

		// The search field takes the keyboard when the panel opens. A panel that lost the keyboard
		// closes and drops its link, so the context tells that apart from a field without focus.
		try await wait(context: { focusContext(link: link, window: window, store: store, panel: panel) }) {
			window.firstResponder is NSTextView
		}
		return picker
	}

	/// Who has the keyboard while the smoke waits for the search field.
	private static func focusContext(
		link: String,
		window: NSWindow,
		store: StoreOf<AppFeature>,
		panel: () -> NSWindow?
	) -> String {
		let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
		let keyWindow = NSApp.keyWindow.map { $0.identifier?.rawValue ?? String(describing: type(of: $0)) } ?? "none"
		return [
			"link=\(link)",
			"responder=\(responder)",
			"key=\(window.isKeyWindow)",
			"visible=\(window.isVisible)",
			"current=\(panel() === window)",
			"asking=\(store.routingInbox.picker?.url.lastPathComponent ?? "none")",
			"keyWindow=\(keyWindow)",
		].joined(separator: " ")
	}

	private static func press(
		keyCode: UInt16,
		characters: String,
		panel: () -> NSWindow?
	) async throws {
		let window = try required(panel(), else: .missingPanel)
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: keyCode
			) else { throw Failure.missingPanel }

			window.sendEvent(event)
		}
	}

	/// Waits for the picker and its panel to close after `step`, which a timeout names.
	private static func waitClosed(
		after step: String,
		store: StoreOf<AppFeature>,
		panel: () -> NSWindow?,
		render: () -> Void
	) async throws {
		try await wait(context: {
			let key = panel()?.isKeyWindow.description ?? "none"
			return "after=\(step) picker=\(store.routingInbox.picker != nil) panel=\(panel() != nil) key=\(key)"
		}) {
			render()
			return store.routingInbox.picker == nil && panel() == nil
		}
	}

	private static func expectNothingOpened(
		store: StoreOf<AppFeature>,
		littleWindows: Set<UUID>,
		workspaceTabs: [BrowserCore.Tab.ID],
		urls: [URL]
	) throws {
		guard
			Set(store.littleWindows.ids) == littleWindows,
			Array(store.workspace.tabs.ids) == workspaceTabs,
			store.routingInbox.requests.isEmpty,
			!store.littleWindows.contains(where: { urls.contains($0.tab.restoration.url) })
		else { throw Failure.openedOnCancel }
	}

	private static func required<Value>(
		_ value: Value?,
		else failure: Failure
	) throws -> Value {
		guard let value else { throw failure }
		return value
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

		let message = "ARX_ROUTING_PROFILE_PICKER_SMOKE_TIMEOUT line=\(line) active=\(NSApp.isActive) \(context())\n"
		FileHandle.standardError.write(Data(message.utf8))
		throw Failure.timedOut
	}
}
#endif
