import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationPasswordsFeatureTests {
	@Test
	internal func theUserApprovesAndPicksTheAccount() async throws {
		let fixture = try PasswordFixture(accounts: [
			.init(id: 1, username: "first", hasForm: true),
			.init(id: 2, username: "second", hasForm: true),
		])
		let request = try fixture.signIn()
		await fixture.send(request).finish()

		// Nothing fills before the user answers.
		expectNoDifference(fixture.attempts, [])
		#expect(fixture.store.automation.pending[request.id]?.awaitingApproval == true)
		expectNoDifference(fixture.store.automation.passwordSignIns[request.id]?.selectedAccountID, 1)

		await fixture.store.send(.automation(.ui(.passwordAccount(request.id, 2)))).finish()
		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.attempts, [.init(tabID: fixture.tab.id, document: "DOC1", account: 2)])
		expectNoDifference(fixture.responses, [
			.passwordSignIn(.init(operationID: UUID(90), outcome: .signedIn, reason: .signedIn)),
		])

		// Approving once doesn't let agents in without asking.
		#expect(fixture.store.automationPreferences.agentSignInSites.isEmpty)
		#expect(fixture.store.automation.passwordSignIns.isEmpty)
	}

	@Test
	internal func lettingAgentsInWithoutAskingSkipsTheNextApproval() async throws {
		let fixture = try PasswordFixture()
		let first = try fixture.signIn()
		await fixture.send(first).finish()
		await fixture.store.send(.automation(.ui(.passwordAllowsWithoutAsking(first.id, true)))).finish()
		await fixture.store.send(.automation(.ui(.approve(first.id)))).finish()
		expectNoDifference(fixture.store.automationPreferences.agentSignInSites, [
			.init(profileID: fixture.tab.profileID, origin: fixture.origin),
		])

		let second = try fixture.signIn(id: UUID(85), operationID: UUID(91))
		await fixture.send(second).finish()
		#expect(fixture.attempts.count == 2)
		#expect(fixture.store.automation.pending[second.id] == nil)
		expectNoDifference(fixture.responses.count, 2)

		// The user can take it back.
		let site = AgentSignInSite(profileID: fixture.tab.profileID, origin: fixture.origin)
		await fixture.store.send(.automation(.ui(.removeAgentSignInSite(site)))).finish()
		#expect(fixture.store.automationPreferences.agentSignInSites.isEmpty)
	}

	@Test
	internal func nobodyToAskNeedsTheUser() async throws {
		let fixture = try PasswordFixture()
		await fixture.store.send(.automation(.ui(.unattended))).finish()
		await fixture.send(try fixture.signIn()).finish()
		expectNoDifference(fixture.attempts, [])
		expectNoDifference(fixture.responses, [
			.passwordSignIn(.init(operationID: UUID(90), outcome: .needsUser, reason: .approval)),
		])
	}

	@Test
	internal func noSavedPasswordFailsWithoutAsking() async throws {
		let fixture = try PasswordFixture(accounts: [])
		await fixture.send(try fixture.signIn()).finish()
		expectNoDifference(fixture.responses, [
			.passwordSignIn(.init(operationID: UUID(90), outcome: .failed, reason: .noSavedPassword)),
		])
	}

	@Test(arguments: ["noSignInGrant", "foreignTab", "staleRevision", "wrongOrigin"])
	internal func refusedRequestsNeverListAccounts(reason: String) async throws {
		let fixture = try PasswordFixture(capabilities: reason == "noSignInGrant" ? [.read, .screenshots] : [.read, .signIn, .screenshots])
		var signIn = try fixture.request()
		switch reason {
		case "foreignTab": signIn.targetID = fixture.other.id.rawValue
		case "staleRevision": signIn.expectedRevision = String(repeating: "0", count: 64)
		case "wrongOrigin": signIn.origin = "https://elsewhere.example"
		default: break
		}
		await fixture.send(.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .passwordSignIn(signIn))).finish()
		let expected: AutomationFailure = reason == "noSignInGrant" || reason == "foreignTab" ? .denied : .staleTarget
		expectNoDifference(fixture.responses, [.failure(expected)])
		expectNoDifference(fixture.listings, 0)
	}

	/// A fill that didn't sign in closes the page to captures until it navigates.
	@Test
	internal func aRefusedFillQuarantinesTheDocument() async throws {
		let fixture = try PasswordFixture(allowed: true)
		fixture.result = .init(outcome: .failed, reason: .rejected, filled: true, passwordVisible: true)
		await fixture.send(try fixture.signIn()).finish()
		expectNoDifference(fixture.responses, [
			.passwordSignIn(.init(operationID: UUID(90), outcome: .failed, reason: .rejected)),
		])

		await fixture.send(try fixture.capture(id: UUID(86))).finish()
		expectNoDifference(fixture.responses.last, .failure(.authenticationProtected))

		fixture.snapshots[fixture.tab.id]?.documentRevision = 9
		#expect(fixture.store.state.automationPasswordQuarantine(
			.capture(try fixture.captureRequest()),
			snapshots: fixture.snapshots
		) == nil)
	}

	@Test
	internal func aSuccessfulSignInLeavesThePageReadable() async throws {
		let fixture = try PasswordFixture(allowed: true)
		await fixture.send(try fixture.signIn()).finish()
		#expect(fixture.store.automation.passwordQuarantine.isEmpty)
	}

	@Test(arguments: [
		(BrowserPasswordFailure.stale(filled: false), AutomationResult.passwordSignIn(.init(operationID: UUID(90), outcome: .failed, reason: .navigation))),
		(.timedOut(filled: true), .passwordSignIn(.init(operationID: UUID(90), outcome: .failed, reason: .timedOut))),
		(.busy, .failure(.busy)),
		(.unavailable, .failure(.unsupported)),
	])
	internal func engineFailuresAreReported(
		failure: BrowserPasswordFailure,
		expected: AutomationResult
	) async throws {
		let fixture = try PasswordFixture(allowed: true)
		fixture.failure = failure
		await fixture.send(try fixture.signIn()).finish()
		expectNoDifference(fixture.responses, [expected])
		#expect(fixture.store.automation.passwordQuarantine.isEmpty == (failure != .timedOut(filled: true)))
	}

	@Test
	internal func saveOffersAreAnsweredOnce() async throws {
		let fixture = try PasswordFixture()
		let offer = BrowserPasswordSaveOffer(tabID: fixture.tab.id, token: 4, origin: fixture.origin, username: "me", isUpdate: false)
		await fixture.store.send(.automation(.event(.passwordSaveOffered(offer)))).finish()
		expectNoDifference(fixture.store.automation.passwordSave, offer)
		await fixture.store.send(.automation(.ui(.answerPasswordSave(.save)))).finish()
		await fixture.store.send(.automation(.ui(.answerPasswordSave(.never)))).finish()
		expectNoDifference(fixture.answers, [.init(tabID: fixture.tab.id, token: 4, answer: .save)])
		#expect(fixture.store.automation.passwordSave == nil)
	}
}

