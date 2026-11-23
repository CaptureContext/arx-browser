import BrowserAutomationClient
import BrowserCore
import Foundation
import _ComposableArchitecture

extension AutomationState {
	/// One approval decision covering a batch's mutating steps, for one connection
	/// and grant revision. Steps must arrive in order with exactly the approved
	/// operations; anything else ends the approval.
	internal struct BatchApproval: Equatable, Sendable {
		internal var batchID: UUID
		internal var clientID: UUID
		internal var grantRevision: UUID
		internal var bindings: [String]
		internal var next: Int
		internal var expiresAt: Date

		/// Whether the user approved it in Arx's prompt, rather than a policy or grant (DEV-1008).
		internal var askedUser: Bool

		internal init(
			batchID: UUID,
			clientID: UUID,
			grantRevision: UUID,
			bindings: [String],
			next: Int = 0,
			expiresAt: Date,
			askedUser: Bool = false
		) {
			self.batchID = batchID
			self.clientID = clientID
			self.grantRevision = grantRevision
			self.bindings = bindings
			self.next = next
			self.expiresAt = expiresAt
			self.askedUser = askedUser
		}
	}

	/// How long an approved batch waits for its steps.
	internal static let batchApprovalWindow: TimeInterval = AutomationBatchPlan.approvalWindow
}

extension AppFeature.State {
	/// Checks that every step targets something the grant covers, before the user is asked.
	/// Each step is still authorized again when it runs.
	internal func automationBatchValidation(
		_ plan: AutomationBatchPlan,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		do {
			try plan.validate()
		} catch {
			return .invalidRequest
		}
		guard client.allows(plan.requiredCapabilities) else { return .denied }

		func permitted(_ id: UUID) -> Bool {
			AutomationInventoryBuilder.item(id, client: client, organization: workspace, snapshots: snapshots) != nil
		}
		for step in plan.steps {
			let targets: [UUID]
			switch step {
			case let .command(command): targets = [command.targetID] + [command.destinationID, command.sourceTabID].compactMap(\.self)
			case let .click(request): targets = [request.targetID]
			case let .form(request): targets = [request.target.targetID]
			case let .scroll(request): targets = [request.target.targetID]
			case let .inspect(request): targets = [request.targetID]
			case let .wait(request): targets = [request.targetID]
			case let .capture(request): targets = [request.targetID]
			case let .load(request): targets = [request.targetID]
			case let .pdf(request): targets = [request.targetID]
			case let .findInPage(request): targets = [request.targetID]
			case let .dialog(request): targets = [request.targetID]
			case let .media(request): targets = request.targetID.map { [$0] } ?? []
			case let .script(request): targets = [request.targetID]
			case let .logs(request): targets = [request.targetID]
			case .inventory, .signIn, .batch, .data, .link, .settings, .passwordSignIn: targets = []
			}
			guard targets.allSatisfy(permitted) else { return .denied }
		}
		return nil
	}

	/// Marks a request approved when it is the next step of an approved batch from the
	/// same connection and grant. A request that is not the next step ends the batch.
	internal mutating func consumeBatchApproval(
		_ request: AutomationRequest,
		binding: String,
		grantRevision: UUID,
		now: Date
	) -> AutomationState.BatchApproval? {
		guard var approval = automation.batchApprovals[request.sessionID] else { return nil }
		guard
			approval.clientID == request.clientID,
			approval.grantRevision == grantRevision,
			approval.expiresAt > now,
			approval.next < approval.bindings.count,
			approval.bindings[approval.next] == binding
		else {
			automation.batchApprovals[request.sessionID] = nil
			return nil
		}

		approval.next += 1
		automation.batchApprovals[request.sessionID] = approval.next < approval.bindings.count ? approval : nil
		return approval
	}
}

extension BrowserAutomation {
	internal func approveBatch(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .batch(plan) = pending.request.operation
		else { return .none }

		let bindings = plan.steps.compactMap(AutomationSecurity.mutationBinding)
		let expiresAt: Date = now.addingTimeInterval(AutomationState.batchApprovalWindow)
		state.automation.batchApprovals[pending.request.sessionID] = bindings.isEmpty ? nil : .init(
			batchID: plan.batchID,
			clientID: pending.request.clientID,
			grantRevision: pending.grantRevision,
			bindings: bindings,
			expiresAt: expiresAt,
			askedUser: pending.awaitingApproval
		)
		return finish(
			id,
			result: .batch(.init(
				batchID: plan.batchID,
				approvedSteps: bindings.count,
				expiresAt: bindings.isEmpty ? nil : expiresAt
			)),
			state: &state
		)
	}
}
