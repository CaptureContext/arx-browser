#if DEBUG
import AppKit
import BrowserCore
import Foundation
import _ComposableArchitecture

/// The caller supplies an already attached page in signed disposable app storage.
/// Native events enter the renderer, and the page's own permission prompt decides: the
/// engine's sheet, whose native buttons are clicked, or with the `ARX_PAGE_PROMPTS` feature
/// flag on, the default since DEV-1143, Arx's prompt sheet (DEV-963), answered with the
/// actions its buttons send. IdleDetector permission is requested without ever starting
/// observation.
@MainActor
internal enum PageConsentSmoke {
	internal enum Context: String {
		case main = "MAIN"
		case little = "LITTLE"
		case privatePage = "PRIVATE"
	}

	internal static func run(
		store: StoreOf<AppFeature>,
		tabID: BrowserCore.Tab.ID,
		view: NSView,
		window: NSWindow,
		baseURL: URL,
		context: Context,
		navigate: @MainActor (URL) async throws -> Void,
		isLoaded: @MainActor (String) -> Bool
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

		// Pinned Chromium resolves *.localhost directly to loopback. Each run gets
		// a fresh origin, so Main/Little/private checks cannot inherit one another's
		// deliberate Block while sharing the fixture server and browser profile.
		let host = "arx-consent-\(UUID().uuidString.lowercased()).localhost"
		var source = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
		source?.host = host
		source?.path = "/page-consent/main.html"

		// Chrome denies idle detection off the record without any prompt.
		let kind = context == .privatePage ? "location" : "idle"
		if context == .privatePage { source?.queryItems = [.init(name: "kind", value: kind)] }
		guard let mainURL = source?.url else { throw Failure.invalidFixture }

		let prompts = Prompts(store: store, tabID: tabID, window: window)
		try await navigate(mainURL)
		try await wait { isLoaded("Arx page consent fixture") }
		window.makeKeyAndOrderFront(nil)
		try clickRequest(view: view, window: window)

		// A click sent just as the window becomes key sometimes doesn't reach the page. With no
		// sheet and no answer after a few seconds, it's sent once more (DEV-965).
		for _ in 0..<30 where prompts.sheet == nil
			&& !["denied", "granted", "unavailable"].contains(where: { isLoaded("Arx consent \(kind) \($0)") }) {
			try await Task.sleep(for: .milliseconds(100))
		}
		if prompts.sheet == nil,
			!["denied", "granted", "unavailable"].contains(where: { isLoaded("Arx consent \(kind) \($0)") }) {
			FileHandle.standardError.write(Data("ARX_PAGE_CONSENT_CLICK_RETRY context=\(context.rawValue)\n".utf8))
			try clickRequest(view: view, window: window)
		}
		do {
			try await wait { prompts.sheet != nil }
		} catch {
			let outcome = ["denied", "granted", "unavailable"].first { isLoaded("Arx consent \(kind) \($0)") } ?? "none"
			let fixtureLoaded = isLoaded("Arx page consent fixture")
			let sheet = window.attachedSheet.map { $0.identifier?.rawValue ?? "other" } ?? "none"
			let message = "ARX_PAGE_CONSENT_FIRST_REQUEST context=\(context.rawValue) outcome=\(outcome) "
			+ "fixture=\(fixtureLoaded) key=\(window.isKeyWindow) arxPrompt=\(prompts.arx != nil) sheet=\(sheet)\n"
			FileHandle.standardError.write(Data(message.utf8))
			throw error
		}
		try requireOrigin(of: prompts, host: host, port: parts.port)
		try await choose(.block, in: prompts)
		try await wait { isLoaded("Arx consent \(kind) denied") }

		// An explicit Block persists in this exact ordinary/OTR context.
		try await navigate(mainURL)
		try await wait { isLoaded("Arx page consent fixture") }
		try clickRequest(view: view, window: window)
		try await wait { isLoaded("Arx consent \(kind) denied") }
		guard window.attachedSheet == nil else { throw Failure.unexpectedSheet }

		var alternate = URLComponents(url: mainURL, resolvingAgainstBaseURL: false)
		alternate?.host = "next." + host
		guard let alternateURL = alternate?.url else { throw Failure.invalidFixture }
		try await navigate(alternateURL)
		try await wait { isLoaded("Arx page consent fixture") }
		try clickRequest(view: view, window: window)
		try await wait { prompts.sheet != nil }
		guard let oldSheet = prompts.sheet else { throw Failure.missingSheet }

		// Start a real host navigation while the old native sheet is outstanding.
		// The same-origin destination proves domain comparison alone is insufficient.
		let destination = alternateURL.deletingLastPathComponent()
			.appending(path: "destination.html")
		try await navigate(destination)
		try await wait {
			isLoaded("Arx consent destination") && window.attachedSheet == nil
		}
		guard !oldSheet.isVisible else { throw Failure.staleSheet }

		// A stale sheet neither remembers Allow nor saves an implicit Block.
		try await navigate(alternateURL)
		try await wait { isLoaded("Arx page consent fixture") }
		try clickRequest(view: view, window: window)
		try await wait { prompts.sheet != nil }
		try await choose(.cancel, in: prompts)
		try await wait { window.attachedSheet == nil }

		print("ARX_PAGE_CONSENT_\(context.rawValue)_SUCCESS")
	}

