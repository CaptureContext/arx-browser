import AppKit
import ChromiumEngine

/// The host validates fresh owned storage before constructing this fixture.
@MainActor
internal final class ReferenceScrollSmoke {
	internal static let argument: String = "--reference-scroll-fixture"
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
				diagnostic("ARX_REFERENCE_SCROLL_SMOKE_VERIFIED")
			} catch {
				let reason: String
				switch error {
				case let error as ChromiumInspectionFailure: reason = String(describing: error)
				case let error as ReferenceScrollSmokeContract.Failure: reason = String(describing: error)
				case is CancellationError: reason = "cancelled"
				default: reason = "unexpected-error"
				}
				diagnostic("ARX_REFERENCE_SCROLL_SMOKE_FAILED phase=\(phase) reason=\(reason)")
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
		guard runtime.supportsReferenceScroll
		else { throw ReferenceScrollSmokeContract.Failure.unavailable }
		try await verifyNestedReplayAndClamp()
		try await verifyAxesAndContainers()
		try await verifyPrivacyAndLifetime()
		try await verifyNavigation()
	}

	private func verifyNestedReplayAndClamp() async throws {
		phase = "nested-replay"
		let fixture = try await makePage()
		let foreground = try await makePage()
		let scope = newScope()
		let request = try await request(fixture.page, scope: scope)
		let keyWindow = foreground.page.view.window
		let wasActive = NSApp.isActive
		guard let keyWindow, NSApp.keyWindow === keyWindow
		else { throw ReferenceScrollSmokeContract.Failure.invalidFixture }

		try ReferenceScrollSmokeContract.require(
			await perform(request, fixture: fixture, scope: scope),
			disposition: .dispatched
		)
		let moved = try await waitEvidence(fixture) { $0.innerY == 80 && $0.events > 0 }
		try requireOffsets(moved, [0, 80, 0, 0, 0, 0])
		guard NSApp.keyWindow === keyWindow, NSApp.isActive == wasActive
		else { throw ReferenceScrollSmokeContract.Failure.changedWindow }

		try ReferenceScrollSmokeContract.require(
			await perform(request, fixture: fixture, scope: scope),
			disposition: .dispatched,
			failure: .duplicateOperation
		)
		let stable = try await waitEvidence(fixture) { $0.sample >= moved.sample + 2 }
		try requireOffsets(stable, moved.offsets)
		guard stable.events == moved.events
		else { throw ReferenceScrollSmokeContract.Failure.unexpectedEffect }

		phase = "clamp-no-chain"
		let clamp = try await self.request(fixture.page, scope: scope, delta: 8_192)
		try ReferenceScrollSmokeContract.require(
			await perform(clamp, fixture: fixture, scope: scope),
			disposition: .dispatched
		)
		let end = try await waitEvidence(fixture) { $0.innerAtEnd && $0.events > stable.events }
		try requireOffsets(end, [0, end.innerY, 0, 0, 0, 0])
		let noOp = try await self.request(fixture.page, scope: scope)
		try ReferenceScrollSmokeContract.require(
			await perform(noOp, fixture: fixture, scope: scope),
			disposition: .unchanged
		)
		let after = try await waitEvidence(fixture) { $0.sample >= end.sample + 2 }
		try requireOffsets(after, end.offsets)
		guard after.events == end.events, after.innerAtEnd
		else { throw ReferenceScrollSmokeContract.Failure.unexpectedEffect }
		fixture.page.close()
		foreground.page.close()
		diagnostic("ARX_REFERENCE_SCROLL_SMOKE_NESTED_REPLAY_CLAMP")
	}

	private func verifyAxesAndContainers() async throws {
		for target in ["anchor", "container", "viewport", "hidden"] {
			phase = "container-\(target)"
			let fixture = try await makePage(mode: target == "hidden" ? "hidden" : "main")
			let scope = newScope()
			let request = try await request(
				fixture.page,
				scope: scope,
				target: target == "hidden" ? "anchor" : target,
				axis: target == "anchor" ? .horizontal : .vertical
			)
			try ReferenceScrollSmokeContract.require(
				await perform(request, fixture: fixture, scope: scope),
				disposition: .dispatched
			)
			let expected: [Double] = switch target {
			case "anchor": [0, 0, 80, 0, 0, 0]
			case "container": [0, 80, 0, 0, 0, 0]
			case "viewport": [0, 0, 0, 0, 0, 80]
			default: [0, 0, 0, 80, 0, 0]
			}
			let effect = try await waitEvidence(fixture) { $0.offsets == expected && $0.events > 0 }
			try requireOffsets(effect, expected)
			fixture.page.close()
		}
		diagnostic("ARX_REFERENCE_SCROLL_SMOKE_AXES_CONTAINERS")
	}

	private func verifyPrivacyAndLifetime() async throws {
		phase = "privacy-lifetime"
		let fixture = try await makePage()
		let scope = newScope()
		let request = try await request(fixture.page, scope: scope)
		let exposesFixtureText = request.snapshot.nodes.contains { node in
			(node.name ?? "").contains("ARX_SCROLL_") || (node.text ?? "").contains("ARX_SCROLL_")
		}
		guard !exposesFixtureText
		else { throw ReferenceScrollSmokeContract.Failure.invalidFixture }

		let profile = UUID()
		try runtime.preparePrivateProfile(profile)
		privateProfiles.append(profile)
		let privateFixture = try await makePage(profile: profile)
		try ReferenceScrollSmokeContract.require(
			await perform(request, fixture: privateFixture, scope: scope),
			disposition: .notDispatched,
			failure: .unsupportedDocument
		)
		privateFixture.page.close()

		let invalid = try await self.request(fixture.page, scope: scope, delta: 8_193)
		try ReferenceScrollSmokeContract.require(
			await perform(invalid, fixture: fixture, scope: scope),
			disposition: .notDispatched,
			failure: .invalidDelta
		)
		let stale = try await self.request(fixture.page, scope: scope)
		runtime.revokeInspectionScope(scope)
		try ReferenceScrollSmokeContract.require(
			await perform(stale, fixture: fixture, scope: scope),
			disposition: .notDispatched,
			failure: .staleReference
		)
		let closeScope = newScope()
		let closed = try await self.request(fixture.page, scope: closeScope)
		fixture.page.close()
		try ReferenceScrollSmokeContract.require(
			await perform(closed, fixture: fixture, scope: closeScope),
			disposition: .notDispatched,
			failure: .staleReference
		)
		diagnostic("ARX_REFERENCE_SCROLL_SMOKE_PRIVACY_LIFETIME")
	}

	private func verifyNavigation() async throws {
		phase = "navigation"
		let fixture = try await makePage(mode: "navigation")
		let scope = newScope()
		let request = try await request(fixture.page, scope: scope)
		try ReferenceScrollSmokeContract.requireNavigation(
			await perform(request, fixture: fixture, scope: scope)
		)
		try await wait {
			fixture.page.navigation.url == self.baseURL.appending(path: "reference-scroll/destination")
			&& fixture.page.navigation.title == "Arx scroll destination"
			&& !fixture.page.navigation.isLoading
			&& fixture.page.navigation.errorCode == nil
		}
		let effect = try await waitEvidence(fixture) { $0.events > 0 }
		try requireOffsets(effect, [0, 80, 0, 0, 0, 0])
		fixture.page.close()
		diagnostic("ARX_REFERENCE_SCROLL_SMOKE_NAVIGATION")
	}

	private func request(
		_ page: ChromiumPage,
		scope: UUID,
		target: String = "anchor",
		axis: ChromiumReferenceScrollAxis = .vertical,
		delta: Double = 80
	) async throws -> ChromiumReferenceScrollRequest {
		let snapshot = try await runtime.inspect(page, scope: scope)
		return .init(
			operationID: UUID(),
			snapshot: snapshot,
			reference: try ReferenceScrollSmokeContract.reference(in: snapshot, target: target),
			axis: axis,
			deltaCSSPixels: delta
		)
	}

	private func perform(
		_ request: ChromiumReferenceScrollRequest,
		fixture: Fixture,
		scope: UUID
	) async -> ChromiumReferenceScrollResult {
		await runtime.scrollInspectionReference(
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
			.appending(path: "reference-scroll/\(mode)")
			.appending(queryItems: [.init(name: "run", value: run)])
		let page = try await runtime.makePage(profile: profile)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 800, height: 700),
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
			&& page.navigation.title == "Arx scroll ready"
			&& !page.navigation.isLoading
			&& page.navigation.errorCode == nil
			&& page.view.window === window
		}
		let fixture = Fixture(page: page, run: run, url: url)
		let initial = try await waitEvidence(fixture) { $0.sample > 0 }
		try requireOffsets(initial, [0, 0, 0, 0, 0, 0])
		return fixture
	}

	private func evidence(_ fixture: Fixture) async throws -> ReferenceScrollSmokeContract.Evidence? {
		let url = baseURL.appending(path: "reference-scroll/state/\(fixture.run)")
		let request = URLRequest(
			url: url,
			cachePolicy: .reloadIgnoringLocalCacheData,
			timeoutInterval: 2
		)
		let (data, response) = try await session.data(for: request)
		guard let response = response as? HTTPURLResponse, response.url == url
		else { throw ReferenceScrollSmokeContract.Failure.invalidFixture }
		if response.statusCode == 404 {
			return nil
		}
		guard response.statusCode == 200
		else { throw ReferenceScrollSmokeContract.Failure.invalidFixture }
		return try ReferenceScrollSmokeContract.evidence(data)
	}

	private func waitEvidence(
		_ fixture: Fixture,
		matching condition: (ReferenceScrollSmokeContract.Evidence) -> Bool
	) async throws -> ReferenceScrollSmokeContract.Evidence {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(15))
		while clock.now < deadline {
			if let result = try await evidence(fixture), condition(result) {
				return result
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		throw ReferenceScrollSmokeContract.Failure.timeout
	}

	private func requireOffsets(
		_ evidence: ReferenceScrollSmokeContract.Evidence,
		_ expected: [Double]
	) throws {
		try ReferenceScrollSmokeContract.requireSafe(evidence)
		guard evidence.offsets == expected
		else { throw ReferenceScrollSmokeContract.Failure.unexpectedEffect }
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
			else { throw ReferenceScrollSmokeContract.Failure.timeout }
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
