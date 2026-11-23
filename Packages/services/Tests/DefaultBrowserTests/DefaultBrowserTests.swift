import DefaultBrowserClient
import Foundation
import Testing
import _TestSupport

@MainActor
internal struct DefaultBrowserTests {
	// MARK: - Status

	@Test
	internal func statusIsDefaultOnlyWhenArxHandlesBothSchemes() {
		let world: World = .init(handled: [.http, .https])
		#expect(world.client.status() == .isDefault)

		world.handled = [.http]
		#expect(world.client.status() == .otherBrowser("Safari"))
	}

	@Test
	internal func statusIsUnavailableWithoutTouchingLaunchServices() {
		let world: World = .init(handled: [], isAvailable: false)

		#expect(world.client.status() == .unavailable)
		#expect(world.checks == 0)
	}

	// MARK: - Results

	@Test
	internal func acceptedWhenThePromptChangesTheDefault() async {
		let world: World = .init(handled: [])

		// macOS changes https together with http.
		world.answer = { world.handled = [.http, .https] }

		#expect(await world.client.makeDefault() == .accepted)
		#expect(world.requests == [.http])
	}

	@Test
	internal func asksForHTTPSWhenHTTPDidNotCarryIt() async {
		let world: World = .init(handled: [])
		world.answer = { world.handled.insert(world.requests.last ?? .http) }

		#expect(await world.client.makeDefault() == .accepted)
		#expect(world.requests == [.http, .https])
	}

	@Test
	internal func declinedWhenThePromptThrows() async {
		let world: World = .init(handled: [])
		world.answer = { throw CocoaError(.userCancelled) }

		#expect(await world.client.makeDefault() == .declined)
		// A declined http prompt isn't followed by a second one.
		#expect(world.requests == [.http])
	}

	@Test
	internal func declinedWhenThePromptReturnsWithoutAChange() async {
		let world: World = .init(handled: [])

		#expect(await world.client.makeDefault() == .declined)
		#expect(world.requests == [.http])
	}

	@Test
	internal func alreadyDefaultAsksNothing() async {
		let world: World = .init(handled: [.http, .https])

		#expect(await world.client.makeDefault() == .alreadyDefault)
		#expect(world.requests.isEmpty)
	}

	@Test
	internal func unavailableAsksNothing() async {
		let world: World = .init(handled: [], isAvailable: false)

		#expect(await world.client.makeDefault() == .unavailable)
		#expect(world.requests.isEmpty)
		#expect(world.checks == 0)
	}

	// MARK: - Automated runs

	@Test
	internal func automatedRunsNeverUseTheSystem() {
		let app: String = "/Applications/Arx.app/Contents/MacOS/Arx"

		#expect(DefaultBrowserClient.isEnabled(environment: [:], arguments: [app]))
		#expect(!DefaultBrowserClient.isEnabled(environment: ["XCTestConfigurationFilePath": "x"], arguments: [app]))
		#expect(!DefaultBrowserClient.isEnabled(environment: ["XCTestBundlePath": "x"], arguments: [app]))
		#expect(!DefaultBrowserClient.isEnabled(environment: ["XCTestSessionIdentifier": "x"], arguments: [app]))
		#expect(!DefaultBrowserClient.isEnabled(environment: ["ARX_ENGINE_PROFILE": "smoke"], arguments: [app]))
		#expect(!DefaultBrowserClient.isEnabled(environment: ["ARX_SKIP_DEFAULT_BROWSER": "1"], arguments: [app]))
		#expect(!DefaultBrowserClient.isEnabled(environment: [:], arguments: [app, "--headless"]))
		#expect(!DefaultBrowserClient.isEnabled(environment: [:], arguments: [app, "--arx-smoke=peek"]))
	}

	@Test
	internal func unavailableClientReportsUnavailable() async {
		let client: DefaultBrowserClient = .unavailable

		#expect(client.status() == .unavailable)
		#expect(await client.makeDefault() == .unavailable)
	}
}

/// Launch Services as the client sees it.
@MainActor
private final class World {
	internal var handled: Set<DefaultBrowserClient.Scheme>
	internal var isAvailable: Bool
	internal var answer: @MainActor () throws -> Void
	internal var requests: [DefaultBrowserClient.Scheme]
	internal var checks: Int

	internal init(
		handled: Set<DefaultBrowserClient.Scheme>,
		isAvailable: Bool = true
	) {
		self.handled = handled
		self.isAvailable = isAvailable
		self.answer = {}
		self.requests = []
		self.checks = 0
	}

	internal var client: DefaultBrowserClient {
		.init(
			isAvailable: { self.isAvailable },
			isDefault: { scheme in
				self.checks += 1
				return self.handled.contains(scheme)
			},
			currentBrowserName: { "Safari" },
			requestDefault: { scheme in
				self.requests.append(scheme)
				try self.answer()
			}
		)
	}
}
