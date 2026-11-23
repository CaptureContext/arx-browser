#if DEBUG
import AppKit
import AppLinkClient
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// The app smoke's `app-link` phase (DEV-857). Needs an ABI50 engine
/// (`external_link_requested`).
///
/// An owned loopback page in Little Arx redirects itself, without a click, to a link with an
/// unregistered test scheme carrying `;`, `$(…)` and quotes. A handler for that scheme runs a
/// script that records `$1` to a file. Arx's prompt must appear on the Little Arx window with
/// the Land verb, the recorded argument must equal the link exactly, and nothing may launch:
/// no app is registered for the scheme, Chrome's dialog never shows, Open app is never chosen
/// and the page stays where it was.
@MainActor
internal enum AppLinkSmoke {
	internal static let scheme: String = "arx-smoke-app-link"

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		windowID: UUID,
		baseURL: URL
	) async throws {
		guard
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			let little = store.littleWindows[id: windowID],
			let original = engine.client.snapshot(little.tab.id)?.navigation.url,
			let probe = URL(string: scheme + "://probe"),
			NSWorkspace.shared.urlForApplication(toOpen: probe) == nil
		else { throw Failure.invalidFixture }

		let directory = FileManager.default.temporaryDirectory
			.appending(path: "arx-app-link-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let record = directory.appending(path: "argument")

		// The handler runs the script in this profile; every other profile would open the app.
		let handler = AppLinkHandler(
			id: UUID(),
			name: "Smoke",
			scheme: scheme,
			defaultHandling: .systemDefault,
			overrides: [.init(
				profileID: little.tab.profileID,
				handling: .runScript(#"printf '%s' "$1" > "$ARX_SMOKE_RECORD""#
					.replacingOccurrences(of: "$ARX_SMOKE_RECORD", with: record.path(percentEncoded: false)))
			)]
		)
		let saved = store.settings.routingPreferences
		store.settings.$routingPreferences.withLock { $0.appLinks.handlers.append(handler) }
		defer { store.settings.$routingPreferences.withLock { $0 = saved } }

		let sourceTab = little.tab.id
		let page = baseURL.deletingLastPathComponent().appending(path: "app-link.html")
		try await engine.client.command(sourceTab, .navigate(page))

		// The page redirects on its own; Arx's prompt replaces Chrome's dialog on its window.
		try await wait(context: {
			"title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil") "
			+ promptSummary(store.appLinkPrompt, windowID: windowID, handlerID: handler.id)
		}) {
			guard let prompt = store.appLinkPrompt else { return false }
			return prompt.windowID == windowID
			&& prompt.phase == .asking
			&& prompt.isPresented
			&& prompt.handler.id == handler.id
			&& prompt.script != nil
			&& prompt.request.isRedirect
			&& !prompt.request.isPrivate
			&& prompt.request.sourceOrigin == "http://127.0.0.1:\(parts.port ?? 80)"
		}
		guard let link = store.appLinkPrompt?.request.link, link.hasPrefix(scheme + "://callback?code=")
		else { throw Failure.wrongLink }

		store.send(.appLinkPrompt(.ui(.confirm)))
		try await wait(context: { "phase=\(String(describing: store.appLinkPrompt?.phase))" }) {
			store.appLinkPrompt == nil
		}
		let recorded = try String(contentsOf: record, encoding: .utf8)
		guard recorded == link else {
			FileHandle.standardError.write(Data("ARX_APP_LINK_SMOKE_MISMATCH \(recorded.utf8.count)\n".utf8))
			throw Failure.wrongLink
		}
		guard !FileManager.default.fileExists(atPath: "/tmp/arx-app-link-pwned")
		else { throw Failure.injected }

		// The page stayed: Chrome launched nothing and navigated nowhere.
		guard engine.client.snapshot(sourceTab)?.navigation.title == "Arx App Link ready"
		else { throw Failure.navigated }

		try await engine.client.command(sourceTab, .navigate(original))
		try await wait {
			guard let navigation = engine.client.snapshot(sourceTab)?.navigation
			else { return false }
			return navigation.url == original && !navigation.isLoading
		}
		print("ARX_APP_LINK_SMOKE_SUCCESS")
	}

	internal static let appScheme: String = "arx-smoke-app-pick"

	/// DEV-862: a handler opens its links with an app chosen by path. The fixture applet
	/// (`ARX_APP_LINK_FIXTURE_APP`, built by `app_link_smoke.prepare_app`) declares no schemes
	/// and nothing is registered for `appScheme`, so the link it records can only have come
	/// from Arx opening it with that app. Then the handler points at an app that isn't there:
	/// the prompt must say so and open nothing until asked.
	internal static func runChosenApp(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		windowID: UUID,
		baseURL: URL
	) async throws {
		let environment = ProcessInfo.processInfo.environment
		guard
			let appPath = environment["ARX_APP_LINK_FIXTURE_APP"],
			let recordPath = environment["ARX_APP_LINK_FIXTURE_RECORD"],
			let choice = AppLinkApplications.choice(at: URL(filePath: appPath, directoryHint: .isDirectory)),
			let little = store.littleWindows[id: windowID],
			let original = engine.client.snapshot(little.tab.id)?.navigation.url,
			let probe = URL(string: appScheme + "://probe"),
			NSWorkspace.shared.urlForApplication(toOpen: probe) == nil
		else { throw Failure.invalidFixture }
		let record = URL(filePath: recordPath)
		try? FileManager.default.removeItem(at: record)
		defer { quitFixture(at: choice.application.path) }

		let handler = AppLinkHandler(
			id: UUID(),
			name: "Smoke App",
			scheme: appScheme,
			application: choice.application,
			defaultHandling: .systemDefault,
			overrides: [.init(profileID: little.tab.profileID, handling: .openApp(choice.application))]
		)
		let saved = store.settings.routingPreferences
		store.settings.$routingPreferences.withLock { $0.appLinks.handlers.append(handler) }
		defer { store.settings.$routingPreferences.withLock { $0 = saved } }

		let sourceTab = little.tab.id
		let page = baseURL.deletingLastPathComponent().appending(path: "app-link-app.html")
		try await engine.client.command(sourceTab, .navigate(page))
		try await wait(context: { "title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")" }) {
			guard let prompt = store.appLinkPrompt else { return false }
			return prompt.windowID == windowID
			&& prompt.phase == .asking
			&& prompt.handler.id == handler.id
			&& prompt.script == nil
			&& prompt.application == choice.application
			&& prompt.appName == choice.application.name
		}
		guard let link = store.appLinkPrompt?.request.link, link.hasPrefix(appScheme + "://callback?code=")
		else { throw Failure.wrongLink }

		store.send(.appLinkPrompt(.ui(.confirm)))
		try await wait(context: { "phase=\(String(describing: store.appLinkPrompt?.phase))" }) {
			store.appLinkPrompt == nil
		}

		// The applet launches, gets the link and writes it.
		try await wait(context: { "record=\(FileManager.default.fileExists(atPath: recordPath))" }) {
			(try? String(contentsOf: record, encoding: .utf8)) == link
		}

		// The chosen app is gone: the prompt says so, and nothing opens until asked.
		let missing = AppLinkApplication(
			path: choice.application.path + "-missing.app",
			bundleID: choice.application.bundleID,
			name: choice.application.name
		)
		store.settings.$routingPreferences.withLock { preferences in
			guard let index = preferences.appLinks.handlers.firstIndex(where: { $0.id == handler.id })
			else { return }
			preferences.appLinks.handlers[index].overrides[0].handling = .openApp(missing)
		}
		try await engine.client.command(sourceTab, .navigate(page))
		try await wait(context: { "missing title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil")" }) {
			guard let prompt = store.appLinkPrompt else { return false }
			return prompt.phase == .asking && prompt.application == missing && prompt.request.link != link
		}
		store.send(.appLinkPrompt(.ui(.confirm)))
		try await wait(context: { "missing phase=\(String(describing: store.appLinkPrompt?.phase))" }) {
			store.appLinkPrompt?.phase == .failed(.applicationMissing(missing))
		}
		guard (try? String(contentsOf: record, encoding: .utf8)) == link
		else { throw Failure.wrongLink }
		store.send(.appLinkPrompt(.ui(.cancel)))
		try await wait { store.appLinkPrompt == nil }

		try await engine.client.command(sourceTab, .navigate(original))
		try await wait {
			guard let navigation = engine.client.snapshot(sourceTab)?.navigation
			else { return false }
			return navigation.url == original && !navigation.isLoading
		}
		print("ARX_APP_LINK_APP_SMOKE_SUCCESS")
	}

	internal static let openScheme: String = "arx-smoke-app-open"

	/// DEV-1259: a link no handler takes gets Arx's prompt, never Chrome's "Open app?" dialog.
	/// The fixture applet (`ARX_APP_LINK_OPEN_FIXTURE_APP`, from `app_link_smoke.prepare_open_app`)
	/// declares `openScheme`, and Launch Services knows it for the run; no handler takes the
	/// scheme. The prompt must name the applet as the app macOS opens, Open must hand it the link,
	/// the page must stay where it was (Chrome launched and navigated nothing), and nothing may be
	/// saved without Always allow.
	internal static func runUnconfigured(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		windowID: UUID,
		baseURL: URL
	) async throws {
		let environment = ProcessInfo.processInfo.environment
		guard
			let appPath = environment["ARX_APP_LINK_OPEN_FIXTURE_APP"],
			let recordPath = environment["ARX_APP_LINK_OPEN_FIXTURE_RECORD"],
			let little = store.littleWindows[id: windowID],
			let original = engine.client.snapshot(little.tab.id)?.navigation.url,
			let probe = URL(string: openScheme + "://probe"),
			store.settings.routingPreferences.appLinks.handler(for: probe) == nil,
			let registered = NSWorkspace.shared.urlForApplication(toOpen: probe),
			registered.standardizedFileURL == URL(filePath: appPath, directoryHint: .isDirectory).standardizedFileURL
		else { throw Failure.invalidFixture }
		let record = URL(filePath: recordPath)
		try? FileManager.default.removeItem(at: record)
		defer { quitFixture(at: appPath) }
		let saved = store.settings.routingPreferences

		let sourceTab = little.tab.id
		let page = baseURL.deletingLastPathComponent().appending(path: "app-link-open.html")
		try await engine.client.command(sourceTab, .navigate(page))
		try await wait(context: {
			"title=\(engine.client.snapshot(sourceTab)?.navigation.title ?? "nil") "
			+ "prompt=\(String(describing: store.appLinkPrompt?.phase)) saved=\(String(describing: store.appLinkPrompt?.isSaved))"
		}) {
			guard let prompt = store.appLinkPrompt else { return false }
			return prompt.windowID == windowID
			&& prompt.phase == .asking
			&& prompt.isPresented
			&& !prompt.isSaved
			&& prompt.handler.scheme == openScheme
			&& prompt.handling == .systemDefault
			&& prompt.appPath.map { URL(filePath: $0).standardizedFileURL } == registered.standardizedFileURL
		}
		guard let link = store.appLinkPrompt?.request.link, link.hasPrefix(openScheme + "://callback?code=")
		else { throw Failure.wrongLink }

		// Chrome's path was dropped: the page is still the fixture, not a navigation or a dialog.
		guard engine.client.snapshot(sourceTab)?.navigation.title == "Arx App Link Open ready"
		else { throw Failure.navigated }

		store.send(.appLinkPrompt(.ui(.confirm)))
		try await wait(context: { "phase=\(String(describing: store.appLinkPrompt?.phase))" }) {
			store.appLinkPrompt == nil
		}
		try await wait(context: { "record=\(FileManager.default.fileExists(atPath: recordPath))" }) {
			(try? String(contentsOf: record, encoding: .utf8)) == link
		}

		// Open without Always allow remembers nothing.
		guard store.settings.routingPreferences == saved
		else { throw Failure.remembered }

		try await engine.client.command(sourceTab, .navigate(original))
		try await wait {
			guard let navigation = engine.client.snapshot(sourceTab)?.navigation
			else { return false }
			return navigation.url == original && !navigation.isLoading
		}

		// The next stage promotes this window, which needs the store's tab to hold the page it
		// shows: the store saves the address and title after the engine reports them.
		try await wait(context: { "store tab behind the page" }) {
			guard
				let navigation = engine.client.snapshot(sourceTab)?.navigation,
				let tab = store.littleWindows[id: windowID]?.tab
			else { return false }
			return tab.restoration.url == original && tab.restoration.title == navigation.title
		}
		print("ARX_APP_LINK_OPEN_SMOKE_SUCCESS")
	}

	/// The applet quits after recording; one that never got the link is stopped here.
	private static func quitFixture(at path: String) {
		let bundle = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
		for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == bundle {
			app.forceTerminate()
		}
	}

	/// Which of the prompt's checks hold, so a timeout says whether the link never arrived or
	/// arrived different from what the phase expects. Never the link itself.
	private static func promptSummary(
		_ prompt: AppLinkPrompt.State?,
		windowID: UUID,
		handlerID: UUID
	) -> String {
		guard let prompt
		else { return "prompt=nil" }

		return "prompt=\(prompt.phase)"
			+ " window=\(prompt.windowID == windowID)"
			+ " presented=\(prompt.isPresented)"
			+ " handler=\(prompt.handler.id == handlerID)"
			+ " script=\(prompt.script != nil)"
			+ " redirect=\(prompt.request.isRedirect)"
			+ " gesture=\(prompt.request.hasUserGesture)"
			+ " private=\(prompt.request.isPrivate)"
			+ " origin=\(prompt.request.sourceOrigin ?? "nil")"
	}

	private static func wait(
		line: UInt = #line,
		context: () -> String = { "" },
		until ready: () -> Bool
	) async throws {
		for _ in 0..<150 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}

		let message = "ARX_APP_LINK_SMOKE_TIMEOUT line=\(line) \(context())\n"
		FileHandle.standardError.write(Data(message.utf8))
		throw Failure.timedOut
	}

	private enum Failure: Error {
		case invalidFixture
		case wrongLink
		case injected
		case navigated
		case remembered
		case timedOut
	}
}
#endif
