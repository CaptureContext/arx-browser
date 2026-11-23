import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1009: a page that stopped answering asks Wait or Reload, and an agent's request that
/// timed out on one reloads it and says so.
@Suite(.dependencies)
@MainActor
internal struct UnresponsivePageTests {
	@Test
	internal func theCardAsksUntilThePersonWaitsOnThisHang() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var state = ViewerItemFeature.State(tab: tab, navigation: .init(url: tab.restoration.url, unresponsive: 2))
		#expect(state.asksAboutHang)
		state.failure = "Renderer stopped"
		#expect(!state.asksAboutHang)
		state.failure = nil
		state.navigation.unresponsive = 0
		#expect(!state.asksAboutHang)

		let waited = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = TestStore(
			initialState: ViewerItemFeature.State(tab: tab, navigation: .init(url: tab.restoration.url, unresponsive: 2))
		) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.waitForPage = { id in
				waited.withValue { $0.append(id) }
				return true
			}
		}
		await store.send(.ui(.waitForPage)) {
			$0.waitedHang = 2
		}
		await store.finish()
		expectNoDifference(waited.value, [tab.id])
		#expect(!store.state.asksAboutHang)

		// The engine checked again and the page still doesn't answer: a new hang asks again.
		var next = store.state
		next.navigation.unresponsive = 3
		#expect(next.asksAboutHang)
	}

	@Test
	internal func waysOutOfADocumentEndAHungRendererFirst() {
		let leaving: [BrowserEngineClient.Command] = [
			.navigate(URL(string: "https://example.com")!), .back, .forward, .reload, .reloadBypassingCache,
			.clearCacheAndReload, .stop, .historyEntry(1),
		]
		#expect(leaving.allSatisfy { $0.leavesTheDocument })
		#expect(!BrowserEngineClient.Command.openDeveloperTools.leavesTheDocument)
		#expect(!BrowserEngineClient.Command.stopFind.leavesTheDocument)
	}

	@Test
	internal func aTimedOutRequestOnAPageThatDoesntAnswerReloadsItAndSaysSo() async throws {
		let fixture = try Self.fixture()
		let ended = LockIsolated<[BrowserCore.Tab.ID]>([])
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		let responses = LockIsolated<[AutomationResult]>([])
		let store = TestStore(initialState: fixture.state) { BrowserAutomation() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.pingPage = { _, _ in false }
			$0.browserEngine.snapshot = { _ in Self.snapshot(document: 5) }
			$0.browserEngine.endRenderer = { id in
				ended.withValue { $0.append(id) }
				return true
			}
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
			$0.automationControl.respond = { _, result in responses.withValue { $0.append(result) } }
		}
		store.exhaustivity = .off

		await store.send(.automation(.event(.finished(fixture.requestID, .failure(.timedOut)))))
		await store.receive(\.automation.event.pageNotAnswering)
		await store.receive(\.automation.event.finished)
		await store.finish()
		expectNoDifference(ended.value, [fixture.tab])
		expectNoDifference(commands.value, [.reload])
		expectNoDifference(responses.value, [.failure(.pageNotAnswering)])
		#expect(store.state.automation.pending[fixture.requestID] == nil)
		#expect(store.state.automation.hangChecks.isEmpty)
	}

	/// nil: the engine couldn't ask, as for a page waiting on its own dialog or frozen by Chromium.
	@Test(arguments: [true, nil] as [Bool?])
	internal func aTimedOutRequestOnAPageThatAnswersOrIsHeldStaysATimeout(answer: Bool?) async throws {
		let fixture = try Self.fixture()
		let ended = LockIsolated<[BrowserCore.Tab.ID]>([])
		let responses = LockIsolated<[AutomationResult]>([])
		let store = TestStore(initialState: fixture.state) { BrowserAutomation() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.pingPage = { _, _ in answer }
			$0.browserEngine.snapshot = { _ in Self.snapshot(document: 5) }
			$0.browserEngine.endRenderer = { id in
				ended.withValue { $0.append(id) }
				return true
			}
			$0.automationControl.respond = { _, result in responses.withValue { $0.append(result) } }
		}
		store.exhaustivity = .off

		await store.send(.automation(.event(.finished(fixture.requestID, .failure(.timedOut)))))
		await store.receive(\.automation.event.finished)
		await store.finish()
		expectNoDifference(ended.value, [])
		expectNoDifference(responses.value, [.failure(.timedOut)])
	}

	@Test
	internal func recoveryEndsNothingOnceTheRequestIsNoLongerAuthorized() async throws {
		let fixture = try Self.fixture()
		let ended = LockIsolated<[BrowserCore.Tab.ID]>([])
		let responses = LockIsolated<[AutomationResult]>([])
		var state = fixture.state
		state.automationPreferences.clients[0].isPaused = true
		let store = TestStore(initialState: state) { BrowserAutomation() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.pingPage = { _, _ in false }
			$0.browserEngine.snapshot = { _ in Self.snapshot(document: 5) }
			$0.browserEngine.endRenderer = { id in
				ended.withValue { $0.append(id) }
				return true
			}
			$0.automationControl.respond = { _, result in responses.withValue { $0.append(result) } }
		}
		store.exhaustivity = .off

		await store.send(.automation(.event(.finished(fixture.requestID, .failure(.timedOut)))))

		// Paused while it asked: the request ends with its own timeout, and nothing is ended.
		await store.receive(\.automation.event.pageNotAnswering)
		await store.finish()
		expectNoDifference(ended.value, [])
		expectNoDifference(responses.value, [.failure(.timedOut)])
	}

	@Test
	internal func recoveryLeavesADocumentThatReplacedTheFrozenOne() async throws {
		let fixture = try Self.fixture()
		let ended = LockIsolated<[BrowserCore.Tab.ID]>([])
		let reads = LockIsolated(0)
		let responses = LockIsolated<[AutomationResult]>([])
		let store = TestStore(initialState: fixture.state) { BrowserAutomation() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.pingPage = { _, _ in false }

			// The person reloaded while the ping waited: the second read is a new document.
			$0.browserEngine.snapshot = { _ in
				reads.withValue { $0 += 1 }
				return Self.snapshot(document: reads.value == 1 ? 5 : 6)
			}
			$0.browserEngine.endRenderer = { id in
				ended.withValue { $0.append(id) }
				return true
			}
			$0.automationControl.respond = { _, result in responses.withValue { $0.append(result) } }
		}
		store.exhaustivity = .off

		await store.send(.automation(.event(.finished(fixture.requestID, .failure(.timedOut)))))
		await store.receive(\.automation.event.pageNotAnswering)
		await store.finish()
		expectNoDifference(ended.value, [])
		expectNoDifference(responses.value, [.failure(.timedOut)])
	}

	@Test
	internal func mediaAndPasswordSignInTimeoutsCount() {
		#expect(AutomationResult.media(.init(action: .play, failure: .timedOut)).failure == .timedOut)
		#expect(AutomationResult.passwordSignIn(.init(operationID: UUID(), outcome: .failed, reason: .timedOut)).failure == .timedOut)
	}

	private static func snapshot(document: UInt64) -> BrowserSessionSnapshot {
		.init(navigation: .init(), revision: 1, documentRevision: document, isVisibleForCapture: false)
	}

	private static func fixture() throws -> (state: AppFeature.State, requestID: UUID, tab: BrowserCore.Tab.ID) {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: true,
			allowsPageContent: true,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		let request = AutomationRequest(
			id: UUID(90),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .wait(.init(targetID: tab.id.rawValue, expectedRevision: "r", condition: .loadingStopped, timeoutMilliseconds: 1000))
		)
		state.automation.pending[request.id] = .init(request: request, grantRevision: UUID(82), approved: true, executing: true)
		return (state, request.id, tab.id)
	}
}
