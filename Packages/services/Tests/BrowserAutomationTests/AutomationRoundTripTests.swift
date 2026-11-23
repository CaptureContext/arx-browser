import BrowserAutomationClient
import BrowserCore
import BrowserMCPServer
import CustomDump
import Foundation
import Testing
import _MCP

internal struct AutomationRoundTripTests {
	@Test
	internal func splitCommandToolsAcceptOnlyTheirOwnActions() throws {
		let revision = String(repeating: "a", count: 64)
		func arguments(_ action: AutomationCommand.Action) -> [String: Value] {
			var arguments: [String: Value] = [
				"operationID": .string(UUID().uuidString),
				"action": .string(action.rawValue),
				"targetID": .string(UUID().uuidString),
				"expectedRevision": .string(revision),
			]
			switch action {
			case .openTab, .navigate, .startDownload: arguments["url"] = .string("https://capturecontext.dev/")
			case .createFolder, .renameFolder, .createProfile, .renameProfile, .createSpace, .renameSpace:
				arguments["name"] = .string("Name")
			case .setSpaceTheme: arguments["theme"] = .string("dark")
			case .setSpaceAppearance, .setProfileAppearance: arguments["appearance"] = .object(["tintHue": .int(120)])
			case .moveFolder, .moveTab, .pinTab, .unpinTab, .removeFavorite:
				arguments["destinationID"] = .string(UUID().uuidString)
				arguments["destinationRevision"] = .string(revision)
			default: break
			}
			return arguments
		}

		let owned = Set(AutomationTools.CommandTool.allCases.flatMap(\.actions))
		expectNoDifference(owned, Set(AutomationCommand.Action.allCases))
		for tool in AutomationTools.CommandTool.allCases {
			for action in AutomationCommand.Action.allCases where !action.isHostOperation {
				if tool.actions.contains(action) {
					guard case let .command(command) = try AutomationTools.operation(
						name: tool.rawValue,
						arguments: arguments(action)
					) else {
						Issue.record("\(tool.rawValue) did not produce a command")
						continue
					}
					expectNoDifference(command.action, action)

				} else {
					#expect(throws: AutomationFailure.self, "\(tool.rawValue) accepted \(action)") {
						try AutomationTools.operation(name: tool.rawValue, arguments: arguments(action))
					}
				}
			}
		}

		let definitions = Dictionary(uniqueKeysWithValues: AutomationTools.definitions.map { ($0.name, $0) })

