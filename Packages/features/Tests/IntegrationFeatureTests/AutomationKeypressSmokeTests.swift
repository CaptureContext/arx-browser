import Foundation
import Testing
import _MCP

@testable import AppFeature

@Suite(.dependencies)
internal struct AutomationKeypressSmokeTests {
	@Test(arguments: [false, true])
	internal func requiresActualEditingOrSuppressedRedirect(redirected: Bool) throws {
		try AutomationKeypressSmoke.verifyEvidence(Self.evidence(redirected: redirected), redirected: redirected)
	}

	@Test(arguments: ["activation", "foreign", "untrusted", "wrongValue", "missing", "replay", "leak", "redirectedInput"])
	internal func rejectsWeakOrLeakingEvidence(change: String) throws {
		let redirected = change == "redirectedInput"
		#expect(throws: AutomationSmokeFailure.invalidResponse) {
			try AutomationKeypressSmoke.verifyEvidence(
				Self.evidence(redirected: redirected, change: change),
				redirected: redirected
			)
		}
	}

	private static func evidence(
		redirected: Bool,
		change: String? = nil
	) throws -> Data {
		let kinds = redirected ? ["keydown", "beforeinput", "settled"] : ["keydown", "input", "keyup", "settled"]
		var events: [[String: Value]] = kinds.map { kind in
			[
				"target": .string(kind == "settled" ? "fixture" : "target"),
				"event": .string(kind),
				"trusted": .bool(kind != "settled"),
				"activation": .bool(false),
				"focused": .bool(!redirected),
				"correct": .bool(true),
			]
		}
		switch change {
		case "activation": events[0]["activation"] = .bool(true)
		case "foreign": events[0]["target"] = .string("foreign")
		case "untrusted": events[0]["trusted"] = .bool(false)
		case "wrongValue": events[events.count - 1]["correct"] = .bool(false)
		case "missing": events.removeLast()
		case "replay": events.append(events[0])
		case "leak": events[0]["value"] = .string("Private field contents")
		case "redirectedInput": events[1]["event"] = .string("input")
		default: break
		}
		return try JSONEncoder().encode(Value.object(["events": .array(events.map(Value.object))]))
	}
}
