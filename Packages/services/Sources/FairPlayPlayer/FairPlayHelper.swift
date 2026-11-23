import AppKit
import AVFoundation
import FairPlayProtocol
import Foundation
import MediaPlayer
import OSLog

/// Arx's FairPlay helper (DEV-1144): plays the one track the app hands it, with keys the page
/// exchanges, and owns Now Playing and the media keys while it plays. The app starts it, speaks
/// to it over its standard input and output, and ends it by closing its input.
@MainActor
public final class FairPlayHelper {
	/// How often the helper reports the player's position.
	public static let reportInterval: Duration = .milliseconds(500)

	/// Artwork larger than this isn't shown.
	private static let maximumArtworkBytes: Int = 4 << 20

	/// Artwork is fetched without cookies or a cache, so private playback leaves nothing behind.
	private static let artworkSession: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieAcceptPolicy = .never
		configuration.httpShouldSetCookies = false
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		return URLSession(configuration: configuration)
	}()

	private let player: AVPlayer = AVPlayer()
	private let send: (FairPlayHelperEvent) -> Void
	private let publishesNowPlaying: Bool
	private let isSilent: Bool
	private var track: FairPlayTrack? {
		didSet { hasTrack.withLock { $0 = track != nil } }
	}

	/// Whether a track is loaded, for the remote command handlers, which may run on any thread.
	private let hasTrack: FairPlaySharedFlag = FairPlaySharedFlag()
	private var observers: [any NSObjectProtocol] = []
	private var lastReport: (time: Double, isPlaying: Bool, sequence: Int)?
	private var completedSeek: Int = 0
	private var isPageMuted: Bool = false
	private var nowPlaying: [String: Any] = [MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
	private var artwork: URL?
	private var publishedStatus: AVPlayer.TimeControlStatus?

	/// - Parameters:
	///   - publishesNowPlaying: Off for unattended runs, which must not take the Mac's media keys.
	///   - isSilent: Mutes the player whatever the page says, for unattended runs.
	public init(
		publishesNowPlaying: Bool,
		isSilent: Bool,
		send: @escaping (FairPlayHelperEvent) -> Void
	) {
		self.publishesNowPlaying = publishesNowPlaying
		self.isSilent = isSilent
		self.send = send
		player.automaticallyWaitsToMinimizeStalling = true
		player.isMuted = isSilent
		if publishesNowPlaying { registerRemoteCommands() }
	}

	public func handle(_ command: FairPlayHelperCommand) {
		switch command {
		case let .load(generation, certificate, playlist, volume, isMuted):
			load(generation: generation, certificate: certificate, playlist: playlist, volume: volume, isMuted: isMuted)
		case let .license(generation, ckc):
			if let track, track.generation == generation { track.license(ckc) }
		case .play:
			if track != nil { player.play() }
		case .pause:
			player.pause()
		case let .seek(time, sequence):
			seek(to: time, sequence: sequence)
		case let .volume(volume):
			player.volume = Float(volume)
		case let .muted(isMuted):
			isPageMuted = isMuted
			player.isMuted = isSilent || isMuted
		case let .metadata(metadata):
			setMetadata(metadata)
		case .stop:
			stop()
			publishNowPlaying()
		}
	}

	/// Reports the player's state; the helper's run loop calls it every `reportInterval`.
	public func report() {
		guard let track else { return }
		if track.item.status == .failed {
			let error = track.item.error as NSError?
			log.error("Helper: track \(track.generation) can't play: \(error?.domain ?? "", privacy: .public) \(error?.code ?? 0)")
			track.fail(.playback)
			return
		}
		if track.item.status == .readyToPlay {
			let duration = track.item.duration.seconds
			if !track.hasAnnouncedReady, duration.isFinite, duration > 0 {
				log.notice("Helper: track \(track.generation) is ready")
				track.hasAnnouncedReady = true
				send(.ready(generation: track.generation, duration: duration))
			}
			if let pending = track.pendingSeek {
				track.pendingSeek = nil
				seek(track, to: pending.time, sequence: pending.sequence)
			}
		}
		if player.timeControlStatus != publishedStatus {
			log.info("Helper: track \(track.generation) is \(Self.describe(self.player.timeControlStatus), privacy: .public)")
			publishedStatus = player.timeControlStatus
			publishNowPlaying()
		}
		let seconds = player.currentTime().seconds
		let time = seconds.isFinite ? seconds : 0
		let isPlaying = player.timeControlStatus == .playing

		// A paused player that hasn't moved says nothing new.
		if !isPlaying, let last = lastReport, !last.isPlaying, last.sequence == completedSeek, abs(last.time - time) < 0.05 {
			return
		}
		lastReport = (time, isPlaying, completedSeek)
		send(.position(generation: track.generation, time: time, isPlaying: isPlaying, sequence: completedSeek))
	}

	// MARK: - Tracks

	private func load(
		generation: Int,
		certificate: Data,
		playlist: String,
		volume: Double,
		isMuted: Bool
	) {
		stop()
		log.notice("Helper: loads track \(generation) (playlist \(playlist.utf8.count) bytes, certificate \(certificate.count) bytes)")
		let track = FairPlayTrack(generation: generation, certificate: certificate, playlist: playlist, send: send)
		self.track = track
		completedSeek = 0
		publishedStatus = nil
		player.volume = Float(volume)
		isPageMuted = isMuted
		player.isMuted = isSilent || isMuted
		player.replaceCurrentItem(with: track.item)
		let center = NotificationCenter.default
		observers = [
			center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: track.item, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self, self.track === track else { return }
					self.send(.ended(generation: generation))
				}
			},
			center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: track.item, queue: .main) { [weak self] notification in
				let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
				log.error("Helper: track \(generation) stopped playing: \(error?.domain ?? "", privacy: .public) \(error?.code ?? 0)")
				MainActor.assumeIsolated {
					guard let self, self.track === track else { return }
					track.fail(.playback)
					self.player.pause()
				}
			},
		]
		publishNowPlaying()
	}

	private func stop() {
		track?.cancel()
		track = nil
		player.pause()
		player.replaceCurrentItem(with: nil)
		observers.forEach { NotificationCenter.default.removeObserver($0) }
		observers = []
		lastReport = nil
	}

	private func seek(
		to time: Double,
		sequence: Int
	) {
		guard let track else { return }
		guard track.item.status == .readyToPlay else {
			track.pendingSeek = (time, sequence)
			return
		}
		seek(track, to: time, sequence: sequence)
	}

	private func seek(
		_ track: FairPlayTrack,
		to time: Double,
		sequence: Int
	) {
		let duration = track.item.duration.seconds
		let target = duration.isFinite && duration > 0 ? min(time, duration) : time
		let helper = WeakReference(self)
		let seeked = WeakReference(track)
		player.seek(
			to: CMTime(seconds: target, preferredTimescale: 600),
			toleranceBefore: .zero,
			toleranceAfter: .zero
		) { _ in
			Task { @MainActor in
				guard let self = helper.object else { return }
				if let track = seeked.object, self.track === track {
					self.completedSeek = max(self.completedSeek, sequence)
				}
				self.publishNowPlaying()
			}
		}
	}

	// MARK: - Now Playing

	private func setMetadata(_ metadata: FairPlayMetadata) {
		nowPlaying[MPMediaItemPropertyTitle] = metadata.title
		nowPlaying[MPMediaItemPropertyArtist] = metadata.artist
		nowPlaying[MPMediaItemPropertyAlbumTitle] = metadata.album
		if metadata.artwork != artwork {
			artwork = metadata.artwork
			nowPlaying[MPMediaItemPropertyArtwork] = nil
			if publishesNowPlaying, let url = metadata.artwork { loadArtwork(url) }
		}
		publishNowPlaying()
	}

	private func loadArtwork(_ url: URL) {
		Task { [weak self] in
			guard
				let (data, _) = try? await Self.artworkSession.data(from: url),
				data.count <= Self.maximumArtworkBytes,
				let image = NSImage(data: data)
			else { return }

			guard let self, self.artwork == url else { return }
			let size = image.size
			let artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
			self.nowPlaying[MPMediaItemPropertyArtwork] = artwork
			self.publishNowPlaying()
		}
	}

	private func publishNowPlaying() {
		guard publishesNowPlaying else { return }
		let center = MPNowPlayingInfoCenter.default()
		guard let track else {
			center.nowPlayingInfo = nil
			center.playbackState = .stopped
			return
		}

		let elapsed = player.currentTime().seconds
		let duration = track.item.duration.seconds
		let isPlaying = player.timeControlStatus == .playing
		nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed.isFinite ? elapsed : 0
		nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
		if duration.isFinite, duration > 0 { nowPlaying[MPMediaItemPropertyPlaybackDuration] = duration }
		center.nowPlayingInfo = nowPlaying
		center.playbackState = isPlaying ? .playing : .paused
	}

	/// The media keys and Now Playing's controls go back to the page, whose own handlers decide
	/// what play, next or a seek means. MediaPlayer may call these handlers on any thread and
	/// wants an answer at once: they read whether a track is loaded through a lock and hop to the
	/// main actor to tell the page.
	private func registerRemoteCommands() {
		let commands = MPRemoteCommandCenter.shared()
		let pairs: [(MPRemoteCommand, FairPlayRemoteCommand)] = [
			(commands.playCommand, .play),
			(commands.pauseCommand, .pause),
			(commands.togglePlayPauseCommand, .toggle),
			(commands.nextTrackCommand, .nextTrack),
			(commands.previousTrackCommand, .previousTrack),
		]
		let helper = WeakReference(self)
		let hasTrack = hasTrack
		for (command, remote) in pairs {
			command.isEnabled = true
			command.addTarget { _ in
				guard hasTrack.withLock({ $0 }) else { return .noActionableNowPlayingItem }
				DispatchQueue.main.async {
					MainActor.assumeIsolated { helper.object?.sendRemote(remote, time: nil) }
				}
				return .success
			}
		}
		commands.changePlaybackPositionCommand.isEnabled = true
		commands.changePlaybackPositionCommand.addTarget { event in
			guard
				hasTrack.withLock({ $0 }),
				let event = event as? MPChangePlaybackPositionCommandEvent
			else { return .commandFailed }

			let time = event.positionTime
			DispatchQueue.main.async {
				MainActor.assumeIsolated { helper.object?.sendRemote(.seek, time: time) }
			}
			return .success
		}
	}

	private func sendRemote(
		_ command: FairPlayRemoteCommand,
		time: Double?
	) {
		guard track != nil else { return }
		send(.remote(command, time: time))
	}

	private static func describe(_ status: AVPlayer.TimeControlStatus) -> String {
		switch status {
		case .paused: "paused"
		case .waitingToPlayAtSpecifiedRate: "waiting"
		case .playing: "playing"
		@unknown default: "unknown"
		}
	}
}

private let log: Logger = FairPlayLog.logger
