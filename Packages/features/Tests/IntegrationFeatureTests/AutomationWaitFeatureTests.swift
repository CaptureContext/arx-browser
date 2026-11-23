import BrowserAutomationClient
import BrowserCore
import BrowserPageWaitClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationWaitFeatureTests {
	@Test(arguments: [nil, -105, -3] as [Int?])
	internal func readOnlyWaitReportsStoppedOrFailedObservationWithoutChangingPresentation(error: Int?) async throws {
		let fixture = Fixture()
		fixture.snapshots[fixture.tab.id]?.navigation.errorCode = error
		let before = fixture.store.state
		await fixture.send(try fixture.request()).finish()
		guard case let .wait(result) = fixture.responses.first else {
			Issue.record("Read-only wait did not return its stopped observation")
			return
		}
		expectNoDifference(result.errorCode, error)
		expectNoDifference(result.status, error == nil ? .stopped : .stoppedWithError)
		expectNoDifference(fixture.store.workspace, before.workspace)
		expectNoDifference(fixture.store.main, before.main)
		expectNoDifference(fixture.store.focusedWindowID, before.focusedWindowID)
		expectNoDifference(fixture.calls.count, 1)
		#expect(fixture.store.automation.usedOperations.isEmpty)
	}

	@Test
	internal func sameGenerationTitleAndLoadingChangesDoNotReuseEntryRevision() async throws {
		let fixture = Fixture()
		fixture.holdsWait = true
		fixture.snapshots[fixture.tab.id]?.navigation.isLoading = true
		let request = try fixture.request()
		let task = fixture.send(request)
		try await fixture.waitForObservation()
		fixture.snapshots[fixture.tab.id]?.revision = 5
		fixture.snapshots[fixture.tab.id]?.navigation.title = "New published title"
		fixture.snapshots[fixture.tab.id]?.navigation.isLoading = false
		#expect(fixture.store.state.automationCanExecute(request.id, snapshots: fixture.snapshots, now: .distantPast))
		fixture.release()
		await task.finish()
		guard case let .wait(result) = fixture.responses.first else {
			Issue.record("A same-generation publication incorrectly invalidated the wait")
			return
		}
		expectNoDifference(result.sessionRevision, 5)
		#expect(result.observedRevision != result.request.expectedRevision)
		let client = fixture.store.automationPreferences.clients[0]
		let current = AutomationInventoryBuilder.items(
			client: client,
			organization: fixture.store.workspace,
			snapshots: fixture.snapshots
		).first { $0.id == fixture.tab.id.rawValue }
		expectNoDifference(result.observedRevision, current?.revision)
	}

	@Test(arguments: [
		"grant", "foreign", "private", "unloaded", "epoch",
		"privileged", "nativeUnavailable", "staleRevision", "authentication",
	])
	internal func invalidEntryDoesNotBeginObservation(reason: String) async throws {
		let fixture = Fixture(readAllowed: reason != "grant")
		if reason == "unloaded" { fixture.snapshots = [:] }
		if reason == "epoch" { fixture.snapshots[fixture.tab.id]?.documentRevision = nil }
		if reason == "privileged" { fixture.snapshots[fixture.tab.id]?.navigation.url = URL(string: "chrome://settings") }
		if reason == "nativeUnavailable" { fixture.available = false }
		if reason == "authentication" { fixture.snapshots[fixture.tab.id]?.navigation.authenticationCancelled = true }
		var request = try fixture.request()
		guard case var .wait(wait) = request.operation else { return }
		if reason == "foreign" { wait.targetID = fixture.other.id.rawValue }
		if reason == "private" { wait.targetID = UUID(90) }
		if reason == "staleRevision" { wait.expectedRevision = String(repeating: "b", count: 64) }
		request.operation = .wait(wait)
		await fixture.send(request).finish()
		let failure: AutomationFailure = switch reason {
		case "grant", "foreign", "private": .denied
		case "unloaded": .notLoaded
		case "staleRevision": .staleTarget
		case "authentication": .userActionRequired
		default: .unsupported
		}
		expectNoDifference(fixture.responses, [.failure(failure)])
		expectNoDifference(fixture.calls, [])
	}

	@Test
	internal func authenticationCancelledDuringWaitRequiresUserAction() async throws {
		let fixture = Fixture()
		fixture.holdsWait = true
		fixture.snapshots[fixture.tab.id]?.navigation.isLoading = true
		let task = fixture.send(try fixture.request())
		try await fixture.waitForObservation()
		fixture.snapshots[fixture.tab.id]?.navigation.authenticationCancelled = true
		fixture.snapshots[fixture.tab.id]?.navigation.isLoading = false
		fixture.release()
		await task.finish()
		expectNoDifference(fixture.responses, [.failure(.userActionRequired)])
	}

	@Test(arguments: ["cancel", "disconnect", "revoke", "grant", "navigation", "closeReopen"])
	internal func pendingWaitCannotOutlivePermissionOrNativeOwner(change: String) async throws {
		let fixture = Fixture()
		fixture.holdsWait = true
		let request = try fixture.request()
		let task = fixture.send(request)
		try await fixture.waitForObservation()
		fixture.change(change, request: request)
		fixture.release()
		await task.finish()
		#expect(!fixture.responses.contains { if case .wait = $0 { true } else { false } })
		#expect(fixture.store.automation.pending.isEmpty)
	}

	@Test(arguments: ["navigation", "closeReopen", "grant", "disconnect", "profile"])
	internal func alreadyStoppedFinalReleaseRejectsChangedPermissionOrNativeOwner(change: String) async throws {
		let fixture = Fixture()
		let request = try fixture.request()
		fixture.beforeRelease = { fixture.change(change, request: request) }
		defer { fixture.beforeRelease = nil }
		await fixture.send(request).finish()
		let expected: AutomationFailure = ["grant", "disconnect", "profile"].contains(change) ? .denied : .staleTarget
		expectNoDifference(fixture.responses, [.failure(expected)])
		expectNoDifference(fixture.calls.count, 1)
	}

	@Test
	internal func finalReleaseKeepsHistoricalObservationAcrossUnrelatedTitleChange() async throws {
		let fixture = Fixture()
		let request = try fixture.request()
		fixture.beforeRelease = {
			fixture.snapshots[fixture.tab.id]?.revision = 4
			fixture.snapshots[fixture.tab.id]?.navigation.title = "Changed after observation"
		}
		defer { fixture.beforeRelease = nil }
		await fixture.send(request).finish()
		guard case let .wait(result) = fixture.responses.first else {
			Issue.record("Historical observation was incorrectly required to retain its publication revision")
			return
		}
		expectNoDifference(result.sessionRevision, 3)
	}
}

