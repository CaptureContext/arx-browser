import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP

@testable import BrowserMCPServer

internal struct AutomationPointerTests {
	@Test
	internal func hoverTakesExactlyOneOfAReferenceAndAPoint() throws {
		let target = AutomationClickTests.request()
		var arguments = Self.target(target)
		expectNoDifference(
			try AutomationTools.operation(name: "browser_hover", arguments: arguments),
			.form(.init(target: target, kind: .hover, value: "", pointer: .init()))
		)

		arguments["reference"] = nil
		arguments["x"] = .double(12.5)
		arguments["y"] = .int(40)
		var viewport = target
		viewport.reference = target.snapshotID
		let hover = AutomationFormRequest(
			target: viewport,
			kind: .hover,
			value: "",
			pointer: .init(point: .init(x: 12.5, y: 40))
		)
		expectNoDifference(try AutomationTools.operation(name: "browser_hover", arguments: arguments), .form(hover))
		#expect(hover.targetsViewport)

		for invalid: [String: Value] in [
			Self.target(target).merging(["x": .int(1), "y": .int(1)]) { $1 },
			Self.target(target).merging(["x": .int(1)]) { $1 },
			Self.target(target).merging(["modifiers": .array([.string("shift")])]) { $1 },
			Self.target(target).merging(["clickCount": .int(2)]) { $1 },
			arguments.merging(["x": .int(-1)]) { $1 },
			arguments.merging(["y": .double(100_001)]) { $1 },
		] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(name: "browser_hover", arguments: invalid)
			}
		}
	}

	@Test
	internal func clickWithPointerOptionsBecomesARealPointerClick() throws {
		let target = AutomationClickTests.request()
		expectNoDifference(
			try AutomationTools.operation(name: "browser_click", arguments: Self.target(target)),
			.click(target)
		)
		let arguments = Self.target(target).merging([
			"clickCount": .int(2),
			"modifiers": .array([.string("shift"), .string("command")]),
		]) { $1 }
		expectNoDifference(
			try AutomationTools.operation(name: "browser_click", arguments: arguments),
			.form(.init(
				target: target,
				kind: .pointerClick,
				value: "",
				pointer: .init(clickCount: 2, modifiers: [.shift, .command])
			))
		)
		for invalid: [String: Value] in [
			arguments.merging(["clickCount": .int(4)]) { $1 },
			arguments.merging(["modifiers": .array([.string("control")])]) { $1 },
			arguments.merging(["modifiers": .array([.string("shift"), .string("shift")])]) { $1 },
		] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(name: "browser_click", arguments: invalid)
			}
		}
	}

	@Test
	internal func dragNeedsExactlyOneDestinationAndBoundedSteps() throws {
		let target = AutomationClickTests.request()
		let arguments = Self.target(target).merging(["toReference": .string("destination")]) { $1 }
		expectNoDifference(
			try AutomationTools.operation(name: "browser_drag", arguments: arguments),
			.form(.init(
				target: target,
				kind: .drag,
				value: "",
				pointer: .init(destinationReference: "destination", steps: 8)
			))
		)
		for invalid: [String: Value] in [
			Self.target(target),
			arguments.merging(["toX": .int(1), "toY": .int(2)]) { $1 },
			arguments.merging(["steps": .int(33)]) { $1 },
			arguments.merging(["steps": .int(0)]) { $1 },
			arguments.merging(["clickCount": .int(1)]) { $1 },
		] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(name: "browser_drag", arguments: invalid)
			}
		}
	}

	@Test
	internal func pointerFieldsChangeTheMutationBindingButFormBindingsKeepTheirDigest() throws {
		let target = AutomationClickTests.request()
		let near = AutomationFormRequest(
			target: target,
			kind: .drag,
			value: "",
			pointer: .init(destinationPoint: .init(x: 10, y: 10))
		)
		var far = near
		far.pointer?.destinationPoint = .init(x: 10, y: 11)
		let nearBinding = try #require(AutomationSecurity.mutationBinding(.form(near)))
		let farBinding = try #require(AutomationSecurity.mutationBinding(.form(far)))
		#expect(nearBinding != farBinding)

		let text = AutomationFormRequest(target: target, kind: .replaceText, value: "value")
		var withPointer = text
		withPointer.pointer = .init()
		#expect(AutomationSecurity.mutationBinding(.form(text)) != AutomationSecurity.mutationBinding(.form(withPointer)))
		#expect(throws: AutomationFailure.invalidValue) { try withPointer.validate() }
	}

	@Test
	internal func pointerToolsNeedThePageInteractionClass() {
		for name in ["browser_hover", "browser_drag"] {
			expectNoDifference(AutomationTools.requiredCapabilities(forTool: name), [.read, .pageContent, .interact])
			#expect(AutomationTools.returnSnapshotTools.contains(name))
			#expect(AutomationTools.batchStepTools.contains(name))
		}
	}

	private static func target(_ request: AutomationClickRequest) -> [String: Value] {
		[
			"operationID": .string(request.operationID.uuidString),
			"targetID": .string(request.targetID.uuidString),
			"expectedRevision": .string(request.expectedRevision),
			"snapshotID": .string(request.snapshotID),
			"reference": .string(request.reference),
		]
	}
}
