import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationDeveloperFeatureTests {
	@Test
	internal func approvedScriptRunsOnceAndReturnsItsValue() async throws {
		let fixture = try DeveloperFixture()
		let request = try fixture.script("return document.title")
		await fixture.send(request).finish()

		// alwaysAsk: nothing runs before the user approves.
		expectNoDifference(fixture.scripts, [])
		#expect(fixture.store.automation.pending[request.id]?.awaitingApproval == true)

		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.scripts, [.init(tabID: fixture.tab.id, script: "return document.title")])
		expectNoDifference(fixture.responses, [
			.script(.init(operationID: UUID(90), targetID: fixture.tab.id.rawValue, outcome: .value, value: #""Fixture""#)),
		])
		#expect(fixture.store.automation.pending.isEmpty)
	}

	@Test
	internal func aTemporaryGrantDoesntCoverScripts() async throws {
		let fixture = try DeveloperFixture(temporaryGrant: true)
		let request = try fixture.script("return 1")
		await fixture.send(request).finish()
		expectNoDifference(fixture.scripts, [])
		#expect(fixture.store.automation.pending[request.id]?.awaitingApproval == true)
	}

	@Test
	internal func aStandingPolicyThatSkipsMutationsRunsAtOnce() async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .destructiveOnly)
		await fixture.send(try fixture.script("return 1")).finish()
		#expect(fixture.scripts.count == 1)
	}

	@Test(arguments: ["noScriptClass", "noDevtoolsClass", "foreignTab", "staleRevision", "unattended"])
	internal func refusedScriptsNeverReachTheEngine(reason: String) async throws {
		let fixture = try DeveloperFixture(
			approvalPolicy: reason == "unattended" ? .alwaysAsk : .never,
			capabilities: reason == "noScriptClass" ? [.read, .devtools] : [.read, .script, .devtools]
		)
		if reason == "unattended" {
			await fixture.store.send(.automation(.ui(.unattended))).finish()
		}
		var script = try fixture.scriptRequest("return 1")
		switch reason {
		case "foreignTab": script.targetID = fixture.other.id.rawValue
		case "staleRevision": script.expectedRevision = String(repeating: "0", count: 64)
		default: break
		}
		let request = AutomationRequest(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .script(script))
		if reason == "noDevtoolsClass" {
			// The devtools class alone never runs scripts; the script class alone never reads logs.
			let logs = try DeveloperFixture(approvalPolicy: .never, capabilities: [.read, .script])
			await logs.send(logs.logs(.start)).finish()
			expectNoDifference(logs.responses, [.failure(.denied)])
			expectNoDifference(logs.logToggles, [])
			return
		}
		await fixture.send(request).finish()

		let expected: AutomationFailure = switch reason {
		case "noScriptClass", "foreignTab": .denied
		case "staleRevision": .staleTarget
		default: .userActionRequired
		}
		expectNoDifference(fixture.responses, [.failure(expected)])
		expectNoDifference(fixture.scripts, [])
	}

	@Test
	internal func developerModeOffRefusesTheWholeTier() async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .never, developerMode: false)
		await fixture.send(try fixture.script("return 1")).finish()
		await fixture.send(fixture.logs(.start, id: UUID(85))).finish()
		expectNoDifference(fixture.responses, [.failure(.developerModeRequired), .failure(.developerModeRequired)])
		expectNoDifference(fixture.scripts, [])
		expectNoDifference(fixture.logToggles, [])
	}

	@Test
	internal func signInPrivacyLockRefusesScripts() async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .never, privacyLocked: true)
		await fixture.send(try fixture.script("return 1")).finish()
		await fixture.send(fixture.logs(.console, id: UUID(85))).finish()
		expectNoDifference(fixture.responses, [.failure(.authenticationProtected), .failure(.authenticationProtected)])
		expectNoDifference(fixture.scripts, [])
		expectNoDifference(fixture.logReads, [])
	}

	@Test
	internal func scriptsCantBeBatchSteps() throws {
		let fixture = try DeveloperFixture()
		let plan = AutomationBatchPlan(batchID: UUID(1), steps: [.script(try fixture.scriptRequest("return 1"))])
		#expect(throws: AutomationFailure.invalidRequest) { try plan.validate() }
		#expect(AutomationOperation.script(try fixture.scriptRequest("x")).ignoresTemporaryGrant)
		#expect(AutomationOperation.script(try fixture.scriptRequest("x")).riskTier == .mutate)
		#expect(AutomationOperation.logs(fixture.logRequest(.console)).riskTier == .read)
	}

	@Test(arguments: [
		BrowserScriptOutcome.exception(name: "TypeError", message: "x is not a function"),
		.syntaxError(name: "SyntaxError", message: "Unexpected end of input", line: 2),
		.unserializable("cyclic object value"),
		.undefined,
	])
	internal func scriptOutcomesKeepTheirShape(outcome: BrowserScriptOutcome) async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .never)
		fixture.outcome = outcome
		await fixture.send(try fixture.script("x()")).finish()
		let request = try fixture.scriptRequest("x()")
		expectNoDifference(fixture.responses, [.script(BrowserAutomation.scriptResult(outcome, request: request))])
	}

	/// Arx's own reads of a page (reading mode's article check, history's page text) hold it for a
	/// moment, so a script that finds it busy asks again, and reports busy only when it stays so.
	@Test
	internal func aScriptWaitsForAPageBusyWithArxsOwnRead() async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .never)
		fixture.busyTries = 2
		await fixture.send(try fixture.script("return 1")).finish()
		let request = try fixture.scriptRequest("return 1")
		expectNoDifference(fixture.responses, [.script(BrowserAutomation.scriptResult(fixture.outcome, request: request))])
		#expect(fixture.scripts.count == 3)

		let busy = try DeveloperFixture(approvalPolicy: .never)
		busy.failure = .busy
		await busy.send(try busy.script("return 1")).finish()
		expectNoDifference(busy.responses, [.failure(.busy)])
		#expect(busy.scripts.count == BrowserEngineClient.busyRetries + 1)
	}

	@Test(arguments: [
		(BrowserDeveloperFailure.limitExceeded, AutomationFailure.limitExceeded),
		(.stale, .staleTarget),
		(.timedOut, .timedOut),
		(.busy, .busy),
		(.unavailable, .unsupported),
	])
	internal func engineFailuresAreReported(
		failure: BrowserDeveloperFailure,
		expected: AutomationFailure
	) async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .never)
		fixture.failure = failure
		await fixture.send(try fixture.script("return 1")).finish()
		expectNoDifference(fixture.responses, [.failure(expected)])
	}

	@Test
	internal func oversizedValuesNeverLeaveTheResponseGate() throws {
		let fixture = try DeveloperFixture()
		let request = try fixture.scriptRequest("return 1")
		let oversized = AutomationScriptResult(
			operationID: request.operationID,
			targetID: request.targetID,
			outcome: .value,
			value: String(repeating: "a", count: AutomationDeveloper.maximumResultBytes + 1)
		)
		let failure = fixture.store.state.automationResponseValidation(
			.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .script(request)),
			result: .script(oversized),
			snapshots: fixture.snapshots
		)
		#expect(failure == .limitExceeded)

		let message = AutomationScriptResult(
			operationID: request.operationID,
			targetID: request.targetID,
			outcome: .exception,
			error: .init(name: "Error", message: String(repeating: "m", count: AutomationDeveloper.maximumMessageBytes + 1))
		)
		#expect(throws: AutomationFailure.limitExceeded) { try message.validate() }
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationScriptRequest(
				operationID: UUID(1),
				targetID: UUID(2),
				expectedRevision: String(repeating: "a", count: 64),
				script: String(repeating: "a", count: AutomationDeveloper.maximumScriptBytes + 1)
			).validate()
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationScriptRequest(
				operationID: UUID(1),
				targetID: UUID(2),
				expectedRevision: String(repeating: "a", count: 64),
				script: "return 1",
				maximumResultBytes: AutomationDeveloper.maximumResultBytes + 1
			).validate()
		}
	}

	@Test
	internal func aResultForAnotherTabOrAfterRevocationIsRefused() async throws {
		let fixture = try DeveloperFixture()
		let request = try fixture.scriptRequest("return 1")
		let automation = AutomationRequest(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .script(request))
		let foreign = AutomationScriptResult(
			operationID: request.operationID,
			targetID: fixture.other.id.rawValue,
			outcome: .undefined
		)
		#expect(
			fixture.store.state.automationResponseValidation(automation, result: .script(foreign), snapshots: fixture.snapshots)
				== .invalidRequest
		)
		let result = AutomationScriptResult(operationID: request.operationID, targetID: request.targetID, outcome: .undefined)
		#expect(fixture.store.state.automationResponseValidation(automation, result: .script(result), snapshots: fixture.snapshots) == nil)

		var client = fixture.store.automationPreferences.clients[0]
		client.capabilities.remove(.script)
		await fixture.store.send(.automation(.ui(.updateClient(client)))).finish()
		#expect(
			fixture.store.state.automationResponseValidation(automation, result: .script(result), snapshots: fixture.snapshots)
				== .denied
		)
	}

	@Test
	internal func logsStartReadAndStopWithoutEnteringState() async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .alwaysAsk)
		fixture.log = .init(
			capturing: true,
			console: [
				.init(sequence: 3, level: .error, message: "Boom", source: "https://a.test/app.js", line: 4, mainFrame: true, time: 1),
			],
			next: 3,
			dropped: 2
		)

		// Logs are reads: they never ask, whatever the policy.
		await fixture.send(fixture.logs(.start)).finish()
		expectNoDifference(fixture.logToggles, [.init(tabID: fixture.tab.id, enabled: true)])
		#expect(fixture.store.automation.developerLogs == [fixture.tab.id: UUID(80)])

		await fixture.send(fixture.logs(.console, id: UUID(85), after: 1, limit: 10)).finish()
		expectNoDifference(fixture.logReads, [.init(tabID: fixture.tab.id, kind: .console, after: 1, limit: 10)])

		await fixture.send(fixture.logs(.stop, id: UUID(86))).finish()
		expectNoDifference(fixture.responses, [
			.logs(.init(action: .start, targetID: fixture.tab.id.rawValue, capturing: true)),
			.logs(.init(
				action: .console,
				targetID: fixture.tab.id.rawValue,
				capturing: true,
				console: fixture.log.console,
				next: 3,
				dropped: 2
			)),
			.logs(.init(action: .stop, targetID: fixture.tab.id.rawValue, capturing: false)),
		])
		expectNoDifference(fixture.logToggles.last, .init(tabID: fixture.tab.id, enabled: false))
		#expect(fixture.store.automation.developerLogs.isEmpty)
	}

	@Test
	internal func aGrantChangeStopsTheClientsLogs() async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .never)
		await fixture.send(fixture.logs(.start)).finish()
		var client = fixture.store.automationPreferences.clients[0]
		client.capabilities.remove(.devtools)
		await fixture.store.send(.automation(.ui(.updateClient(client)))).finish()
		expectNoDifference(fixture.logToggles, [
			.init(tabID: fixture.tab.id, enabled: true),
			.init(tabID: fixture.tab.id, enabled: false),
		])
		#expect(fixture.store.automation.developerLogs.isEmpty)
	}

	@Test
	internal func aStartOnAnUnloadedTabReportsNotLoaded() async throws {
		let fixture = try DeveloperFixture(approvalPolicy: .never)
		fixture.snapshots = [:]
		await fixture.send(fixture.logs(.start)).finish()
		expectNoDifference(fixture.responses, [.failure(.notLoaded)])
		expectNoDifference(fixture.logToggles, [])
	}
}