	/// The two answers the smoke gives: Block, which the profile keeps, and Cancel, which only
	/// dismisses.
	private enum Choice {
		case block
		case cancel

		/// The engine sheet's button.
		var identifier: String {
			switch self {
			case .block: "ArxPermissionBlock"
			case .cancel: "ArxPermissionCancel"
			}
		}

		/// What Arx's prompt card sends for the same button.
		var action: PagePermissionPrompt.Action.UI {
			switch self {
			case .block: .block
			case .cancel: .cancel
			}
		}
	}

	/// The page's permission prompt on its window, whichever shows it.
	@MainActor
	private struct Prompts {
		internal let store: StoreOf<AppFeature>
		internal let tabID: BrowserCore.Tab.ID
		internal let window: NSWindow

		/// Arx's own prompt for the page (DEV-963), while the engine hands prompts to the app.
		internal var arx: PagePermissionPrompt.State? {
			store.pagePermissionPrompts.first { $0.tabID == tabID && $0.isRevealed }
		}

		/// The prompt's sheet on the page's window: the engine's, or Arx's own, which takes the
		/// window's key status while it shows.
		internal var sheet: NSWindow? {
			guard
				let sheet = window.attachedSheet,
				sheet.sheetParent === window,
				sheet.isVisible,
				arx != nil || sheet.identifier?.rawValue == "ArxWebsitePermission"
			else { return nil }

			return sheet
		}
	}

	/// The engine turns an answer to Arx's prompt into a dismissal within 500 ms of handing it
	/// over, as its own sheet keeps its buttons disabled, and the card waits as long to arm them.
	private static let arxPromptInputProtection: Duration = .milliseconds(600)

	private static func requireOrigin(
		of prompts: Prompts,
		host: String,
		port: Int?
	) throws {
		guard let port, let sheet = prompts.sheet else { throw Failure.missingOrigin }

		let origin = "\(host):\(port)"
		if let prompt = prompts.arx {
			guard prompt.request.site.contains(origin) else { throw Failure.missingOrigin }

			return
		}

		guard
			let content = sheet.contentView,
			textFields(in: content).contains(where: { $0.stringValue.contains(origin) })
		else { throw Failure.missingOrigin }
	}

	private static func choose(
		_ choice: Choice,
		in prompts: Prompts
	) async throws {
		if let prompt = prompts.arx {
			// The card's buttons are SwiftUI's, with no NSButton to click, and send these actions.
			// The engine also takes an answer only while the prompt's sheet or its window is key.
			try await Task.sleep(for: arxPromptInputProtection)
			try await wait {
				prompts.arx?.id == prompt.id && NSApp.isActive
				&& (NSApp.keyWindow === prompts.window || NSApp.keyWindow?.sheetParent === prompts.window)
			}
			prompts.store.send(.pagePermissionPrompts(.element(id: prompt.id, action: .ui(choice.action))))
			return
		}

		try await wait {
			guard let content = prompts.sheet?.contentView else { return false }

			return button(in: content, identifier: choice.identifier)?.isEnabled == true
		}
		guard
			let content = prompts.sheet?.contentView,
			let target = button(in: content, identifier: choice.identifier)
		else { throw Failure.missingSheet }

		target.performClick(nil)
	}

	private static func button(
		in view: NSView,
		identifier: String
	) -> NSButton? {
		if let button = view as? NSButton, button.identifier?.rawValue == identifier {
			return button
		}

		return view.subviews.lazy.compactMap {
			button(in: $0, identifier: identifier)
		}.first
	}

	private static func textFields(in view: NSView) -> [NSTextField] {
		let current = (view as? NSTextField).map { [$0] } ?? []
		return current + view.subviews.flatMap { textFields(in: $0) }
	}

	internal static func clickRequest(
		view: NSView,
		window: NSWindow
	) throws {
		guard
			view.window === window,
			window.isKeyWindow,
			window.isVisible,
			!window.isMiniaturized,
			!view.isHiddenOrHasHiddenAncestor,
			view.bounds.width >= 264,
			view.bounds.height >= 88
		else { throw Failure.missingSource }

		let point = view.convert(
			.init(x: 120, y: view.isFlipped ? 38 : view.bounds.height - 38),
			to: nil
		)
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
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
		until ready: () -> Bool
	) async throws {
		for _ in 0..<100 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}

		FileHandle.standardError.write(Data("ARX_PAGE_CONSENT_SMOKE_TIMEOUT line=\(line) active=\(NSApp.isActive)\n".utf8))
		throw Failure.timedOut
	}

	private enum Failure: Error {
		case invalidFixture
		case missingSource
		case missingSheet
		case missingOrigin
		case unexpectedSheet
		case staleSheet
		case timedOut
	}
}
#endif
