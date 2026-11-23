import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	internal static var typeDefinition: Tool {
		.init(
			name: "browser_type",
			title: "Type text into an approved field",
			description: """
			Focuses an input, textarea or contenteditable reference, puts the caret at the end and types text one \\
			character at a time as real key events (keydown, keypress, beforeinput, input, keyup). text is 1 to 1024 \\
			UTF-8 bytes of printable characters; a line feed presses Enter and is refused for single-line inputs. \\
			Editing stops as soon as focus or the selection leaves the reference or reaches a password field, even \\
			when page listeners redirect focus; the receipt is then possiblyDispatched and the rest isn't typed. \\
			Password fields are refused, and nothing is typed while Arx's sign-in privacy lock is on. \\
			To replace a whole value use browser_replace_text. Consumes the snapshot. \\
			Uses this connection's latest released browser_inspect snapshot, explicit tab/revision and a unique \\
			operationID. Requires read, page-content and page-interaction grants plus mutation approval. \\
			Typed text is never echoed. Never replay after an uncertain result.
			""",
			inputSchema: schema(
				properties: [
					"operationID": string(maximum: 36),
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"snapshotID": string(maximum: 128),
					"reference": string(maximum: 128),
					"text": string(maximum: 1_024),
				],
				required: ["operationID", "targetID", "expectedRevision", "snapshotID", "reference", "text"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	internal static var keyModifiersSchema: Value {
		.object([
			"type": .string("array"),
			"items": .object([
				"type": .string("string"),
				"enum": .array(AutomationFormRequest.KeyModifier.allCases.map { .string($0.rawValue) }),
			]),
			"maxItems": .int(4),
			"uniqueItems": .bool(true),
		])
	}

	internal static func typeOperation(_ arguments: [String: Value]) throws -> AutomationOperation {
		guard
			Set(arguments.keys) == ["operationID", "targetID", "expectedRevision", "snapshotID", "reference", "text"],
			let target = try referenceTarget(arguments),
			let text = arguments["text"]?.stringValue
		else { throw AutomationFailure.invalidRequest }

		let request = AutomationFormRequest(target: target, kind: .typeText, value: text)
		try request.validate()
		return .form(request)
	}

	/// Legacy keys without modifiers keep the guarded keypress on an already
	/// focused field; anything else is a chord that focuses the reference first.
	internal static func keypressOperation(_ arguments: [String: Value]) throws -> AutomationOperation {
		guard
			Set(arguments.keys).isSubset(of: [
				"operationID", "targetID", "expectedRevision", "snapshotID", "reference", "key", "modifiers",
			]),
			let target = try referenceTarget(arguments),
			let key = try optionalString("key", in: arguments, maximum: 32)
		else { throw AutomationFailure.invalidRequest }

		let modifiers = try keyModifiers(arguments["modifiers"])
		let isLegacy = modifiers == nil && AutomationFormRequest.isSupportedKeypress(key)
		let request = AutomationFormRequest(
			target: target,
			kind: isLegacy ? .keyPress : .keyChord,
			value: key,
			keyModifiers: isLegacy ? nil : modifiers ?? []
		)
		try request.validate()
		return .form(request)
	}

	private static func referenceTarget(_ arguments: [String: Value]) throws -> AutomationClickRequest? {
		guard
			let operationID = try optionalString("operationID", in: arguments, maximum: 36).flatMap(UUID.init(uuidString:)),
			let targetID = try optionalString("targetID", in: arguments, maximum: 36).flatMap(UUID.init(uuidString:)),
			let revision = try optionalString("expectedRevision", in: arguments, maximum: 64),
			let snapshotID = try optionalString("snapshotID", in: arguments, maximum: 128),
			let reference = try optionalString("reference", in: arguments, maximum: 128)
		else { return nil }

		return .init(
			operationID: operationID,
			targetID: targetID,
			expectedRevision: revision,
			snapshotID: snapshotID,
			reference: reference
		)
	}

	private static func keyModifiers(_ value: Value?) throws -> [AutomationFormRequest.KeyModifier]? {
		guard let value else { return nil }
		guard let items = value.arrayValue, items.count <= 4
		else { throw AutomationFailure.invalidRequest }
		return try items.map { item in
			guard let modifier = item.stringValue.flatMap(AutomationFormRequest.KeyModifier.init(rawValue:))
			else { throw AutomationFailure.invalidRequest }
			return modifier
		}
	}
}
