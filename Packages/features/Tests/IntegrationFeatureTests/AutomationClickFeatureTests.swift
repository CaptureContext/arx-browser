import BrowserAutomationClient
import BrowserCore
import BrowserPageInteractionClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationClickFeatureTests {
	@Test(arguments: ["read", "content", "interaction"])
	internal func eachPermissionIsRequiredIndependently(permission: String) async throws {
		let fixture = try Fixture(denying: permission)
		await fixture.send(try fixture.request()).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .denied)
	}

	@Test
	internal func interactionDoesNotNeedTheOrganizeClass() async throws {
		let fixture = try Fixture(denying: "management")
		await fixture.send(try fixture.request()).finish()
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.outcomes.last?.failure, nil)
	}

	@Test
	internal func approvalDoesNotClassifyPageLabelsAsSafeAndRechecksLatestSnapshot() async throws {
		let fixture = try Fixture(temporaryApproval: false)
		let request = try fixture.request()
		await fixture.send(request).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.store.automation.pending[request.id]?.awaitingApproval, true)

		fixture.release(snapshotID: "newer")
		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.outcomes.last?.failure, .staleReference)
	}

	@Test(arguments: ["unreleased", "foreignSession", "foreignTab", "reference", "expired", "navigation", "closeReopen"])
	internal func onlyLatestReleasedExactSourceCanClick(change: String) async throws {
		let fixture = try Fixture()
		var request = try fixture.request()
		guard case var .click(click) = request.operation else { return }
		switch change {
		case "unreleased": fixture.store.send(.automation(.event(.host(.connected(clientID: UUID(80), sessionID: UUID(81))))))
		case "foreignSession": request.sessionID = UUID(99)
		case "foreignTab": click.targetID = fixture.other.id.rawValue
		case "reference": click.reference = "foreign"
		case "expired": fixture.now = fixture.now.addingTimeInterval(31)
		case "navigation": fixture.snapshots[fixture.tab.id]?.documentRevision = 9
		default: fixture.snapshots[fixture.tab.id]?.revision = 20
		}
		request.operation = .click(click)
		await fixture.send(request).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		#expect(fixture.outcomes.last?.failure != nil)
	}

	@Test
	internal func finalAuthorizationRejectsNavigationQueuedAfterApproval() async throws {
		let fixture = try Fixture()
		fixture.beforeAuthorize = { fixture.snapshots[fixture.tab.id]?.documentRevision = 9 }
		defer { fixture.beforeAuthorize = nil }
		await fixture.send(try fixture.request()).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
	}

	@Test
	internal func ownNavigationKeepsDispatchReceiptAndDuplicateNeverClicksAgain() async throws {
		let fixture = try Fixture()
		let before = fixture.store.focusedWindowID
		fixture.afterDispatch = { fixture.snapshots[fixture.tab.id]?.documentRevision = 9 }
		defer { fixture.afterDispatch = nil }
		let request = try fixture.request()
		await fixture.send(request).finish()
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .dispatched)
		expectNoDifference(fixture.outcomes.last?.failure, nil)
		expectNoDifference(fixture.store.focusedWindowID, before)
		#expect(fixture.store.automation.clickReceipts.isEmpty)

		var replay = request
		replay.id = UUID()
		await fixture.send(replay).finish()
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .dispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .duplicateOperation)
	}


	@Test(arguments: ["reference", "snapshot", "formBinding"])
	internal func duplicateFinalReleaseRequiresExactOriginalBinding(change: String) async throws {
		let fixture = try Fixture()
		let original = try fixture.request()
		await fixture.send(original).finish()
		var state = fixture.store.state
		var duplicate = original
		duplicate.id = UUID()
		guard case var .click(click) = duplicate.operation else { return }
		let response = AutomationResult.click(.init(
			operationID: click.operationID,
			disposition: .dispatched,
			failure: .duplicateOperation
		))
		expectNoDifference(state.automationResponseValidation(
			duplicate, result: response, snapshots: fixture.snapshots
		), nil)

		switch change {
		case "reference": click.reference = "other"

		case "snapshot": click.snapshotID = "other"

		default:
			let key = AutomationState.OperationKey(clientID: original.clientID, operationID: click.operationID)
			state.automation.operationBindings[key] = AutomationSecurity.mutationBinding(.form(.init(
				target: click,
				kind: .replaceText,
				value: "fixture"
			)))
		}
		duplicate.operation = .click(click)
		expectNoDifference(state.automationResponseValidation(
			duplicate, result: response, snapshots: fixture.snapshots
		), .denied)
	}

	@Test
	internal func cancelledSubmittedAttemptRemainsUncertainAcrossReconnect() async throws {
		let fixture = try Fixture()
		let request = try fixture.request()
		fixture.afterDispatch = {
			fixture.store.send(.automation(.event(.host(.cancel(request.id)))))
		}
		defer { fixture.afterDispatch = nil }
		await fixture.send(request).finish()
		expectNoDifference(fixture.clicks, 1)
		let key = AutomationState.OperationKey(clientID: request.clientID, operationID: try #require(request.operation.mutationID))
		expectNoDifference(fixture.store.automation.clickOutcomes[key]?.disposition, .possiblyDispatched)
		await fixture.store.send(.automation(.event(.host(.disconnected(sessionID: request.sessionID))))).finish()
		await fixture.store.send(.automation(.event(.host(.connected(clientID: request.clientID, sessionID: request.sessionID))))).finish()
		var replay = request
		replay.id = UUID()
		await fixture.send(replay).finish()
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .possiblyDispatched)
	}

	@Test
	internal func anotherClientCannotRunAConflictingMutationDuringApproval() async throws {
		let fixture = try Fixture(temporaryApproval: false)
		let first = try fixture.request()
		await fixture.send(first).finish()
		var second = try fixture.request()
		second.clientID = UUID(90)
		second.sessionID = UUID(91)
		await fixture.send(second).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.outcomes.last?.failure, .busy)
		await fixture.store.send(.automation(.ui(.decline(first.id)))).finish()
		expectNoDifference(fixture.outcomes.last?.failure, .approvalDeclined)
	}

	@Test
	internal func expiryAtSubmissionCannotEraseRecordedUncertainty() async throws {
		let fixture = try Fixture()
		let request = try fixture.request()
		fixture.beforeBegin = { fixture.now = fixture.now.addingTimeInterval(31) }
		fixture.afterDispatch = { fixture.store.send(.automation(.event(.host(.cancel(request.id))))) }
		defer {
			fixture.beforeBegin = nil
			fixture.afterDispatch = nil
		}
		await fixture.send(request).finish()
		let key = AutomationState.OperationKey(clientID: request.clientID, operationID: try #require(request.operation.mutationID))
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.store.automation.clickOutcomes[key]?.disposition, .possiblyDispatched)
	}

	@Test
	internal func duplicateWhileApprovalIsPendingCannotPromiseNoEffect() async throws {
		let fixture = try Fixture(temporaryApproval: false)
		let original = try fixture.request()
		await fixture.send(original).finish()
		var duplicate = original
		duplicate.id = UUID()
		await fixture.send(duplicate).finish()
		let heldReply = try #require(fixture.outcomes.last)
		expectNoDifference(heldReply.disposition, .possiblyDispatched)
		expectNoDifference(heldReply.failure, .duplicateOperation)
		expectNoDifference(fixture.clicks, 0)

		await fixture.store.send(.automation(.ui(.approve(original.id)))).finish()
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .dispatched)
		expectNoDifference(fixture.store.state.automationResponseValidation(
			duplicate, result: .click(heldReply), snapshots: fixture.snapshots
		), nil)
	}

	@Test(arguments: ["client", "global"])
	internal func capacityRejectionSurvivesFinalResponseWithoutReplayAuthority(budget: String) async throws {
		let fixture = try Fixture(exhaustedBudget: budget)
		let request = try fixture.request()
		await fixture.send(request).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .limitExceeded)
		let key = AutomationState.OperationKey(clientID: request.clientID, operationID: try #require(request.operation.mutationID))
		#expect(!fixture.store.automation.usedOperations.contains(key))
		#expect(fixture.store.automation.clickOutcomes[key] == nil)
	}

	@Test(arguments: AutomationApprovalPolicy.allCases, ["Pay now", "Send", "Post", "Delete"])
	internal func consequentialClickAsksUnderEveryPolicyAndGrant(
		policy: AutomationApprovalPolicy,
		label: String
	) async throws {
		let fixture = try Fixture(temporaryApproval: true, label: label, policy: policy)
		let request = try fixture.request()
		await fixture.send(request).finish()
		expectNoDifference(fixture.clicks, 0)
		let pending = try #require(fixture.store.automation.pending[request.id])
		#expect(pending.awaitingApproval && !pending.approved)
		expectNoDifference(pending.consequence?.label, label)

		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .dispatched)
	}

	@Test(arguments: [AutomationApprovalPolicy.destructiveOnly, .never])
	internal func ordinaryClickFollowsThePolicy(policy: AutomationApprovalPolicy) async throws {
		let fixture = try Fixture(temporaryApproval: false, label: "Next", policy: policy)
		await fixture.send(try fixture.request()).finish()
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.outcomes.last?.failure, nil)
	}

	@Test
	internal func consequentialClickIsRefusedWhenNobodyCanAsk() async throws {
		let fixture = try Fixture(label: "Pay now", policy: .never)
		await fixture.store.send(.automation(.ui(.unattended))).finish()
		await fixture.send(try fixture.request()).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.outcomes.last?.failure, .userActionRequired)
	}

	@Test
	internal func batchWithAConsequentialStepAsksAndThenCoversIt() async throws {
		let fixture = try Fixture(temporaryApproval: false, label: "Delete", policy: .never)
		let step = try fixture.request()
		let batch = AutomationRequest(
			id: UUID(),
			clientID: step.clientID,
			sessionID: step.sessionID,
			operation: .batch(.init(batchID: UUID(), steps: [step.operation]))
		)
		await fixture.send(batch).finish()
		let pending = try #require(fixture.store.automation.pending[batch.id])
		#expect(pending.awaitingApproval)
		expectNoDifference(pending.stepConsequences[0]?.kind, .delete)

		await fixture.store.send(.automation(.ui(.approve(batch.id)))).finish()
		#expect(fixture.store.automation.batchApprovals[step.sessionID]?.askedUser == true)
		await fixture.send(step).finish()
		expectNoDifference(fixture.clicks, 1)
	}

	@Test
	internal func batchApprovalTheUserNeverSawDoesNotCoverAConsequentialStep() async throws {
		// As a batch approved under the never policy, before the step's snapshot showed a Delete.
		let operationID = UUID()
		let fixture = try Fixture(
			temporaryApproval: false,
			label: "Delete",
			policy: .never,
			unaskedBatchFor: operationID
		)
		let step = try fixture.request(operationID: operationID)
		await fixture.send(step).finish()
		expectNoDifference(fixture.clicks, 0)
		#expect(fixture.store.automation.pending[step.id]?.awaitingApproval == true)
		#expect(fixture.store.automation.pending[step.id]?.approvalExpiresAt == nil)

		await fixture.store.send(.automation(.ui(.approve(step.id)))).finish()
		expectNoDifference(fixture.clicks, 1)
	}

	@Test
	internal func askingTheUserTellsTheCallAtOnce() async throws {
		let fixture = try Fixture(temporaryApproval: false)
		let request = try fixture.request()
		await fixture.send(request).finish()
		expectNoDifference(fixture.clicks, 0)
		expectNoDifference(fixture.waits, [request.id: .init(kind: .approval, question: "approve a click in Arx")])

		// Approved later, the click runs and answers the request as before.
		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.clicks, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .dispatched)
	}

	@Test
	internal func aGrantedClickNeverSaysItWaits() async throws {
		let fixture = try Fixture()
		await fixture.send(try fixture.request()).finish()
		expectNoDifference(fixture.clicks, 1)
		#expect(fixture.waits.isEmpty)
	}

	@Test
	internal func snapshotRegistryEvictsOldPayloadAndGrantChangeClearsIt() async throws {
		let fixture = try Fixture()
		var state = fixture.store.state
		let original = try #require(state.automation.releasedInspections.first)
		for index in 0..<17 {
			var result = original.result
			result.source.tabID = .init(rawValue: UUID(100 + index))
			result.request.targetID = result.source.tabID.rawValue
			var request = original.request
			request.operation = .inspect(result.request)
			state.recordReleasedInspection(request, result: result, grantRevision: original.grantRevision, now: fixture.now)
		}
		expectNoDifference(state.automation.releasedInspections.count, 16)
		#expect(!state.automation.releasedInspections.contains { $0.result.source.tabID == fixture.tab.id })

		let oldRevision = fixture.store.automationPreferences.clients[0].grantRevision
		var client = fixture.store.automationPreferences.clients[0]
		client.allowsPageInteraction = false
		await fixture.store.send(.automation(.ui(.updateClient(client)))).finish()
		#expect(fixture.store.automationPreferences.clients[0].grantRevision != oldRevision)
		#expect(fixture.store.automation.releasedInspections.isEmpty)
		#expect(fixture.store.automation.inspectionScopes.isEmpty)
	}
}