		// The hint follows the riskiest action each tool carries.
		for tool in AutomationTools.CommandTool.allCases {
			let destructive = tool.actions.contains { $0.riskTier == .destructive }
			#expect(definitions[tool.rawValue]?.annotations.destructiveHint == destructive, "\(tool.rawValue)")
			#expect(definitions[tool.rawValue]?.annotations.readOnlyHint == false, "\(tool.rawValue)")
		}
		#expect(definitions["browser_windows"]?.annotations.destructiveHint == false)
		#expect(definitions["browser_profiles"]?.annotations.destructiveHint == true)
		#expect(definitions["browser_command"] == nil)
		for name in AutomationTools.returnSnapshotTools {
			let schema = String(decoding: try JSONEncoder().encode(definitions[name]?.inputSchema), as: UTF8.self)
			#expect(schema.contains("returnSnapshot"), "\(name)")
		}
	}

	@Test
	internal func dataAndLinkToolsParseBoundedRequests() throws {
		expectNoDifference(
			try AutomationTools.operation(name: "browser_history", arguments: ["query": .string("swift"), "limit": .int(10)]),
			.data(.init(kind: .history, query: "swift", limit: 10))
		)
		expectNoDifference(
			try AutomationTools.dataRequest(.archive, arguments: ["action": .string("list")]),
			.init(kind: .archive)
		)
		#expect(throws: AutomationFailure.self) {
			try AutomationTools.operation(name: "browser_history", arguments: ["limit": .int(500)])
		}
		#expect(throws: AutomationFailure.self) {
			try AutomationTools.operation(name: "browser_history", arguments: ["path": .string("/etc")])
		}
		expectNoDifference(
			try AutomationTools.operation(name: "browser_links", arguments: ["kind": .string("bang"), "query": .string("!w swift")]),
			.link(.init(kind: .bang, query: "!w swift"))
		)
		#expect(throws: AutomationFailure.self) {
			try AutomationTools.operation(name: "browser_links", arguments: ["kind": .string("clean"), "url": .string("file:///etc/hosts")])
		}
		expectNoDifference(AutomationTools.requiredCapabilities(forTool: "browser_history"), [.read, .history])
		expectNoDifference(AutomationTools.requiredCapabilities(forTool: "browser_downloads"), [.read, .downloads])
	}

	@Test
	internal func startDownloadParsesAsAProfileCommandThatNeedsAURL() throws {
		let operationID = UUID()
		let profileID = UUID()
		let revision = String(repeating: "b", count: 64)
		let arguments: [String: Value] = [
			"action": .string("startDownload"),
			"operationID": .string(operationID.uuidString),
			"targetID": .string(profileID.uuidString),
			"expectedRevision": .string(revision),
			"url": .string("https://capturecontext.dev/file.zip"),
		]
		let operation = try AutomationTools.operation(name: "browser_downloads", arguments: arguments)
		expectNoDifference(operation, .command(.init(
			operationID: operationID,
			action: .startDownload,
			targetID: profileID,
			expectedRevision: revision,
			url: URL(string: "https://capturecontext.dev/file.zip")
		)))
		expectNoDifference(operation.requiredCapabilities, [.read, .downloads])
		expectNoDifference(operation.riskTier, .mutate)
		#expect(operation.ignoresTemporaryGrant)
		#expect(!operation.alwaysAsks)
		expectNoDifference(AutomationCommand.Action.startDownload.targetKind, .profile)
		#expect(AutomationSecurity.mutationBinding(operation) != nil)

		var missing = arguments
		missing["url"] = nil
		for invalid in [
			missing,
			arguments.merging(["url": .string("file:///etc/hosts")]) { $1 },
			arguments.merging(["url": .string("https://user:secret@capturecontext.dev/file.zip")]) { $1 },
		] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(name: "browser_downloads", arguments: invalid)
			}
		}

		// startDownload belongs to browser_downloads, not the tab tools.
		#expect(throws: AutomationFailure.self) {
			try AutomationTools.operation(name: "browser_tabs", arguments: arguments)
		}

		let definition = try #require(
			AutomationTools.definitions(for: .init(capabilities: [.read, .downloads])).first { $0.name == "browser_downloads" }
		)
		let schema = String(decoding: try JSONEncoder().encode(definition.inputSchema), as: UTF8.self)
		#expect(schema.contains("startDownload"))
		#expect(schema.contains("\"url\""))
		#expect(definition.annotations.openWorldHint == true)
	}

	@Test
	internal func startDownloadCanNeverRideOnABatchApproval() {
		let start = AutomationOperation.command(.init(
			operationID: UUID(),
			action: .startDownload,
			targetID: UUID(),
			expectedRevision: String(repeating: "c", count: 64),
			url: URL(string: "https://capturecontext.dev/file.zip")
		))
		#expect(throws: AutomationFailure.self) {
			try AutomationBatchPlan(batchID: UUID(), steps: [start]).validate()
		}
	}

	@Test
	internal func batchPlansRejectNestingSignInAndRepeatedOperations() throws {
		let command = AutomationOperation.command(.init(
			operationID: UUID(),
			action: .reload,
			targetID: UUID(),
			expectedRevision: String(repeating: "a", count: 64)
		))
		try AutomationBatchPlan(batchID: UUID(), steps: [command, .inventory(cursor: nil, limit: 1)]).validate()
		expectNoDifference(AutomationBatchPlan(batchID: UUID(), steps: [command]).riskTier, .mutate)

		let rejected: [[AutomationOperation]] = [
			[],
			[command, command],
			[.batch(.init(batchID: UUID(), steps: [command]))],
			[.signIn(.init(operationID: UUID(), action: .status))],
			Array(repeating: .inventory(cursor: nil, limit: 1), count: AutomationBatchPlan.maximumSteps + 1),
		]
		for steps in rejected {
			#expect(throws: AutomationFailure.self) {
				try AutomationBatchPlan(batchID: UUID(), steps: steps).validate()
			}
		}
	}
}
