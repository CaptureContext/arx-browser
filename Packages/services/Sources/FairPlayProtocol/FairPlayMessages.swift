import Foundation

/// Where a FairPlay track failed (DEV-1144): its key exchange, its playback, or the helper that
/// plays it.
public enum FairPlayStep: String, Codable, Equatable, Sendable {
	case license
	case playback
	case player
}

/// What a page's media session says about the playing track, for Now Playing.
public struct FairPlayMetadata: Codable, Equatable, Sendable {
	public var title: String
	public var artist: String
	public var album: String

	/// An https image, or nil.
	public var artwork: URL?

	public init(
		title: String = "",
		artist: String = "",
		album: String = "",
		artwork: URL? = nil
	) {
		self.title = title
		self.artist = artist
		self.album = album
		self.artwork = artwork
	}

	/// What Now Playing shows for a private window's track: the app's name, as Chromium shows
	/// its product name for an incognito page's media, and nothing of the track.
	public static let privateTrack: Self = .init(title: "Arx")

	/// The same metadata with each text cut to `FairPlayLimits.maximumTextLength` and a non-https
	/// artwork dropped.
	public var bounded: Self {
		.init(
			title: String(title.prefix(FairPlayLimits.maximumTextLength)),
			artist: String(artist.prefix(FairPlayLimits.maximumTextLength)),
			album: String(album.prefix(FairPlayLimits.maximumTextLength)),
			artwork: artwork?.scheme?.lowercased() == "https" ? artwork : nil
		)
	}
}

/// A media key or Now Playing control the helper heard; the page's own handlers act on it.
public enum FairPlayRemoteCommand: String, Codable, Equatable, Sendable {
	case play
	case pause
	case toggle
	case nextTrack = "nexttrack"
	case previousTrack = "previoustrack"
	case seek = "seekto"
}

/// What the app tells the FairPlay helper. `generation` is the app's number for one track; the
/// helper's events name it, so the app drops events about a track it replaced.
public enum FairPlayHelperCommand: Equatable, Sendable {
	case load(generation: Int, certificate: Data, playlist: String, volume: Double, isMuted: Bool)
	case license(generation: Int, ckc: Data)
	case play
	case pause
	case seek(time: Double, sequence: Int)
	case volume(Double)
	case muted(Bool)
	case metadata(FairPlayMetadata)
	case stop
}

/// What the FairPlay helper tells the app.
public enum FairPlayHelperEvent: Equatable, Sendable {
	/// The key request (SPC) for the page to send to its licence server.
	case request(generation: Int, spc: Data)
	case ready(generation: Int, duration: Double)
	case position(generation: Int, time: Double, isPlaying: Bool, sequence: Int)
	case ended(generation: Int)
	case failed(generation: Int, step: FairPlayStep)
	case remote(FairPlayRemoteCommand, time: Double?)
}

/// What the bridge's page script tells the app. `generation` is the page's number for the
/// element and playlist it bridges.
public enum FairPlayPageMessage: Equatable, Sendable {
	/// One part of a playlist: the page splits a long one. The first part carries the
	/// certificate the page gave its media keys.
	case load(generation: Int, part: Int, parts: Int, playlist: String, certificate: Data?, volume: Double, isMuted: Bool)
	case license(generation: Int, ckc: Data)
	case play
	case pause
	case seek(time: Double, sequence: Int)
	case volume(Double)
	case muted(Bool)
	case metadata(FairPlayMetadata)
	case stop

	/// The page gave up on its track, such as one that never became ready; the app falls back.
	case failed

	/// A step the page's player took or missed, for the diagnostics log only.
	case trace(FairPlayTrace)
}

/// The steps of a page's FairPlay playback the bridge script reports, so the log shows which one
/// a track stopped at (`FairPlayLog`). Only these names cross: never a URL, a title or a key.
public enum FairPlayTrace: String, CaseIterable, Codable, Equatable, Sendable {
	/// The script runs in the page.
	case installed

	/// The page asked for FairPlay and got Arx's.
	case accessFairPlay = "access-fairplay"

	/// The page asked for Widevine or PlayReady and was refused.
	case accessRefused = "access-refused"

	/// The page asked for another key system, which Chromium answers.
	case accessOther = "access-other"
	case keysCreated = "keys-created"
	case certificate

	/// The page gave a media element Arx's keys.
	case keysAttached = "keys-attached"

	/// A FairPlay playlist went to the helper.
	case playlistTaken = "playlist-taken"

	/// A `<source>` outside a media element got a FairPlay playlist; the element it's put in takes
	/// it over once the page loads or plays it.
	case playlistDeferred = "playlist-deferred"

	/// A FairPlay playlist went to an element the page never gave Arx's keys, such as a player it
	/// made anew, and the page's FairPlay keys were adopted for it.
	case keysAdopted = "keys-adopted"

	/// A FairPlay playlist came from a page that made no FairPlay keys; the app falls back.
	case playlistNotKeyed = "playlist-not-keyed"

	/// A FairPlay playlist came before the page's certificate; the app falls back.
	case playlistNoCertificate = "playlist-no-certificate"
	case playlistNoKey = "playlist-no-key"
	case playlistUnreadable = "playlist-unreadable"

	/// An element with Arx's keys got a MediaSource (`blob:`) source instead of a playlist.
	case sourceMediaSource = "source-media-source"

	/// An element with Arx's keys got another source, such as an ad's.
	case sourceOther = "source-other"

	/// The `encrypted` event that starts the page's licence request.
	case encrypted

	/// The page asked its key session for a licence request.
	case keySession = "key-session"

	/// The page played an element with Arx's keys that the helper doesn't play.
	case playUnbridged = "play-unbridged"

	/// The track wasn't ready in time; the page gives up and the app falls back.
	case readyTimeout = "ready-timeout"
}

/// What the app tells the bridge's page script, about the page's own generation.
public enum FairPlayPageEvent: Equatable, Sendable {
	case request(generation: Int, spc: Data)
	case ready(generation: Int, duration: Double)
	case position(generation: Int, time: Double, isPlaying: Bool, sequence: Int)
	case ended(generation: Int)
	case failed(generation: Int, step: FairPlayStep)

	/// Another tab took the player; the page pauses its element.
	case stolen(generation: Int)
	case remote(FairPlayRemoteCommand, time: Double?)
}

/// Bounds on what any side accepts (DEV-1144).
public enum FairPlayLimits {
	public static let maximumCertificateBytes: Int = 64 * 1024
	public static let maximumLicenseBytes: Int = 64 * 1024
	public static let maximumPlaylistPartLength: Int = 60 * 1024
	public static let maximumPlaylistLength: Int = 2 * 1024 * 1024
	public static let maximumPlaylistParts: Int = 40
	public static let maximumTextLength: Int = 1024

	/// The longest line either pipe carries: a whole playlist and certificate, encoded.
	public static let maximumLineBytes: Int = 4 * 1024 * 1024
}
