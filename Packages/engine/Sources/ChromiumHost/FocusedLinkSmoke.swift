import AppKit
import ChromiumEngine

/// ABI37 focused links (DEV-713). Each fixture page focuses its own target with script,
/// so no keyboard input is needed. The host validates fresh owned storage first.
@MainActor
internal final class FocusedLinkSmoke {
	internal static let argument: String = "--focused-link-fixture"
	private static let readyTitle: String = "Arx focused link ready"

	private enum Failure: Error, CustomStringConvertible {
		case unavailable
		case timedOut
		case unexpected(page: String, link: String)

		internal var description: String {
			switch self {
			case .unavailable: "unavailable"
			case .timedOut: "timed-out"
			case let .unexpected(page, link): "unexpected page=\(page) link=\(link)"
			}
		}
	}

	private let runtime: ChromiumRuntime
	private let baseURL: URL
	private var pages: [ChromiumPage] = []
	private var windows: [UInt64: NSWindow] = [:]
	private var privateProfiles: [UUID] = []
	private var phase: String = "startup"
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.baseURL = url
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_FOCUSED_LINK_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_FOCUSED_LINK_SMOKE_FAILED phase=\(phase) reason=\(error)")
			}

			for page in pages {
				page.close()
			}
			for profile in privateProfiles {
				runtime.releasePrivateProfile(profile)
			}
			for window in windows.values {
				window.orderOut(nil)
				window.close()
			}
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		guard runtime.supportsFocusedLink
		else { throw Failure.unavailable }

		phase = "main-frame"
		try await expect("link", "https://capturecontext.dev/focused/main?a=1#fragment")
		try await expect("nested", "https://capturecontext.dev/focused/nested")
		try await expect("shadow", "https://capturecontext.dev/focused/shadow")

		// An SVG link's relative href resolves against the page.
		try await expect("svg", URL(string: "/focused/svg?a=1", relativeTo: baseURL)!.absoluteString)
		diagnostic("ARX_FOCUSED_LINK_SMOKE_MAIN_FRAME")

		phase = "same-origin-frame"
		try await expect("same-frame", "https://capturecontext.dev/focused/frame")
		diagnostic("ARX_FOCUSED_LINK_SMOKE_SAME_ORIGIN_FRAME")

		phase = "cross-origin-frame"
		try await expect("cross-frame", "https://capturecontext.dev/focused/frame")
		diagnostic("ARX_FOCUSED_LINK_SMOKE_CROSS_ORIGIN_FRAME")

		phase = "not-links"
		for name in ["field", "field-in-link", "button", "none", "script-link", "credentials"] {
			try await expect(name, nil)
		}
		diagnostic("ARX_FOCUSED_LINK_SMOKE_NOT_LINKS")

		phase = "stale"
		let stale = try await makePage("link")
		async let answer = runtime.focusedLink(on: stale)

		// The read is asked for first; the navigation then makes its answer stale.
		await Task.yield()
		try stale.navigate(to: url("none"))
		try require("stale", await answer, nil)

		// The page itself still answers for its new document.
		try await wait { stale.navigation.title == Self.readyTitle && !stale.navigation.isLoading }
		try require("stale-after", await runtime.focusedLink(on: stale), nil)
		close(stale)
		diagnostic("ARX_FOCUSED_LINK_SMOKE_STALE")

		phase = "private-hidden"
		let profile = UUID()
		try runtime.preparePrivateProfile(profile)
		privateProfiles.append(profile)
		let privatePage = try await makePage("link", profile: profile)
		try require("private", await runtime.focusedLink(on: privatePage), nil)
		close(privatePage)
		let hidden = try await makePage("link")
		windows[hidden.identifier]?.orderOut(nil)
		try require("hidden", await runtime.focusedLink(on: hidden), nil)
		close(hidden)
		diagnostic("ARX_FOCUSED_LINK_SMOKE_PRIVATE_HIDDEN")
	}

	private func expect(
		_ name: String,
		_ expected: String?
	) async throws {
		let page = try await makePage(name)
		let link = await runtime.focusedLink(on: page)
		if let link, link.documentRevision != runtime.documentRevision(for: page) {
			throw Failure.unexpected(page: name, link: "stale-revision")
		}
		try require(name, link, expected)
		close(page)
	}

	private func require(
		_ name: String,
		_ link: ChromiumFocusedLink?,
		_ expected: String?
	) throws {
		guard link?.url.absoluteString == expected
		else { throw Failure.unexpected(page: name, link: link?.url.absoluteString ?? "none") }
	}

	private func makePage(
		_ name: String,
		profile: UUID? = nil
	) async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: profile)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 480),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.makeKeyAndOrderFront(nil)
		pages.append(page)
		windows[page.identifier] = window
		try page.navigate(to: url(name))
		try await wait {
			page.navigation.url == self.url(name)
			&& page.navigation.title == Self.readyTitle
			&& !page.navigation.isLoading
			&& page.navigation.errorCode == nil
			&& page.view.window === window
		}
		return page
	}

	private func close(_ page: ChromiumPage) {
		page.close()
		pages.removeAll { $0 === page }
		if let window = windows.removeValue(forKey: page.identifier) {
			window.orderOut(nil)
			window.close()
		}
	}

	private func url(_ name: String) -> URL {
		URL(string: "/focused-link/\(name)", relativeTo: baseURL)!.absoluteURL
	}

	private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(15)
		while !condition() {
			guard Date() < deadline else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(25))
		}
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
