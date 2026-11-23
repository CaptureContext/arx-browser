import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

internal struct AutomationPresentationTests {
	private let revision: String = .init(repeating: "a", count: 64)

	@Test
	internal func hostSchemaRequiresExplicitForegroundSourceAndCurrentHandle() async throws {
		let base: [String: Value] = [
			"operationID": .string(UUID(1).uuidString),
			"action": .string("openPeek"),
			"targetID": .string(UUID(2).uuidString),
			"expectedRevision": .string(revision),
			"sourceTabID": .string(UUID(3).uuidString),
			"sourceRevision": .string(revision),
			"focus": .bool(true),
		]
		guard case let .command(command) = try AutomationTools.operation(name: "browser_command", arguments: base) else {
			Issue.record("Missing host command")
			return
		}
		expectNoDifference(command.sourceTabID, UUID(3))

		for field in ["sourceTabID", "sourceRevision", "focus"] {
			var invalid = base
			invalid[field] = nil
			#expect(throws: (any Error).self) {
				try AutomationTools.operation(name: "browser_command", arguments: invalid)
			}
		}

		var promotion = base
		promotion["action"] = .string("promotePeekToTab")
		promotion["sourceTabID"] = nil
		promotion["sourceRevision"] = nil
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: promotion)
		}

		promotion["presentationID"] = .string(UUID(4).uuidString)
		promotion["presentationRevision"] = .string(revision)
		#expect(throws: Never.self) {
			try AutomationTools.operation(name: "browser_command", arguments: promotion)
		}

		promotion["presentationID"] = .string("not-a-UUID")
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: promotion)
		}
	}

	@Test
	internal func nonHostCommandsRejectHostFields() async throws {
		let arguments: [String: Value] = [
			"operationID": .string(UUID(1).uuidString),
			"action": .string("selectTab"),
			"targetID": .string(UUID(2).uuidString),
			"expectedRevision": .string(revision),
			"presentationID": .string(UUID(4).uuidString),
			"presentationRevision": .string(revision),
		]
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: arguments)
		}
	}

	@Test
	internal func hostMutationBindingIncludesExplicitSourceAndPresentationProof() async throws {
		var command = AutomationCommand(
			operationID: UUID(1),
			action: .openPeek,
			targetID: UUID(2),
			expectedRevision: revision,
			focus: true,
			sourceTabID: UUID(3),
			sourceRevision: String(repeating: "b", count: 64)
		)
		let original = AutomationSecurity.mutationBinding(.command(command))

		command.sourceTabID = UUID(4)
		#expect(original != AutomationSecurity.mutationBinding(.command(command)))

		command.sourceTabID = UUID(3)
		command.presentationID = UUID(5)
		#expect(original != AutomationSecurity.mutationBinding(.command(command)))
	}

	@Test
	internal func presentationsReachClientsWithoutPageValues() async throws {
		let presentation = AutomationPresentation(
			id: UUID(1),
			kind: .peek,
			tabID: UUID(2),
			profileID: UUID(3),
			sourceTargetID: UUID(4),
			revision: revision
		)

		let inventory = try BrowserMCPServer.payload(.inventory(.init(items: [], presentations: [presentation])))
		guard
			case let .object(inventoryFields) = inventory,
			case let .array(presentations) = inventoryFields["presentations"],
			case let .object(entry) = presentations.first
		else {
			Issue.record("Missing inventory presentations")
			return
		}
		expectNoDifference(
			Set(entry.keys),
			["id", "kind", "tabID", "profileID", "sourceTargetID", "revision"]
		)
		expectNoDifference(entry["kind"], .string("peek"))

		let command = try BrowserMCPServer.payload(.command(.init(
			operationID: UUID(5),
			status: .acceptedLoading,
			targetID: UUID(4),
			presentation: presentation
		)))
		guard case let .object(commandFields) = command else {
			Issue.record("Missing command payload")
			return
		}
		expectNoDifference(commandFields["presentation"], .object(entry))

		let committed = try BrowserMCPServer.payload(.command(.init(operationID: UUID(5), status: .committed)))
		guard case let .object(committedFields) = committed else {
			Issue.record("Missing committed payload")
			return
		}
		expectNoDifference(committedFields["presentation"], .null)

		let bytes = try JSONEncoder().encode(inventory)
		let text = String(decoding: bytes, as: UTF8.self)
		#expect(!text.contains("url") && !text.contains("title") && !text.contains("content"))
	}

	@Test
	internal func olderInventoryWithoutPresentationsDecodes() async throws {
		let data = Data(#"{"items":[]}"#.utf8)
		let inventory = try JSONDecoder().decode(AutomationInventory.self, from: data)
		expectNoDifference(inventory.presentations, [])
	}
}

