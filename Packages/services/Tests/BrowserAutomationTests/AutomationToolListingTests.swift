import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP

@testable import BrowserMCPServer

/// The core listing and `browser_more_tools` (DEV-1021).
internal struct AutomationToolListingTests {
	private static let everything: AutomationGrantSummary = .init(capabilities: AutomationCapability.allCases)

	private static func names(
		_ grants: AutomationGrantSummary,
		_ listing: AutomationTools.Listing
	) -> [String] {
		AutomationTools.definitions(for: grants, listing: listing).map(\.name)
	}

	private static func bytes(_ tools: [Tool]) throws -> Int {
		try JSONEncoder().encode(tools).count
	}

	@Test
	internal func claudeCodeStartsWithTheCoreToolsAndOthersWithEveryTool() {
		expectNoDifference(AutomationTools.listing(client: "claude-code", environment: [:]), .core(added: []))
		expectNoDifference(AutomationTools.listing(client: "codex-mcp-client", environment: [:]), .full)
		expectNoDifference(AutomationTools.listing(client: "codex-mcp-client", environment: ["ARX_MCP_TOOLS": "core"]), .core(added: []))
		expectNoDifference(AutomationTools.listing(client: "claude-code", environment: ["ARX_MCP_TOOLS": "all"]), .full)
		expectNoDifference(AutomationTools.listing(client: "claude-code", environment: ["ARX_MCP_TOOLS": "other"]), .core(added: []))
	}

	@Test
	internal func theFullListingIsUnchanged() {
		expectNoDifference(
			Self.names(Self.everything, .full),
			AutomationTools.definitions(for: Self.everything).map(\.name)
		)
		#expect(!Self.names(Self.everything, .full).contains(AutomationTools.moreToolsName))
	}

	@Test
	internal func everyToolIsCoreOrInExactlyOneGroup() {
		let listed: [String] = Self.names(Self.everything, .full)
		for name in listed {
			let groups = AutomationTools.ToolGroup.allCases.filter { $0.tools.contains(name) }
			let core = AutomationTools.coreTools.contains(name)
			#expect(core ? groups.isEmpty : groups.count == 1, "\(name): core \(core), groups \(groups)")
		}
		let named: Set<String> = AutomationTools.coreTools.union(AutomationTools.ToolGroup.allCases.flatMap(\.tools))
		expectNoDifference(named.subtracting(listed), [])
	}

	@Test
	internal func theCoreListingIsSmallAndFollowsTheGrant() throws {
		let core: [String] = Self.names(Self.everything, .core(added: []))
		expectNoDifference(Set(core), AutomationTools.coreTools.union([AutomationTools.moreToolsName]))
		#expect(core.last == AutomationTools.moreToolsName)

		let full = AutomationTools.definitions(for: Self.everything, listing: .full)
		let lean = AutomationTools.definitions(for: Self.everything, listing: .core(added: []))
		let leanBytes: Int = try Self.bytes(lean)
		let fullBytes: Int = try Self.bytes(full)

		// With every class granted: about 19 KB of 75 KB when DEV-1021 landed.
		#expect(leanBytes * 3 < fullBytes, "\(leanBytes) of \(fullBytes) bytes")

		// A core tool is described more briefly than in the full listing, and still by name.
		for tool in lean where tool.name != AutomationTools.moreToolsName {
			let whole = try #require(full.first { $0.name == tool.name })
			#expect((tool.description ?? "").count < (whole.description ?? "").count, "\(tool.name)")
			#expect(!(tool.description ?? "").isEmpty, "\(tool.name)")
		}

		// The grant still decides: read alone lists its core tools and browser_more_tools.
		expectNoDifference(
			Self.names(.init(capabilities: [.read]), .core(added: [])),
			["browser_inventory", "browser_wait", "browser_batch", "browser_run", AutomationTools.moreToolsName]
		)
		#expect(Self.names(.init(capabilities: [.organize, .interact]), .core(added: [])).isEmpty)
	}

	@Test
	internal func theCoreListingKeepsEveryArgument() throws {
		let full = AutomationTools.definitions(for: Self.everything, listing: .full)
		for tool in AutomationTools.definitions(for: Self.everything, listing: .core(added: [])) {
			guard let whole = full.first(where: { $0.name == tool.name })
			else { continue }

			guard
				case let .object(lean) = tool.inputSchema,
				case let .object(original) = whole.inputSchema,
				case let .object(leanProperties) = lean["properties"],
				case let .object(originalProperties) = original["properties"]
			else {
				Issue.record("\(tool.name) has no properties")
				continue
			}
			expectNoDifference(Set(leanProperties.keys), Set(originalProperties.keys), "\(tool.name)")
			expectNoDifference(lean["required"], original["required"], "\(tool.name)")
		}
	}