@MainActor
private final class Fixture {
	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var now: Date = Date(timeIntervalSince1970: 100)
	fileprivate var clicks: Int = 0
	fileprivate var outcomes: [AutomationClickResult] = []
	fileprivate var waits: [UUID: AutomationUserWait] = [:]
	fileprivate var beforeBegin: (@MainActor () -> Void)?
	fileprivate var beforeAuthorize: (@MainActor () -> Void)?
	fileprivate var afterDispatch: (@MainActor () -> Void)?
	private var requests: [UUID: AutomationRequest] = [:]
	private let inspection: AutomationInspectionResult

	fileprivate init(
		denying permission: String? = nil,
		temporaryApproval: Bool = true,
		exhaustedBudget: String? = nil,
		label: String = "Totally safe submit",
		policy: AutomationApprovalPolicy = .alwaysAsk,
		unaskedBatchFor operationID: UUID? = nil
	) throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		self.tab = tab
		self.other = organization.tabs[1]
		let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [
			tab.id: .init(navigation: .init(url: tab.restoration.url), revision: 3, documentRevision: 8)
		]
		self.snapshots = snapshots
		var client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: permission != "read",
			allowsPageContent: permission != "content",
			allowsPageInteraction: permission != "interaction",
			allowsManagement: permission != "management",
			mutationGrantUntil: temporaryApproval ? Date(timeIntervalSince1970: 500) : nil,
			grantRevision: UUID(82)
		)
		client.approvalPolicy = policy
		var readable = client
		readable.allowsRead = true
		let revision = try #require(AutomationInventoryBuilder.items(
			client: readable,
			organization: organization,
			snapshots: snapshots
		).first { $0.id == tab.id.rawValue }?.revision)
		self.inspection = .init(
			request: .init(targetID: tab.id.rawValue, expectedRevision: revision),
			source: .init(tabID: tab.id, profileID: tab.profileID, sessionRevision: 3, documentRevision: 8, scopeID: UUID(83)),
			snapshot: .init(
				snapshotID: "snapshot",
				documentID: "document",
				frameID: "frame",
				domVersion: "4",
				nodes: [.init(index: 0, role: "button", name: label, reference: "opaque")],
				omissions: PageInspectionOmission.allCases
			)
		)
		var second = client
		second.id = UUID(90)
		second.grantRevision = UUID(92)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id),
			automation: .init(isEnabled: true, clients: [client, second])
		)
		state.automation.sessions[UUID(81)] = client.id
		state.automation.sessions[UUID(91)] = second.id
		state.automation.inspectionScopes[UUID(81)] = .init(id: UUID(83), clientID: client.id, grantRevision: client.grantRevision)
		if let operationID {
			let binding = try #require(AutomationSecurity.mutationBinding(.click(Self.click(
				operationID: operationID,
				targetID: tab.id.rawValue,
				revision: revision
			))))
			state.automation.batchApprovals[UUID(81)] = .init(
				batchID: UUID(84),
				clientID: client.id,
				grantRevision: client.grantRevision,
				bindings: [binding],
				expiresAt: Date(timeIntervalSince1970: 160),
				askedUser: false
			)
		}
		if let exhaustedBudget {
			let count = exhaustedBudget == "client" ? 256 : 4096
			state.automation.usedOperations = Set((0..<count).map {
				.init(
					clientID: exhaustedBudget == "client" ? client.id : UUID(1000 + $0),
					operationID: UUID(6000 + $0)
				)
			})
		}
		self.store = Store(initialState: state) { BrowserAutomation() } withDependencies: { [weak self] dependencies in
			dependencies.uuid = .incrementing
			dependencies.date = .init { MainActor.assumeIsolated { self?.now ?? .distantPast } }
			dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
			dependencies.automationControl.authorize = { id in
				guard let self else { return false }
				return self.store.state.automationCanExecute(id, snapshots: self.snapshots, now: self.now)
			}
			dependencies.automationControl.beginClick = { id in
				guard let self else { return false }
				self.beforeBegin?()
				self.store.send(.automation(.event(.host(.clickSubmitted(id)))))
				return true
			}
			dependencies.automationControl.respond = { id, result in
				guard
					let self,
					let request = self.requests[id],
					case var .click(receipt) = result
				else { return }
				if let failure = self.store.state.automationResponseValidation(request, result: result, snapshots: self.snapshots) {
					receipt.failure = failure
				}
				self.outcomes.append(receipt)
			}
			dependencies.automationControl.waitForUser = { id, wait in
				self?.waits[id] = wait
			}
			dependencies.browserPageInteraction.isAvailable = { true }
			dependencies.browserPageInteraction.clickAuthorized = { request, _, authorize in
				guard let self else {
					return .init(operationID: request.operationID, disposition: .notDispatched)
				}
				self.beforeAuthorize?()
				guard authorize() else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .denied)
				}
				self.clicks += 1
				self.afterDispatch?()
				return .init(operationID: request.operationID, disposition: .dispatched)
			}
		}
		release(snapshotID: "snapshot")
	}

	fileprivate func release(snapshotID: String) {
		var result = inspection
		result.snapshot.snapshotID = snapshotID
		let request = AutomationRequest(id: UUID(), clientID: UUID(80), sessionID: UUID(81), operation: .inspect(result.request))
		store.send(.automation(.event(.host(.inspectionReleased(request, result, grantRevision: UUID(82))))))
	}

	fileprivate func request(operationID: UUID = UUID()) throws -> AutomationRequest {
		.init(id: UUID(), clientID: UUID(80), sessionID: UUID(81), operation: .click(Self.click(
			operationID: operationID,
			targetID: tab.id.rawValue,
			revision: inspection.request.expectedRevision
		)))
	}

	private static func click(
		operationID: UUID,
		targetID: UUID,
		revision: String
	) -> AutomationClickRequest {
		.init(
			operationID: operationID,
			targetID: targetID,
			expectedRevision: revision,
			snapshotID: "snapshot",
			reference: "opaque"
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		return store.send(.automation(.event(.host(.request(request)))))
	}
}
