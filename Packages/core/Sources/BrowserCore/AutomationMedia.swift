import Foundation

/// Lists the media sessions in a client's permitted tabs, plays, pauses, seeks
/// or moves one into or out of ArxPiP, mutes or unmutes a tab, or reads a tab's
/// playback position once.
public struct AutomationMediaRequest: Codable, Equatable, Sendable {
	public enum Action: String, Codable, CaseIterable, Sendable {
		case list
		case play
		case pause
		case enterPictureInPicture
		case exitPictureInPicture
		case seek

		/// Tab-level: they need no session token.
		case mute
		case unmute

		/// Reads one tab's position and mute on request.
		case position

		/// The session action a control maps to; reads and tab-level mute have none.
		public var mediaAction: BrowserMediaSource.Action? {
			switch self {
			case .list, .position, .mute, .unmute: nil
			case .play: .play
			case .pause: .pause
			case .enterPictureInPicture: .enterPictureInPicture
			case .exitPictureInPicture: .exitPictureInPicture
			case .seek: .seek
			}
		}
	}

	/// The furthest a seek may ask for: a day.
	public static let maximumSeconds: Double = 86_400

	public var action: Action

	/// For `list`: limits the result to one tab. Required for a control.
	public var targetID: UUID?

	/// The tab's inventory revision; required for a control.
	public var expectedRevision: String?

	/// Required for a control, so a retried call can't act twice.
	public var operationID: UUID?

	/// The token `list` returned for the session; binds a control to that exact
	/// media generation and revision.
	public var token: String?

	/// For `seek`: the absolute time, in seconds from the start.
	public var seconds: Double?

	public init(
		action: Action,
		targetID: UUID? = nil,
		expectedRevision: String? = nil,
		operationID: UUID? = nil,
		token: String? = nil,
		seconds: Double? = nil
	) {
		self.action = action
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.operationID = operationID
		self.token = token
		self.seconds = seconds
	}

	/// Controls change playback or sound; `list` and `position` only read.
	public var isControl: Bool { action != .list && action != .position }

	/// Session controls name a session token; mute and unmute act on the tab.
	public var needsToken: Bool { action.mediaAction != nil }

	public func validate() throws {
		let isRevisionValid = expectedRevision.map {
			$0.utf8.count == 64 && $0.allSatisfy(\.isHexDigit)
		} ?? true
		let isSecondsValid = seconds.map { $0.isFinite && $0 >= 0 && $0 <= Self.maximumSeconds } ?? true
		guard
			isRevisionValid,
			isSecondsValid,
			isControl == (operationID != nil),
			needsToken == (token.flatMap(AutomationMediaSession.Token.init(rawValue:)) != nil),
			needsToken || token == nil,
			(action == .seek) == (seconds != nil),
			action == .list || targetID != nil,
			!isControl || expectedRevision != nil,
			targetID != nil || expectedRevision == nil
		else { throw AutomationFailure.invalidRequest }
	}
}

/// One tab's media session as an agent sees it. Playback position isn't part
/// of it: `position` reads it on request, and nothing streams per frame.
public struct AutomationMediaSession: Codable, Equatable, Sendable {
	/// `generation.revision` of the native source, opaque to the agent.
	public struct Token: Hashable, Sendable {
		public var generation: UInt64
		public var revision: UInt64

		public init(
			generation: UInt64,
			revision: UInt64
		) {
			self.generation = generation
			self.revision = revision
		}

		public init?(rawValue: String) {
			guard rawValue.utf8.count <= 41 else { return nil }
			let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
			guard
				parts.count == 2,
				parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
				let generation = UInt64(parts[0]),
				let revision = UInt64(parts[1]),
				generation > 0,
				revision > 0
			else { return nil }
			self.init(generation: generation, revision: revision)
		}

		public var rawValue: String { "\(generation).\(revision)" }
	}

	public enum Playback: String, Codable, Sendable {
		case inactive
		case playing
		case paused
	}

	public var targetID: UUID
	public var token: String