	@Test
	internal func groupsJoinTheListingWithinTheGrant() {
		let organized: [String] = Self.names(Self.everything, .core(added: [.organize, .screenshots]))
		#expect(organized.contains("browser_spaces"))
		#expect(organized.contains("browser_capture"))
		#expect(!organized.contains("browser_history"))

		// A group the grant doesn't cover adds nothing.
		let reader: AutomationGrantSummary = .init(capabilities: [.read, .pageContent])
		#expect(!Self.names(reader, .core(added: [.screenshots])).contains("browser_capture"))

		expectNoDifference(
			Set(Self.names(Self.everything, .core(added: Set(AutomationTools.ToolGroup.allCases)))),
			Set(Self.names(Self.everything, .full)).union([AutomationTools.moreToolsName])
		)
	}

	@Test
	internal func theFocusedTabNoteSurvivesTheCoreListing() {
		var focused = Self.everything
		focused.allowsFocusedTab = true
		let described = AutomationTools.definitions(for: focused, listing: .core(added: []))
			.filter { $0.description?.contains("focusedTab") == true }
			.map(\.name)
		expectNoDifference(Set(described), AutomationTools.focusedTabTools.intersection(AutomationTools.coreTools))
	}

	@Test
	internal func moreToolsNamesEveryGroup() throws {
		let tool = AutomationTools.moreToolsDefinition
		guard
			case let .object(schema) = tool.inputSchema,
			case let .object(properties) = schema["properties"],
			case let .object(groups) = properties["groups"],
			case let .object(items) = groups["items"],
			case let .array(names) = items["enum"]
		else {
			Issue.record("browser_more_tools has no group enum")
			return
		}
		expectNoDifference(names.compactMap(\.stringValue), AutomationTools.ToolGroup.allCases.map(\.rawValue) + ["all"])
		for group in AutomationTools.ToolGroup.allCases {
			#expect(tool.description?.contains(group.rawValue + " (") == true, "\(group)")
		}
	}

	@Test
	internal func moreToolsAddsGroupsAndReportsWhatTheGrantLacks() async throws {
		let listing = AutomationToolListing()
		await listing.choose(client: "claude-code", environment: [:])
		let grants: AutomationGrantSummary = .init(capabilities: [.read, .pageContent, .interact])

		let first = try await listing.moreTools(["groups": .array([.string("find"), .string("history")])], grants: grants)
		#expect(first.changed)
		expectNoDifference(Self.answer(first.result)["added"], .array([.string("browser_find"), .string("browser_find_in_page")]))
		expectNoDifference(Self.answer(first.result)["notGranted"], .array([.string("history")]))
		let current: AutomationTools.Listing = await listing.listing
		expectNoDifference(current, .core(added: [.find, .history]))

		// Adding a group again changes nothing.
		let again = try await listing.moreTools(["groups": .array([.string("find")])], grants: grants)
		#expect(!again.changed)
		expectNoDifference(Self.answer(again.result)["added"], .array([]))

		let all = try await listing.moreTools(["groups": .array([.string("all")])], grants: grants)
		#expect(all.changed)
		let widened: AutomationTools.Listing = await listing.listing
		expectNoDifference(widened, .core(added: Set(AutomationTools.ToolGroup.allCases)))

		await #expect(throws: MCPError.self) {
			try await listing.moreTools(["groups": .array([.string("passwords")])], grants: grants)
		}
		await #expect(throws: MCPError.self) {
			try await listing.moreTools(["groups": .array([])], grants: grants)
		}
		await #expect(throws: MCPError.self) {
			try await listing.moreTools(["groups": .array([.string("find")]), "extra": .bool(true)], grants: grants)
		}
	}

	@Test
	internal func moreToolsAddsNothingToAFullListing() async throws {
		let listing = AutomationToolListing()
		await listing.choose(client: "codex-mcp-client", environment: [:])
		let answer = try await listing.moreTools(["groups": .array([.string("all")])], grants: Self.everything)
		#expect(!answer.changed)
		expectNoDifference(Self.answer(answer.result)["added"], .array([]))
		let current: AutomationTools.Listing = await listing.listing
		expectNoDifference(current, .full)
	}

	private static func answer(_ result: CallTool.Result) -> [String: Value] {
		guard
			case let .object(fields) = result.structuredContent,
			case let .object(answer) = fields["result"]
		else { return [:] }

		return answer
	}
}
