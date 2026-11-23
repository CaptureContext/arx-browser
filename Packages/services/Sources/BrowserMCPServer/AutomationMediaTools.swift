import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	internal static var mediaDefinition: Tool {
		.init(
			name: "browser_media",
			title: "List, control and read media playback, sound and ArxPiP",
			description: """
			list returns the media sessions in this client's permitted tabs (or one targetID), with a token, the \\
			title (untrusted page metadata), playback (inactive, playing or paused), hasVideo, isInPictureInPicture \\
			and the actions the session supports right now. play, pause, seek, enterPictureInPicture and \\
			exitPictureInPicture take a targetID, its current inventory revision, the session's token and a unique \\
			operationID; seek also takes seconds, an absolute time from the start (clamped to the duration). mute \\
			and unmute take a targetID, its revision and an operationID, no token: they act on the tab's sound. \\
			Controls follow this client's approval policy like other page interactions. An action the session \\
			doesn't support (paused media can't pause, audio can't enter Picture in Picture, live media can't seek) \\
			reports unsupported, and a token from an older list reports staleTarget. position reads one targetID \\
			once: isMuted, and with a session its token, position and duration in seconds (duration is absent when \\
			unknown or live) and playbackRate. Nothing streams; call position again to read it again. A muted tab's \\
			playing media leaves its media session (unless it's in ArxPiP), so it isn't listed until unmuted. \\
			ArxPiP shows at most one video. Private windows are never listed. Requires read and page-interaction \\
			grants. Batches can't control media.
			""",
			inputSchema: schema(
				properties: [
					"action": .object([
						"type": .string("string"),
						"enum": .array(AutomationMediaRequest.Action.allCases.map { .string($0.rawValue) }),
					]),
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"operationID": string(maximum: 36),
					"token": string(maximum: 41),
					"seconds": .object([
						"type": .string("number"),
						"minimum": .double(0),
						"maximum": .double(AutomationMediaRequest.maximumSeconds),
					]),
				],
				required: ["action"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: false,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	internal static func mediaOperation(_ arguments: [String: Value]) throws -> AutomationOperation {
		guard
			Set(arguments.keys).isSubset(of: ["action", "targetID", "expectedRevision", "operationID", "token", "seconds"]),
			let action = try optionalString("action", in: arguments, maximum: 32)
				.flatMap(AutomationMediaRequest.Action.init(rawValue:))
		else { throw AutomationFailure.invalidRequest }

		let targetID = try optionalString("targetID", in: arguments, maximum: 36)
		let operationID = try optionalString("operationID", in: arguments, maximum: 36)
		let seconds = arguments["seconds"].map(number)
		guard
			targetID.map({ UUID(uuidString: $0) != nil }) ?? true,
			operationID.map({ UUID(uuidString: $0) != nil }) ?? true,
			seconds.map({ $0 != nil }) ?? true
		else { throw AutomationFailure.invalidRequest }

		let request = AutomationMediaRequest(
			action: action,
			targetID: targetID.flatMap(UUID.init(uuidString:)),
			expectedRevision: try optionalString("expectedRevision", in: arguments, maximum: 64),
			operationID: operationID.flatMap(UUID.init(uuidString:)),
			token: try optionalString("token", in: arguments, maximum: 41),
			seconds: seconds.flatMap(\.self)
		)
		try request.validate()
		return .media(request)
	}

	internal static func mediaPayload(_ media: AutomationMediaResult) throws -> Value {
		var value: [String: Value] = [
			"kind": .string("media"),
			"action": .string(media.action.rawValue),
		]
		if media.action == .list {
			value["sessions"] = .array(media.sessions.map { session in
				.object([
					"targetID": .string(session.targetID.uuidString),
					"token": .string(session.token),
					"title": .string(session.title),
					"playback": .string(session.playback.rawValue),
					"hasVideo": .bool(session.hasVideo),
					"isInPictureInPicture": .bool(session.isInPictureInPicture),
					"actions": .array(session.actions.map { .string($0.rawValue) }),
				])
			})
		} else if let position = media.position {
			var read: [String: Value] = [
				"targetID": .string(position.targetID.uuidString),
				"isMuted": .bool(position.isMuted),
			]
			if let token = position.token { read["token"] = .string(token) }
			if let seconds = position.position { read["position"] = .double(seconds) }
			if let duration = position.duration { read["duration"] = .double(duration) }
			if let rate = position.playbackRate { read["playbackRate"] = .double(rate) }
			value["position"] = .object(read)
		} else {
			value["performed"] = .bool(media.performed)
			if let operationID = media.operationID { value["operationID"] = .string(operationID.uuidString) }
			if let failure = media.failure { value["failure"] = .string(failure.rawValue) }
		}
		return .object(value)
	}
}
