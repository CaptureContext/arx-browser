import AppKit
import ChromiumEngine

/// The host validates fresh owned storage before constructing this fixture.
@MainActor
internal final class ReferenceClickSmoke {
	internal static let argument: String = "--reference-click-fixture"
	private let runtime: ChromiumRuntime
	private let baseURL: URL
	private var pages: [ChromiumPage] = []
	private var windows: [UInt64: NSWindow] = [:]
	private var scopes: [UUID] = []
	private var privateProfiles: [UUID] = []
	private var phase: String = "startup"
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) throws {
		self.runtime = runtime
		self.baseURL = try InspectionSmokeContract.baseURL(url)
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_REFERENCE_CLICK_SMOKE_VERIFIED")
			} catch {
				let reason: String
				switch error {
				case let error as ChromiumInspectionFailure: reason = String(describing: error)
				case let error as ReferenceClickSmokeContract.Failure: reason = String(describing: error)
				case is CancellationError: reason = "cancelled"
				default: reason = "unexpected-error"
				}
				diagnostic("ARX_REFERENCE_CLICK_SMOKE_FAILED phase=\(phase) reason=\(reason)")
			}

			for scope in scopes {
				runtime.revokeInspectionScope(scope)
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
		guard runtime.supportsReferenceClick
		else { throw ReferenceClickSmokeContract.Failure.unavailable }

		try await verifyDispatchAndReplay()
		try await verifyStaleAndScope()
		try await verifyPrivacyAndEligibility()
		try await verifyTimeoutAndCancellation()
		try await verifyNavigation()
	}

	private func verifyDispatchAndReplay() async throws {
		phase = "dispatch-background"
		let page = try await makePage()
		let foreground = try await makePage(path: "reference-click/destination")
		guard let keyWindow = windows[foreground.identifier]
		else { throw ReferenceClickSmokeContract.Failure.invalidFixture }
		keyWindow.makeKeyAndOrderFront(nil)
		let scope = newScope()
		let request = try await request(page, scope: scope)
		let wasActive = NSApp.isActive
		guard
			NSApp.keyWindow === keyWindow,
			page.view.window !== keyWindow
		else { throw ReferenceClickSmokeContract.Failure.invalidFixture }

		try ReferenceClickSmokeContract.require(
			await click(request, page: page, scope: scope),
			disposition: .dispatched
		)
		try await wait { page.navigation.title == ReferenceClickSmokeContract.clickedTitle }
		guard NSApp.keyWindow === keyWindow, NSApp.isActive == wasActive
		else { throw ReferenceClickSmokeContract.Failure.changedWindow }
		try ReferenceClickSmokeContract.require(
			await click(request, page: page, scope: scope),
			disposition: .dispatched,
			failure: .duplicateOperation
		)
		try ReferenceClickSmokeContract.require(
			await click(request, page: foreground, scope: newScope()),
			disposition: .possiblyDispatched,
			failure: .duplicateOperation
		)
		guard page.navigation.title == ReferenceClickSmokeContract.clickedTitle
		else { throw ReferenceClickSmokeContract.Failure.unexpectedReceipt }
		page.close()
		foreground.close()
		diagnostic("ARX_REFERENCE_CLICK_SMOKE_DISPATCH_REPLAY")
	}

	private func verifyStaleAndScope() async throws {
		for reinsert in [false, true] {
			phase = reinsert ? "reinsert-stale" : "replacement-stale"
			let page = try await makePage()
			let scope = newScope()
			let request = try await request(page, scope: scope)
			try mutate(page, reinsert: reinsert)
			let expectedTitle = reinsert ? "Arx reference reinserted" : "Arx reference replaced"
			try await wait { page.navigation.title == expectedTitle }
			try ReferenceClickSmokeContract.require(
				await click(request, page: page, scope: scope),
				disposition: .notDispatched,
				failure: .staleReference
			)
			guard page.navigation.title == expectedTitle
			else { throw ReferenceClickSmokeContract.Failure.unexpectedReceipt }
			page.close()
		}

		phase = "latest-scope-close"
		let page = try await makePage()
		let scope = newScope()
		let original = try await request(page, scope: scope)
		let current = try await request(page, scope: scope)
		try ReferenceClickSmokeContract.require(
			await click(original, page: page, scope: scope),
			disposition: .notDispatched,
			failure: .staleReference
		)
		try ReferenceClickSmokeContract.require(
			await click(current, page: page, scope: newScope()),
			disposition: .notDispatched,
			failure: .staleReference
		)
		let revoked = try await request(page, scope: scope)
		runtime.revokeInspectionScope(scope)
		try ReferenceClickSmokeContract.require(
			await click(revoked, page: page, scope: scope),
			disposition: .notDispatched,
			failure: .staleReference
		)
		let closeScope = newScope()
		let closed = try await request(page, scope: closeScope)
		page.close()
		try ReferenceClickSmokeContract.require(
			await click(closed, page: page, scope: closeScope),
			disposition: .notDispatched,
			failure: .staleReference
		)
		diagnostic("ARX_REFERENCE_CLICK_SMOKE_STALE_SCOPE")
	}

	private func verifyPrivacyAndEligibility() async throws {
		phase = "hidden-private"
		let hidden = try await makePage(path: "reference-click/transparent")
		let scope = newScope()
		let request = try await request(hidden, scope: scope)
		try ReferenceClickSmokeContract.require(
			await click(request, page: hidden, scope: scope),
			disposition: .notDispatched,
			failure: .notInteractable
		)
		hidden.close()

		let ordinary = try await makePage()
		let ordinaryScope = newScope()
		let privateRequest = try await self.request(ordinary, scope: ordinaryScope)
		let profile = UUID()
		try runtime.preparePrivateProfile(profile)
		privateProfiles.append(profile)
		let privatePage = try await makePage(profile: profile)
		try ReferenceClickSmokeContract.require(
			await click(privateRequest, page: privatePage, scope: ordinaryScope),
			disposition: .notDispatched,
			failure: .unsupportedDocument
		)
		privatePage.close()
		ordinary.close()
		diagnostic("ARX_REFERENCE_CLICK_SMOKE_PRIVATE_HIDDEN")
	}

	private func verifyTimeoutAndCancellation() async throws {
		phase = "timeout-after-dispatch"
		let slow = try await makePage(path: "reference-click/slow")
		let scope = newScope()
		let request = try await request(slow, scope: scope, timeout: 50)
		try ReferenceClickSmokeContract.require(
			await click(request, page: slow, scope: scope),
			disposition: .possiblyDispatched,
			failure: .timedOut
		)
		try await wait { slow.navigation.title == ReferenceClickSmokeContract.clickedTitle }
		let duplicate = await click(request, page: slow, scope: scope)
		guard
			duplicate.failure == .duplicateOperation,
			duplicate.disposition != .notDispatched
		else { throw ReferenceClickSmokeContract.Failure.unexpectedReceipt }
		slow.close()

		phase = "cancel-after-submission"
		let cancelled = try await makePage(path: "reference-click/slow")
		let cancelScope = newScope()
		let cancelRequest = try await self.request(cancelled, scope: cancelScope)
		var authorized = false
		let task = Task { [self] in
			await runtime.clickInspectionReference(
				cancelRequest,
				on: cancelled,
				scope: cancelScope,
				authorize: {
					authorized = true
					return true
				}
			)
		}
		defer { task.cancel() }
		try await wait { authorized }
		task.cancel()
		try ReferenceClickSmokeContract.require(
			await task.value,
			disposition: .possiblyDispatched,
			failure: .cancelled
		)
		try await wait { cancelled.navigation.title == ReferenceClickSmokeContract.clickedTitle }
		cancelled.close()
		diagnostic("ARX_REFERENCE_CLICK_SMOKE_TIMEOUT_CANCEL")
	}

	private func verifyNavigation() async throws {
		phase = "navigation-effect"
		let page = try await makePage()
		let scope = newScope()
		let snapshot = try await runtime.inspect(page, scope: scope)
		let reference = try ReferenceClickSmokeContract.reference(
			in: snapshot,
			named: ReferenceClickSmokeContract.navigationName,
			role: "link"
		)
		let request: ChromiumReferenceClickRequest = .init(
			operationID: UUID(),
			snapshot: snapshot,
			reference: reference
		)
		let result = await click(request, page: page, scope: scope)
		try ReferenceClickSmokeContract.requireNavigationReceipt(result)
		try await wait {
			page.navigation.url == self.url("reference-click/destination")
			&& page.navigation.title == "Arx reference destination"
			&& !page.navigation.isLoading
			&& page.navigation.errorCode == nil
		}
		page.close()
		diagnostic("ARX_REFERENCE_CLICK_SMOKE_NAVIGATION")
	}

	private func request(
		_ page: ChromiumPage,
		scope: UUID,
		timeout: Int = 2_000
	) async throws -> ChromiumReferenceClickRequest {
		let snapshot = try await runtime.inspect(page, scope: scope)
		let reference = try ReferenceClickSmokeContract.reference(
			in: snapshot,
			named: ReferenceClickSmokeContract.buttonName
		)
		return .init(
			operationID: UUID(),
			snapshot: snapshot,
			reference: reference,
			timeoutMilliseconds: timeout
		)
	}

	private func click(
		_ request: ChromiumReferenceClickRequest,
		page: ChromiumPage,
		scope: UUID
	) async -> ChromiumReferenceClickResult {
		await runtime.clickInspectionReference(
			request,
			on: page,
			scope: scope,
			authorize: { true }
		)
	}

	private func makePage(
		path: String = "reference-click/main",
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
		try page.navigate(to: url(path))
		let title = path == "reference-click/destination"
		? "Arx reference destination"
		: ReferenceClickSmokeContract.readyTitle
		try await wait {
			page.navigation.url == self.url(path)
			&& page.navigation.title == title
			&& !page.navigation.isLoading
			&& page.navigation.errorCode == nil
			&& page.view.window === window
		}
		return page
	}

	private func mutate(
		_ page: ChromiumPage,
		reinsert: Bool
	) throws {
		guard
			pages.contains(where: { $0 === page }),
			!page.isClosed,
			!page.isPrivate,
			let window = windows[page.identifier],
			window.contentView === page.view,
			page.view.window === window
		else { throw ReferenceClickSmokeContract.Failure.invalidFixture }
		window.makeKeyAndOrderFront(nil)
		guard
			window.isVisible,
			window.isKeyWindow,
			NSApp.keyWindow === window
		else { throw ReferenceClickSmokeContract.Failure.invalidFixture }

		let point = try ReferenceClickSmokeContract.inputPoint(
			currentURL: page.navigation.url,
			expectedURL: url("reference-click/main"),
			bounds: page.view.bounds,
			isFlipped: page.view.isFlipped,
			reinsert: reinsert
		)
		let location = page.view.convert(point, to: nil)
		for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
			guard
				let event = NSEvent.mouseEvent(
					with: type,
					location: location,
					modifierFlags: [],
					timestamp: ProcessInfo.processInfo.systemUptime,
					windowNumber: window.windowNumber,
					context: nil,
					eventNumber: type == .leftMouseDown ? 1 : 2,
					clickCount: 1,
					pressure: type == .leftMouseDown ? 1 : 0
				)
			else { throw ReferenceClickSmokeContract.Failure.invalidFixture }

			// Direct delivery is confined to this validated fixture window.
			window.sendEvent(event)
		}
	}

	private func newScope() -> UUID {
		let scope = UUID()
		scopes.append(scope)
		return scope
	}

	private func wait(_ condition: () -> Bool) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(15))
		while !condition() {
			guard clock.now < deadline
			else { throw ReferenceClickSmokeContract.Failure.timeout }
			try await Task.sleep(for: .milliseconds(20))
		}
	}

	private func url(_ path: String) -> URL {
		baseURL.appending(path: path)
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}
}
