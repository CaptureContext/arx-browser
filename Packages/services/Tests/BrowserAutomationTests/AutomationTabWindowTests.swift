import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

/// DEV-1157: with independent windows, MCP names the window that keeps each open tab, and
/// `openTab` can name the window that keeps the new one.
internal struct AutomationTabWindowTests {
	private let revision: String = .init(repeating: "a", count: 64)

	@Test
	internal func openTabTakesAWindowAndBindsItsApproval() throws {
		let definition = try #require(AutomationTools.definitions.first { $0.name == "browser_tabs" })
		guard
			case let .object(schema) = definition.inputSchema,
			case let .object(properties) = schema["properties"],
			case let .object(window) = properties["windowID"]
		else {
			Issue.record("browser_tabs omits windowID")
			return
		}
		expectNoDifference(window["type"], .string("string"))

		var arguments = openTab
		arguments["windowID"] = .string(UUID(9).uuidString)
		guard
			case let .command(windowed) = try AutomationTools.operation(name: "browser_tabs", arguments: arguments),
			case let .command(plain) = try AutomationTools.operation(name: "browser_tabs", arguments: openTab)
		else {
			Issue.record("Missing openTab")
			return
		}
		expectNoDifference(windowed.windowID, UUID(9))
		#expect(plain.windowID == nil)
		// An approval of one never covers the other.
		#expect(
			AutomationSecurity.mutationBinding(.command(windowed))
			!= AutomationSecurity.mutationBinding(.command(plain))
		)
	}

	@Test
	internal func onlyAnUnroutedOpenTabNamesAWindow() throws {
		var notAnID = openTab
		notAnID["windowID"] = .string("main")
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: notAnID)
		}

		var routed = openTab
		routed["windowID"] = .string(UUID(9).uuidString)
		routed["route"] = .bool(true)
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: routed)
		}

		var navigation = openTab
		navigation["action"] = .string("navigate")
		navigation["windowID"] = .string(UUID(9).uuidString)
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_command", arguments: navigation)
		}
	}

	@Test
	internal func windowsAndTabsCarryTheirWindowAndOlderPayloadsStillDecode() throws {
		let window = AutomationWindowItem(id: UUID(1), spaceID: UUID(2), isMain: true, revision: revision)
		let decoded = try JSONDecoder().decode(AutomationWindowItem.self, from: JSONEncoder().encode(window))
		expectNoDifference(decoded, window)

		// From before DEV-1157: no isMain, so not the main window.
		let older = Data(#"{"id":"\#(UUID(1))","spaceID":"\#(UUID(2))","paneTabIDs":[],"isFocused":false,"revision":"\#(revision)"}"#.utf8)
		#expect(try JSONDecoder().decode(AutomationWindowItem.self, from: older).isMain == false)

		var tab = AutomationInventoryItem(id: UUID(3), kind: .tab, title: "Tab", profileID: UUID(4), revision: revision)
		tab.windowID = UUID(1)
		let item = try JSONDecoder().decode(AutomationInventoryItem.self, from: JSONEncoder().encode(tab))
		expectNoDifference(item.windowID, UUID(1))
	}

	private var openTab: [String: Value] {
		[
			"operationID": .string(UUID(1).uuidString),
			"action": .string("openTab"),
			"targetID": .string(UUID(2).uuidString),
			"expectedRevision": .string(revision),
			"url": .string("https://window.example/"),
		]
	}
}
