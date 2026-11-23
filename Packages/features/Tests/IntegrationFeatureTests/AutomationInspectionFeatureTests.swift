import BrowserAutomationClient
import BrowserPageInspectionClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationInspectionFeatureTests {
	@Test
	internal func contentToggleRotatesPermissionRevisionAndKeepsExistingSession() async throws {
		let fixture = Fixture(contentAllowed: false)
		let original = fixture.store.automationPreferences.clients[0]
		let before = fixture.store.automation.sessions
		#expect(!before.isEmpty)
		var updated = original
		updated.allowsPageContent = true
		await fixture.store.send(.automation(.ui(.updateClient(updated)))).finish()
		let saved = try #require(fixture.store.automationPreferences.clients.first)
		#expect(saved.grantRevision != original.grantRevision)
		expectNoDifference(saved.allowsPageContent, true)
		expectNoDifference(fixture.store.automation.sessions, before)
	}

	@Test
	internal func historicalReadKeepsWorkspaceAndPresentationUnchanged() async throws {
		let fixture = Fixture()
		let before = fixture.store.state
		await fixture.send(try fixture.request()).finish()
		guard case let .inspection(result) = fixture.responses.first else {
			Issue.record("Authorized read did not return a snapshot")
			return
		}
		expectNoDifference(result.snapshot.domVersion, "4")
		expectNoDifference(result.snapshot.nodes.first?.text, "Untrusted fixture text")
		expectNoDifference(fixture.store.workspace, before.workspace)
		expectNoDifference(fixture.store.main, before.main)
		expectNoDifference(fixture.store.focusedWindowID, before.focusedWindowID)
		expectNoDifference(fixture.calls.count, 1)
		#expect(fixture.store.automation.activity.allSatisfy { $0.operation == "inspect" && $0.outcome == "inspected" })
	}

	@Test(arguments: [
		"grant", "foreign", "private", "unloaded", "discarded", "epoch",
		"privileged", "failed", "loading", "nativeUnavailable", "authentication",
	])
	internal func deniedOrUnavailableSourcesNeverInspect(reason: String) async throws {
		let fixture = Fixture(contentAllowed: reason != "grant")
		if reason == "unloaded" { fixture.snapshots = [:] }

		// DEV-873: Arx unloaded the page to free memory; it has no document until loaded.
		if reason == "discarded" {
			fixture.snapshots[fixture.tab.id]?.navigation.isUnloaded = true
			fixture.snapshots[fixture.tab.id]?.documentRevision = nil
		}
		if reason == "epoch" { fixture.snapshots[fixture.tab.id]?.documentRevision = nil }
		if reason == "privileged" { fixture.snapshots[fixture.tab.id]?.navigation.url = URL(string: "chrome://settings") }
		if reason == "failed" { fixture.snapshots[fixture.tab.id]?.navigation.errorCode = -1 }
		if reason == "loading" { fixture.snapshots[fixture.tab.id]?.navigation.isLoading = true }
		if reason == "authentication" { fixture.snapshots[fixture.tab.id]?.navigation.authenticationCancelled = true }
		if reason == "nativeUnavailable" { fixture.available = false }
		var request = try fixture.request()
		if reason == "foreign" || reason == "private" {
			guard case var .inspect(inspection) = request.operation else { return }
			inspection.targetID = reason == "foreign" ? fixture.other.id.rawValue : UUID(90)
			request.operation = .inspect(inspection)
		}
		await fixture.send(request).finish()
		let failure: AutomationFailure = switch reason {
		case "grant", "foreign", "private": .denied
		case "unloaded", "discarded": .notLoaded
		case "failed", "loading": .notReady
		case "authentication": .userActionRequired
		default: .unsupported
		}
		expectNoDifference(fixture.responses, [.failure(failure)])
		expectNoDifference(fixture.calls, [])
	}

	@Test(arguments: ["cancel", "disconnect", "revoke", "grant", "navigation", "closeReopen"])
	internal func heldReadCannotOutliveGrantSessionOrNativeDocument(change: String) async throws {
		let fixture = Fixture()
		fixture.holdsInspection = true
		let request = try fixture.request()
		let task = fixture.send(request)
		try await fixture.waitForInspection()
		fixture.change(change, request: request)
		fixture.releaseInspection()
		await task.finish()
		#expect(!fixture.responses.contains { if case .inspection = $0 { true } else { false } })
		#expect(fixture.store.automation.pending.isEmpty)
		expectNoDifference(fixture.calls.count, 1)
		if ["disconnect", "revoke", "grant"].contains(change) {
			#expect(fixture.store.automation.inspectionScopes.isEmpty)
			expectNoDifference(fixture.revokedScopes, [fixture.calls[0].scopeID])
		}
	}

	@Test(arguments: ["navigation", "closeReopen", "grant", "disconnect", "nativeRegistry"])
	internal func finalReleaseRechecksDocumentAndScopeAfterSuccessfulRead(change: String) async throws {
		let fixture = Fixture()
		let request = try fixture.request()
		fixture.beforeRelease = { fixture.change(change, request: request) }
		defer { fixture.beforeRelease = nil }
		await fixture.send(request).finish()
		expectNoDifference(fixture.calls.count, 1)
		let expected: AutomationFailure = ["grant", "disconnect"].contains(change) ? .denied : .staleTarget
		expectNoDifference(fixture.responses, [.failure(expected)])
	}

	@Test
	internal func queuedNavigationPreventsEntryAndReconnectUsesNewScope() async throws {
		let fixture = Fixture()
		let stale = try fixture.request()
		fixture.snapshots[fixture.tab.id]?.documentRevision = 9
		await fixture.send(stale).finish()
		expectNoDifference(fixture.calls, [])
		expectNoDifference(fixture.responses, [.failure(.staleTarget)])

		await fixture.send(try fixture.request()).finish()
		let oldScope = try #require(fixture.calls.first?.scopeID)
		await fixture.store.send(.automation(.event(.host(.disconnected(sessionID: UUID(81)))))).finish()
		await fixture.store.send(.automation(.event(.host(.connected(clientID: UUID(80), sessionID: UUID(81)))))).finish()
		await fixture.send(try fixture.request()).finish()
		#expect(fixture.calls.last?.scopeID != oldScope)
		expectNoDifference(fixture.revokedScopes, [oldScope])
	}
}

