import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

internal struct AutomationPasswordSignInTests {
	private static let revision: String = .init(repeating: "b", count: 64)

	private static var arguments: [String: Value] {
		[
			"operationID": .string(UUID(5).uuidString),
			"targetID": .string(UUID(6).uuidString),
			"expectedRevision": .string(revision),
			"origin": .string("https://example.com"),
		]
	}

	@Test
	internal func parsesTheBoundTabOriginAndFrame() throws {
		expectNoDifference(
			try AutomationTools.operation(name: "browser_password_sign_in", arguments: Self.arguments),
			.passwordSignIn(.init(
				operationID: UUID(5),
				targetID: UUID(6),
				expectedRevision: Self.revision,
				origin: "https://example.com"
			))
		)
		let framed = try AutomationTools.operation(
			name: "browser_password_sign_in",
			arguments: Self.arguments.merging(["frameID": .string("0A1B2C3D4E5F")]) { $1 }
		)
		guard case let .passwordSignIn(request) = framed else {
			Issue.record("browser_password_sign_in didn't parse")
			return
		}
		#expect(request.frameID == "0A1B2C3D4E5F")
	}

	/// Nothing credential-shaped is accepted, and every binding must be exact.
	@Test(arguments: [
		["password": Value.string("secret")],
		["username": .string("someone")],
		["origin": .string("https://example.com/login")],
		["origin": .string("http://example.com")],
		["origin": .string("https://user:pass@example.com")],
		["expectedRevision": .string("short")],
		["frameID": .string("not a token")],
		["frameID": .string("")],
		["targetID": .int(1)],
	])
	internal func refusesAnythingElse(_ change: [String: Value]) {
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(
				name: "browser_password_sign_in",
				arguments: Self.arguments.merging(change) { $1 }
			)
		}
	}

	@Test
	internal func needsTheSignInGrantAndIsAMutation() {
		#expect(AutomationTools.requiredCapabilities(forTool: "browser_password_sign_in") == [.read, .signIn])
		let operation = AutomationOperation.passwordSignIn(.init(
			operationID: UUID(5),
			targetID: UUID(6),
			expectedRevision: Self.revision,
			origin: "https://example.com"
		))
		#expect(operation.requiredCapabilities == [.read, .signIn])
		#expect(operation.riskTier == .mutate)
		#expect(AutomationSecurity.mutationBinding(operation) != nil)
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationBatchPlan(batchID: UUID(1), steps: [operation]).validate()
		}
	}

	/// The reply carries the operation, outcome and reason, and nothing else.
	@Test
	internal func payloadIsAnOutcomeOnly() throws {
		let payload = try BrowserMCPServer.payload(.passwordSignIn(.init(
			operationID: UUID(5),
			outcome: .needsUser,
			reason: .twoFactor
		)))
		expectNoDifference(payload, .object([
			"kind": .string("passwordSignIn"),
			"operationID": .string(UUID(5).uuidString),
			"outcome": .string("needsUser"),
			"reason": .string("twoFactor"),
		]))
	}
}
