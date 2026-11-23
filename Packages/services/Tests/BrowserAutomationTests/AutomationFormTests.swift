import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP

@testable import BrowserMCPServer

internal struct AutomationFormTests {
	@Test(arguments: [AutomationFormRequest.Kind.replaceText, .selectValue])
	internal func explicitSchemaPreservesEmptyAndExactUnicodeValues(kind: AutomationFormRequest.Kind) throws {
		for value in ["", " exact value ", "é\u{0301}🙂"] {
			let form = Self.request(kind: kind, value: value)
			let name = kind == .replaceText ? "browser_replace_text" : "browser_select_value"
			let arguments = Self.arguments(form)
			expectNoDifference(try AutomationTools.operation(name: name, arguments: arguments), .form(form))
			for key in arguments.keys {
				var missing = arguments
				missing[key] = nil
				#expect(throws: AutomationFailure.invalidRequest) {
					try AutomationTools.operation(name: name, arguments: missing)
				}
			}
			var implicit = arguments
			implicit["focus"] = .bool(true)
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: name, arguments: implicit)
			}
		}
	}

	@Test(arguments: ["x", "🙂", "é", " ", "Enter", "Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"])
	internal func keypressSchemaRequiresExactKeyAndTarget(key: String) throws {
		let request = Self.request(kind: .keyPress, value: key)
		let arguments = Self.arguments(request)
		expectNoDifference(try AutomationTools.operation(name: "browser_keypress", arguments: arguments), .form(request))
		for field in arguments.keys {
			var changed = arguments
			changed[field] = nil
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_keypress", arguments: changed)
			}
		}
		for field in ["value", "focus", "modifiers", "code", "repeat"] {
			var changed = arguments
			changed[field] = .string("unsupported")
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_keypress", arguments: changed)
			}
		}
	}

	@Test(arguments: ["", "Tab", "Escape", "Control+a", "ab", "e\u{0301}", "\r", "\n", "\u{7F}", "\u{2029}", "\u{10FFFF}"])
	internal func unsupportedKeyRequestsAreRejectedBeforeExchange(key: String) throws {
		#expect(throws: AutomationFailure.invalidValue) { try Self.request(kind: .keyPress, value: key).validate() }
	}

	@Test
	internal func byteLimitsAndForbiddenCharactersNeverNormalizeOrTruncate() throws {
		try Self.request(value: String(repeating: "🙂", count: 8192)).validate()
		try Self.request(kind: .selectValue, value: String(repeating: "🙂", count: 1024)).validate()
		try Self.request(value: "line\nline").validate()
		try Self.request(kind: .selectValue, value: "\r\n").validate()
		for request in [
			Self.request(value: String(repeating: "🙂", count: 8193)),
			Self.request(kind: .selectValue, value: String(repeating: "🙂", count: 1025)),
			Self.request(value: "\0"),
			Self.request(kind: .selectValue, value: "\0"),
			Self.request(value: "\r"),
		] {
			#expect(throws: AutomationFailure.invalidValue) { try request.validate() }
		}
	}

	@Test
	internal func canonicalBindingSeparatesExactKindPayloadTargetAndFieldBoundaries() throws {
		let original = Self.request(value: "Sensitive test value")
		let digest = try #require(AutomationSecurity.mutationBinding(.form(original)))
		expectNoDifference(digest, AutomationSecurity.mutationBinding(.form(original)))
		#expect(digest.count == 64 && !digest.contains(original.value))
		var changed = original
		changed.kind = .selectValue
		#expect(digest != AutomationSecurity.mutationBinding(.form(changed)))
		changed = original
		changed.value += " "
		#expect(digest != AutomationSecurity.mutationBinding(.form(changed)))
		changed = original
		changed.target.targetID = UUID()
		#expect(digest != AutomationSecurity.mutationBinding(.form(changed)))
		#expect(digest != AutomationSecurity.mutationBinding(.click(original.target)))
		var first = original
		var second = original
		first.target.reference = "ab"
		first.value = "c"
		second.target.reference = "a"
		second.value = "bc"
		#expect(AutomationSecurity.mutationBinding(.form(first)) != AutomationSecurity.mutationBinding(.form(second)))
	}

	@Test(arguments: [AutomationFormDisposition.notDispatched, .dispatched, .possiblyDispatched, .unchanged])
	internal func receiptsContainNoValuesOrReferenceContent(disposition: AutomationFormDisposition) throws {
		let result = AutomationFormResult(operationID: UUID(), disposition: disposition)
		let payload = try BrowserMCPServer.payload(.form(result))
		guard case let .object(fields) = payload else {
			Issue.record("Missing form payload")
			return
		}
		expectNoDifference(Set(fields.keys), ["kind", "operationID", "disposition", "failure", "navigationCompleted"])
		expectNoDifference(fields["disposition"], .string(disposition.rawValue))
		expectNoDifference(fields["navigationCompleted"], .bool(false))
	}

	@Test(.timeLimit(.minutes(1)))
	internal func unexpectedReplyAfterExchangePreservesUncertainty() async throws {
		let socket = LocalAutomationSocket()
		let directory = URL(fileURLWithPath: "/tmp/arx-form-gateway-" + UUID().uuidString.prefix(8))
		defer {
			do { try FileManager.default.removeItem(at: directory) }
			catch { Issue.record("Gateway fixture cleanup failed") }
		}
		let path = try await socket.start(directory: directory) { envelope in
			if case .hello = envelope.payload { return .hello(UUID()) }
			return .acknowledged
		}
		let gateway = AutomationGateway(path: path, clientID: UUID(), credential: String(repeating: "0", count: 64))
		try await gateway.initialize()
		let request = Self.request()
		let result = await gateway.perform(.form(request))
		expectNoDifference(result, .form(.init(
			operationID: request.operationID,
			disposition: .possiblyDispatched,
			failure: .invalidRequest
		)))
		await gateway.disconnect()
		await socket.stop()
	}

	internal static func request(
		kind: AutomationFormRequest.Kind = .replaceText,
		value: String = "Sensitive test value"
	) -> AutomationFormRequest {
		.init(target: AutomationClickTests.request(), kind: kind, value: value)
	}

	private static func arguments(_ request: AutomationFormRequest) -> [String: Value] {
		[
			"operationID": .string(request.operationID.uuidString),
			"targetID": .string(request.target.targetID.uuidString),
			"expectedRevision": .string(request.target.expectedRevision),
			"snapshotID": .string(request.target.snapshotID),
			"reference": .string(request.target.reference),
			request.kind == .keyPress ? "key" : "value": .string(request.value),
		]
	}
}
