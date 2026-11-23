import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP

@testable import BrowserMCPServer

internal struct AutomationKeyboardTests {
	@Test
	internal func typeTakesPrintableTextUpToTheByteLimit() throws {
		let target = AutomationClickTests.request()
		let arguments = Self.target(target).merging(["text": .string("one\ntwo 🙂")]) { $1 }
		expectNoDifference(
			try AutomationTools.operation(name: "browser_type", arguments: arguments),
			.form(.init(target: target, kind: .typeText, value: "one\ntwo 🙂"))
		)
		for text in ["", "tab\there", "\u{7F}", String(repeating: "é", count: 513)] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(
					name: "browser_type",
					arguments: arguments.merging(["text": .string(text)]) { $1 }
				)
			}
		}
		#expect(throws: AutomationFailure.self) {
			try AutomationTools.operation(
				name: "browser_type",
				arguments: arguments.merging(["modifiers": .array([])]) { $1 }
			)
		}
	}

	@Test
	internal func keypressKeepsLegacyKeysAndBecomesAChordOtherwise() throws {
		let target = AutomationClickTests.request()
		let legacy = Self.target(target).merging(["key": .string("ArrowLeft")]) { $1 }
		expectNoDifference(
			try AutomationTools.operation(name: "browser_keypress", arguments: legacy),
			.form(.init(target: target, kind: .keyPress, value: "ArrowLeft"))
		)
		let tab = Self.target(target).merging(["key": .string("Tab")]) { $1 }
		expectNoDifference(
			try AutomationTools.operation(name: "browser_keypress", arguments: tab),
			.form(.init(target: target, kind: .keyChord, value: "Tab", keyModifiers: []))
		)
		let shortcut = Self.target(target).merging([
			"key": .string("k"),
			"modifiers": .array([.string("control"), .string("shift")]),
		]) { $1 }
		expectNoDifference(
			try AutomationTools.operation(name: "browser_keypress", arguments: shortcut),
			.form(.init(target: target, kind: .keyChord, value: "k", keyModifiers: [.control, .shift]))
		)
		for invalid: [String: Value] in [
			shortcut.merging(["key": .string("F13")]) { $1 },
			shortcut.merging(["key": .string("ab")]) { $1 },
			shortcut.merging(["modifiers": .array([.string("hyper")])]) { $1 },
			shortcut.merging(["modifiers": .array([.string("shift"), .string("shift")])]) { $1 },
		] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(name: "browser_keypress", arguments: invalid)
			}
		}
	}

	@Test
	internal func modifiersChangeTheBindingAndTypedTextIsNeverInTheReceipt() throws {
		let target = AutomationClickTests.request()
		let plain = AutomationFormRequest(target: target, kind: .keyChord, value: "k", keyModifiers: [])
		let control = AutomationFormRequest(target: target, kind: .keyChord, value: "k", keyModifiers: [.control])
		#expect(AutomationSecurity.mutationBinding(.form(plain)) != AutomationSecurity.mutationBinding(.form(control)))
		let receipt = AutomationFormResult(operationID: target.operationID, disposition: .dispatched)
		let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
		#expect(!encoded.contains("Typed secret"))
		expectNoDifference(AutomationTools.requiredCapabilities(forTool: "browser_type"), [.read, .pageContent, .interact])
		#expect(AutomationTools.returnSnapshotTools.contains("browser_type"))
		#expect(AutomationTools.batchStepTools.contains("browser_type"))
	}

	@Test
	internal func formStateToolsParseValuesAndCheckedState() throws {
		let target = AutomationClickTests.request()
		let checked = Self.target(target).merging(["checked": .bool(false)]) { $1 }
		expectNoDifference(
			try AutomationTools.operation(name: "browser_set_checked", arguments: checked),
			.form(.init(target: target, kind: .setChecked, value: "", checked: false))
		)
		let values = Self.target(target).merging(["values": .array([.string("a"), .string("")])]) { $1 }
		expectNoDifference(
			try AutomationTools.operation(name: "browser_select_value", arguments: values),
			.form(.init(target: target, kind: .selectValues, value: "", values: ["a", ""]))
		)
		for (name, invalid): (String, [String: Value]) in [
			("browser_set_checked", Self.target(target)),
			("browser_set_checked", checked.merging(["checked": .string("true")]) { $1 }),
			("browser_select_value", values.merging(["value": .string("a")]) { $1 }),
			("browser_select_value", values.merging(["values": .array([.string("a"), .string("a")])]) { $1 }),
			("browser_select_value", values.merging(["values": .array([.int(1)])]) { $1 }),
		] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(name: name, arguments: invalid)
			}
		}
		let first = AutomationFormRequest(target: target, kind: .selectValues, value: "", values: ["a"])
		let second = AutomationFormRequest(target: target, kind: .selectValues, value: "", values: ["b"])
		#expect(AutomationSecurity.mutationBinding(.form(first)) != AutomationSecurity.mutationBinding(.form(second)))
		expectNoDifference(
			AutomationTools.requiredCapabilities(forTool: "browser_set_checked"),
			[.read, .pageContent, .interact]
		)
	}

	@Test
	internal func uploadTakesAbsolutePathsAndNeedsTheFilesClass() throws {
		let target = AutomationClickTests.request()
		let arguments = Self.target(target).merging(["paths": .array([.string("/Users/a/report.pdf")])]) { $1 }
		let upload = AutomationFormRequest(target: target, kind: .upload, value: "", values: ["/Users/a/report.pdf"])
		expectNoDifference(try AutomationTools.operation(name: "browser_upload", arguments: arguments), .form(upload))
		expectNoDifference(
			try AutomationTools.operation(name: "browser_upload", arguments: arguments.merging(["paths": .array([])]) { $1 }),
			.form(.init(target: target, kind: .upload, value: "", values: []))
		)
		for paths in [["relative.txt"], ["/a/../etc/passwd"], ["/a", "/a"], (0..<33).map { "/f\($0)" }] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(
					name: "browser_upload",
					arguments: arguments.merging(["paths": .array(paths.map(Value.string))]) { $1 }
				)
			}
		}
		expectNoDifference(
			AutomationTools.requiredCapabilities(forTool: "browser_upload"),
			[.read, .pageContent, .interact, .files]
		)
		expectNoDifference(AutomationOperation.form(upload).requiredCapabilities, [.read, .pageContent, .interact, .files])
		#expect(AutomationOperation.form(upload).alwaysAsks)
		#expect(!AutomationTools.batchStepTools.contains("browser_upload"))
		var other = upload
		other.values = ["/Users/a/other.pdf"]
		#expect(AutomationSecurity.mutationBinding(.form(upload)) != AutomationSecurity.mutationBinding(.form(other)))
	}

	@Test
	internal func dialogReadsFreelyAndAnswersNeedAnOperationAndToken() throws {
		let target = AutomationClickTests.request()
		let base: [String: Value] = [
			"targetID": .string(target.targetID.uuidString),
			"expectedRevision": .string(target.expectedRevision),
		]
		expectNoDifference(
			try AutomationTools.operation(name: "browser_dialog", arguments: base.merging(["action": .string("read")]) { $1 }),
			.dialog(.init(action: .read, targetID: target.targetID, expectedRevision: target.expectedRevision))
		)
		let accept = base.merging([
			"action": .string("accept"),
			"operationID": .string(target.operationID.uuidString),
			"token": .string("1f"),
			"text": .string("Private answer"),
		]) { $1 }
		let request = AutomationDialogRequest(
			action: .accept,
			targetID: target.targetID,
			expectedRevision: target.expectedRevision,
			operationID: target.operationID,
			token: "1f",
			text: "Private answer"
		)
		expectNoDifference(try AutomationTools.operation(name: "browser_dialog", arguments: accept), .dialog(request))
		for invalid: [String: Value] in [
			accept.merging(["action": .string("dismiss")]) { $1 },
			base.merging(["action": .string("dismiss"), "token": .string("1f")]) { $1 },
			base.merging(["action": .string("read"), "operationID": .string(target.operationID.uuidString)]) { $1 },
			accept.merging(["action": .string("close")]) { $1 },
		] {
			#expect(throws: AutomationFailure.self) {
				try AutomationTools.operation(name: "browser_dialog", arguments: invalid)
			}
		}
		#expect(AutomationOperation.dialog(request).alwaysAsks)
		expectNoDifference(AutomationOperation.dialog(request).riskTier, .mutate)
		var dismiss = request
		dismiss.action = .dismiss
		dismiss.text = nil
		#expect(!AutomationOperation.dialog(dismiss).alwaysAsks)
		expectNoDifference(AutomationOperation.dialog(dismiss).riskTier, .read)
		#expect(!AutomationTools.batchStepTools.contains("browser_dialog"))
		#expect(throws: AutomationFailure.self) {
			try AutomationBatchPlan(batchID: UUID(), steps: [.dialog(dismiss)]).validate()
		}
		var other = request
		other.text = "Other answer"
		#expect(AutomationSecurity.mutationBinding(.dialog(request)) != AutomationSecurity.mutationBinding(.dialog(other)))
		let payload = try BrowserMCPServer.payload(.dialog(.init(
			targetID: target.targetID,
			operationID: target.operationID,
			answered: true
		)))
		#expect(!String(describing: payload).contains("Private answer"))
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
