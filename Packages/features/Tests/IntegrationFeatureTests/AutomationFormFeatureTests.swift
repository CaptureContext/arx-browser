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
internal struct AutomationFormFeatureTests {
	@Test(arguments: ["read", "content", "interaction"], AutomationFormRequest.Kind.allCases)
	internal func separatePermissionsAreRequired(
		permission: String,
		kind: AutomationFormRequest.Kind
	) async throws {
		let fixture = try FormFixture(denying: permission)
		await fixture.send(fixture.request(kind: kind)).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .denied)
	}

	@Test
	internal func keypressRequiresItsOwnNativeCapability() async throws {
		let fixture = try FormFixture()
		fixture.keypressAvailable = false
		await fixture.send(fixture.request(kind: .keyPress)).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .unsupported)
	}

	@Test
	internal func keypressUsesExplicitMutationApproval() async throws {
		let fixture = try FormFixture(temporaryApproval: false)
		let request = fixture.request(kind: .keyPress)
		await fixture.send(request).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.store.automation.pending[request.id]?.awaitingApproval, true)
		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.writes, 1)
	}

	@Test(arguments: AutomationFormRequest.Kind.allCases.filter { $0 != .upload })
	internal func unchangedRequiresAuthorizationAndConsumesTheSharedOperationID(kind: AutomationFormRequest.Kind) async throws {
		let fixture = try FormFixture()
		let request = fixture.request(kind: kind)
		await fixture.send(request).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .unchanged)
		expectNoDifference(fixture.outcomes.last?.failure, nil)
		#expect(fixture.store.automation.formReceipts.isEmpty)
		#expect(fixture.store.automation.pending.isEmpty)
		#expect(!String(reflecting: fixture.store.automation).contains("Secret fixture payload"))

		var duplicate = request
		duplicate.id = UUID()
		await fixture.send(duplicate).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .unchanged)
		expectNoDifference(fixture.outcomes.last?.failure, .duplicateOperation)
	}


	@Test(arguments: [AutomationApprovalPolicy.alwaysAsk, .destructiveOnly, .never])
	internal func uploadsAskEveryTimeWhateverTheApprovalPolicy(policy: AutomationApprovalPolicy) async throws {
		let fixture = try FormFixture(grantsFiles: true, approvalPolicy: policy)
		let request = fixture.request(kind: .upload)
		await fixture.send(request).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.store.automation.pending[request.id]?.awaitingApproval, true)
		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.writes, 1)
	}

	@Test(arguments: [AutomationApprovalPolicy.alwaysAsk, .never])
	internal func acceptingADialogAlwaysAsksAndDismissingNever(policy: AutomationApprovalPolicy) async throws {
		let fixture = try FormFixture(temporaryApproval: false, approvalPolicy: policy)
		let accept = fixture.dialogRequest(.accept)
		await fixture.send(accept).finish()
		expectNoDifference(fixture.dialogAnswers, [])
		expectNoDifference(fixture.store.automation.pending[accept.id]?.awaitingApproval, true)
		await fixture.store.send(.automation(.ui(.approve(accept.id)))).finish()
		expectNoDifference(fixture.dialogAnswers, [true])

		await fixture.send(fixture.dialogRequest(.dismiss)).finish()
		expectNoDifference(fixture.dialogAnswers, [true, false])
		guard case let .dialog(result) = fixture.allResults.last else {
			Issue.record("A dismissal didn't answer")
			return
		}
		#expect(result.answered)

		await fixture.send(fixture.dialogRequest(.read)).finish()
		guard case let .dialog(read) = fixture.allResults.last else {
			Issue.record("A read didn't return the dialog")
			return
		}
		expectNoDifference(read.dialog, fixture.dialog)
	}

	@Test
	internal func uploadsNeedTheFilesClass() async throws {
		let fixture = try FormFixture()
		await fixture.send(fixture.request(kind: .upload)).finish()
		expectNoDifference(fixture.writes, 0)
		switch fixture.allResults.last {
		case let .form(result): expectNoDifference(result.failure, .denied)
		case let .failure(failure): expectNoDifference(failure, .denied)
		default: Issue.record("An upload without the files class wasn't denied")
		}
	}

	@Test(arguments: ["viewport", "foreignDestination"])
	internal func pointerTargetsComeFromTheReleasedSnapshot(change: String) async throws {
		let fixture = try FormFixture()
		var request = fixture.request(kind: change == "viewport" ? .pointerClick : .drag)
		guard case var .form(form) = request.operation else { return }
		if change == "viewport" {
			form.target.reference = form.target.snapshotID
			form.pointer = .init(point: .init(x: 5, y: 6))
		} else {
			form.pointer = .init(destinationReference: "foreign")
		}
		request.operation = .form(form)
		await fixture.send(request).finish()
		if change == "viewport" {
			expectNoDifference(fixture.writes, 1)
			expectNoDifference(fixture.outcomes.last?.failure, nil)
		} else {
			expectNoDifference(fixture.writes, 0)
			switch fixture.allResults.last {
			case let .form(result): expectNoDifference(result.failure, .staleReference)
			case let .failure(failure): expectNoDifference(failure, .staleReference)
			default: Issue.record("A foreign drag destination wasn't refused as stale")
			}
		}
	}

	@Test(arguments: [AutomationFailure.cancelled, .staleReference, .timedOut, .denied])
	internal func knownUnchangedOutcomeIsNotRewrittenAsUncertainty(failure: AutomationFailure) async throws {
		let fixture = try FormFixture()
		fixture.resultFailure = failure
		await fixture.send(fixture.request()).finish()
		expectNoDifference(fixture.outcomes.last?.disposition, .unchanged)
		expectNoDifference(fixture.outcomes.last?.failure, failure)
		expectNoDifference(fixture.writes, 1)
	}

	@Test(arguments: ["value", "kind", "target", "reference", "click", "command"])
	internal func changedBindingNeverBorrowsAnUnchangedReceiptOrReplays(change: String) async throws {
		let fixture = try FormFixture()
		let first = fixture.request()
		await fixture.send(first).finish()
		var replay = first
		replay.id = UUID()
		guard case var .form(form) = replay.operation else { return }
		switch change {
		case "value": form.value += "different"
		case "kind": form.kind = .selectValue
		case "target": form.target.targetID = fixture.other.id.rawValue
		case "reference": form.target.reference = "different"
		default: break
		}
		replay.operation = .form(form)
		if change == "click" { replay.operation = .click(form.target) }
		if change == "command" {
			replay.operation = .command(.init(
				operationID: form.operationID,
				action: .reload,
				targetID: form.target.targetID,
				expectedRevision: form.target.expectedRevision
			))
		}
		await fixture.send(replay).finish()
		expectNoDifference(fixture.writes, 1)
		switch fixture.allResults.last {
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
		let fixture = try FormFixture(temporaryApproval: false)
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
		let fixture = try FormFixture()
		fixture.beforeAuthorize = { fixture.snapshots[fixture.tab.id]?.documentRevision = 9 }
		defer { fixture.beforeAuthorize = nil }
		await fixture.send(fixture.request()).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
	}

	@Test
	internal func cancellationRetainsUncertaintyAndDropsPayloadAcrossReconnect() async throws {
		let fixture = try FormFixture()
		let request = fixture.request()
		fixture.afterDispatch = { fixture.store.send(.automation(.event(.host(.cancel(request.id))))) }
		defer { fixture.afterDispatch = nil }
		await fixture.send(request).finish()
		expectNoDifference(fixture.writes, 1)
		let key = AutomationState.OperationKey(clientID: request.clientID, operationID: try #require(request.operation.mutationID))
		expectNoDifference(fixture.store.automation.formOutcomes[key]?.disposition, .possiblyDispatched)
		#expect(fixture.store.automation.pending.isEmpty)
		#expect(fixture.store.automation.formReceipts.isEmpty)
		#expect(!String(reflecting: fixture.store.automation).contains("Secret fixture payload"))
		await fixture.store.send(.automation(.event(.host(.disconnected(sessionID: request.sessionID))))).finish()
		await fixture.store.send(.automation(.event(.host(.connected(clientID: request.clientID, sessionID: request.sessionID))))).finish()
		var replay = request
		replay.id = UUID()
		await fixture.send(replay).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.outcomes.last?.disposition, .possiblyDispatched)
	}

	@Test
	internal func pendingApprovalSerializesClickAndBothFormKinds() async throws {
		let fixture = try FormFixture(temporaryApproval: false)
		let first = fixture.request()
		await fixture.send(first).finish()
		var duplicate = first
		duplicate.id = UUID()
		await fixture.send(duplicate).finish()
		expectNoDifference(fixture.outcomes.last?.disposition, .possiblyDispatched)
		let held = try #require(fixture.outcomes.last)
		var click = fixture.request()
		if case let .form(form) = click.operation { click.operation = .click(form.target) }
		await fixture.send(click).finish()
		guard case let .click(clickResult) = fixture.allResults.last else {
			Issue.record("Concurrent click did not return an interaction result")
			return
		}
		expectNoDifference(clickResult.failure, .busy)
		await fixture.send(fixture.request(kind: .selectValue)).finish()
		expectNoDifference(fixture.outcomes.last?.failure, .busy)
		await fixture.store.send(.automation(.ui(.approve(first.id)))).finish()
		expectNoDifference(fixture.writes, 1)
		expectNoDifference(fixture.store.state.automationResponseValidation(
			duplicate, result: .form(held), snapshots: fixture.snapshots
		), nil)
	}

	@Test(arguments: ["client", "global"])
	internal func sharedCapacityFailureRemainsExplicitAtFinalRelease(budget: String) async throws {
		let fixture = try FormFixture(exhaustedBudget: budget)
		await fixture.send(fixture.request()).finish()
		expectNoDifference(fixture.writes, 0)
		expectNoDifference(fixture.outcomes.last?.disposition, .notDispatched)
		expectNoDifference(fixture.outcomes.last?.failure, .limitExceeded)
	}
}