@MainActor
private final class Fixture {
	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var calls: [PageWaitTarget] = []
	fileprivate var responses: [AutomationResult] = []
	fileprivate var available: Bool = true
	fileprivate var pageID: UInt64 = 7
	fileprivate var holdsWait: Bool = false
	fileprivate var beforeRelease: (@MainActor () -> Void)?
	private var continuation: CheckedContinuation<Void, Never>?
	private var requests: [UUID: AutomationRequest] = [:]
	private var clients: [UUID: AutomationClient] = [:]

	fileprivate init(readAllowed: Bool = true) {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.other = organization.tabs[1]
		self.snapshots = [tab.id: .init(navigation: .init(url: tab.restoration.url), revision: 3, documentRevision: 8)]
		let client = AutomationClient(
			id: UUID(80),
			name: "Read-only wait fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: readAllowed,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		self.store = Store(initialState: state) { BrowserAutomation() } withDependencies: { [weak self] dependencies in
			dependencies.uuid = .incrementing
			dependencies.date.now = Date(timeIntervalSince1970: 100)
			dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
			dependencies.browserEngine.open = { _ in Issue.record("Wait loaded a tab") }
			dependencies.browserEngine.command = { _, _ in Issue.record("Wait mutated a page") }
			dependencies.browserEngine.close = { _ in Issue.record("Wait closed a page") }
			dependencies.browserPageWait.isAvailable = { self?.available == true }
			dependencies.browserPageWait.sourceIsCurrent = { self?.isCurrent($0) == true }
			dependencies.browserPageWait.waitAuthorized = { _, target, authorize in
				guard let self, authorize() else { throw AutomationFailure.denied }
				let source = PageWaitSource(target: target, pageID: self.pageID)
				self.calls.append(target)
				if self.holdsWait { await withCheckedContinuation { self.continuation = $0 } }
				try Task.checkCancellation()
				guard self.isCurrent(source) else { throw AutomationFailure.staleTarget }
				guard authorize() else { throw AutomationFailure.denied }
				return .init(source: source, snapshot: self.snapshots[target.tabID]!)
			}
			dependencies.automationControl.authorize = { id in
				guard let self else { return false }
				return self.store.state.automationCanExecute(id, snapshots: self.snapshots, now: Date(timeIntervalSince1970: 100))
			}
			dependencies.automationControl.respond = { id, result in
				guard let self, let request = self.requests[id] else { return }
				self.beforeRelease?()
				let current = self.store.automationPreferences.clients.first { $0.id == request.clientID }
				let failure = current == self.clients[id]
				? self.store.state.automationResponseValidation(
					request,
					result: result,
					snapshots: self.snapshots,
					waitSourceIsCurrent: { self.isCurrent($0) }
				)
				: .denied
				self.responses.append(failure.map(AutomationResult.failure) ?? result)
			}
		}
	}

	private func isCurrent(_ source: PageWaitSource) -> Bool {
		pageID == source.pageID
		&& snapshots[source.target.tabID]?.documentRevision == source.target.documentRevision
	}

	fileprivate func change(
		_ change: String,
		request: AutomationRequest
	) {
		switch change {
		case "cancel":
			store.send(.automation(.event(.host(.cancel(request.id)))))

		case "disconnect":
			store.send(.automation(.event(.host(.disconnected(sessionID: request.sessionID)))))

		case "revoke":
			store.send(.automation(.ui(.revokeClient(request.clientID))))

		case "grant":
			var client = store.automationPreferences.clients[0]
			client.allowsRead = false
			store.send(.automation(.ui(.updateClient(client))))

		case "navigation":
			snapshots[tab.id]?.documentRevision = 9

		case "profile":
			var client = store.automationPreferences.clients[0]
			client.scopes = []
			store.send(.automation(.ui(.updateClient(client))))

		default:
			pageID = 20
		}
	}

	fileprivate func request() throws -> AutomationRequest {
		var client = store.automationPreferences.clients[0]
		client.allowsRead = true
		let item = try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: store.workspace,
			snapshots: snapshots
		).first { $0.id == tab.id.rawValue })
		return .init(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .wait(.init(targetID: item.id, expectedRevision: item.revision))
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		clients[request.id] = store.automationPreferences.clients.first { $0.id == request.clientID }
		return store.send(.automation(.event(.host(.request(request)))))
	}

	fileprivate func waitForObservation() async throws {
		for _ in 0..<1000 {
			if continuation != nil { return }
			await Task.yield()
		}
		throw AutomationFailure.timedOut
	}

	fileprivate func release() {
		continuation?.resume()
		continuation = nil
	}
}
