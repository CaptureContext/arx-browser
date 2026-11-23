import AppKit
import ChromiumEngine

/// ABI43 cross-site link offers (DEV-727). Pages are served from 127.0.0.1 and link to
/// localhost, a different site. Each page is one link or button filling the window, which
/// the smoke clicks with window-local mouse events, so the click carries a user gesture
/// without touching the real pointer.
@MainActor
internal final class CrossSiteLinkSmoke {
	internal static let argument: String = "--cross-site-link-fixture"
	private static let readyTitle: String = "Arx cross-site ready"
	private static let arrivedTitle: String = "Arx cross-site arrived"

	private enum Failure: Error, CustomStringConvertible {
		case timedOut
		case click
		case unexpected(String)

		internal var description: String {
			switch self {
			case .timedOut: "timed-out"
			case .click: "click"
			case let .unexpected(detail): "unexpected \(detail)"
			}
		}
	}

	private let runtime: ChromiumRuntime
	private let baseURL: URL
	private var pages: [ChromiumPage] = []
	private var windows: [UInt64: NSWindow] = [:]
	private var privateProfiles: [UUID] = []
	private var offers: [(page: UInt64, url: URL)] = []
	private var takesOffers: Bool = false
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
		runtime.onCrossSiteLink = { [weak self] page, generation, url in
			guard let self else { return false }

			guard generation == self.runtime.documentRevision(for: page) else { return false }
			self.offers.append((page.identifier, url))
			return self.takesOffers
		}
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_CROSS_SITE_LINK_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_CROSS_SITE_LINK_SMOKE_FAILED phase=\(phase) reason=\(error)")
			}

			runtime.onCrossSiteLink = nil
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
		let other = otherSite("/cross-site-link/arrived")

		phase = "same-site"
		try await expectNavigation("same-site", to: url("arrived"), offered: false)
		diagnostic("ARX_CROSS_SITE_LINK_SMOKE_SAME_SITE")

		phase = "declined"
		try await expectNavigation("cross-site", to: other, offered: true)
		diagnostic("ARX_CROSS_SITE_LINK_SMOKE_DECLINED")

		phase = "taken"
		takesOffers = true
		let taken = try await makePage("cross-site")
		offers.removeAll()
		try click(taken)
		try await wait { !self.offers.isEmpty }
		try await settle()
		guard
			offers.count == 1,
			offers[0].page == taken.identifier,
			offers[0].url == other,
			taken.navigation.url == url("cross-site"),
			taken.navigation.title == Self.readyTitle,
			taken.navigation.errorCode == nil,
			!taken.navigation.isLoading
		else { throw Failure.unexpected("taken offers=\(offers.count) url=\(taken.navigation.url?.absoluteString ?? "none")") }
		close(taken)
		takesOffers = false
		diagnostic("ARX_CROSS_SITE_LINK_SMOKE_TAKEN")

		// Taking every offer from here on: anything offered would stay on its page.
		takesOffers = true
		phase = "redirect"
		try await expectNavigation("redirect", to: other, offered: false)
		diagnostic("ARX_CROSS_SITE_LINK_SMOKE_REDIRECT")

		phase = "form-post"
		try await expectNavigation("form-post", to: other, offered: false)
		diagnostic("ARX_CROSS_SITE_LINK_SMOKE_FORM_POST")

		phase = "scripted"
		let scripted = try await makePage("scripted")
		offers.removeAll()
		let scriptedTarget = otherSite("/cross-site-link/arrived?scripted")
		try await wait { scripted.navigation.url == scriptedTarget && scripted.navigation.title == Self.arrivedTitle }
		guard offers.isEmpty else { throw Failure.unexpected("scripted offered") }
		close(scripted)
		diagnostic("ARX_CROSS_SITE_LINK_SMOKE_SCRIPTED")

		phase = "private"
		let profile = UUID()
		try runtime.preparePrivateProfile(profile)
		privateProfiles.append(profile)
		try await expectNavigation("cross-site", to: other, offered: false, profile: profile)
		diagnostic("ARX_CROSS_SITE_LINK_SMOKE_PRIVATE")
	}

	/// Clicks the page and expects it to arrive at `destination`, offered once or never.
	private func expectNavigation(
		_ name: String,
		to destination: URL,
		offered: Bool,
		profile: UUID? = nil
	) async throws {
		let page = try await makePage(name, profile: profile)
		offers.removeAll()
		try click(page)
		try await wait { page.navigation.url == destination && page.navigation.title == Self.arrivedTitle }
		let expected = offered ? 1 : 0
		guard offers.count == expected, offers.allSatisfy({ $0.page == page.identifier })
		else { throw Failure.unexpected("\(name) offers=\(offers.count) expected=\(expected)") }
		close(page)
	}

	private func click(_ page: ChromiumPage) throws {
		let view = page.view
		guard
			let window = view.window,
			window.isVisible,
			!view.isHiddenOrHasHiddenAncestor
		else { throw Failure.click }

		let point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
		let location = view.convert(point, to: nil)
		let timestamp = ProcessInfo.processInfo.systemUptime
		for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: location,
				modifierFlags: [],
				timestamp: timestamp + Double(offset) * 0.001,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: offset + 1,
				clickCount: 1,
				pressure: offset == 0 ? 1 : 0
			)
			else { throw Failure.click }

			window.sendEvent(event)
		}
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

		// Let the first frame reach the compositor so the click hits the page.
		try await settle()
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
		URL(string: "/cross-site-link/\(name)", relativeTo: baseURL)!.absoluteURL
	}

	private func otherSite(_ path: String) -> URL {
		var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
		components.host = "localhost"
		let parts = path.split(separator: "?", maxSplits: 1)
		components.path = String(parts[0])
		components.query = parts.count > 1 ? String(parts[1]) : nil
		components.fragment = nil
		return components.url!
	}

	private func settle() async throws {
		try await Task.sleep(for: .milliseconds(500))
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