@MainActor
private final class Fixture {
	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var calls: [PageInspectionSource] = []
	fileprivate var responses: [AutomationResult] = []
	fileprivate var revokedScopes: [UUID] = []
	fileprivate var available: Bool = true
	fileprivate var nativeCurrent: Bool = true
	fileprivate var holdsInspection: Bool = false
	fileprivate var beforeRelease: (@MainActor () -> Void)?
	private var continuation: CheckedContinuation<Void, Never>?
	private var requests: [UUID: AutomationRequest] = [:]
	private var clients: [UUID: AutomationClient] = [:]

	fileprivate init(contentAllowed: Bool = true) {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.other = organization.tabs[1]
		self.snapshots = [
			tab.id: .init(navigation: .init(url: tab.restoration.url), revision: 3, documentRevision: 8),
		]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: true,
			allowsPageContent: contentAllowed,
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
			dependencies.browserEngine.open = { _ in Issue.record("Inspection loaded a tab") }
			dependencies.browserEngine.command = { _, _ in Issue.record("Inspection navigated or scrolled") }
			dependencies.browserPageInspection.isAvailable = { self?.available == true }
			dependencies.browserPageInspection.documentIsCurrent = { _ in self?.nativeCurrent == true }
			dependencies.browserPageInspection.revokeScope = { self?.revokedScopes.append($0) }
			dependencies.browserPageInspection.inspectAuthorized = { _, source, authorize in
				guard let self, authorize() else { throw AutomationFailure.staleTarget }
				self.calls.append(source)
				if self.holdsInspection {
					await withCheckedContinuation { self.continuation = $0 }
				}
				try Task.checkCancellation()
				guard authorize() else { throw AutomationFailure.staleTarget }
				return .init(
					snapshotID: "snapshot",
					documentID: "document",
					frameID: "frame",
					domVersion: "4",
					nodes: [.init(index: 0, role: "staticText", text: "Untrusted fixture text", reference: "opaque")],
					omissions: PageInspectionOmission.allCases
				)
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
					inspectionDocumentIsCurrent: { _ in self.nativeCurrent }
				)
				: .denied
				self.responses.append(failure.map(AutomationResult.failure) ?? result)
			}
		}
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
			client.allowsPageContent = false
			store.send(.automation(.ui(.updateClient(client))))

		case "navigation":
			snapshots[tab.id]?.documentRevision = 9

		case "nativeRegistry":
			nativeCurrent = false

		default:
			snapshots[tab.id]?.revision = 20
		}
	}

	fileprivate func request() throws -> AutomationRequest {
		let client = store.automationPreferences.clients[0]
		let item = try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: store.workspace,
			snapshots: snapshots
		).first { $0.id == tab.id.rawValue })
		return .init(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .inspect(.init(targetID: item.id, expectedRevision: item.revision))
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		clients[request.id] = store.automationPreferences.clients.first { $0.id == request.clientID }
		return store.send(.automation(.event(.host(.request(request)))))
	}

	fileprivate func waitForInspection() async throws {
		for _ in 0..<1000 {
			if continuation != nil { return }
			await Task.yield()
		}
		throw AutomationFailure.timedOut
	}

	fileprivate func releaseInspection() {
		continuation?.resume()
		continuation = nil
	}
}
