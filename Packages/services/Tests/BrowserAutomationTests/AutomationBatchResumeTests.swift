import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Synchronization
import Testing
import _MCP

@testable import BrowserMCPServer

/// An approved batch whose step waits for the user goes on from that step on the same call
/// again, without asking for the batch again or repeating the steps that ran (DEV-1072).
internal struct AutomationBatchResumeTests {
	@Test(.timeLimit(.minutes(1)))
	internal func aBatchWhoseSecondStepWaitedResumesWithoutAskingAgain() async throws {
		let steps: [UUID] = [UUID(), UUID(), UUID()]
		let fake = BatchArx(waitingStep: steps[1])
		let (gateway, socket) = try await fake.start()
		let calls = AutomationCalls(gateway: gateway)
		let arguments = Self.batch(steps)
		let identity = BrowserMCPServer.callIdentity("browser_batch", arguments: arguments)

		let first = try await AutomationGateway.$userWait.withValue(.init(limit: .milliseconds(300), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}
		let waited = try Self.result(first)
		expectNoDifference(waited["stoppedAt"], .int(1))
		expectNoDifference(Self.codes(waited), ["committed", "waitingForUser"])

		// The user answers; the same call again goes on from the step that waited.
		fake.answer()
		let second = try await AutomationGateway.$userWait.withValue(.init(limit: .seconds(30), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}
		let finished = try Self.result(second)
		expectNoDifference(finished["completed"], .int(3))
		expectNoDifference(finished["stoppedAt"], .null)
		expectNoDifference(Self.codes(finished), ["committed", "committed", "committed"])
		expectNoDifference(fake.batches.count, 1)
		expectNoDifference(fake.commands, steps)

		await gateway.disconnect()
		await socket.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aLapsedApprovalIsAskedOnceForTheStepsLeft() async throws {
		let steps: [UUID] = [UUID(), UUID(), UUID(), UUID()]
		let fake = BatchArx(waitingStep: steps[1])
		let (gateway, socket) = try await fake.start()
		let calls = AutomationCalls(gateway: gateway, batchApprovalWindow: .seconds(1))
		let arguments = Self.batch(steps)
		let identity = BrowserMCPServer.callIdentity("browser_batch", arguments: arguments)

		_ = try await AutomationGateway.$userWait.withValue(.init(limit: .milliseconds(300), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}

		// The user answers after the batch approval lapsed.
		try await Task.sleep(for: .milliseconds(1200))
		fake.answer()
		let second = try await AutomationGateway.$userWait.withValue(.init(limit: .seconds(30), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}
		let finished = try Self.result(second)
		expectNoDifference(finished["completed"], .int(4))

		// One more approval, for the two steps that hadn't run; the waiting step wasn't asked again.
		let batches = fake.batches
		expectNoDifference(batches.count, 2)
		expectNoDifference(batches.last?.steps.compactMap(\.mutationID), Array(steps[2...]))
		expectNoDifference(fake.commands, steps)

		await gateway.disconnect()
		await socket.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func arxsOwnExpiryDecidesWhenTheApprovalLapsed() async throws {
		// The user approved long before the helper collected it: Arx's approval has 11 s left,
		// though the helper's own window, counted from when it heard, has nearly two minutes.
		let steps: [UUID] = [UUID(), UUID(), UUID(), UUID()]
		let fake = BatchArx(waitingStep: steps[1], approvalLifetime: 11)
		let (gateway, socket) = try await fake.start()
		let calls = AutomationCalls(gateway: gateway)
		let arguments = Self.batch(steps)
		let identity = BrowserMCPServer.callIdentity("browser_batch", arguments: arguments)

		_ = try await AutomationGateway.$userWait.withValue(.init(limit: .milliseconds(300), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}

		// Within 10 s of Arx's expiry, the helper asks again for the steps left.
		try await Task.sleep(for: .milliseconds(1200))
		fake.answer()
		let second = try await AutomationGateway.$userWait.withValue(.init(limit: .seconds(30), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}
		expectNoDifference(try Self.result(second)["completed"], .int(4))
		expectNoDifference(fake.batches.count, 2)
		expectNoDifference(fake.batches.last?.steps.compactMap(\.mutationID), Array(steps[2...]))

		await gateway.disconnect()
		await socket.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aRenewedApprovalThatWaitsKeepsTheReceiptsSoFar() async throws {
		let steps: [UUID] = [UUID(), UUID(), UUID()]
		let fake = BatchArx(waitingStep: steps[1], renewalWaits: true)
		let (gateway, socket) = try await fake.start()
		let calls = AutomationCalls(gateway: gateway, batchApprovalWindow: .seconds(1))
		let arguments = Self.batch(steps)
		let identity = BrowserMCPServer.callIdentity("browser_batch", arguments: arguments)

		_ = try await AutomationGateway.$userWait.withValue(.init(limit: .milliseconds(300), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}
		try await Task.sleep(for: .milliseconds(1200))
		fake.answer()

		// The step that waited is collected; the approval for the step left waits, and the call
		// still reports both steps that ran.
		let second = try await AutomationGateway.$userWait.withValue(.init(limit: .milliseconds(300), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}
		let waited = try Self.result(second)
		expectNoDifference(waited["stoppedAt"], .int(2))
		expectNoDifference(Self.codes(waited), ["committed", "committed", "waitingForUser"])

		// The user approves the step left; the same call again collects that approval.
		fake.answerRenewal()
		let third = try await AutomationGateway.$userWait.withValue(.init(limit: .seconds(30), call: identity)) {
			try await calls.call("browser_batch", arguments: arguments)
		}
		let finished = try Self.result(third)
		expectNoDifference(finished["completed"], .int(3))
		expectNoDifference(Self.codes(finished), ["committed", "committed", "committed"])
		expectNoDifference(fake.batches.count, 2)
		expectNoDifference(fake.commands, steps)

		await gateway.disconnect()
		await socket.stop()
	}

	// MARK: - Helpers

	private static func batch(_ operations: [UUID]) -> [String: Value] {
		let target: String = "8F0C2A9B-6A51-4C56-9D0B-3E1F4A7B2C10"
		return ["steps": .array(operations.map { operation in
			.object([
				"tool": .string("browser_tabs"),
				"arguments": .object([
					"operationID": .string(operation.uuidString),
					"action": .string("reload"),
					"targetID": .string(target),
					"expectedRevision": .string(String(repeating: "a", count: 64)),
				]),
			])
		})]
	}

	private static func result(_ response: CallTool.Result) throws -> [String: Value] {
		guard
			case let .object(fields) = response.structuredContent,
			case let .object(result) = fields["result"]
		else { throw AutomationFailure.invalidRequest }

		return result
	}

	/// Each step's status, or its failure code.
	private static func codes(_ result: [String: Value]) -> [String] {
		guard case let .array(steps) = result["steps"] else { return [] }
		return steps.compactMap { step in
			guard
				case let .object(fields) = step,
				case let .object(outcome) = fields["result"]
			else { return nil }

			return outcome["status"]?.stringValue ?? outcome["code"]?.stringValue
		}
	}
}

/// Stands in for Arx: approves every batch, runs every command, and asks the user about one.
private final class BatchArx: Sendable {
	private let state: Mutex<State>
	private let waitingStep: UUID

	/// Whether a second batch approval, for the steps left, waits for the user too.
	private let renewalWaits: Bool

	/// How long an approval lasts from Arx's answer, when Arx says.
	private let approvalLifetime: TimeInterval?

	private struct State {
		var batches: [AutomationBatchPlan] = []
		var commands: [UUID] = []
		var answered: Bool = false
		var renewalAnswered: Bool = false

		/// The request a `wait` collects: the waiting step's, or a renewal's.
		var renewal: AutomationBatchPlan?
	}

	internal init(
		waitingStep: UUID,
		renewalWaits: Bool = false,
		approvalLifetime: TimeInterval? = nil
	) {
		self.state = .init(.init())
		self.waitingStep = waitingStep
		self.renewalWaits = renewalWaits
		self.approvalLifetime = approvalLifetime
	}

	private func approval(_ plan: AutomationBatchPlan) -> AutomationIPC.Reply {
		.result(.batch(.init(
			batchID: plan.batchID,
			approvedSteps: plan.steps.count,
			expiresAt: approvalLifetime.map { Date().addingTimeInterval($0) }
		)))
	}

	internal var batches: [AutomationBatchPlan] { state.withLock { $0.batches } }

	/// The commands Arx received, in order: a repeated one would show twice.
	internal var commands: [UUID] { state.withLock { $0.commands } }

	internal func answer() {
		state.withLock { $0.answered = true }
	}

	internal func answerRenewal() {
		state.withLock { $0.renewalAnswered = true }
	}

	internal func start() async throws -> (AutomationGateway, LocalAutomationSocket) {
		let socket = LocalAutomationSocket()
		let directory = URL(fileURLWithPath: "/tmp/arx-batch-resume-" + UUID().uuidString.prefix(8))
		let path = try await socket.start(directory: directory) { [self] envelope in
			reply(envelope.payload)
		}
		let gateway = AutomationGateway(path: path, clientID: UUID(), credential: String(repeating: "0", count: 64))
		try await gateway.initialize()
		return (gateway, socket)
	}

	private func reply(_ payload: AutomationIPC.Payload) -> AutomationIPC.Reply {
		let asking = AutomationUserWait(kind: .approval, question: "approve a reload in Arx")
		switch payload {
		case .hello:
			return .hello(UUID())

		case .grants:
			return .grants(.init())

		case let .request(_, .batch(plan)):
			let waits = state.withLock { state in
				state.batches.append(plan)
				guard renewalWaits, state.batches.count > 1 else { return false }

				state.renewal = plan
				return true
			}
			if waits { return .waitingForUser(asking) }
			return approval(plan)

		case let .request(_, .command(command)):
			let operationID = command.operationID
			let waits = state.withLock { state in
				state.commands.append(operationID)
				return operationID == waitingStep && !state.answered
			}
			if waits { return .waitingForUser(asking) }
			return .result(.command(.init(operationID: operationID, status: .committed)))

		case .wait:
			return state.withLock { state in
				if let renewal = state.renewal {
					guard state.renewalAnswered else { return .waitingForUser(asking) }
					state.renewal = nil
					return approval(renewal)
				}
				guard state.answered else { return .waitingForUser(asking) }
				return .result(.command(.init(operationID: waitingStep, status: .committed)))
			}

		default:
			return .acknowledged
		}
	}
}
