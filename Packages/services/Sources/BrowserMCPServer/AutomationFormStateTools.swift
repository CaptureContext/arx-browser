import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	internal static var setCheckedDefinition: Tool {
		.init(
			name: "browser_set_checked",
			title: "Set an approved checkbox or radio",
			description: """
			Sets a checkbox or radio reference to checked true or false, firing input and change like a user toggle. \\
			A radio can only be checked; checking it unchecks the rest of its group natively. When the control already \\
			has that state the result is unchanged and no event fires; the operationID is still consumed. \\
			Disabled, inert and hidden controls are refused. Consumes the snapshot. \\
			Uses this connection's latest released browser_inspect snapshot, explicit tab/revision and a unique \\
			operationID. Requires read, page-content and page-interaction grants plus mutation approval. \\
			Handlers may change website state; dispatched is not website success. Never replay after an uncertain result.
			""",
			inputSchema: schema(
				properties: [
					"operationID": string(maximum: 36),
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"snapshotID": string(maximum: 128),
					"reference": string(maximum: 128),
					"checked": .object(["type": .string("boolean")]),
				],
				required: ["operationID", "targetID", "expectedRevision", "snapshotID", "reference", "checked"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	internal static var uploadDefinition: Tool {
		.init(
			name: "browser_upload",
			title: "Upload approved files to a page's file chooser",
			description: """
			Answers the file chooser a page opened right after one of this connection's pointer or keyboard actions \
			(for example browser_click with clickCount 1 on a file input), with absolute paths of files on this Mac, \
			or cancels it with an empty paths list. Arx shows every path to the user and asks each time, whatever \
			this client's approval policy; batches can't upload. Each path must be an existing, readable regular file, \
			not a folder or a symbolic link; at most 32, or one when the input doesn't take several. A chooser waits \
			about a minute and is cancelled on navigation. The reference names the file input in this connection's \
			latest released browser_inspect snapshot. Requires read, page-content, page-interaction and files grants. \
			Paths are never echoed. Dispatched means the page received the files; its handlers run afterwards.
			""",
			inputSchema: schema(
				properties: [
					"operationID": string(maximum: 36),
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"snapshotID": string(maximum: 128),
					"reference": string(maximum: 128),
					"paths": .object([
						"type": .string("array"),
						"items": string(maximum: 4_096),
						"maxItems": .int(32),
						"uniqueItems": .bool(true),
					]),
				],
				required: ["operationID", "targetID", "expectedRevision", "snapshotID", "reference", "paths"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	/// `browser_select_value` with `values` sets a multiple select's whole selection.
	internal static var selectValuesSchema: Value {
		.object([
			"type": .string("array"),
			"items": string(maximum: 4_096, minimum: 0),
			"maxItems": .int(64),
			"uniqueItems": .bool(true),
		])
	}

	internal static func formStateOperation(
		name: String,
		arguments: [String: Value]
	) throws -> AutomationOperation {
		let base: Set<String> = ["operationID", "targetID", "expectedRevision", "snapshotID", "reference"]
		guard let target = try formStateTarget(arguments)
		else { throw AutomationFailure.invalidRequest }

		let request: AutomationFormRequest
		switch name {
		case "browser_set_checked":
			guard
				Set(arguments.keys) == base.union(["checked"]),
				let checked = arguments["checked"]?.boolValue
			else { throw AutomationFailure.invalidRequest }

			request = .init(target: target, kind: .setChecked, value: "", checked: checked)

		case "browser_upload":
			guard
				Set(arguments.keys) == base.union(["paths"]),
				let items = arguments["paths"]?.arrayValue
			else { throw AutomationFailure.invalidRequest }

			let paths = try items.map { item in
				guard let path = item.stringValue else { throw AutomationFailure.invalidRequest }
				return path
			}
			request = .init(target: target, kind: .upload, value: "", values: paths)

		case "browser_select_value":
			guard
				Set(arguments.keys) == base.union(["values"]),
				let items = arguments["values"]?.arrayValue
			else { throw AutomationFailure.invalidRequest }

			let values = try items.map { item in
				guard let value = item.stringValue else { throw AutomationFailure.invalidRequest }
				return value
			}
			request = .init(target: target, kind: .selectValues, value: "", values: values)

		default:
			throw AutomationFailure.invalidRequest
		}
		try request.validate()
		return .form(request)
	}

	private static func formStateTarget(_ arguments: [String: Value]) throws -> AutomationClickRequest? {
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
}
