import BrowserCore
import Foundation

/// A track a tab's page plays outside Chromium, such as Spotify's through Arx's FairPlay helper
/// (DEV-1147). Chromium's media session hears nothing of it, so the engine's media sources take
/// it from here: the tab's speaker, the Media page and their controls see it as any other source,
/// in place of whatever Chromium reports for that tab.
public struct OutsideChromiumMedia: Equatable, Sendable {
	/// Changes with each track, so a control meant for the previous one is refused.
	public var track: UInt64
	public var title: String
	public var artist: String
	public var site: MediaSite?

	/// Playing or paused.
	public var playback: BrowserMediaSource.Playback

	/// What the page's own player takes: play, pause, and its next and previous track.
	public var actions: Set<BrowserMediaSource.Action>

	public init(
		track: UInt64,
		title: String,
		artist: String = "",
		site: MediaSite? = nil,
		playback: BrowserMediaSource.Playback,
		actions: Set<BrowserMediaSource.Action>
	) {
		self.track = track
		self.title = title
		self.artist = artist
		self.site = site
		self.playback = playback
		self.actions = actions
	}
}
