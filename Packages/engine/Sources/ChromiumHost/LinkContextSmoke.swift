import AppKit
import ChromiumEngine

/// Runs only with the host's validated disposable profile and loopback fixture.
/// Mouse events go to the actual Chromium view; no context callback is synthesized.
@MainActor
internal final class LinkContextSmoke {
	internal static let argument: String = "--link-context-fixture"
	private let runtime: ChromiumRuntime
	private let url: URL
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var received: [ChromiumLinkContext] = []
	private var observation: Task<Void, Never>?
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.url = url
	}

	internal func open() {
		let events = runtime.linkContextEvents()
		observation = Task { [weak self] in
			for await context in events { self?.received.append(context) }
		}
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_LINK_CONTEXT_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_LINK_CONTEXT_SMOKE_FAILED: \(error)")
			}
			observation?.cancel()
			for page in pages { page.close() }
			for window in windows { window.orderOut(nil) }
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		let ordinary = try await makePage()
		let main = try await request(ordinary, x: 30, y: 35)
		try require(main, page: ordinary, path: "/main", text: "Main [link]", x: 30, y: 35)
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MAIN_TARGET")

		// Chromium suppresses further requests while a context menu is showing.
		// Match the app's menu-dismiss lifecycle before requesting another target.
		runtime.dismissLinkContext(page: ordinary.identifier, token: main.token)
		let nested = try await request(ordinary, x: 70, y: 185)
		try require(nested, page: ordinary, path: "/frame", text: "Frame [link]", x: 70, y: 185)
		guard nested.token != main.token, !runtime.linkContextIsCurrent(main, on: ordinary)
		else { throw Failure.acceptedStale }

		// Dismissing an earlier menu must not revoke its replacement.
		runtime.dismissLinkContext(page: ordinary.identifier, token: main.token)
		guard runtime.linkContextIsCurrent(nested, on: ordinary)
		else { throw Failure.notCurrent }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_SOURCE_AND_ROOT_COORDINATES")
		try await wait { !self.runtime.linkContextIsCurrent(nested, on: ordinary) }
		guard ordinary.navigation.url?.path == "/link-context/main"
		else { throw Failure.wrongSource }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_SOURCE_FRAME_STALE")
		let beforeNavigation = try await request(ordinary, x: 30, y: 35)
		let destination = url.deletingLastPathComponent().appending(path: "link-context/destination")
		try ordinary.navigate(to: destination)
		guard !runtime.linkContextIsCurrent(beforeNavigation, on: ordinary)
		else { throw Failure.acceptedStale }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_REPLACEMENT_NAVIGATION_STALE")

		let profile = UUID()
		try runtime.preparePrivateProfile(profile)
		let privatePage = try await makePage(profileID: profile)
		guard privatePage.isPrivate else { throw Failure.wrongSource }
		let privateContext = try await request(privatePage, x: 30, y: 35)
		try require(
			privateContext,
			page: privatePage,
			path: "/main",
			text: "Main [link]",
			x: 30,
			y: 35
		)
		privatePage.close()
		guard !runtime.linkContextIsCurrent(privateContext, on: privatePage)
		else { throw Failure.acceptedStale }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_PRIVATE_CLOSE")

		try await verifyDownloadReferrer()
		diagnostic("ARX_LINK_CONTEXT_SMOKE_DOWNLOAD_REFERRER")

		// DEV-853: every link gets the menu, as in Chromium, whatever its port or scheme.
		let schemes = try await makePage(path: "link-context/schemes")
		let port = try await request(schemes, x: 30, y: 35)
		try require(
			port,
			page: schemes,
			url: "http://localhost:3000/port?a=1",
			text: "Port [link]",
			x: 30,
			y: 35
		)
		runtime.dismissLinkContext(page: schemes.identifier, token: port.token)
		diagnostic("ARX_LINK_CONTEXT_SMOKE_NONDEFAULT_PORT")
		let mail = try await request(schemes, x: 30, y: 135)
		try require(
			mail,
			page: schemes,
			url: "mailto:hello@capturecontext.dev?subject=Arx",
			text: "Mail [link]",
			x: 30,
			y: 135
		)
		runtime.dismissLinkContext(page: schemes.identifier, token: mail.token)
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MAILTO")

		// ABI48 (DEV-814, DEV-818): the menus for text fields, selections, images, media and
		// the page menu's Share….
		try await ContextMenuSmoke(runtime: runtime, url: url) { [unowned self] path in
			try await makePage(path: path)
		}.verify()
	}

	/// DEV-851: the fixture's file answers only a request whose referrer is its page. Download
	/// Linked File, started from the link's menu, gets it; a plain download of the same URL
	/// doesn't.
	private func verifyDownloadReferrer() async throws {
		let folder = FileManager.default.temporaryDirectory
			.appending(path: "arx-link-download-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let initial = try await runtime.downloadSettings(profile: nil)
		_ = try await runtime.setDownloadSettings(profile: nil, directory: folder.path, ask: false)

		let page = try await makePage(path: "link-context/download")
		let context = try await request(page, x: 30, y: 35)
		let events = runtime.downloadEvents()
		guard let started = runtime.startLinkContextDownload(context, on: page)
		else { throw Failure.download("link download refused") }

		runtime.dismissLinkContext(page: page.identifier, token: context.token)
		let linked = try await finished(try await runtime.linkContextDownload(started), in: events)
		guard
			linked.state == .complete,
			let target = linked.target,
			try Data(contentsOf: target) == Data("arx-referrer-ok".utf8)
		else { throw Failure.download("link download \(linked.state) reason=\(linked.interruptReason)") }

		let plainURL = url.deletingLastPathComponent().appending(path: "link-context/protected.bin")
		let plainEvents = runtime.downloadEvents()
		let plain = try await finished(try await runtime.startDownload(profileKey: "", url: plainURL), in: plainEvents)
		guard plain.state != .complete
		else { throw Failure.download("a download without the page's referrer got the file") }

		_ = try await runtime.setDownloadSettings(profile: nil, directory: initial.directory, ask: initial.ask)
	}

	/// The download's first state other than in progress.
	private func finished(
		_ guid: String,
		in events: AsyncStream<ChromiumDownloadEvent>
	) async throws -> ChromiumDownload {
		for await event in events {
			guard case let .changed(download) = event, download.guid == guid else { continue }

			if download.state != .inProgress { return download }
		}
		throw Failure.download("download events ended")
	}

	private func makePage(
		profileID: UUID? = nil,
		path: String = "link-context/main"
	) async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: profileID)
		pages.append(page)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 700, height: 500),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
		windows.append(window)
		try page.navigate(to: url.deletingLastPathComponent().appending(path: path))
		return page
	}

	private func request(
		_ page: ChromiumPage,
		x: Double,
		y: Double
	) async throws -> ChromiumLinkContext {
		try await wait { page.navigation.title == "Arx link context ready" && !page.navigation.isLoading }

		// Allow the embedded frame's first layout to reach the compositor.
		try await Task.sleep(for: .milliseconds(250))
		guard let window = page.view.window else { throw Failure.wrongSource }
		window.makeKeyAndOrderFront(nil)
		let local = NSPoint(x: x, y: page.view.isFlipped ? y : page.view.bounds.height - y)
		let point = page.view.convert(local, to: nil)
		let before = received.count
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
			else { throw Failure.invalidEvent }
			window.sendEvent(event)
		}
		try await wait { self.received.count > before }
		return received[before]
	}

	private func require(
		_ context: ChromiumLinkContext,
		page: ChromiumPage,
		path: String,
		text: String,
		x: Double,
		y: Double
	) throws {
		try require(
			context,
			page: page,
			url: "https://capturecontext.dev\(path)?a=1&a=2#fragment",
			text: text,
			x: x,
			y: y
		)
	}

	private func require(
		_ context: ChromiumLinkContext,
		page: ChromiumPage,
		url: String,
		text: String,
		x: Double,
		y: Double
	) throws {
		guard
			context.pageID == page.identifier,
			context.documentGeneration > 0,
			context.url.absoluteString == url,
			context.text == text,
			abs(context.x - x) <= 2,
			abs(context.y - y) <= 2,
			runtime.linkContextIsCurrent(context, on: page)
		else { throw Failure.wrongSource }
	}

	private func wait(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(25))
		}
	}

	private enum Failure: Error {
		case timedOut
		case wrongSource
		case invalidEvent
		case acceptedStale
		case notCurrent
		case download(String)
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
