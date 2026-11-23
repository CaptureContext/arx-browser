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
internal struct AutomationScrollFeatureTests {
	@Test(arguments: ["read", "content", "interaction"], AutomationScrollRequest.Axis.allCases)
	internal func separatePermissionsAreRequired(
		permission: String,
		axis: AutomationScrollRequest.Axis
	) async throws {
		let fixture = try ScrollFixture(denying: permission)
		await fixture.send(fixture.request(axis: axis)).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .denied)
	}

	@Test(arguments: AutomationScrollRequest.Axis.allCases)
	internal func unchangedRequiresAuthorizationAndConsumesTheSharedOperationID(axis: AutomationScrollRequest.Axis) async throws {
		let fixture = try ScrollFixture()
		let request = fixture.request(axis: axis)
		await fixture.send(request).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .unchanged)
		expectNoDifference(fixture.outcomes.last?.failure, nil)
		#expect(fixture.store.automation.scrollReceipts.isEmpty)
		#expect(fixture.store.automation.pending.isEmpty)

		var duplicate = request
		duplicate.id = UUID()
		await fixture.send(duplicate).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .unchanged)
		expectNoDifference(fixture.outcomes.last?.failure, .duplicateOperation)
	}

	@Test
	internal func signedZeroSharesOneConsumedOperation() async throws {
		let fixture = try ScrollFixture()
		let first = fixture.request(delta: 0)
		await fixture.send(first).finish()
		var duplicate = first
		duplicate.id = UUID()
		guard case var .scroll(scroll) = duplicate.operation else { return }
		scroll.deltaCSSPixels = -0.0
		duplicate.operation = .scroll(scroll)
		await fixture.send(duplicate).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .unchanged)
		expectNoDifference(fixture.outcomes.last?.failure, .duplicateOperation)
	}

	@Test(arguments: [Double.nan, .infinity, -.infinity, 8193, -8193])
	internal func invalidDeltaIsRejectedBeforeApprovalAndNativeSubmission(delta: Double) async throws {
		let fixture = try ScrollFixture(temporaryApproval: false)
		await fixture.send(fixture.request(delta: delta)).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .invalidDelta)
		#expect(fixture.store.automation.pending.isEmpty)
	}

	@Test
	internal func priorFormOperationCannotAuthorizeScrollReplay() async throws {
		let fixture = try ScrollFixture()
		let scroll = fixture.request()
		var form = scroll
		guard case let .scroll(request) = scroll.operation else { return }
		form.operation = .form(.init(target: request.target, kind: .replaceText, value: "fixture"))
		await fixture.send(form).finish()
		var replay = scroll
		replay.id = UUID()
		await fixture.send(replay).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .possiblyDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .duplicateOperation)
	}

	@Test
	internal func finalReleaseCannotBorrowUnchangedReceiptForDifferentAxis() async throws {
		let fixture = try ScrollFixture()
		let first = fixture.request()
		await fixture.send(first).finish()
		var replay = first
		replay.id = UUID()
		guard case var .scroll(request) = replay.operation else { return }
		request.axis = .horizontal
		replay.operation = .scroll(request)
		let forged = AutomationScrollResult(
			operationID: request.operationID,
			disposition: .unchanged,
			failure: .duplicateOperation
		)
		expectNoDifference(fixture.store.state.automationResponseValidation(
			replay,
			result: .scroll(forged),
			snapshots: fixture.snapshots
		), .denied)
	}

	@Test(arguments: [AutomationFailure.cancelled, .staleReference, .timedOut, .denied])
	internal func knownUnchangedOutcomeIsNotRewrittenAsUncertainty(failure: AutomationFailure) async throws {
		let fixture = try ScrollFixture()
		fixture.resultFailure = failure
		await fixture.send(fixture.request()).finish()
		expectNoDifference(fixture.outcomes.last?.disposition, .unchanged)
		expectNoDifference(fixture.outcomes.last?.failure, failure)
		expectNoDifference(fixture.writes, 1)
	}

	@Test(arguments: ["delta", "axis", "target", "reference", "click", "form", "command"])
	internal func changedBindingNeverBorrowsAnUnchangedReceiptOrReplays(change: String) async throws {
		let fixture = try ScrollFixture()
		let first = fixture.request()
		await fixture.send(first).finish()
		var replay = first
		replay.id = UUID()
		guard case var .scroll(scroll) = replay.operation else { return }
		switch change {
		case "delta": scroll.deltaCSSPixels += 1
		case "axis": scroll.axis = .horizontal
		case "target": scroll.target.targetID = fixture.other.id.rawValue
		case "reference": scroll.target.reference = "different"
		default: break
		}
		replay.operation = .scroll(scroll)
		if change == "click" { replay.operation = .click(scroll.target) }
		if change == "form" { replay.operation = .form(.init(target: scroll.target, kind: .replaceText, value: "fixture")) }
		if change == "command" {
			replay.operation = .command(.init(
				operationID: scroll.operationID,
				action: .reload,
				targetID: scroll.target.targetID,
				expectedRevision: scroll.target.expectedRevision
			))
		}
		await fixture.send(replay).finish()
		expectNoDifference(fixture.writes, 1)
		switch fixture.allResults.last {
		case let .scroll(result):
			expectNoDifference(result.disposition, .possiblyDispatched)
			expectNoDifference(result.failure, .duplicateOperation)

		case let .form(result):
			expectNoDifference(result.disposition, .possiblyDispatched)
			expectNoDifference(result.failure, .duplicateOperation)

		case let .click(result):
			expectNoDifference(result.disposition, .possiblyDispatched)
			expectNoDifference(result.failure, .duplicateOperation)

		case let .failure(failure):
			expectNoDifference(failure, .duplicateOperation)

		default:
			Issue.record("Changed operation binding received a reusable receipt")
		}
	}

	@Test(arguments: ["latest", "document", "session", "disconnect", "grant", "expired"])
	internal func staleAuthorityNeverReachesNative(change: String) async throws {
		let fixture = try ScrollFixture(temporaryApproval: false)
		let request = fixture.request()
		await fixture.send(request).finish()
		expectNoDifference(fixture.store.automation.pending[request.id]?.awaitingApproval, true)
		switch change {
		case "latest":
			fixture.release(snapshotID: "newer")

		case "document":
			fixture.snapshots[fixture.tab.id]?.documentRevision = 9

		case "session":
			fixture.snapshots[fixture.tab.id]?.revision = 90

		case "expired":
			fixture.now = fixture.now.addingTimeInterval(31)

		case "grant":
			var client = fixture.store.automationPreferences.clients[0]
			client.allowsPageInteraction = false
			await fixture.store.send(.automation(.ui(.updateClient(client)))).finish()

		default:
			await fixture.store.send(.automation(.event(.host(.disconnected(sessionID: request.sessionID))))).finish()
		}
		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.writes, 0)
	}

	@Test
	internal func finalCallbackRechecksNavigationBeforeNativeAdmission() async throws {
		let fixture = try ScrollFixture()
		fixture.beforeAuthorize = { fixture.snapshots[fixture.tab.id]?.documentRevision = 9 }
		defer { fixture.beforeAuthorize = nil }
		await fixture.send(fixture.request()).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
	}

	@Test
	internal func cancellationBeforeSubmissionRetainsKnownNonDispatch() async throws {
		let fixture = try ScrollFixture(temporaryApproval: false)
		let request = fixture.request()
		await fixture.send(request).finish()
		await fixture.store.send(.automation(.event(.host(.cancel(request.id))))).finish()

		let key = AutomationState.OperationKey(
			clientID: request.clientID,
			operationID: try #require(request.operation.mutationID)
		)
		expectNoDifference(fixture.store.automation.scrollOutcomes[key]?.disposition, .notDispatched)
		var replay = request
		replay.id = UUID()
		await fixture.send(replay).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .duplicateOperation)
	}

	@Test
	internal func cancellationRetainsUncertaintyAcrossReconnect() async throws {
		let fixture = try ScrollFixture()
		let request = fixture.request()
		fixture.afterDispatch = { fixture.store.send(.automation(.event(.host(.cancel(request.id))))) }
		defer { fixture.afterDispatch = nil }
		await fixture.send(request).finish()
		expectNoDifference(fixture.writes, 1)
		let key = AutomationState.OperationKey(clientID: request.clientID, operationID: try #require(request.operation.mutationID))
		expectNoDifference(fixture.store.automation.scrollOutcomes[key]?.disposition, .possiblyDispatched)
		#expect(fixture.store.automation.pending.isEmpty)
		#expect(fixture.store.automation.scrollReceipts.isEmpty)
		await fixture.store.send(.automation(.event(.host(.disconnected(sessionID: request.sessionID))))).finish()
		await fixture.store.send(.automation(.event(.host(.connected(clientID: request.clientID, sessionID: request.sessionID))))).finish()
		var replay = request
		replay.id = UUID()
		await fixture.send(replay).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .possiblyDispatched)
	}

	@Test
	internal func pendingApprovalSerializesAllReferenceMutations() async throws {
		let fixture = try ScrollFixture(temporaryApproval: false)
		let first = fixture.request()
		await fixture.send(first).finish()
		var duplicate = first
		duplicate.id = UUID()
		await fixture.send(duplicate).finish()
		expectNoDifference(fixture.outcomes.last?.disposition, .possiblyDispatched)
		let held = try #require(fixture.outcomes.last)
		var click = fixture.request()
		if case let .scroll(scroll) = click.operation { click.operation = .click(scroll.target) }
		await fixture.send(click).finish()
		guard case let .click(clickResult) = fixture.allResults.last else {
			Issue.record("Concurrent click did not return an interaction result")
			return
		}
		expectNoDifference(clickResult.failure, .busy)
		var form = fixture.request()
		if case let .scroll(scroll) = form.operation {
			form.operation = .form(.init(target: scroll.target, kind: .replaceText, value: "fixture"))
		}
		await fixture.send(form).finish()
		guard case let .form(formResult) = fixture.allResults.last else {
			Issue.record("Concurrent form did not return an interaction result")
			return
		}
		expectNoDifference(formResult.failure, .busy)
		await fixture.send(fixture.request(axis: .horizontal)).finish()
		expectNoDifference(fixture.outcomes.last?.failure, .busy)
		await fixture.store.send(.automation(.ui(.approve(first.id)))).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.store.state.automationResponseValidation(
			duplicate, result: .scroll(held), snapshots: fixture.snapshots
		), nil)
	}

	@Test(arguments: ["client", "global"])
	internal func sharedCapacityFailureRemainsExplicitAtFinalRelease(budget: String) async throws {
		let fixture = try ScrollFixture(exhaustedBudget: budget)
		await fixture.send(fixture.request()).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .limitExceeded)
	}
}

