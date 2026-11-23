import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

internal struct AutomationMediaTests {
	private static let revision: String = .init(repeating: "a", count: 64)

	@Test
	internal func listNeedsNoTargetAndControlsNeedEveryBinding() throws {
		expectNoDifference(
			try AutomationTools.operation(name: "browser_media", arguments: ["action": .string("list")]),
			.media(.init(action: .list))
		)
		let control: [String: Value] = [
			"action": .string("enterPictureInPicture"),
			"targetID": .string(UUID(3).uuidString),
			"expectedRevision": .string(Self.revision),
			"operationID": .string(UUID(4).uuidString),
			"token": .string("7.2"),
		]
		let request = AutomationMediaRequest(
			action: .enterPictureInPicture,
			targetID: UUID(3),
			expectedRevision: Self.revision,
			operationID: UUID(4),
			token: "7.2"
		)
		expectNoDifference(try AutomationTools.operation(name: "browser_media", arguments: control), .media(request))
		#expect(AutomationOperation.media(request).riskTier == .mutate)
		#expect(AutomationOperation.media(.init(action: .list)).riskTier == .read)
		expectNoDifference(AutomationOperation.media(request).requiredCapabilities, [.read, .interact])
		expectNoDifference(AutomationOperation.media(request).mutationID, UUID(4))
		#expect(AutomationSecurity.mutationBinding(.media(request)) != nil)

		var invalid: [[String: Value]] = []
		for key in ["targetID", "expectedRevision", "operationID", "token"] {
			var missing = control
			missing[key] = nil
			invalid.append(missing)
		}
		for token in ["0.2", "7", "7.", ".2", "7.2.1", "-1.2", "a.b", "٧.٢", "99999999999999999999.1"] {
			invalid.append(control.merging(["token": .string(token)]) { $1 })
		}
		invalid += [
			control.merging(["action": .string("seek")]) { $1 },
			control.merging(["position": .double(10)]) { $1 },
			["action": .string("list"), "token": .string("7.2")],
			["action": .string("list"), "operationID": .string(UUID(4).uuidString)],
			["action": .string("list"), "expectedRevision": .string(Self.revision)],
		]
		for arguments in invalid {
			#expect(throws: AutomationFailure.invalidRequest, "\(arguments)") {
				try AutomationTools.operation(name: "browser_media", arguments: arguments)
			}
		}
		#expect(!AutomationTools.batchStepTools.contains("browser_media"))
	}

	@Test
	internal func seekMuteAndPositionTakeOnlyTheirOwnBindings() throws {
		let seek: [String: Value] = [
			"action": .string("seek"),
			"targetID": .string(UUID(3).uuidString),
			"expectedRevision": .string(Self.revision),
			"operationID": .string(UUID(4).uuidString),
			"token": .string("7.2"),
			"seconds": .int(12),
		]
		let seekRequest = AutomationMediaRequest(
			action: .seek,
			targetID: UUID(3),
			expectedRevision: Self.revision,
			operationID: UUID(4),
			token: "7.2",
			seconds: 12
		)
		expectNoDifference(try AutomationTools.operation(name: "browser_media", arguments: seek), .media(seekRequest))
		#expect(AutomationOperation.media(seekRequest).riskTier == .mutate)

		// The time is part of what the user approves.
		var later = seekRequest
		later.seconds = 13
		#expect(AutomationSecurity.mutationBinding(.media(seekRequest)) != AutomationSecurity.mutationBinding(.media(later)))

		let mute: [String: Value] = [
			"action": .string("mute"),
			"targetID": .string(UUID(3).uuidString),
			"expectedRevision": .string(Self.revision),
			"operationID": .string(UUID(4).uuidString),
		]
		let muteRequest = AutomationMediaRequest(
			action: .mute,
			targetID: UUID(3),
			expectedRevision: Self.revision,
			operationID: UUID(4)
		)
		expectNoDifference(try AutomationTools.operation(name: "browser_media", arguments: mute), .media(muteRequest))
		#expect(AutomationOperation.media(muteRequest).riskTier == .mutate)
		expectNoDifference(AutomationOperation.media(muteRequest).mutationID, UUID(4))

		let position = AutomationMediaRequest(action: .position, targetID: UUID(3))
		expectNoDifference(
			try AutomationTools.operation(
				name: "browser_media",
				arguments: ["action": .string("position"), "targetID": .string(UUID(3).uuidString)]
			),
			.media(position)
		)
		#expect(AutomationOperation.media(position).riskTier == .read)
		#expect(AutomationSecurity.mutationBinding(.media(position)) == nil)

		var invalid: [[String: Value]] = [
			seek.merging(["seconds": .double(-1)]) { $1 },
			seek.merging(["seconds": .double(AutomationMediaRequest.maximumSeconds + 1)]) { $1 },
			seek.merging(["seconds": .string("12")]) { $1 },
			seek.filter { $0.key != "seconds" },
			seek.filter { $0.key != "token" },
			mute.merging(["token": .string("7.2")]) { $1 },
			mute.merging(["seconds": .int(1)]) { $1 },
			mute.filter { $0.key != "operationID" },
			mute.merging(["action": .string("unmute")]) { $1 }.filter { $0.key != "expectedRevision" },
			["action": .string("position")],
			["action": .string("position"), "targetID": .string(UUID(3).uuidString), "operationID": .string(UUID(4).uuidString)],
			["action": .string("position"), "targetID": .string(UUID(3).uuidString), "token": .string("7.2")],
			["action": .string("pause")].merging(seek.filter { $0.key != "action" }) { $1 },
		]
		invalid.append(["action": .string("list"), "seconds": .int(1)])
		for arguments in invalid {
			#expect(throws: AutomationFailure.invalidRequest, "\(arguments)") {
				try AutomationTools.operation(name: "browser_media", arguments: arguments)
			}
		}
	}

	@Test
	internal func positionPayloadsReportOnlyWhatWasRead() throws {
		let read = AutomationMediaResult(action: .position, position: .init(
			targetID: UUID(3),
			token: "7.2",
			isMuted: false,
			position: 1.5,
			duration: 2,
			playbackRate: 1
		))
		try read.validate()
		let response = try BrowserMCPServer.toolResult(.media(read))
		expectNoDifference(response.isError, false)
		let text = String(decoding: try JSONEncoder().encode(response.structuredContent), as: UTF8.self)
		#expect(text.contains("\"position\":1.5"))
		#expect(text.contains("\"isMuted\":false"))
		#expect(!text.contains("performed"))

		let muted = AutomationMediaResult(action: .position, position: .init(targetID: UUID(3), token: nil, isMuted: true))
		try muted.validate()
		let mutedText = String(
			decoding: try JSONEncoder().encode(try BrowserMCPServer.toolResult(.media(muted)).structuredContent),
			as: UTF8.self
		)
		#expect(mutedText.contains("\"isMuted\":true"))
		#expect(!mutedText.contains("duration"))

		// Without a session there is no time, and a read never carries an operation.
		var sessionless = muted
		sessionless.position?.position = 1
		#expect(throws: AutomationFailure.invalidRequest) { try sessionless.validate() }
		var negative = read
		negative.position?.position = -1
		#expect(throws: AutomationFailure.invalidRequest) { try negative.validate() }
		var withOperation = read
		withOperation.operationID = UUID(4)
		#expect(throws: AutomationFailure.invalidRequest) { try withOperation.validate() }
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationMediaResult(action: .position).validate()
		}
	}

	@Test
	internal func sessionsReportOnlyTheActionsTheSourceSupports() {
		let source = BrowserMediaSource(
			id: .init(tabID: .init(rawValue: UUID(3)), profileID: .init(rawValue: UUID(0)), generation: 7),
			revision: 2,
			title: "Clip",
			site: nil,
			hasVideo: false,
			playback: .paused,
			actions: [.play, .pause, .enterPictureInPicture]
		)

		// Audio can't enter Picture in Picture, and paused media can't pause.
		expectNoDifference(AutomationMediaSession(source).actions, [.play])

		var seekable = source
		seekable.actions.insert(.seek)
		expectNoDifference(AutomationMediaSession(seekable).actions, [.play, .seek])
		var inactive = seekable
		inactive.playback = .inactive
		expectNoDifference(AutomationMediaSession(inactive).actions, [])
		expectNoDifference(AutomationMediaSession(source).token, "7.2")
		expectNoDifference(AutomationMediaSession.Token(rawValue: "7.2"), .init(generation: 7, revision: 2))
	}

	@Test
	internal func payloadsCarrySessionsOrTheControlOutcome() throws {
		let list = AutomationMediaResult(action: .list, sessions: [
			.init(
				targetID: UUID(3),
				token: "7.2",
				title: "Clip",
				playback: .playing,
				hasVideo: true,
				isInPictureInPicture: false,
				actions: [.pause, .enterPictureInPicture]
			),
		])
		let listed = try BrowserMCPServer.toolResult(.media(list))
		expectNoDifference(listed.isError, false)
		let text = String(decoding: try JSONEncoder().encode(listed.structuredContent), as: UTF8.self)
		#expect(text.contains("\"enterPictureInPicture\""))
		#expect(text.contains("\"7.2\""))

		let refused = AutomationMediaResult(action: .play, operationID: UUID(4), failure: .unsupported)
		let response = try BrowserMCPServer.toolResult(.media(refused))
		let refusal = String(decoding: try JSONEncoder().encode(response.structuredContent), as: UTF8.self)
		#expect(refusal.contains("\"unsupported\""))
		#expect(refusal.contains("\"performed\":false"))

		// A control never reports sessions, and a list never carries an operation.
		var invalid = refused
		invalid.sessions = list.sessions
		#expect(throws: AutomationFailure.invalidRequest) { try invalid.validate() }
		var listWithOperation = list
		listWithOperation.operationID = UUID(4)
		#expect(throws: AutomationFailure.invalidRequest) { try listWithOperation.validate() }
	}
}
