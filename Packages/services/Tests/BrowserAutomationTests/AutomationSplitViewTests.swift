import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

/// DEV-692: `openSplit` takes two to four tabs and the orientation.
internal struct AutomationSplitViewTests {
	private let revision: String = .init(repeating: "a", count: 64)

	private var base: [String: Value] {
		[
			"operationID": .string(UUID(1).uuidString),
			"action": .string("openSplit"),
			"targetID": .string(UUID(2).uuidString),
			"expectedRevision": .string(revision),
		]
	}

	private func splitTabs(_ ids: [Int]) -> Value {
		.array(ids.map { id in
			.object(["id": .string(UUID(id).uuidString), "revision": .string(revision)])
		})
	}

	@Test
	internal func windowsToolDescribesSplitTabsAndOrientation() throws {
		let definition = try #require(AutomationTools.definitions.first { $0.name == "browser_windows" })
		guard
			case let .object(schema) = definition.inputSchema,
			case let .object(properties) = schema["properties"],
			case let .object(tabs) = properties["splitTabs"],
			case let .object(orientation) = properties["orientation"]
		else {
			Issue.record("browser_windows omits splitTabs or orientation")
			return
		}
		expectNoDifference(tabs["maxItems"], .int(3))
		expectNoDifference(orientation["enum"], .array([.string("horizontal"), .string("vertical")]))
	}

	@Test
	internal func openSplitAcceptsTwoToFourTabsAndAnOrientation() throws {
		guard case let .command(single) = try AutomationTools.operation(name: "browser_windows", arguments: base) else {
			Issue.record("Missing openSplit")
			return
		}
		expectNoDifference(single.splitTabs, nil)

		for count in 1 ... 3 {
			var arguments = base
			arguments["splitTabs"] = splitTabs(Array(3 ..< 3 + count))
			arguments["orientation"] = .string("vertical")
			guard
				case let .command(command) = try AutomationTools.operation(name: "browser_windows", arguments: arguments)
			else {
				Issue.record("Missing openSplit of \(count + 1)")
				return
			}
			expectNoDifference(command.splitTabs?.map(\.id), Array(3 ..< 3 + count).map { UUID($0) })
			expectNoDifference(command.orientation, .vertical)
			#expect(
				AutomationSecurity.mutationBinding(.command(command))
				!= AutomationSecurity.mutationBinding(.command(single))
			)
		}
	}

	@Test
	internal func openSplitRefusesAFifthTabRepeatsAndStrayFields() throws {
		var five = base
		five["splitTabs"] = splitTabs([3, 4, 5, 6])
		var none = base
		none["splitTabs"] = .array([])
		var repeated = base
		repeated["splitTabs"] = splitTabs([3, 3])
		var target = base
		target["splitTabs"] = splitTabs([2])
		var shortRevision = base
		shortRevision["splitTabs"] = .array([.object(["id": .string(UUID(3).uuidString), "revision": .string("a")])])
		var orientationAlone = base
		orientationAlone["orientation"] = .string("vertical")
		var badOrientation = base
		badOrientation["splitTabs"] = splitTabs([3])
		badOrientation["orientation"] = .string("diagonal")
		var otherAction = base
		otherAction["action"] = .string("swapSplit")
		otherAction["splitTabs"] = splitTabs([3])

		for arguments in [five, none, repeated, target, shortRevision, orientationAlone, badOrientation, otherAction] {
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_command", arguments: arguments)
			}
		}
	}
}