@MainActor
private final class ScrollFixture {
	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var now: Date = Date(timeIntervalSince1970: 100)
	fileprivate var writes: Int = 0
	fileprivate var outcomes: [AutomationScrollResult] = []
	fileprivate var resultDisposition: AutomationScrollDisposition = .unchanged
	fileprivate var resultFailure: AutomationFailure?
	fileprivate var allResults: [AutomationResult] = []
	fileprivate var beforeAuthorize: (@MainActor () -> Void)?
	fileprivate var afterDispatch: (@MainActor () -> Void)?
	private var requests: [UUID: AutomationRequest] = [:]
	private let inspection: AutomationInspectionResult

	fileprivate init(
		denying permission: String? = nil,
		temporaryApproval: Bool = true,
		exhaustedBudget: String? = nil
	) throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		self.tab = tab
		self.other = organization.tabs[1]
		let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [
			tab.id: .init(
				navigation: .init(url: tab.restoration.url),
				revision: 3,
				documentRevision: 8
			),
		]
		self.snapshots = snapshots
		let client = AutomationClient(
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
				nodes: [.init(index: 0, role: "button", name: "Totally safe submit", reference: "opaque")],
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
			dependencies.automationControl.beginScroll = { id in
				guard let self else { return false }
				self.store.send(.automation(.event(.host(.scrollSubmitted(id)))))
				return true
			}
			dependencies.automationControl.respond = { id, result in
				guard let self, let request = self.requests[id] else { return }
				self.allResults.append(result)
				guard case var .scroll(receipt) = result else { return }
				if let failure = self.store.state.automationResponseValidation(request, result: result, snapshots: self.snapshots) {
					receipt.failure = failure
				}
				self.outcomes.append(receipt)
			}
			dependencies.browserPageInteraction.scrollIsAvailable = { true }
			dependencies.browserPageInteraction.scrollAuthorized = { request, _, authorize in
				guard let self else {
					return .init(operationID: request.operationID, disposition: .notDispatched)
				}
				self.beforeAuthorize?()
				guard authorize() else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .denied)
				}
				self.writes += 1
				self.afterDispatch?()
				return .init(
					operationID: request.operationID,
					disposition: self.resultDisposition,
					failure: self.resultFailure
				)
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

	fileprivate func request(
		axis: AutomationScrollRequest.Axis = .vertical,
		delta: Double = 120.5
	) -> AutomationRequest {
		.init(
			id: UUID(),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .scroll(.init(
				target: .init(
					operationID: UUID(),
					targetID: tab.id.rawValue,
					expectedRevision: inspection.request.expectedRevision,
					snapshotID: "snapshot",
					reference: "opaque"
				),
				axis: axis,
				deltaCSSPixels: delta
			))
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		return store.send(.automation(.event(.host(.request(request)))))
	}
}