@MainActor
private final class PasswordFixture {
	fileprivate struct Attempt: Equatable {
		fileprivate var tabID: BrowserCore.Tab.ID
		fileprivate var document: String
		fileprivate var account: UInt32
	}

	fileprivate struct Answer: Equatable {
		fileprivate var tabID: BrowserCore.Tab.ID
		fileprivate var token: UInt64
		fileprivate var answer: BrowserPasswordSaveAnswer
	}

	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate let origin: String
	fileprivate var store: StoreOf<AutomationPasswordsFixture>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var accounts: [BrowserSavedAccount]
	fileprivate var attempts: [Attempt] = []
	fileprivate var answers: [Answer] = []
	fileprivate var listings: Int = 0
	fileprivate var responses: [AutomationResult] = []
	fileprivate var result = BrowserPasswordSignInResult(outcome: .signedIn, reason: .signedIn, filled: true, passwordVisible: false)
	fileprivate var failure: BrowserPasswordFailure?
	private var requests: [UUID: AutomationRequest] = [:]

	fileprivate init(
		accounts: [BrowserSavedAccount] = [.init(id: 1, username: "me", hasForm: true)],
		capabilities: Set<AutomationCapability> = [.read, .signIn, .screenshots],
		allowed: Bool = false
	) throws {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.other = organization.tabs[1]
		self.accounts = accounts
		self.origin = try #require(AppFeature.State.signInOrigin(tab.restoration.url))
		self.snapshots = [
			tab.id: .init(
				navigation: .init(url: tab.restoration.url),
				revision: 3,
				documentRevision: 8,
				isVisibleForCapture: true,
				nativePageID: 7,
				nativeProfileID: tab.profileID
			),
		]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			capabilities: capabilities,
			approvalPolicy: .never,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(
				isEnabled: true,
				clients: [client],
				agentSignInSites: allowed ? [.init(profileID: tab.profileID, origin: origin)] : []
			)
		)
		state.automation.sessions[UUID(81)] = client.id
		let originValue = origin
		self.store = Store(initialState: state) { AutomationPasswordsFixture() } withDependencies: { [weak self] dependencies in
			dependencies.uuid = .incrementing
			dependencies.date.now = Date(timeIntervalSince1970: 100)
			dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
			dependencies.browserEngine.passwordsAreAvailable = { true }
			dependencies.browserEngine.savedAccounts = { _ throws(BrowserPasswordFailure) in
				guard let self else { throw .unavailable }
				self.listings += 1
				return .init(document: "DOC1", origin: originValue, accounts: self.accounts)
			}
			dependencies.browserEngine.signInWithPassword = { tabID, document, _, account, authorize throws(BrowserPasswordFailure) in
				guard let self else { throw .unavailable }
				guard authorize() else { throw .denied }
				self.attempts.append(.init(tabID: tabID, document: document, account: account))
				if let failure = self.failure { throw failure }
				return self.result
			}
			dependencies.browserEngine.answerPasswordSave = { tabID, token, answer in
				self?.answers.append(.init(tabID: tabID, token: token, answer: answer))
				return true
			}
			dependencies.automationControl.authorize = { id in
				guard let self else { return false }
				return self.store.state.automationCanExecute(id, snapshots: self.snapshots, now: Date(timeIntervalSince1970: 100))
			}
			dependencies.automationControl.respond = { id, result in
				guard let self, let request = self.requests[id] else { return }
				let failure = self.store.state.automationResponseValidation(request, result: result, snapshots: self.snapshots)
				self.responses.append(failure.map(AutomationResult.failure) ?? result)
			}
		}
	}

	fileprivate func request(operationID: UUID = UUID(90)) throws -> AutomationPasswordSignInRequest {
		.init(operationID: operationID, targetID: tab.id.rawValue, expectedRevision: try revision(), origin: origin)
	}

	fileprivate func signIn(
		id: UUID = UUID(84),
		operationID: UUID = UUID(90)
	) throws -> AutomationRequest {
		.init(id: id, clientID: UUID(80), sessionID: UUID(81), operation: .passwordSignIn(try request(operationID: operationID)))
	}

	fileprivate func captureRequest() throws -> AutomationCaptureRequest {
		.init(targetID: tab.id.rawValue, expectedRevision: try revision(), mode: .viewport)
	}

	fileprivate func capture(id: UUID) throws -> AutomationRequest {
		.init(id: id, clientID: UUID(80), sessionID: UUID(81), operation: .capture(try captureRequest()))
	}

	private func revision() throws -> String {
		let client = store.automationPreferences.clients[0]
		return try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: store.workspace,
			snapshots: snapshots
		).first { $0.id == tab.id.rawValue }).revision
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		return store.send(.automation(.event(.host(.request(request)))))
	}
}

@Reducer
private struct AutomationPasswordsFixture {
	typealias State = AppFeature.State
	typealias Action = AppFeature.Action

	var body: some ReducerOf<Self> {
		BrowserAutomation()
		AutomationPasswords()
	}
}