	/// Untrusted page metadata.
	public var title: String
	public var playback: Playback
	public var hasVideo: Bool
	public var isInPictureInPicture: Bool

	/// The controls the session supports right now, by the same rules ArxPiP uses.
	public var actions: [AutomationMediaRequest.Action]

	public init(
		targetID: UUID,
		token: String,
		title: String,
		playback: Playback,
		hasVideo: Bool,
		isInPictureInPicture: Bool,
		actions: [AutomationMediaRequest.Action]
	) {
		self.targetID = targetID
		self.token = token
		self.title = title
		self.playback = playback
		self.hasVideo = hasVideo
		self.isInPictureInPicture = isInPictureInPicture
		self.actions = actions
	}

	public init(_ source: BrowserMediaSource) {
		let playback: Playback = switch source.playback {
		case .inactive: .inactive
		case .playing: .playing
		case .paused: .paused
		}
		self.init(
			targetID: source.id.tabID.rawValue,
			token: Token(generation: source.id.generation, revision: source.revision).rawValue,
			title: source.title,
			playback: playback,
			hasVideo: source.hasVideo,
			isInPictureInPicture: source.isInPictureInPicture,
			actions: AutomationMediaRequest.Action.allCases.filter { action in
				action.mediaAction.map(source.supports) ?? false
			}
		)
	}
}

/// One read of a tab's playback position and audio mute, at the time of the call.
public struct AutomationMediaPosition: Codable, Equatable, Sendable {
	public var targetID: UUID

	/// The tab's current session token, or nil when it has no media session
	/// (a muted tab's playing media leaves its session outside ArxPiP).
	public var token: String?
	public var isMuted: Bool

	/// Seconds from the start; nil without a session or when the page reports none.
	public var position: Double?

	/// Seconds; nil when unknown or live.
	public var duration: Double?
	public var playbackRate: Double?

	public init(
		targetID: UUID,
		token: String?,
		isMuted: Bool,
		position: Double? = nil,
		duration: Double? = nil,
		playbackRate: Double? = nil
	) {
		self.targetID = targetID
		self.token = token
		self.isMuted = isMuted
		self.position = position
		self.duration = duration
		self.playbackRate = playbackRate
	}

	public var isValid: Bool {
		let times = [position, duration].compactMap(\.self)
		return times.allSatisfy { $0.isFinite && $0 >= 0 }
		&& (playbackRate?.isFinite ?? true)
		&& (token == nil ? position == nil && duration == nil && playbackRate == nil : true)
		&& (token.flatMap(AutomationMediaSession.Token.init(rawValue:)) != nil || token == nil)
	}
}

public struct AutomationMediaResult: Codable, Equatable, Sendable {
	public static let maximumSessions: Int = 64

	public var action: AutomationMediaRequest.Action

	/// For `list`: the sessions in permitted tabs, in native order.
	public var sessions: [AutomationMediaSession]

	/// For `position`: the tab's position and mute.
	public var position: AutomationMediaPosition?

	/// For a control: its operation, whether the engine performed it, and why not.
	public var operationID: UUID?
	public var performed: Bool
	public var failure: AutomationFailure?

	public init(
		action: AutomationMediaRequest.Action,
		sessions: [AutomationMediaSession] = [],
		position: AutomationMediaPosition? = nil,
		operationID: UUID? = nil,
		performed: Bool = false,
		failure: AutomationFailure? = nil
	) {
		self.action = action
		self.sessions = sessions
		self.position = position
		self.operationID = operationID
		self.performed = performed
		self.failure = failure
	}

	public func validate() throws {
		let isRead = action == .list || action == .position
		guard
			sessions.count <= Self.maximumSessions,
			isRead == (operationID == nil),
			action == .list || sessions.isEmpty,
			(action == .position) == (position != nil),
			position?.isValid ?? true,
			!isRead || (!performed && failure == nil),
			!performed || failure == nil
		else { throw AutomationFailure.invalidRequest }
	}
}
