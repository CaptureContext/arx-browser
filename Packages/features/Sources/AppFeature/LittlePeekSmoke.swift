#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import PeekFeature
import _ComposableArchitecture

/// Exercises disposable Little Peek sessions through the app's real native surface handoff.
@MainActor
internal enum LittlePeekSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		windowID: UUID,
		littleWindow: NSWindow,
		mainWindow: NSWindow,
		baseURL: URL
	) async throws {
		guard
			baseURL.scheme == "http",
			baseURL.host == "127.0.0.1",
			let source = store.state.peekSource(windowID: windowID, paneID: windowID),
			case let .littleArx(generation) = source.host,
			let sourceTabID = source.tabID,
			let original = engine.client.snapshot(sourceTabID)?.navigation,
			!original.isLoading,
			original.errorCode == nil,
			engine.isAttached(sourceTabID)
		else { throw Failure.invalidSource }

		engine.surface.focus(sourceTabID)
		guard let sourceView = littleWindow.firstResponder as? NSView
		else { throw Failure.missingNativeView }

		func sourceIsPreserved() -> Bool {
			guard let little = store.littleWindows[id: windowID]
			else { return false }

			return little.tab.id == sourceTabID
			&& little.tab.profileID == source.profileID
			&& little.viewer.generation == generation
			&& engine.client.snapshot(sourceTabID)?.navigation == original
			&& engine.isAttached(sourceTabID)
			&& sourceView.window === littleWindow
		}

		let fixture = baseURL.deletingLastPathComponent().appendingPathComponent("little-peek.html")
		let dismissedURL = fixture.appending(queryItems: [.init(name: "phase", value: "dismiss")])
		let dismissed = try await open(
			dismissedURL,
			phase: "dismiss",
			source: source,
			store: store,
			engine: engine
		)
		guard sourceIsPreserved()
		else { throw Failure.sourceChanged }

		store.send(.ui(.dismissPeek(windowID: windowID)))
		try await wait("Dismissal did not restore the original Little native view") {
			store.peeks[id: dismissed.id] == nil
			&& engine.client.snapshot(dismissed.tab.id) == nil
			&& store.littleWindows[id: windowID]?.peekID == nil
			&& store.focusedWindowID == windowID
			&& littleWindow.firstResponder === sourceView
			&& sourceIsPreserved()
		}
		print("ARX_LITTLE_PEEK_DISMISS_SMOKE_SUCCESS")

		let startURL = fixture.appending(queryItems: [.init(name: "phase", value: "promote-start")])
		let nextURL = fixture.appending(queryItems: [.init(name: "phase", value: "promote-next")])
		let promoted = try await open(
			startURL,
			phase: "promote-start",
			source: source,
			store: store,
			engine: engine
		)
		store.send(.peeks(.element(
			id: promoted.id,
			action: .viewer(.ui(.command(.navigate(nextURL))))
		)))
		try await wait("Preview navigation did not retain both native history entries") {
			guard let navigation = loadedNavigation(engine, tabID: promoted.tab.id, url: nextURL, phase: "promote-next")
			else { return false }

			return navigation.entries(in: .back).contains { $0.url == startURL }
			&& store.peeks[id: promoted.id]?.viewer.navigation == navigation
		}
		guard
			let before = loadedNavigation(engine, tabID: promoted.tab.id, url: nextURL, phase: "promote-next"),
			sourceIsPreserved(),
			!store.workspace.tabs.ids.contains(promoted.tab.id)
		else { throw Failure.sourceChanged }

		engine.surface.focus(promoted.tab.id)
		guard
			let previewView = littleWindow.firstResponder as? NSView,
			previewView !== sourceView,
			previewView.window === littleWindow
		else { throw Failure.missingNativeView }

		store.send(.ui(.promotePeek(windowID: windowID, destination: .tab)))
		do {
			try await wait("Promotion attachment and focus invariants did not settle in the normal browser") {
				store.peeks[id: promoted.id] == nil
				&& store.workspace.tabs[id: promoted.tab.id]?.profileID == source.profileID
				&& store.main.sidebar.selectedTab?.id == promoted.tab.id
				&& store.main.viewer.item.tab?.id == promoted.tab.id
				&& store.main.viewer.item.navigation == before
				&& store.focusedWindowID == store.main.id
				&& store.littleWindows[id: windowID]?.peekID == nil
				&& engine.isAttached(promoted.tab.id)
				&& previewView.window === mainWindow
				&& mainWindow.firstResponder === previewView
				&& sourceIsPreserved()
			}

		} catch {
			// Only fixture-state booleans are logged; page URLs, titles and IDs stay private.
			let responder = mainWindow.firstResponder as? NSView
			let checks: [(String, Bool)] = [
				("peekRemoved", store.peeks[id: promoted.id] == nil),
				("durable", store.workspace.tabs.contains {
					$0.id == promoted.tab.id && $0.profileID == source.profileID
				}),
				("selected", store.main.sidebar.selectedTab?.id == promoted.tab.id),
				("activePane", store.main.viewer.item.tab?.id == promoted.tab.id),
				("anyPane", store.main.viewer.panes.contains { $0.item.tab?.id == promoted.tab.id }),
				("navigation", store.main.viewer.item.navigation == before),
				("nativeNavigation", engine.client.snapshot(promoted.tab.id)?.navigation == before),
				("mainFocused", store.focusedWindowID == store.main.id),
				("littleReleased", store.littleWindows[id: windowID]?.peekID == nil),
				("attached", engine.isAttached(promoted.tab.id)),
				("viewInMain", previewView.window === mainWindow),
				("viewInLittle", previewView.window === littleWindow),
				("viewDetached", previewView.window == nil),
				("responder", mainWindow.firstResponder === previewView),
				("responderIsWindow", mainWindow.firstResponder === mainWindow),
				("responderIsView", responder != nil),
				("responderInMain", responder?.window === mainWindow),
				("responderWithinPreview", responder?.isDescendant(of: previewView) == true),
				("previewWithinResponder", responder.map { previewView.isDescendant(of: $0) } == true),
				("previewAcceptsResponder", previewView.acceptsFirstResponder),
				("mainIsKey", mainWindow.isKeyWindow),
				("sourcePreserved", sourceIsPreserved()),
				("sourceNativeNavigation", engine.client.snapshot(sourceTabID)?.navigation == original),
				("sourceAttached", engine.isAttached(sourceTabID)),
				("sourceViewInLittle", sourceView.window === littleWindow),
				("destinationSpace", store.main.viewer.spaceID == source.spaceID),
				("hasViewerError", store.main.viewer.item.failure != nil),
				("hasPeekError", store.peeks[id: promoted.id]?.error != nil),
			]
			let diagnostic = checks.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
			print("ARX_LITTLE_PEEK_PROMOTION_STATE \(diagnostic)")
			fflush(stdout)
			throw error
		}

		// The same native view, history entry IDs and document-created nonce must survive.
		guard engine.client.snapshot(promoted.tab.id)?.navigation == before
		else { throw Failure.recreatedSession }

		let forbidden = [dismissedURL, startURL]
		guard store.history.snapshots.values.allSatisfy({ snapshot in
			!snapshot.entries.contains { forbidden.contains($0.url) }
		})
		else { throw Failure.temporaryHistory }
		print("ARX_LITTLE_PEEK_PROMOTION_SMOKE_SUCCESS")
	}

	private static func open(
		_ url: URL,
		phase: String,
		source: PeekFeature.Source,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine
	) async throws -> PeekFeature.State {
		store.send(.ui(.peekURLFromSource(url, source)))
		try await wait("Little Peek did not load its controlled document: \(phase)") {
			guard let peek = store.peeks.first(where: { $0.source.windowID == source.windowID })
			else { return false }

			return peek.source == source
			&& peek.isTemporary
			&& peek.tab.profileID == source.profileID
			&& !store.workspace.tabs.ids.contains(peek.tab.id)
			&& engine.isAttached(peek.tab.id)
			&& loadedNavigation(engine, tabID: peek.tab.id, url: url, phase: phase) != nil
		}
		guard let peek = store.peeks.first(where: { $0.source.windowID == source.windowID })
		else { throw Failure.invalidSource }
		return peek
	}

	private static func loadedNavigation(
		_ engine: ChromiumBrowserEngine,
		tabID: BrowserCore.Tab.ID,
		url: URL,
		phase: String
	) -> BrowserNavigation? {
		let prefix = "Arx Little Peek \(phase):"
		guard
			let navigation = engine.client.snapshot(tabID)?.navigation,
			navigation.url == url,
			!navigation.isLoading,
			navigation.errorCode == nil,
			navigation.title.hasPrefix(prefix),
			UUID(uuidString: String(navigation.title.dropFirst(prefix.count))) != nil,
			navigation.history.first(where: \.isCurrent)?.url == url,
			navigation.history.first(where: \.isCurrent)?.title == navigation.title
		else { return nil }
		return navigation
	}

	private static func wait(
		_ message: String,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<100 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut(message)
	}

	private enum Failure: Error {
		case invalidSource
		case missingNativeView
		case sourceChanged
		case recreatedSession
		case temporaryHistory
		case timedOut(String)
	}
}
#endif
