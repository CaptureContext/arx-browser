import AppKit
import ChromiumEngine

/// Executes static owned pages only, after the host validates disposable storage.
@MainActor
internal final class ReferenceKeypressSmoke {
	internal static let argument: String = "--reference-keypress-fixture"
	private let runtime: ChromiumRuntime
	private let baseURL: URL
	private let session: URLSession
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var scopes: [UUID] = []
	private var phase: String = "startup"
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) throws {
		self.runtime = runtime
		self.baseURL = try InspectionSmokeContract.baseURL(url)
		self.session = .init(configuration: .ephemeral)
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_REFERENCE_KEYPRESS_SMOKE_VERIFIED")
			} catch {
				let reason = (error as? Failure)?.rawValue
				?? (error is CancellationError ? "cancelled" : "fixture-check-failed")
				diagnostic("ARX_REFERENCE_KEYPRESS_SMOKE_FAILED phase=\(phase) reason=\(reason)")
			}
			for scope in scopes {
				runtime.revokeInspectionScope(scope)
			}
			for page in pages {
				page.close()
			}
			for window in windows {
				window.orderOut(nil)
				window.close()
			}
			session.invalidateAndCancel()
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		guard runtime.supportsReferenceKeypress else { throw Failure.unavailable }
		for (mode, key) in [
			("printable", "x"),
			("unicode", "🙂"),
			("backspace", "Backspace"),
			("delete", "Delete"),
			("left", "ArrowLeft"),
			("right", "ArrowRight"),
			("home", "Home"),
			("end", "End"),
			("fallback", "ArrowUp"),
			("up", "ArrowUp"),
			("down", "ArrowDown"),
			("enter", "Enter"),
		] {
			phase = mode
			let fixture = try await makePage(mode: mode)
			let request = try await request(fixture, key: key)
			try require(await perform(request, fixture: fixture), disposition: .dispatched)
			let evidence = try await settled(fixture)
			try requireEvidence(evidence, redirected: false)
			let count = evidence.count
			try require(
				await perform(request, fixture: fixture),
				disposition: .dispatched,
				failure: .duplicateOperation
			)
			let changed: ChromiumReferenceFormRequest = .init(
				operationID: request.operationID,
				snapshot: request.snapshot,
				reference: request.reference,
				action: .keyPress("z")
			)
			try require(
				await perform(changed, fixture: fixture),
				disposition: .possiblyDispatched,
				failure: .duplicateOperation
			)
			guard try await events(fixture).count == count
			else { throw Failure.replayed }
			fixture.page.close()
		}
		diagnostic("ARX_REFERENCE_KEYPRESS_SMOKE_EDITING_REPLAY")

		for mode in [
			"keydown-focus",
			"keydown-selection",
			"keydown-value",
			"beforeinput-focus",
			"beforeinput-selection",
			"textInput-focus",
			"textInput-selection",
		] {
			let keys = mode.hasPrefix("textInput") ? ["x"] : ["x", "Backspace", "Delete"]
			for key in keys {
				phase = "\(mode)-\(key)"
				let fixture = try await makePage(mode: mode)
				let request = try await request(fixture, key: key)
				try require(
					await perform(request, fixture: fixture),
					disposition: .possiblyDispatched,
					failure: .staleReference
				)
				try requireEvidence(try await settled(fixture), redirected: true)
				fixture.page.close()
			}
		}
		diagnostic("ARX_REFERENCE_KEYPRESS_SMOKE_HOSTILE_DEFAULTS")

		phase = "prevent-beforeinput"
		let prevented = try await makePage(mode: phase)
		let preventedRequest = try await request(prevented, key: "x")
		try require(await perform(preventedRequest, fixture: prevented), disposition: .dispatched)
		let preventedEvents = try await settled(prevented)
		try requireEvidence(preventedEvents, redirected: false)
		guard
			preventedEvents.contains(where: { $0.event == "beforeinput" }),
			!preventedEvents.contains(where: { $0.event == "input" })
		else {
			let summary = preventedEvents.map {
				"\($0.event):trusted=\($0.trusted),activation=\($0.activation),focused=\($0.focused),correct=\($0.correct)"
			}.joined(separator: " ")
			diagnostic("ARX_REFERENCE_KEYPRESS_EVIDENCE count=\(preventedEvents.count) " + summary)
			throw Failure.defaultNotSuppressed
		}
		prevented.page.close()

		phase = "enter-change"
		let submission = try await makePage(mode: phase)
		let submissionRequest = try await request(submission, key: "x")
		try require(await perform(submissionRequest, fixture: submission), disposition: .dispatched)
		_ = try await settled(submission)
		try require(
			await perform(try await request(submission, key: "Enter"), fixture: submission),
			disposition: .possiblyDispatched,
			failure: .staleReference
		)
		try await wait {
			let evidence = try await self.events(submission)
			return evidence.filter { $0.event == "settled" }.count == 2
		}
		try requireEvidence(try await events(submission), redirected: false)
		submission.page.close()
		diagnostic("ARX_REFERENCE_KEYPRESS_SMOKE_SUPPRESSION_SUBMISSION")

		try await verifyCancellationAndFocus()
	}

	private func verifyCancellationAndFocus() async throws {
		phase = "cancel-background"
		let fixture = try await makePage(mode: "slow")
		let request = try await request(fixture, key: "x")
		let foreground = try await makePage(mode: "printable")
		let keyWindow = NSApp.keyWindow
		let active = NSApp.isActive
		var authorized = false
		let task = Task {
			await runtime.performInspectionFormAction(request, on: fixture.page, scope: fixture.scope) {
				authorized = true
				return true
			}
		}
		defer { task.cancel() }
		try await wait { authorized }
		task.cancel()
		try require(await task.value, disposition: .possiblyDispatched, failure: .cancelled)
		try requireEvidence(try await settled(fixture), redirected: false)
		guard NSApp.keyWindow === keyWindow, NSApp.isActive == active
		else { throw Failure.changedWindow }
		try require(
			await perform(request, fixture: fixture),
			disposition: .possiblyDispatched,
			failure: .duplicateOperation
		)
		foreground.page.close()
		fixture.page.close()
		diagnostic("ARX_REFERENCE_KEYPRESS_SMOKE_CANCEL_FOCUS")
	}

	private func makePage(mode: String) async throws -> Fixture {
		let run = UUID().uuidString.lowercased()
		let url = baseURL
			.appending(path: "reference-keypress/\(mode)")
			.appending(queryItems: [.init(name: "run", value: run)])
		let page = try runtime.makePage()
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
		windows.append(window)
		let scope = UUID()
		scopes.append(scope)
		try page.navigate(to: url)
		do {
			try await wait {
				page.navigation.url == url
				&& page.navigation.title == "Arx keypress ready"
				&& !page.navigation.isLoading
				&& page.navigation.errorCode == nil
			}
		} catch Failure.timeout {
			let error = String(describing: page.navigation.errorCode)
			diagnostic("ARX_REFERENCE_KEYPRESS_LOAD loading=\(page.navigation.isLoading) error=\(error)")
			throw Failure.timeout
		}
		return .init(page: page, run: run, scope: scope)
	}

	private func request(
		_ fixture: Fixture,
		key: String
	) async throws -> ChromiumReferenceFormRequest {
		let snapshot = try await runtime.inspect(fixture.page, scope: fixture.scope)
		let matches = snapshot.nodes.filter { $0.name == "Arx keypress target" }
		guard matches.count == 1, let reference = matches.first?.reference
		else { throw Failure.missingReference }
		return .init(
			operationID: UUID(),
			snapshot: snapshot,
			reference: reference,
			action: .keyPress(key)
		)
	}

	private func perform(
		_ request: ChromiumReferenceFormRequest,
		fixture: Fixture
	) async -> ChromiumReferenceFormResult {
		await runtime.performInspectionFormAction(
			request,
			on: fixture.page,
			scope: fixture.scope,
			authorize: { true }
		)
	}

	private func events(_ fixture: Fixture) async throws -> [Event] {
		let url = baseURL.appending(path: "reference-keypress/state/\(fixture.run)")
		let (data, response) = try await session.data(for: .init(
			url: url,
			cachePolicy: .reloadIgnoringLocalCacheData,
			timeoutInterval: 2
		))
		guard
			let response = response as? HTTPURLResponse,
			response.statusCode == 200,
			response.url == url,
			data.count <= 16_384
		else { throw Failure.invalidEvidence }
		let envelope = try JSONDecoder().decode(Envelope.self, from: data)
		guard envelope.events.count <= 32 else { throw Failure.invalidEvidence }
		return envelope.events
	}

	private func settled(_ fixture: Fixture) async throws -> [Event] {
		do {
			try await wait { try await self.events(fixture).contains(where: { $0.event == "settled" }) }
		} catch Failure.timeout {
			let events = try await events(fixture)
			let summary = events.map {
				"\($0.target).\($0.event):trusted=\($0.trusted),activation=\($0.activation),focused=\($0.focused),correct=\($0.correct)"
			}.joined(separator: " ")
			diagnostic("ARX_REFERENCE_KEYPRESS_UNSETTLED count=\(events.count) " + summary)
			throw Failure.timeout
		}
		return try await events(fixture)
	}

	private func requireEvidence(
		_ events: [Event],
		redirected: Bool
	) throws {
		guard
			events.contains(where: { $0.event == "keydown" }),
			events.contains(where: { $0.event == "settled" }),
			events.allSatisfy({ $0.correct && !$0.activation && $0.target != "foreign" && $0.event != "submit" }),
			events.filter({ $0.event != "settled" }).allSatisfy(\.trusted),
			!redirected || !events.contains(where: { $0.event == "input" })
		else {
			let summary = events.map {
				"\($0.event):trusted=\($0.trusted),activation=\($0.activation),focused=\($0.focused),correct=\($0.correct)"
			}.joined(separator: " ")
			diagnostic("ARX_REFERENCE_KEYPRESS_EVIDENCE count=\(events.count) " + summary)
			throw Failure.defaultNotSuppressed
		}
	}

	private func require(
		_ result: ChromiumReferenceFormResult,
		disposition: ChromiumReferenceFormDisposition,
		failure: ChromiumReferenceFormFailure? = nil
	) throws {
		guard result.disposition == disposition, result.failure == failure else {
			let actualFailure = String(describing: result.failure)
			let expectedFailure = String(describing: failure)
			diagnostic(
				"ARX_REFERENCE_KEYPRESS_RECEIPT actual=\(result.disposition) failure=\(actualFailure) "
				+ "expected=\(disposition) expectedFailure=\(expectedFailure)"
			)
			throw Failure.receipt
		}
	}

	private func wait(_ condition: () async throws -> Bool) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(15))
		while try await !condition() {
			guard clock.now < deadline else { throw Failure.timeout }
			try await Task.sleep(for: .milliseconds(20))
		}
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}

	private struct Fixture {
		internal let page: ChromiumPage
		internal let run: String
		internal let scope: UUID

		internal init(
			page: ChromiumPage,
			run: String,
			scope: UUID
		) {
			self.page = page
			self.run = run
			self.scope = scope
		}
	}

	private struct Event: Decodable {
		internal let target: String
		internal let event: String
		internal let trusted: Bool
		internal let activation: Bool
		internal let focused: Bool
		internal let correct: Bool

		internal init(
			target: String,
			event: String,
			trusted: Bool,
			activation: Bool,
			focused: Bool,
			correct: Bool
		) {
			self.target = target
			self.event = event
			self.trusted = trusted
			self.activation = activation
			self.focused = focused
			self.correct = correct
		}
	}

	private struct Envelope: Decodable {
		internal let events: [Event]

		internal init(events: [Event]) {
			self.events = events
		}
	}

	private enum Failure: String, Error {
		case unavailable
		case missingReference
		case receipt
		case invalidEvidence
		case defaultNotSuppressed
		case replayed
		case changedWindow
		case timeout
	}
}
