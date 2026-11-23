import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	internal static var dialogDefinition: Tool {
		.init(
			name: "browser_dialog",
			title: "Read or answer a tab's dialog or permission request",
			description: """
			read returns the JavaScript dialog (alert, confirm, prompt or beforeUnload) a tab is showing, or else \\
			Arx's website permission request for it, with a token, its type, its message (untrusted page text), a \\
			prompt's defaultPrompt and a permission's origin; dialog is null when nothing is showing. A JavaScript \\
			dialog blocks the page, so inspect, read and capture wait until it is answered. accept and dismiss take \\
			that token and a unique operationID. accept confirms, sends text to a prompt, leaves on beforeUnload or \\
			grants the permission (this time only when the permission supports it); Arx asks the user every time, \\
			whatever this client's approval policy, showing any text. dismiss cancels, stays on beforeUnload or \\
			dismisses the permission without blocking it, and never asks. The user can also answer the dialog in \\
			Arx; whichever answer comes first wins and the other is staleTarget. Batches can't answer dialogs. \\
			Requires read, page-content and page-interaction grants. text is never echoed.
			""",
			inputSchema: schema(
				properties: [
					"action": .object([
						"type": .string("string"),
						"enum": .array(AutomationDialogRequest.Action.allCases.map { .string($0.rawValue) }),
					]),
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"operationID": string(maximum: 36),
					"token": string(maximum: 32),
					"text": string(maximum: 4_096, minimum: 0),
				],
				required: ["action", "targetID", "expectedRevision"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	internal static func dialogOperation(_ arguments: [String: Value]) throws -> AutomationOperation {
		guard
			Set(arguments.keys).isSubset(of: ["action", "targetID", "expectedRevision", "operationID", "token", "text"]),
			let action = try optionalString("action", in: arguments, maximum: 16)
				.flatMap(AutomationDialogRequest.Action.init(rawValue:)),
			let targetID = try optionalString("targetID", in: arguments, maximum: 36).flatMap(UUID.init(uuidString:)),
			let revision = try optionalString("expectedRevision", in: arguments, maximum: 64)
		else { throw AutomationFailure.invalidRequest }

		let operationID = try optionalString("operationID", in: arguments, maximum: 36)
		guard operationID.map({ UUID(uuidString: $0) != nil }) ?? true
		else { throw AutomationFailure.invalidRequest }
		let text: String?
		switch arguments["text"] {
		case .none: text = nil
		case let .string(value): text = value
		default: throw AutomationFailure.invalidRequest
		}
		let request = AutomationDialogRequest(
			action: action,
			targetID: targetID,
			expectedRevision: revision,
			operationID: operationID.flatMap(UUID.init(uuidString:)),
			token: try optionalString("token", in: arguments, maximum: 32),
			text: text
		)
		try request.validate()
		return .dialog(request)
	}
}
