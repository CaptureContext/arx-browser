import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	internal static var signInDefinition: Tool {
		.init(
			name: "browser_sign_in",
			title: "Request a trusted user sign-in handoff",
			description: """
			Requires the separate sign-in grant and an explicit loaded ordinary tab, inventory revision and exact top-level origin. \
			Begin shows non-sensitive consent in Arx; only the user can approve pausing every assistant before entering secrets. \
			Status/cancel use only the same opaque operationID and connection. Operations expire after five minutes. \
			Begin and status follow the handoff inside the call while the user approves and signs in, with progress \
			notifications, until it ends or the call's wait limit passes; call status again to keep following it. \
			During protected sign-in all other tools and clients are denied, including inventory, page reads, images and actions. \
			Navigation cancels the exact operation but privacy remains locked. Only the user can resume, requiring fresh grants. \
			userConfirmed is a user assertion, never verified authentication. No passwords, OTPs, cookies, account names, \
			tokens, credential handles or provider access are accepted or returned. An uncertain earlier action on the same \
			page document blocks sensitive readiness until that page navigates, closes or Arx restarts; actions in other tabs \
			do not. Cancellation cannot undo dispatched website effects. \
			Unattended runs cannot sign in because nobody can approve.
			""",
			inputSchema: schema(
				properties: [
					"operationID": string(maximum: 36),
					"action": .object([
						"type": .string("string"),
						"enum": .array(AutomationSignInRequest.Action.allValues.map(Value.string)),
					]),
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"origin": string(maximum: 512),
				],
				required: ["operationID", "action"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: false,
				idempotentHint: false,
				openWorldHint: false
			)
		)
	}

	/// Unknown keys are rejected, so no credential-shaped argument can reach Arx.
	internal static func signInRequest(_ arguments: [String: Value]) throws -> AutomationSignInRequest {
		guard
			Set(arguments.keys).isSubset(of: ["operationID", "action", "targetID", "expectedRevision", "origin"]),
			arguments.values.allSatisfy({ $0.stringValue != nil }),
			let id = arguments["operationID"]?.stringValue.flatMap(UUID.init(uuidString:)),
			let action = arguments["action"]?.stringValue.flatMap(AutomationSignInRequest.Action.init(rawValue:))
		else { throw AutomationFailure.invalidRequest }

		let target = arguments["targetID"]?.stringValue.flatMap(UUID.init(uuidString:))
		guard arguments["targetID"] == nil || target != nil
		else { throw AutomationFailure.invalidRequest }

		let request: AutomationSignInRequest = .init(
			operationID: id,
			action: action,
			targetID: target,
			expectedRevision: arguments["expectedRevision"]?.stringValue,
			origin: arguments["origin"]?.stringValue
		)
		try request.validate()
		return request
	}
}

extension AutomationSignInRequest.Action {
	fileprivate static var allValues: [String] { [begin, status, cancel].map(\.rawValue) }
}

extension AutomationTools {
	internal static var passwordSignInDefinition: Tool {
		.init(
			name: "browser_password_sign_in",
			title: "Sign in with a password saved in Arx",
			description: """
			Requires the sign-in grant and an explicit loaded ordinary tab, its inventory revision and the exact top-level \
			origin. Arx fills a password saved in the tab's own profile for exactly that origin into the page's sign-in form, \
			submits it and reports only the outcome: signedIn, needsUser or failed, with a fixed reason. The password, the \
			account name and any code never reach you, and none are accepted. Pass frameID (a snapshot node's frame) when the \
			form is in a same-site frame. Unless the user let agents sign in to this site without asking, Arx asks the user \
			first, and the user may pick the account. needsUser means only the user can go on (a one-time code, a passkey, \
			a macOS reauthentication, an approval or a choice of account): hand off with browser_sign_in. After a fill that \
			didn't sign in, the tab's page can't be captured or read until it navigates. Private tabs have no saved passwords.
			""",
			inputSchema: schema(
				properties: [
					"operationID": string(maximum: 36),
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"origin": string(maximum: 512),
					"frameID": string(maximum: 64),
				],
				required: ["operationID", "targetID", "expectedRevision", "origin"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: false,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	/// Unknown keys are rejected, so no credential-shaped argument can reach Arx.
	internal static func passwordSignInRequest(_ arguments: [String: Value]) throws -> AutomationPasswordSignInRequest {
		guard
			Set(arguments.keys).isSubset(of: ["operationID", "targetID", "expectedRevision", "origin", "frameID"]),
			arguments.values.allSatisfy({ $0.stringValue != nil }),
			let id = arguments["operationID"]?.stringValue.flatMap(UUID.init(uuidString:)),
			let target = arguments["targetID"]?.stringValue.flatMap(UUID.init(uuidString:)),
			let revision = arguments["expectedRevision"]?.stringValue,
			let origin = arguments["origin"]?.stringValue
		else { throw AutomationFailure.invalidRequest }

		let request: AutomationPasswordSignInRequest = .init(
			operationID: id,
			targetID: target,
			expectedRevision: revision,
			origin: origin,
			frameID: arguments["frameID"]?.stringValue
		)
		try request.validate()
		return request
	}

	internal static func passwordSignInPayload(_ result: AutomationPasswordSignInResult) -> Value {
		.object([
			"operationID": .string(result.operationID.uuidString),
			"outcome": .string(result.outcome.rawValue),
			"reason": .string(result.reason.rawValue),
		])
	}
}
