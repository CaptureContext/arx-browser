import Foundation

/// A media session belongs to its existing tab. Generation changes invalidate queued controls.
public struct BrowserMediaSource: Equatable, Identifiable, Sendable {
	public struct ID: Hashable, Sendable {
		public var tabID: Tab.ID
		public var profileID: Profile.ID
		public var generation: UInt64

		public init(
			tabID: Tab.ID,
			profileID: Profile.ID,
			generation: UInt64
		) {
			self.tabID = tabID
			self.profileID = profileID
			self.generation = generation
		}
	}

	public enum Playback: Equatable, Sendable { case inactive, playing, paused }

	public enum Action: Hashable, Sendable {
		case play, pause, enterPictureInPicture, exitPictureInPicture, enterAutomaticPictureInPicture

		/// Seeking to an absolute time; a request carries the time.
		case seek

		/// The page's own next and previous track (DEV-906).
		case nextTrack, previousTrack

		/// A call's microphone, camera and hang up, through the site's Media Session handlers
		/// (DEV-948).
		case toggleMicrophone, toggleCamera, hangUp
	}

	/// A call in progress (DEV-948): the page uses the camera or microphone and offers call
	/// controls or automatic Picture in Picture. Its microphone and camera are as the site
	/// reports them; nil when it doesn't.
	public struct Call: Equatable, Sendable {
		public var isMicrophoneOn: Bool?
		public var isCameraOn: Bool?

		public init(
			isMicrophoneOn: Bool? = nil,
			isCameraOn: Bool? = nil
		) {
			self.isMicrophoneOn = isMicrophoneOn
			self.isCameraOn = isCameraOn
		}
	}

	public var id: ID
	public var revision: UInt64
	public var title: String

	/// The page's Media Session artist; empty when it names none.
	public var artist: String

	/// The page's Media Session artwork as PNG bytes, at most 256 px a side.
	public var artwork: Data?
	public var site: MediaSite?
	public var isPrivate: Bool
	public var hasVideo: Bool
	public var playback: Playback
	public var actions: Set<Action>
	public var isInPictureInPicture: Bool

	/// Nil unless the page is in a call. A call's Picture in Picture may be the site's own window
	/// (Google Meet's), without a video.
	public var call: Call?

	public init(
		id: ID,
		revision: UInt64,
		title: String,
		artist: String = "",
		artwork: Data? = nil,
		site: MediaSite?,
		isPrivate: Bool = false,
		hasVideo: Bool = false,
		playback: Playback = .inactive,
		actions: Set<Action> = [],
		isInPictureInPicture: Bool = false,
		call: Call? = nil
	) {
		self.id = id
		self.revision = revision
		self.title = String(title.unicodeScalars.prefix(512))
		self.artist = String(artist.unicodeScalars.prefix(512))
		self.artwork = artwork
		self.site = site
		self.isPrivate = isPrivate
		self.hasVideo = hasVideo
		self.playback = playback
		self.actions = actions
		self.isInPictureInPicture = isInPictureInPicture
		self.call = call
	}

	public var isCall: Bool { call != nil }

	public func supports(_ action: Action) -> Bool {
		guard actions.contains(action) else { return false }
		switch action {
		case .enterPictureInPicture: return hasVideo && !isInPictureInPicture
		case .enterAutomaticPictureInPicture:
			return (isCall || hasVideo && playback == .playing) && !isInPictureInPicture
		case .exitPictureInPicture: return isInPictureInPicture
		case .play: return playback == .paused
		case .pause: return playback == .playing
		case .seek: return playback != .inactive
		case .nextTrack, .previousTrack: return true
		case .toggleMicrophone, .toggleCamera, .hangUp: return isCall
		}
	}
}

/// Ordered, authoritative native state. At most one source owns a video PiP window.
public struct BrowserMediaSnapshot: Equatable, Sendable {
	public var revision: UInt64
	public var sources: [BrowserMediaSource]

	public init(
		revision: UInt64 = 0,
		sources: [BrowserMediaSource] = []
	) {
		self.revision = revision
		self.sources = sources
	}

	public var isValid: Bool {
		Set(sources.map(\.id)).count == sources.count
		&& Set(sources.map(\.id.tabID)).count == sources.count
		&& sources.filter(\.isInPictureInPicture).count <= 1
		&& sources.allSatisfy { source in
			source.id.generation > 0
			&& source.revision > 0
			&& (!source.isInPictureInPicture || source.hasVideo || source.isCall)
		}
	}
}

/// All effects must revalidate this identity and revision at the final native call boundary.
public struct BrowserMediaRequest: Equatable, Sendable {
	public var sourceID: BrowserMediaSource.ID
	public var expectedRevision: UInt64
	public var action: BrowserMediaSource.Action

	/// Seconds from the start; only a seek has one.
	public var position: Double?

	public init(
		source: BrowserMediaSource,
		action: BrowserMediaSource.Action
	) {
		self.sourceID = source.id
		self.expectedRevision = source.revision
		self.action = action
		self.position = nil
	}

	public init(
		source: BrowserMediaSource,
		seekingTo position: Double
	) {
		self.sourceID = source.id
		self.expectedRevision = source.revision
		self.action = .seek
		self.position = position
	}

	public func isValid(for source: BrowserMediaSource) -> Bool {
		let hasValidPosition = position.map { $0.isFinite && $0 >= 0 } ?? false
		return source.id == sourceID
		&& source.revision == expectedRevision
		&& source.supports(action)
		&& (action == .seek) == hasValidPosition
	}
}

/// One on-demand read of a tab's media position and audio mute. Nothing
/// streams or enters feature state per frame.
public struct BrowserMediaPosition: Equatable, Sendable {
	/// The tab's current media source, or nil when it has none (a muted tab's
	/// playing media leaves its media session outside PiP).
	public var sourceID: BrowserMediaSource.ID?
	public var isMuted: Bool

	/// Seconds, at the time of the read.
	public var position: Double?

	/// Seconds; nil when unknown or unbounded (live).
	public var duration: Double?
	public var playbackRate: Double?

	public init(
		sourceID: BrowserMediaSource.ID?,
		isMuted: Bool,
		position: Double? = nil,
		duration: Double? = nil,
		playbackRate: Double? = nil
	) {
		self.sourceID = sourceID
		self.isMuted = isMuted
		self.position = position
		self.duration = duration
		self.playbackRate = playbackRate
	}
}