@MainActor
private final class DeveloperFixture {
	fileprivate struct Script: Equatable {
		fileprivate var tabID: BrowserCore.Tab.ID
		fileprivate var script: String
	}

	fileprivate struct Toggle: Equatable {
		fileprivate var tabID: BrowserCore.Tab.ID
		fileprivate var enabled: Bool
	}

	fileprivate struct Read: Equatable {
		fileprivate var tabID: BrowserCore.Tab.ID
		fileprivate var kind: BrowserDeveloperLogKind
		fileprivate var after: UInt64
		fileprivate var limit: Int
	}

	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var scripts: [Script] = []
	fileprivate var logToggles: [Toggle] = []
	fileprivate var logReads: [Read] = []
	fileprivate var responses: [AutomationResult] = []
	fileprivate var outcome: BrowserScriptOutcome = .value(#""Fixture""#)
	fileprivate var failure: BrowserDeveloperFailure?

	/// How many tries find the page busy before the script runs.
	fileprivate var busyTries: Int = 0
	fileprivate var log = BrowserDeveloperLog(capturing: true, next: 0, dropped: 0)
	private var requests: [UUID: AutomationRequest] = [:]

	fileprivate init(
		approvalPolicy: AutomationApprovalPolicy = .alwaysAsk,
		capabilities: Set<AutomationCapability> = [.read, .script, .devtools],
		developerMode: Bool = true,
		temporaryGrant: Bool = false,
		privacyLocked: Bool = false
	) throws {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.other = organization.tabs[1]
		self.snapshots = [
			tab.id: .init(
				navigation: .init(url: tab.restoration.url),
				revision: 3,
				documentRevision: 8,
				isVisibleForCapture: true
			),
		]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			capabilities: capabilities,
			approvalPolicy: approvalPolicy,
			mutationGrantUntil: temporaryGrant ? Date(timeIntervalSince1970: 400) : nil,
			grantRevision: UUID(82)
		)

		// Developer mode is a shared preference, so each fixture gets its own document:
		// parameterized cases run in parallel and must not share one.
		let document = WorkspaceDocument.unsaved(.init(developerModeEnabled: developerMode))
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(
				main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
				automation: .init(isEnabled: true, clients: [client])
			)
		}
		state.automation.sessions[UUID(81)] = client.id
		if privacyLocked {
			state.automationPreferences.authenticationLockID = UUID(99)
		}
		self.store = Store(initialState: state) { BrowserAutomation() } withDependencies: { [weak self] dependencies in
			dependencies.workspaceDocument = document
			dependencies.uuid = .incrementing
			dependencies.date.now = Date(timeIntervalSince1970: 100)
			dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
			dependencies.continuousClock = ImmediateClock()
			dependencies.browserEngine.developerTierIsAvailable = { true }
			dependencies.browserEngine.evaluateScript = { tabID, script, _, _, authorize throws(BrowserDeveloperFailure) in
				guard let self else { throw .unavailable }
				guard authorize() else { throw .denied }
				self.scripts.append(.init(tabID: tabID, script: script))
				if self.busyTries > 0 {
					self.busyTries -= 1
					throw .busy
				}
				if let failure = self.failure { throw failure }
				return self.outcome
			}
			dependencies.browserEngine.setDeveloperLog = { tabID, enabled in
				guard let self, self.snapshots[tabID] != nil || !enabled else { return false }
				self.logToggles.append(.init(tabID: tabID, enabled: enabled))
				return true
			}
			dependencies.browserEngine.readDeveloperLog = { tabID, kind, after, limit throws(BrowserDeveloperFailure) in
				guard let self else { throw .unavailable }
				self.logReads.append(.init(tabID: tabID, kind: kind, after: after, limit: limit))
				return self.log
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

	fileprivate func scriptRequest(_ script: String) throws -> AutomationScriptRequest {
		let client = store.automationPreferences.clients[0]
		let item = try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: store.workspace,
			snapshots: snapshots
		).first { $0.id == tab.id.rawValue })
		return .init(
			operationID: UUID(90),
			targetID: tab.id.rawValue,
			expectedRevision: item.revision,
			script: script
		)
	}

	fileprivate func script(_ script: String) throws -> AutomationRequest {
		.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .script(try scriptRequest(script)))
	}

	fileprivate func logRequest(
		_ action: AutomationLogRequest.Action,
		after: UInt64 = 0,
		limit: Int = AutomationDeveloper.defaultLogEntries
	) -> AutomationLogRequest {
		.init(action: action, targetID: tab.id.rawValue, after: after, limit: limit)
	}

	fileprivate func logs(
		_ action: AutomationLogRequest.Action,
		id: UUID = UUID(84),
		after: UInt64 = 0,
		limit: Int = AutomationDeveloper.defaultLogEntries
	) -> AutomationRequest {
		.init(id: id, clientID: UUID(80), sessionID: UUID(81), operation: .logs(logRequest(action, after: after, limit: limit)))
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		return store.send(.automation(.event(.host(.request(request)))))
	}
}