@MainActor
private final class FormFixture {
	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var now: Date = Date(timeIntervalSince1970: 100)
	fileprivate var writes: Int = 0
	fileprivate var dialogAnswers: [Bool] = []
	fileprivate let dialog = BrowserPageDialog(token: "1f", kind: .confirm, message: "Leave?")
	fileprivate var keypressAvailable: Bool = true
	fileprivate var outcomes: [AutomationFormResult] = []
	fileprivate var resultDisposition: AutomationFormDisposition = .unchanged
	fileprivate var resultFailure: AutomationFailure?
	fileprivate var allResults: [AutomationResult] = []
	fileprivate var beforeBegin: (@MainActor () -> Void)?
	fileprivate var beforeAuthorize: (@MainActor () -> Void)?
	fileprivate var afterDispatch: (@MainActor () -> Void)?
	private var requests: [UUID: AutomationRequest] = [:]
	private let inspection: AutomationInspectionResult

	fileprivate init(
		denying permission: String? = nil,
		temporaryApproval: Bool = true,
		exhaustedBudget: String? = nil,
		grantsFiles: Bool = false,
		approvalPolicy: AutomationApprovalPolicy = .alwaysAsk
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
		if grantsFiles { client.capabilities.insert(.files) }
		client.approvalPolicy = approvalPolicy
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
			dependencies.browserEngine.pageDialog = { _ in self?.dialog }
			dependencies.browserEngine.answerPageDialog = { _, _, accept, _, authorize in
				guard let self, authorize() else { return .denied }
				self.dialogAnswers.append(accept)
				return .answered
			}
			dependencies.automationControl.authorize = { id in
				guard let self else { return false }
				return self.store.state.automationCanExecute(id, snapshots: self.snapshots, now: self.now)
			}
			dependencies.automationControl.beginForm = { id in
				guard let self else { return false }
				self.beforeBegin?()
				self.store.send(.automation(.event(.host(.formSubmitted(id)))))
				return true
			}
			dependencies.automationControl.respond = { id, result in
				guard let self, let request = self.requests[id] else { return }
				if case .dialog = result {
					let failure = self.store.state.automationResponseValidation(request, result: result, snapshots: self.snapshots)
					self.allResults.append(failure.map(AutomationResult.failure) ?? result)
					return
				}
				self.allResults.append(result)
				guard case var .form(receipt) = result else { return }
				if let failure = self.store.state.automationResponseValidation(request, result: result, snapshots: self.snapshots) {
					receipt.failure = failure
				}
				self.outcomes.append(receipt)
			}
			dependencies.browserPageInteraction.formIsAvailable = { true }
			dependencies.browserPageInteraction.keypressIsAvailable = { self?.keypressAvailable == true }
			dependencies.browserPageInteraction.formAuthorized = { request, _, authorize in
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
		kind: AutomationFormRequest.Kind = .replaceText,
		value: String = "Secret fixture payload"
	) -> AutomationRequest {
		.init(
			id: UUID(),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .form(.init(
				target: .init(
					operationID: UUID(),
					targetID: tab.id.rawValue,
					expectedRevision: inspection.request.expectedRevision,
					snapshotID: "snapshot",
					reference: "opaque"
				),
				kind: kind,
				value: Self.value(kind, default: value),
				pointer: Self.pointer(kind),
				keyModifiers: kind == .keyChord ? [.control] : nil,
				values: kind == .selectValues ? ["first", "second"] : kind == .upload ? ["/tmp/arx-fixture.txt"] : nil,
				checked: kind == .setChecked ? true : nil
			))
		)
	}

	private static func value(_ kind: AutomationFormRequest.Kind, default value: String) -> String {
		switch kind {
		case .keyPress, .keyChord: "x"
		case .hover, .pointerClick, .drag, .selectValues, .setChecked, .upload: ""
		case .replaceText, .selectValue, .typeText: value
		}
	}

	private static func pointer(_ kind: AutomationFormRequest.Kind) -> AutomationPointer? {
		switch kind {
		case .hover, .pointerClick: .init()
		case .drag: .init(destinationReference: "opaque")
		case .replaceText, .selectValue, .keyPress, .typeText, .keyChord, .selectValues, .setChecked, .upload: nil
		}
	}

	fileprivate func dialogRequest(_ action: AutomationDialogRequest.Action) -> AutomationRequest {
		.init(
			id: UUID(),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .dialog(.init(
				action: action,
				targetID: tab.id.rawValue,
				expectedRevision: inspection.request.expectedRevision,
				operationID: action == .read ? nil : UUID(),
				token: action == .read ? nil : dialog.token
			))
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		return store.send(.automation(.event(.host(.request(request)))))
	}
}