internal struct AutomationRoutingSchemaTests {
	private let revision: String = .init(repeating: "a", count: 64)

	private var base: [String: Value] {
		[
			"operationID": .string(UUID(1).uuidString),
			"action": .string("openTab"),
			"targetID": .string(UUID(2).uuidString),
			"expectedRevision": .string(revision),
			"url": .string("https://routed.example/docs"),
		]
	}

	@Test
	internal func routeIsAnExplicitOpenTabOptIn() async throws {
		let definition = try #require(AutomationTools.definitions.first { $0.name == "browser_tabs" })
		guard
			case let .object(schema) = definition.inputSchema,
			case let .object(properties) = schema["properties"],
			case let .object(route) = properties["route"]
		else {
			Issue.record("browser_tabs omits route")
			return
		}
		expectNoDifference(route["type"], .string("boolean"))

		guard case let .command(unrouted) = try AutomationTools.operation(name: "browser_command", arguments: base) else {
			Issue.record("Missing openTab")
			return
		}
		#expect(!unrouted.route)

		var arguments = base
		arguments["route"] = .bool(true)
		guard case let .command(routed) = try AutomationTools.operation(name: "browser_command", arguments: arguments) else {
			Issue.record("Missing routed openTab")
			return
		}
		#expect(routed.route)
		#expect(
			AutomationSecurity.mutationBinding(.command(routed))
			!= AutomationSecurity.mutationBinding(.command(unrouted))
		)

		arguments["route"] = .string("true")
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: arguments)
		}

		var explicit = base
		explicit["route"] = .bool(true)
		explicit["destinationID"] = .string(UUID(3).uuidString)
		explicit["destinationRevision"] = .string(revision)
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: explicit)
		}

		var navigation = base
		navigation["action"] = .string("navigate")
		navigation["route"] = .bool(true)
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: navigation)
		}
	}

	@Test
	internal func resultReportsTheResolvedRoute() async throws {
		let route = AutomationRoute(
			profileID: UUID(4),
			spaceID: UUID(5),
			mode: .littleArx,
			source: .rule,
			ruleID: UUID(6),
			ruleName: "Docs"
		)
		let response = try BrowserMCPServer.toolResult(.command(.init(
			operationID: UUID(1),
			status: .acceptedLoading,
			targetID: UUID(5),
			route: route
		)))
		guard
			case let .object(envelope) = response.structuredContent,
			case let .object(result) = envelope["result"]
		else {
			Issue.record("Missing command payload")
			return
		}
		expectNoDifference(result["route"], .object([
			"profileID": .string(UUID(4).uuidString),
			"spaceID": .string(UUID(5).uuidString),
			"mode": .string("littleArx"),
			"source": .string("rule"),
			"ruleID": .string(UUID(6).uuidString),
			"ruleName": .string("Docs"),
		]))
	}

	@Test
	internal func crossProfileRefusalIsSpecificAndExplainsTheUIPath() async throws {
		let response = try BrowserMCPServer.toolResult(.failure(.crossProfileTransferUnsupported))
		#expect(response.isError == true)
		guard
			case let .object(envelope) = response.structuredContent,
			case let .object(result) = envelope["result"]
		else {
			Issue.record("Missing error payload")
			return
		}
		expectNoDifference(result["code"], .string("crossProfileTransferUnsupported"))
		expectNoDifference(result["message"], AutomationFailure.crossProfileTransferUnsupported.message.map(Value.string))
		#expect(AutomationFailure.crossProfileTransferUnsupported.message?.contains("move it") == true)

		let plain = try BrowserMCPServer.toolResult(.failure(.denied))
		guard
			case let .object(plainEnvelope) = plain.structuredContent,
			case let .object(plainResult) = plainEnvelope["result"]
		else {
			Issue.record("Missing error payload")
			return
		}
		expectNoDifference(plainResult, ["kind": .string("error"), "code": .string("denied")])
	}
}
