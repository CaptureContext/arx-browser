import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

internal struct AutomationDeveloperTests {
	private static let revision: String = .init(repeating: "a", count: 64)

	private static var evaluate: [String: Value] {
		[
			"operationID": .string(UUID(4).uuidString),
			"targetID": .string(UUID(3).uuidString),
			"expectedRevision": .string(revision),
			"script": .string("return document.title"),
		]
	}

	@Test
	internal func evaluateParsesWithDefaultBoundsAndRefusesEverythingElse() throws {
		let request = AutomationScriptRequest(
			operationID: UUID(4),
			targetID: UUID(3),
			expectedRevision: Self.revision,
			script: "return document.title"
		)
		expectNoDifference(try AutomationTools.operation(name: "browser_evaluate", arguments: Self.evaluate), .script(request))
		expectNoDifference(request.maximumResultBytes, AutomationDeveloper.defaultResultBytes)
		expectNoDifference(request.timeoutMilliseconds, AutomationDeveloper.defaultTimeoutMilliseconds)

		let bounded = try AutomationTools.operation(
			name: "browser_evaluate",
			arguments: Self.evaluate.merging([
				"maximumResultBytes": .int(1024),
				"timeoutMilliseconds": .int(30_000),
			]) { $1 }
		)
		guard case let .script(script) = bounded else {
			Issue.record("browser_evaluate didn't parse as a script")
			return
		}
		#expect(script.maximumResultBytes == 1024)
		#expect(script.timeoutMilliseconds == 30_000)

		var invalid: [[String: Value]] = []
		for key in ["operationID", "targetID", "expectedRevision", "script"] {
			var missing = Self.evaluate
			missing[key] = nil
			invalid.append(missing)
		}
		invalid += [
			Self.evaluate.merging(["script": .string(String(repeating: "a", count: AutomationDeveloper.maximumScriptBytes + 1))]) { $1 },
			Self.evaluate.merging(["script": .string("   ")]) { $1 },
			Self.evaluate.merging(["maximumResultBytes": .int(AutomationDeveloper.maximumResultBytes + 1)]) { $1 },
			Self.evaluate.merging(["maximumResultBytes": .int(1023)]) { $1 },
			Self.evaluate.merging(["timeoutMilliseconds": .int(30_001)]) { $1 },
			Self.evaluate.merging(["timeoutMilliseconds": .int(99)]) { $1 },
			Self.evaluate.merging(["expectedRevision": .string("short")]) { $1 },
			Self.evaluate.merging(["world": .string("main")]) { $1 },
		]
		for arguments in invalid {
			#expect(throws: AutomationFailure.invalidRequest, "\(arguments.keys.sorted())") {
				try AutomationTools.operation(name: "browser_evaluate", arguments: arguments)
			}
		}
	}

	@Test
	internal func scriptsNeedTheirOwnClassAskEveryTimeAndBindTheirText() throws {
		let request = AutomationScriptRequest(
			operationID: UUID(4),
			targetID: UUID(3),
			expectedRevision: Self.revision,
			script: "return 1"
		)
		let operation = AutomationOperation.script(request)
		expectNoDifference(operation.requiredCapabilities, [.read, .script])
		#expect(operation.riskTier == .mutate)
		#expect(operation.ignoresTemporaryGrant)
		expectNoDifference(operation.mutationID, UUID(4))
		#expect(!AutomationTools.batchStepTools.contains("browser_evaluate"))

		var changed = request
		changed.script = "return 2"
		let binding = try #require(AutomationSecurity.mutationBinding(operation))
		#expect(binding != AutomationSecurity.mutationBinding(.script(changed)))
		changed = request
		changed.maximumResultBytes = 2048
		#expect(binding != AutomationSecurity.mutationBinding(.script(changed)))
	}

	@Test
	internal func logsParseReadsAndNeedTheDevtoolsClass() throws {
		let arguments: [String: Value] = [
			"action": .string("network"),
			"targetID": .string(UUID(3).uuidString),
			"after": .int(12),
			"limit": .int(20),
		]
		let request = AutomationLogRequest(action: .network, targetID: UUID(3), after: 12, limit: 20)
		expectNoDifference(try AutomationTools.operation(name: "browser_logs", arguments: arguments), .logs(request))
		expectNoDifference(AutomationOperation.logs(request).requiredCapabilities, [.read, .devtools])
		#expect(AutomationOperation.logs(request).riskTier == .read)
		#expect(AutomationSecurity.mutationBinding(.logs(request)) == nil)

		let invalid: [[String: Value]] = [
			arguments.merging(["action": .string("clear")]) { $1 },
			arguments.merging(["limit": .int(0)]) { $1 },
			arguments.merging(["limit": .int(201)]) { $1 },
			arguments.merging(["after": .int(-1)]) { $1 },
			["action": .string("start"), "targetID": .string(UUID(3).uuidString), "after": .int(4)],
			["action": .string("start")],
			arguments.merging(["headers": .bool(true)]) { $1 },
		]
		for arguments in invalid {
			#expect(throws: AutomationFailure.invalidRequest, "\(arguments)") {
				try AutomationTools.operation(name: "browser_logs", arguments: arguments)
			}
		}
	}

	@Test
	internal func developerToolsAreListedOnlyForTheirClasses() {
		let ordinary = AutomationTools.definitions(for: .init(capabilities: [.read, .pageContent, .interact])).map(\.name)
		#expect(!ordinary.contains("browser_evaluate"))
		#expect(!ordinary.contains("browser_logs"))

		let script = AutomationTools.definitions(for: .init(capabilities: [.read, .script])).map(\.name)
		#expect(script.contains("browser_evaluate"))
		#expect(!script.contains("browser_logs"))

		let devtools = AutomationTools.definitions(for: .init(capabilities: [.read, .devtools])).map(\.name)
		#expect(devtools.contains("browser_logs"))
		#expect(!devtools.contains("browser_evaluate"))

		let evaluate = AutomationTools.definitions.first { $0.name == "browser_evaluate" }
		#expect(evaluate?.annotations.destructiveHint == true)
		#expect(evaluate?.description?.contains("untrusted") == true)
	}

	@Test
	internal func scriptPayloadEmbedsTheValueAsJSONAndMarksItUntrusted() throws {
		let result = AutomationScriptResult(
			operationID: UUID(4),
			targetID: UUID(3),
			outcome: .value,
			value: #"{"title":"Fixture","count":2}"#
		)
		let tool = try BrowserMCPServer.toolResult(.script(result))
		let structured = try #require(tool.structuredContent?.objectValue)
		#expect(structured["untrustedData"] == .bool(true))
		let payload = try #require(structured["result"]?.objectValue)
		expectNoDifference(payload["outcome"], .string("value"))
		expectNoDifference(payload["value"], .object(["title": .string("Fixture"), "count": .int(2)]))

		let oversized = AutomationScriptResult(
			operationID: UUID(4),
			targetID: UUID(3),
			outcome: .value,
			value: String(repeating: "a", count: AutomationDeveloper.maximumResultBytes + 1)
		)
		expectNoDifference(BrowserMCPServer.validated(.script(oversized)), .failure(.limitExceeded))

		let syntax = AutomationScriptResult(
			operationID: UUID(4),
			targetID: UUID(3),
			outcome: .syntaxError,
			error: .init(name: "SyntaxError", message: "Unexpected end of input", line: 2)
		)
		let error = try #require(
			BrowserMCPServer.toolResult(.script(syntax)).structuredContent?.objectValue?["result"]?.objectValue?["error"]
		)
		expectNoDifference(error, .object([
			"name": .string("SyntaxError"),
			"message": .string("Unexpected end of input"),
			"line": .int(2),
		]))
	}

	@Test
	internal func logPayloadsCarryOnlyTheirEntriesAndCursor() throws {
		let result = AutomationLogResult(
			action: .network,
			targetID: UUID(3),
			capturing: true,
			network: [
				.init(
					sequence: 7,
					method: "GET",
					url: "https://a.test/api?token=redacted&page=2",
					status: 200,
					type: "empty",
					mimeType: "application/json",
					cached: false,
					bytes: 42,
					mainFrame: true,
					time: 1
				),
			],
			next: 7,
			dropped: 3
		)
		let payload = try #require(
			BrowserMCPServer.toolResult(.logs(result)).structuredContent?.objectValue?["result"]?.objectValue
		)
		expectNoDifference(payload["next"], .int(7))
		expectNoDifference(payload["dropped"], .int(3))
		let entry = try #require(payload["entries"]?.arrayValue?.first?.objectValue)
		expectNoDifference(Set(entry.keys), [
			"sequence", "method", "url", "status", "type", "mimeType", "cached", "bytes", "mainFrame", "time",
		])

		var tooMany = result
		tooMany.network = Array(repeating: result.network[0], count: AutomationDeveloper.maximumLogEntries + 1)
		expectNoDifference(BrowserMCPServer.validated(.logs(tooMany)), .failure(.limitExceeded))
		var mixed = result
		mixed.console = [.init(sequence: 1, level: .info, message: "x", mainFrame: true, time: 1)]
		expectNoDifference(BrowserMCPServer.validated(.logs(mixed)), .failure(.limitExceeded))
	}
}
