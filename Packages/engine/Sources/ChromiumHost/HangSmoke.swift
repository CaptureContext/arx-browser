import AppKit
import ChromiumEngine

/// DEV-1009. A loopback page that loops forever once a key reaches it: Chromium reports it
/// unresponsive after the key goes unanswered, Wait asks the engine to check again and the
/// hang comes back with a new number, ending its renderer reports the renderer gone, and the
/// page loads again on a new one. DEV-1135: a script on the looping page times out and lets
/// the page go, so the next one isn't refused as busy, and a script on another page answers
/// at once. Developer-only fixture on fresh owned storage.
@MainActor
internal final class HangSmoke {
	internal static let argument: String = "--hang-fixture"
	private let runtime: ChromiumRuntime
	private let url: URL
	private var page: ChromiumPage?
	private var window: NSWindow?
	internal private(set) var verified: Bool = false

	internal enum Failure: Error {
		case timeout(String)
		case unavailable
		case script(String)
	}

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.url = url.deletingLastPathComponent().appending(path: "hang.html")
	}

	internal func open() {
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_HANG_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_HANG_SMOKE_FAILED: \(error)")
			}
			page?.close()
			window?.orderOut(nil)
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		let page = try runtime.makePage()
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 480),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.makeKeyAndOrderFront(nil)
		NSApp.activate()
		self.page = page
		self.window = window

		var looping = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		looping.queryItems = [.init(name: "loop", value: "1")]
		try page.navigate(to: looping.url!)
		try await wait("load") { page.navigation.title == "Arx hang" && !page.navigation.isLoading }

		// A key the page never answers: its keydown handler loops forever.
		page.focusContent()
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: "a",
				charactersIgnoringModifiers: "a",
				isARepeat: false,
				keyCode: 0
			) else { throw Failure.unavailable }
			window.sendEvent(event)
		}
		try await wait("unresponsive", seconds: 45) { page.navigation.unresponsive != 0 }
		let first = page.navigation.unresponsive
		diagnostic("ARX_HANG_SMOKE_REPORTED")

		guard runtime.waitForPage(page) else { throw Failure.unavailable }
		try await wait("asked again", seconds: 45) { page.navigation.unresponsive > first }
		diagnostic("ARX_HANG_SMOKE_WAIT_ASKS_AGAIN")

		try await scriptsOutlastATimeout(on: page)
		diagnostic("ARX_HANG_SMOKE_TIMEOUT_LETS_GO")

		guard runtime.endRenderer(page) else { throw Failure.unavailable }
		try await wait("ended") { page.navigation.errorCode != nil && page.navigation.unresponsive == 0 }
		diagnostic("ARX_HANG_SMOKE_ENDED")

		try page.navigate(to: url)
		try await wait("reloaded") {
			page.navigation.url == self.url && page.navigation.title == "Arx hang"
			&& !page.navigation.isLoading && page.navigation.errorCode == nil
		}
		diagnostic("ARX_HANG_SMOKE_RELOADED")
	}

	/// DEV-1135. The looping page never answers a script. Its first times out; the second is
	/// taken, not refused as busy, so the first let go of the page and its app-wide slot, which
	/// share one table; it times out too. A script on another page answers well within its time.
	/// That page is the same server as `localhost`, another site, so site isolation gives it a
	/// renderer of its own rather than the looping one.
	private func scriptsOutlastATimeout(on page: ChromiumPage) async throws {
		guard runtime.supportsDeveloperTier else { throw Failure.unavailable }
		for attempt in 1 ... 2 {
			do {
				_ = try await runtime.evaluateScript(page, source: "return 1;", maximumBytes: 1024, timeoutMilliseconds: 1000)
				throw Failure.script("the looping page answered script \(attempt)")
			} catch ChromiumDeveloperFailure.timedOut {
				continue
			} catch let failure as ChromiumDeveloperFailure {
				throw Failure.script("script \(attempt) on the looping page: \(failure)")
			}
		}

		var otherSite = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		otherSite.host = "localhost"
		guard let otherURL = otherSite.url, url.host == "127.0.0.1" else { throw Failure.unavailable }
		let other = try runtime.makePage()
		defer { other.close() }
		try other.navigate(to: otherURL)
		try await wait("other page") {
			other.navigation.url == otherURL && other.navigation.title == "Arx hang" && !other.navigation.isLoading
		}
		let start = ContinuousClock.now
		let value = try await runtime.evaluateScript(other, source: "return 2;", maximumBytes: 1024, timeoutMilliseconds: 5000)
		guard case .json("2") = value, start.duration(to: .now) < .seconds(2)
		else { throw Failure.script("the other page answered \(value) after \(start.duration(to: .now))") }
	}

	private func wait(
		_ step: String,
		seconds: Int = 15,
		_ condition: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure.timeout(step) }
			try await Task.sleep(for: .milliseconds(50))
		}
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}
}
