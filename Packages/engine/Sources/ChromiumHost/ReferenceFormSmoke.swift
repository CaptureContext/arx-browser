import AppKit
import ChromiumEngine

/// The host validates fresh owned storage before constructing this fixture.
@MainActor
internal final class ReferenceFormSmoke {
	internal static let argument: String = "--reference-form-fixture"
	private let runtime: ChromiumRuntime
	private let baseURL: URL
	private let session: URLSession
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
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 2
		configuration.timeoutIntervalForResource = 4
		self.session = .init(configuration: configuration)
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_REFERENCE_FORM_SMOKE_VERIFIED")
			} catch {
				let reason: String
				switch error {
				case let error as ChromiumInspectionFailure: reason = String(describing: error)
				case let error as ReferenceFormSmokeContract.Failure: reason = String(describing: error)
				case is CancellationError: reason = "cancelled"
				default: reason = "unexpected-error"
				}
				diagnostic("ARX_REFERENCE_FORM_SMOKE_FAILED phase=\(phase) reason=\(reason)")
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
			session.invalidateAndCancel()
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		guard runtime.supportsReferenceFormActions
		else { throw ReferenceFormSmokeContract.Failure.unavailable }
		try await verifyDispatchAndReplay()
		try await verifyUnchangedAndOptions()
		try await verifyPropertyChanges()
		try await verifyEligibilityAndLifetime()
		try await verifyTimeoutAndNavigation()
	}

	private func verifyDispatchAndReplay() async throws {
		for target in ["text", "search", "textarea", "select"] {
			phase = "dispatch-\(target)"
			let fixture = try await makePage()
			let foreground = try await makePage()
			let scope = newScope()
			let request = try await request(fixture.page, target: target, scope: scope)
			let keyWindow = foreground.page.view.window
			let wasActive = NSApp.isActive
			guard let keyWindow, NSApp.keyWindow === keyWindow
			else { throw ReferenceFormSmokeContract.Failure.invalidFixture }

			try ReferenceFormSmokeContract.require(
				await perform(request, fixture: fixture, scope: scope),
				disposition: .dispatched
			)
			try ReferenceFormSmokeContract.requireEvents(
				try await waitEvents(fixture, count: 2),
				target: target
			)
			guard NSApp.keyWindow === keyWindow, NSApp.isActive == wasActive
			else { throw ReferenceFormSmokeContract.Failure.changedWindow }
			try ReferenceFormSmokeContract.require(
				await perform(request, fixture: fixture, scope: scope),
				disposition: .dispatched,
				failure: .duplicateOperation
			)
			let click = await runtime.clickInspectionReference(
				.init(
					operationID: request.operationID,
					snapshot: request.snapshot,
					reference: request.reference
				),
				on: fixture.page,
				scope: scope,
				authorize: { true }
			)
			guard click.disposition == .possiblyDispatched, click.failure == .duplicateOperation
			else { throw ReferenceFormSmokeContract.Failure.unexpectedReceipt }
			try ReferenceFormSmokeContract.requireEvents(try await events(fixture), target: target)
			fixture.page.close()
			foreground.page.close()
		}
		diagnostic("ARX_REFERENCE_FORM_SMOKE_DISPATCH_REPLAY")
	}

	private func verifyUnchangedAndOptions() async throws {
		for target in ["text", "select"] {
			phase = "unchanged-\(target)"
			let fixture = try await makePage()
			let scope = newScope()
			let action: ChromiumReferenceFormAction = target == "text"
			? .replaceText("original")
			: .selectValue("a")
			let request = try await request(
				fixture.page,
				target: target,
				scope: scope,
				action: action
			)
			try ReferenceFormSmokeContract.require(
				await perform(request, fixture: fixture, scope: scope),
				disposition: .unchanged
			)
			try ReferenceFormSmokeContract.require(
				await perform(request, fixture: fixture, scope: scope),
				disposition: .unchanged,
				failure: .duplicateOperation
			)
			guard try await events(fixture).isEmpty
			else { throw ReferenceFormSmokeContract.Failure.unexpectedEvents }
			fixture.page.close()
		}

		for value in ["missing", "duplicate", "disabled", "hidden", "css-hidden", "hidden-group"] {
			phase = "option-\(value)"
			let fixture = try await makePage()
			let scope = newScope()
			let request = try await request(
				fixture.page,
				target: "select",
				scope: scope,
				action: .selectValue(value)
			)
			let failure: ChromiumReferenceFormFailure = switch value {
			case "missing": .optionNotFound
			case "duplicate": .ambiguousOption
			default: .notInteractable
			}
			try ReferenceFormSmokeContract.require(
				await perform(request, fixture: fixture, scope: scope),
				disposition: .notDispatched,
				failure: failure
			)
			guard try await events(fixture).isEmpty
			else { throw ReferenceFormSmokeContract.Failure.unexpectedEvents }
			fixture.page.close()
		}
		diagnostic("ARX_REFERENCE_FORM_SMOKE_UNCHANGED_OPTIONS")
	}

	private func verifyPropertyChanges() async throws {
		let modes = [
			"value",
			"selection",
			"readonly",
			"maxlength",
			"type",
			"selected",
			"option-value",
			"replace",
		]
		for mode in modes {
			phase = "baseline-\(mode)"
			let fixture = try await makePage(mode: mode)
			let scope = newScope()
			let target = mode == "selected" || mode == "option-value" ? "select" : "text"
			let request = try await request(fixture.page, target: target, scope: scope)
			try mutate(fixture)
			let observed = try await waitEvents(fixture, count: 1)
			guard observed.first?.event == "mutation", observed.first?.trusted == true
			else { throw ReferenceFormSmokeContract.Failure.unexpectedEvents }

			if mode == "selection" {
				// Value/selected setters can also mutate Chromium's UA editor DOM.
				// Selection-only metadata establishes the independent baseline guard.
				// A different scope leaves the original scope's snapshot current.
				let after = try await runtime.inspect(fixture.page, scope: newScope())
				guard after.domVersion == request.snapshot.domVersion
				else { throw ReferenceFormSmokeContract.Failure.changedDOM }
			}
			try ReferenceFormSmokeContract.require(
				await perform(request, fixture: fixture, scope: scope),
				disposition: .notDispatched,
				failure: .staleReference
			)
			guard try await events(fixture).count == 1
			else { throw ReferenceFormSmokeContract.Failure.unexpectedEvents }
			fixture.page.close()
		}
		diagnostic("ARX_REFERENCE_FORM_SMOKE_PROPERTY_STALE")
	}

	private func verifyEligibilityAndLifetime() async throws {
		phase = "privacy-lifetime"
		let ordinary = try await makePage()
		let scope = newScope()
		let request = try await request(ordinary.page, target: "text", scope: scope)
		let exposesFormValues = request.snapshot.nodes.contains { node in
			(node.name ?? "").contains("ARX_FORM_") || (node.text ?? "").contains("ARX_FORM_")
		}
		guard !exposesFormValues
		else { throw ReferenceFormSmokeContract.Failure.invalidFixture }

		let profile = UUID()
		try runtime.preparePrivateProfile(profile)
		privateProfiles.append(profile)
		let privateFixture = try await makePage(profile: profile)
		try ReferenceFormSmokeContract.require(
			await perform(request, fixture: privateFixture, scope: scope),
			disposition: .notDispatched,
			failure: .unsupportedDocument
		)
		privateFixture.page.close()
		phase = "file-policy"
		let fileScope = newScope()
		let fileSnapshot = try await runtime.inspect(ordinary.page, scope: fileScope)
		let fileReferences = fileSnapshot.nodes
			.filter { $0.name == "Arx form file" }
			.compactMap(\.reference)
		guard fileReferences.count <= 1
		else { throw ReferenceFormSmokeContract.Failure.invalidFixture }

		if let reference = fileReferences.first {
			let fileRequest: ChromiumReferenceFormRequest = .init(
				operationID: UUID(),
				snapshot: fileSnapshot,
				reference: reference,
				action: .replaceText("replacement")
			)
			try ReferenceFormSmokeContract.require(
				await perform(fileRequest, fixture: ordinary, scope: fileScope),
				disposition: .notDispatched,
				failure: .unsupportedControl
			)
			diagnostic("ARX_REFERENCE_FORM_SMOKE_FILE_NATIVE_REFUSAL")

		} else {
			// No returned handle means this control cannot be addressed by the
			// public action boundary. Native direct-target policy is tested too.
			diagnostic("ARX_REFERENCE_FORM_SMOKE_FILE_UNADDRESSABLE")
		}
		runtime.revokeInspectionScope(scope)
		try ReferenceFormSmokeContract.require(
			await perform(copy(request), fixture: ordinary, scope: scope),
			disposition: .notDispatched,
			failure: .staleReference
		)
		ordinary.page.close()

		for mode in ["hidden", "oversized"] {
			phase = "eligibility-\(mode)"
			let fixture = try await makePage(mode: mode)
			let scope = newScope()
			let request = try await self.request(fixture.page, target: "text", scope: scope)
			try ReferenceFormSmokeContract.require(
				await perform(request, fixture: fixture, scope: scope),
				disposition: .notDispatched,
				failure: mode == "hidden" ? .notInteractable : .limitExceeded
			)
			fixture.page.close()
		}
		diagnostic("ARX_REFERENCE_FORM_SMOKE_PRIVACY_LIMITS")
	}

	private func verifyTimeoutAndNavigation() async throws {
		phase = "timeout"
		let slow = try await makePage(mode: "slow")
		let scope = newScope()
		let request = try await request(slow.page, target: "text", scope: scope, timeout: 50)
		try ReferenceFormSmokeContract.require(
			await perform(request, fixture: slow, scope: scope),
			disposition: .possiblyDispatched,
			failure: .timedOut
		)
		try ReferenceFormSmokeContract.requireEvents(try await waitEvents(slow, count: 2), target: "text")
		slow.page.close()

		phase = "cancel"
		let cancelled = try await makePage(mode: "slow")
		let cancelScope = newScope()
		let cancelRequest = try await self.request(cancelled.page, target: "text", scope: cancelScope)
		var authorized = false
		let task = Task {
			await runtime.performInspectionFormAction(cancelRequest, on: cancelled.page, scope: cancelScope) {
				authorized = true
				return true
			}
		}
		defer { task.cancel() }
		try await wait { authorized }
		task.cancel()
		try ReferenceFormSmokeContract.require(
			await task.value,
			disposition: .possiblyDispatched,
			failure: .cancelled
		)
		try ReferenceFormSmokeContract.requireEvents(try await waitEvents(cancelled, count: 2), target: "text")
		cancelled.page.close()

		phase = "navigation"
		let navigation = try await makePage(mode: "navigation")
		let navigationScope = newScope()
		let navigationRequest = try await self.request(navigation.page, target: "text", scope: navigationScope)
		let result = await perform(navigationRequest, fixture: navigation, scope: navigationScope)
		let dispatched = result.disposition == .dispatched && result.failure == nil
		let uncertain = result.disposition == .possiblyDispatched && result.failure == .staleReference
		guard dispatched || uncertain
		else { throw ReferenceFormSmokeContract.Failure.unexpectedReceipt }
		try await wait {
			navigation.page.navigation.url == self.baseURL.appending(path: "reference-form/destination")
			&& navigation.page.navigation.title == "Arx form destination"
			&& !navigation.page.navigation.isLoading
			&& navigation.page.navigation.errorCode == nil
		}
		try ReferenceFormSmokeContract.requireEvents(try await events(navigation), target: "text")
		navigation.page.close()
		diagnostic("ARX_REFERENCE_FORM_SMOKE_TIMEOUT_CANCEL_NAVIGATION")
	}

	private func request(
		_ page: ChromiumPage,
		target: String,
		scope: UUID,
		action: ChromiumReferenceFormAction? = nil,
		timeout: Int = 2_000
	) async throws -> ChromiumReferenceFormRequest {
		let snapshot = try await runtime.inspect(page, scope: scope)
		let defaultAction: ChromiumReferenceFormAction = switch target {
		case "select": .selectValue("b")
		case "textarea": .replaceText("replacement\nline")
		default: .replaceText("replacement")
		}
		return .init(
			operationID: UUID(),
			snapshot: snapshot,
			reference: try ReferenceFormSmokeContract.reference(in: snapshot, target: target),
			action: action ?? defaultAction,
			timeoutMilliseconds: timeout
		)
	}

	private func copy(_ request: ChromiumReferenceFormRequest) -> ChromiumReferenceFormRequest {
		.init(
			operationID: UUID(),
			snapshot: request.snapshot,
			reference: request.reference,
			action: request.action,
			timeoutMilliseconds: request.timeoutMilliseconds
		)
	}

	private func perform(
		_ request: ChromiumReferenceFormRequest,
		fixture: Fixture,
		scope: UUID
	) async -> ChromiumReferenceFormResult {
		await runtime.performInspectionFormAction(
			request,
			on: fixture.page,
			scope: scope,
			authorize: { true }
		)
	}

	private func makePage(
		mode: String = "main",
		profile: UUID? = nil
	) async throws -> Fixture {
		let run = UUID().uuidString.lowercased()
		let url = baseURL
			.appending(path: "reference-form/\(mode)")
			.appending(queryItems: [.init(name: "run", value: run)])
		let page = try await runtime.makePage(profile: profile)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 700),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.makeKeyAndOrderFront(nil)
		pages.append(page)
		windows[page.identifier] = window
		try page.navigate(to: url)
		try await wait {
			page.navigation.url == url
			&& page.navigation.title == "Arx form ready"
			&& !page.navigation.isLoading
			&& page.navigation.errorCode == nil
			&& page.view.window === window
		}
		return .init(page: page, run: run, url: url)
	}

	private func events(_ fixture: Fixture) async throws -> [ReferenceFormSmokeContract.Event] {
		let url = baseURL.appending(path: "reference-form/state/\(fixture.run)")
		var request = URLRequest(
			url: url,
			cachePolicy: .reloadIgnoringLocalCacheData,
			timeoutInterval: 2
		)
		request.httpMethod = "GET"
		let (data, response) = try await session.data(for: request)
		guard
			let response = response as? HTTPURLResponse,
			response.statusCode == 200,
			response.url == url
		else { throw ReferenceFormSmokeContract.Failure.invalidFixture }
		return try ReferenceFormSmokeContract.events(data)
	}

	private func waitEvents(
		_ fixture: Fixture,
		count: Int
	) async throws -> [ReferenceFormSmokeContract.Event] {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(15))
		while clock.now < deadline {
			let result = try await events(fixture)
			if result.count >= count { return result }
			try await Task.sleep(for: .milliseconds(20))
		}
		throw ReferenceFormSmokeContract.Failure.timeout
	}

	private func mutate(_ fixture: Fixture) throws {
		let page = fixture.page
		guard
			pages.contains(where: { $0 === page }),
			!page.isClosed,
			!page.isPrivate,
			let window = windows[page.identifier],
			window.contentView === page.view,
			page.view.window === window
		else { throw ReferenceFormSmokeContract.Failure.invalidFixture }
		window.makeKeyAndOrderFront(nil)
		guard
			window.isVisible,
			window.isKeyWindow,
			NSApp.keyWindow === window
		else { throw ReferenceFormSmokeContract.Failure.invalidFixture }

		let point = try ReferenceFormSmokeContract.inputPoint(
			currentURL: page.navigation.url,
			expectedURL: fixture.url,
			bounds: page.view.bounds,
			isFlipped: page.view.isFlipped
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
			else { throw ReferenceFormSmokeContract.Failure.invalidFixture }
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
			else { throw ReferenceFormSmokeContract.Failure.timeout }
			try await Task.sleep(for: .milliseconds(20))
		}
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}

	private struct Fixture {
		internal let page: ChromiumPage
		internal let run: String
		internal let url: URL

		internal init(
			page: ChromiumPage,
			run: String,
			url: URL
		) {
			self.page = page
			self.run = run
			self.url = url
		}
	}
}
