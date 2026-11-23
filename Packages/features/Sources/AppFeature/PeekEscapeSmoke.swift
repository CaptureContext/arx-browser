#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import PeekFeature
import _ComposableArchitecture

/// Native key delivery into disposable Peek documents in the owned app fixture.
/// This uses the normal renderer ACK and before-unload close; it never calls the
/// native delegate directly or installs a local/global Escape monitor.
@MainActor
internal enum PeekEscapeSmoke {
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
			let sourceTab = source.tabID
		else { throw Failure.invalidFixture }

		// The previous stage returns once the source finished loading; its title
		// and history entries can still change afterwards. Compare against a
		// snapshot that has stopped moving.
		let original = try await settledNavigation(sourceTab, engine: engine)

		window.makeKeyAndOrderFront(nil)
		engine.surface.focus(sourceTab)
		try await wait { (window.firstResponder as? NSView)?.window === window }
		guard let originalResponder = window.firstResponder as? NSView
		else { throw Failure.missingNativeFocus }

		var owned: [BrowserCore.Tab.ID] = []
		defer {
			for tabID in owned {
				if let peek = store.peeks.first(where: { $0.tab.id == tabID }) {
					store.send(.peeks(.element(id: peek.id, action: .ui(.close))))
				}
			}
		}

		for phase in ["consumed", "navigate", "unconsumed"] {
			let url = baseURL.deletingLastPathComponent().appending(path: "peek-escape.html")
				.appending(queryItems: [.init(name: "phase", value: phase)])
			store.send(.ui(.peekURLFromSource(url, source)))
			try await wait {
				guard let peek = store.peeks.first(where: { $0.source == source })
				else { return false }

				return peek.isTemporary && peek.phase == .idle
				&& peek.tab.profileID == source.profileID
				&& engine.isAttached(peek.tab.id)
				&& engine.client.snapshot(peek.tab.id)?.navigation.title == "Arx Peek Escape \(phase):0"
			}
			guard let peek = store.peeks.first(where: { $0.source == source })
			else { throw Failure.missingPeek }

			owned.append(peek.tab.id)
			window.makeKeyAndOrderFront(nil)
			engine.surface.focus(peek.tab.id)
			try await wait { window.isKeyWindow && engine.isAttached(peek.tab.id) }
			guard
				let responder = window.firstResponder as? NSView,
				responder.window === window,
				engine.client.snapshot(peek.tab.id)?.navigation.url == url,
				let down = key(.keyDown, window: window),
				let up = key(.keyUp, window: window)
			else { throw Failure.missingNativeFocus }

			window.sendEvent(down)
			window.sendEvent(up)
			if phase == "unconsumed" {
				try await wait {
					store.peeks[id: peek.id] == nil
					&& engine.client.snapshot(peek.tab.id) == nil
					&& engine.isAttached(sourceTab)
				}

			} else {
				let title = phase == "navigate" ? "Arx Peek Escape arrived:0" : "Arx Peek Escape consumed:1"
				try await wait { engine.client.snapshot(peek.tab.id)?.navigation.title == title }

				// Allow the renderer's unconsumed ACK to return after its navigation.
				try await Task.sleep(for: .milliseconds(200))
				guard store.peeks[id: peek.id]?.phase == .idle
				else { throw Failure.contentWasNotRespected }

				store.send(.peeks(.element(id: peek.id, action: .ui(.close))))
				try await wait { store.peeks[id: peek.id] == nil && engine.isAttached(sourceTab) }
			}
			try await waitForRestoration(
				Restoration(
					store: store,
					engine: engine,
					window: window,
					sourceTab: sourceTab,
					peekTab: peek.tab.id,
					original: original,
					originalResponder: originalResponder
				),
				host: source.host,
				phase: phase
			)
		}
		switch source.host {
		case .window: print("ARX_PEEK_ESCAPE_MAIN_SUCCESS")
		case .littleArx: print("ARX_PEEK_ESCAPE_LITTLE_SUCCESS")
		}
	}

	/// What closing a Peek must leave behind, checked together so a failure
	/// names every condition that was still off.
	@MainActor
	private struct Restoration {
		internal let store: StoreOf<AppFeature>
		internal let engine: ChromiumBrowserEngine
		internal let window: NSWindow
		internal let sourceTab: BrowserCore.Tab.ID
		internal let peekTab: BrowserCore.Tab.ID
		internal let original: BrowserNavigation
		internal let originalResponder: NSView

		internal enum Condition: String, Sendable {
			case navigation
			case firstResponder
			case history
			case workspace
		}

		internal func failed() -> [Condition] {
			var failed: [Condition] = []
			if engine.client.snapshot(sourceTab)?.navigation != original { failed.append(.navigation) }
			if window.firstResponder !== originalResponder { failed.append(.firstResponder) }
			if !peekHistory().isEmpty { failed.append(.history) }
			if store.workspace.tabs.ids.contains(peekTab) { failed.append(.workspace) }
			return failed
		}

		internal func describe(_ conditions: [Condition]) -> String {
			conditions.map { condition in
				switch condition {
				case .navigation:
					let current = engine.client.snapshot(sourceTab)?.navigation
					return "navigation=[\(Self.difference(original, current))]"

				case .firstResponder:
					let responder = window.firstResponder
					let inside = (responder as? NSView)?.isDescendant(of: originalResponder) == true
					return "firstResponder=[expected=\(Self.name(originalResponder)) "
						+ "actual=\(Self.name(responder)) insideExpected=\(inside) "
						+ "expectedWindow=\(originalResponder.window === window) "
						+ "key=\(window.isKeyWindow) appActive=\(NSApp.isActive)]"

				case .history:
					return "history=[\(peekHistory().map(\.absoluteString).joined(separator: ","))]"

				case .workspace:
					return "workspace=[peekTab=\(peekTab) attached=\(engine.isAttached(peekTab))]"
				}
			}
			.joined(separator: " ")
		}

		private func peekHistory() -> [URL] {
			store.history.snapshots.values.flatMap { snapshot in
				snapshot.entries.lazy.map(\.url).filter { $0.path == "/peek-escape.html" }
			}
		}

		private static func name(_ responder: NSResponder?) -> String {
			responder.map { "\(type(of: $0))@\(ObjectIdentifier($0).hashValue)" } ?? "nil"
		}

		private static func difference(
			_ expected: BrowserNavigation,
			_ actual: BrowserNavigation?
		) -> String {
			guard let actual else { return "snapshot=nil" }

			var fields: [String] = []
			func field<Value: Equatable>(
				_ name: String,
				_ keyPath: KeyPath<BrowserNavigation, Value>
			) {
				guard expected[keyPath: keyPath] != actual[keyPath: keyPath] else { return }
				fields.append("\(name):\(expected[keyPath: keyPath])->\(actual[keyPath: keyPath])")
			}
			field("url", \.url)
			field("title", \.title)
			field("isLoading", \.isLoading)
			field("errorCode", \.errorCode)
			field("canGoBack", \.canGoBack)
			field("canGoForward", \.canGoForward)
			field("history", \.history.count)
			if expected.history != actual.history, expected.history.count == actual.history.count {
				fields.append("historyEntries:changed")
			}
			if fields.isEmpty { fields.append("other") }
			return fields.joined(separator: " ")
		}
	}

	/// Closing a Peek restores focus through an effect and a SwiftUI update,
	/// so the source settles shortly after the Peek leaves the store.
	private static func waitForRestoration(
		_ restoration: Restoration,
		host: PeekFeature.Source.Host,
		phase: String
	) async throws {
		let clock = ContinuousClock()
		let start = clock.now
		var failed = restoration.failed()
		var polls = 0
		while !failed.isEmpty, polls < 50 {
			try await Task.sleep(for: .milliseconds(100))
			polls += 1
			failed = restoration.failed()
		}

		let elapsed = (clock.now - start).components
		let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
		let host = switch host {
		case .window: "main"
		case .littleArx: "little"
		}
		guard failed.isEmpty else {
			let message = "ARX_PEEK_ESCAPE_SOURCE_CHANGED host=\(host) phase=\(phase) "
				+ "elapsedMs=\(milliseconds) failed=\(failed.map(\.rawValue).joined(separator: ",")) "
				+ restoration.describe(failed) + "\n"
			FileHandle.standardError.write(Data(message.utf8))
			throw Failure.sourceChanged(failed.map(\.rawValue))
		}
		if polls > 0 {
			print("ARX_PEEK_ESCAPE_RESTORE_WAIT host=\(host) phase=\(phase) elapsedMs=\(milliseconds)")
		}
	}

	/// Waits until the source tab is not loading and its navigation has not
	/// changed for three consecutive polls.
	private static func settledNavigation(
		_ tabID: BrowserCore.Tab.ID,
		engine: ChromiumBrowserEngine
	) async throws -> BrowserNavigation {
		var previous: BrowserNavigation?
		var stable = 0
		for _ in 0..<100 {
			if let current = engine.client.snapshot(tabID)?.navigation, !current.isLoading {
				stable = current == previous ? stable + 1 : 0
				previous = current
				if stable >= 2 { return current }
			} else {
				previous = nil
				stable = 0
			}
			try await Task.sleep(for: .milliseconds(100))
		}

		FileHandle.standardError.write(Data("ARX_PEEK_ESCAPE_SOURCE_UNSETTLED tab=\(tabID)\n".utf8))
		throw Failure.sourceDidNotSettle
	}

	private static func key(
		_ type: NSEvent.EventType,
		window: NSWindow
	) -> NSEvent? {
		NSEvent.keyEvent(
			with: type,
			location: .zero,
			modifierFlags: [],
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: window.windowNumber,
			context: nil,
			characters: "\u{1b}",
			charactersIgnoringModifiers: "\u{1b}",
			isARepeat: false,
			keyCode: 53
		)
	}

	private static func wait(
		line: UInt = #line,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<100 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}

		let keyWindow = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
		let message = "ARX_PEEK_ESCAPE_SMOKE_TIMEOUT line=\(line) active=\(NSApp.isActive) key=\(keyWindow)\n"
		FileHandle.standardError.write(Data(message.utf8))
		throw Failure.timedOut
	}

	private enum Failure: Error {
		case invalidFixture
		case missingPeek
		case missingNativeFocus
		case contentWasNotRespected

		/// Names the restoration conditions still off after the wait:
		/// `navigation`, `firstResponder`, `history` or `workspace`.
		case sourceChanged([String])
		case sourceDidNotSettle
		case timedOut
	}
}
#endif
