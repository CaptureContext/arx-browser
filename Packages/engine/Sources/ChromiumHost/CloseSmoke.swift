import AppKit
import ChromiumEngine

/// Developer-only fixture. The host validates fresh owned storage and a loopback URL
/// before running; no user profile or interactive before-unload dialog is involved.
@MainActor
internal final class CloseSmoke {
	internal static let argument: String = "--close-fixture"
	private let runtime: ChromiumRuntime
	private let url: URL
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var revisions: [UInt64: Int] = [:]
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.url = url
	}

	internal func open() {
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_CLOSE_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_CLOSE_SMOKE_FAILED: \(error)")
			}

			for page in pages { page.close() }
			for window in windows { window.orderOut(nil) }
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		let first = try makePage()
		let second = try makePage()
		try first.navigate(to: url)
		try second.navigate(to: url)
		try await wait(first, after: 0, url: url)
		try await wait(second, after: 0, url: url)

		let cancelled = try await approval(first)
		try requireStale { try runtime.consumeClose(cancelled, for: second) }
		guard !second.isClosed, !first.isClosed
		else { throw Failure.unexpectedClosure }

		runtime.cancelClose(cancelled)
		try requireStale { try runtime.consumeClose(cancelled, for: first) }
		diagnostic("ARX_CLOSE_SMOKE_CANCEL_OTHER_PAGE")

		let navigated = try await approval(first)
		let beforeNavigation = revisions[first.identifier, default: 0]
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		components?.queryItems = [.init(name: "document", value: UUID().uuidString)]
		guard let destination = components?.url
		else { throw Failure.invalidFixture }

		try first.navigate(to: destination)

		// Deliberately consume before yielding to queued Swift navigation callbacks.
		try requireStale { try runtime.consumeClose(navigated, for: first) }
		guard !first.isClosed else { throw Failure.unexpectedClosure }
		try await wait(first, after: beforeNavigation, url: destination)
		diagnostic("ARX_CLOSE_SMOKE_NAVIGATION_STALE")

		let reloaded = try await approval(first)
		let beforeReload = revisions[first.identifier, default: 0]
		try first.reload()
		try requireStale { try runtime.consumeClose(reloaded, for: first) }
		guard !first.isClosed else { throw Failure.unexpectedClosure }
		try await wait(first, after: beforeReload, url: destination)
		diagnostic("ARX_CLOSE_SMOKE_RELOAD_STALE")

		let current = try await approval(first)
		try runtime.consumeClose(current, for: first)
		guard first.isClosed, !second.isClosed
		else { throw Failure.unexpectedClosure }

		try requireStale { try runtime.consumeClose(current, for: first) }
		let beforeSurvivorReload = revisions[second.identifier, default: 0]
		try second.reload()
		try await wait(second, after: beforeSurvivorReload, url: url)
		diagnostic("ARX_CLOSE_SMOKE_CONSUMED_ONCE")
	}

	private func approval(_ page: ChromiumPage) async throws -> ChromiumCloseApproval {
		guard let approval = try await runtime.approveClose(page)
		else { throw Failure.refused }
		return approval
	}

	private func requireStale(_ action: () throws -> Void) throws {
		do {
			try action()
			throw Failure.acceptedStaleApproval
		} catch ChromiumCloseFailure.staleDocument {
			// Exact expected failure; unrelated errors fail the fixture.
		}
	}

	private func makePage() throws -> ChromiumPage {
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
		page.onNavigation = { [weak self, weak page] _ in
			guard let self, let page else { return }
			self.revisions[page.identifier, default: 0] += 1
		}
		pages.append(page)
		windows.append(window)
		return page
	}

	private func wait(
		_ page: ChromiumPage,
		after revision: Int,
		url: URL
	) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(15))

		while clock.now < deadline {
			guard
				revisions[page.identifier, default: 0] > revision,
				page.navigation.url == url,
				page.navigation.title == "Arx engine smoke",
				!page.navigation.isLoading,
				page.navigation.errorCode == nil,
				page.view.window != nil
			else {
				try await Task.sleep(for: .milliseconds(20))
				continue
			}

			return
		}

		throw Failure.timeout
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}

	private enum Failure: Error {
		case refused
		case unexpectedClosure
		case acceptedStaleApproval
		case invalidFixture
		case timeout
	}
}
