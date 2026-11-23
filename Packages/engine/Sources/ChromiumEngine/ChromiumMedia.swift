import ChromiumBridge
import Foundation

/// An ordinary-profile media session. No player, video pixels, or native window crosses this boundary.
public struct ChromiumMediaSource: Equatable, Sendable {
	public enum Playback: Int, Sendable {
		case inactive, playing, paused
	}

	public enum Action: Int, CaseIterable, Hashable, Sendable {
		case play, pause, enterPictureInPicture, exitPictureInPicture, enterAutomaticPictureInPicture, seek

		// ABI53 (DEV-906).
		case nextTrack, previousTrack

		/// ABI54 (DEV-948): a call's Media Session actions.
		case toggleMicrophone, toggleCamera, hangUp
	}

	/// ABI54 (DEV-948). A call's microphone or camera, as the site reports it.
	public enum DeviceState: Int, Sendable {
		case unknown, off, on
	}

	/// The largest artwork accepted from the engine. The engine asks for 256 px, so a PNG
	/// beyond this is not one it made.
	public static let maximumArtworkSize: Int = 1 << 20

	public var page: UInt64
	public var generation: UInt64
	public var revision: UInt64
	public var title: String

	/// The Media Session's artist, empty when the page names none.
	public var artist: String

	/// The Media Session's artwork as PNG bytes, at most 256 px a side.
	public var artwork: Data?
	public var origin: URL?
	public var hasVideo: Bool
	public var playback: Playback
	public var actions: Set<Action>
	public var isInPictureInPicture: Bool

	/// ABI54 (DEV-948). The page is in a call: it uses the camera or microphone and offers a
	/// call action or automatic Picture in Picture. Its Picture in Picture may be the site's own
	/// document, without a video.
	public var isCall: Bool
	public var microphone: DeviceState
	public var camera: DeviceState

	public init(
		page: UInt64,
		generation: UInt64,
		revision: UInt64,
		title: String,
		artist: String = "",
		artwork: Data? = nil,
		origin: URL?,
		hasVideo: Bool,
		playback: Playback,
		actions: Set<Action>,
		isInPictureInPicture: Bool,
		isCall: Bool = false,
		microphone: DeviceState = .unknown,
		camera: DeviceState = .unknown
	) {
		self.page = page
		self.generation = generation
		self.revision = revision
		self.title = String(title.unicodeScalars.prefix(512))
		self.artist = String(artist.unicodeScalars.prefix(512))
		self.artwork = artwork.flatMap { $0.isEmpty || $0.count > Self.maximumArtworkSize ? nil : $0 }
		self.origin = origin
		self.hasVideo = hasVideo
		self.playback = playback
		self.actions = actions
		self.isInPictureInPicture = isInPictureInPicture
		self.isCall = isCall
		self.microphone = microphone
		self.camera = camera
	}

	internal init?(
		page: UInt64,
		native: ArxMediaSnapshot
	) {
		guard
			page > 0,
			native.generation > 0,
			native.revision > 0,
			native.present,
			let playback = Playback(rawValue: Int(native.playback)),
			!native.picture || native.video || native.call,
			native.actions & ~UInt32(2047) == 0,
			let microphone = DeviceState(rawValue: Int(native.microphone.rawValue)),
			let camera = DeviceState(rawValue: Int(native.camera.rawValue))
		else { return nil }

		self.init(
			page: page,
			generation: native.generation,
			revision: native.revision,
			title: native.title.map { String(cString: $0) } ?? "",
			artist: native.artist.map { String(cString: $0) } ?? "",
			artwork: native.artwork.flatMap { bytes in
				(1...Self.maximumArtworkSize).contains(native.artwork_size)
				? Data(bytes: bytes, count: native.artwork_size)
				: nil
			},
			origin: native.origin.flatMap { URL(string: String(cString: $0)) },
			hasVideo: native.video,
			playback: playback,
			actions: Set(Action.allCases.filter { native.actions & (1 << $0.rawValue) != 0 }),
			isInPictureInPicture: native.picture,
			isCall: native.call,
			microphone: microphone,
			camera: camera
		)
	}
}

/// One on-demand read of an ordinary page's media position and audio mute.
/// Nothing streams: each read asks the engine once.
public struct ChromiumMediaPosition: Equatable, Sendable {
	/// The current media source's generation, or nil when the page has none.
	public var generation: UInt64?
	public var isMuted: Bool

	/// Seconds, extrapolated to the time of the read; nil when the session reports none.
	public var position: Double?

	/// Seconds; nil when unknown or unbounded (live).
	public var duration: Double?
	public var playbackRate: Double?

	public init(
		generation: UInt64?,
		isMuted: Bool,
		position: Double? = nil,
		duration: Double? = nil,
		playbackRate: Double? = nil
	) {
		self.generation = generation
		self.isMuted = isMuted
		self.position = position
		self.duration = duration
		self.playbackRate = playbackRate
	}

	internal init?(native: ArxMediaPosition) {
		let hasPosition = native.has_position
		guard
			!hasPosition || (native.position.isFinite && native.position >= 0),
			!hasPosition || native.duration.isFinite,
			!hasPosition || native.playback_rate.isFinite,
			hasPosition == false || native.generation > 0
		else { return nil }

		self.init(
			generation: native.generation > 0 ? native.generation : nil,
			isMuted: native.muted,
			position: hasPosition ? native.position : nil,
			duration: hasPosition && native.duration >= 0 ? native.duration : nil,
			playbackRate: hasPosition ? native.playback_rate : nil
		)
	}
}

public struct ChromiumMediaActivation: Equatable, Sendable {
	public var page: UInt64
	public var generation: UInt64

	public init(
		page: UInt64,
		generation: UInt64
	) {
		self.page = page
		self.generation = generation
	}
}

public enum ChromiumMediaFailure: Error, Equatable, Sendable {
	case unavailable, staleSource, unsupportedAction, timedOut, requestFailed

	internal init(status: ArxMediaStatus) {
		self = switch status {
		case ARX_MEDIA_STALE: .staleSource
		case ARX_MEDIA_UNSUPPORTED: .unsupportedAction
		case ARX_MEDIA_TIMEOUT: .timedOut
		case ARX_MEDIA_UNAVAILABLE: .unavailable
		default: .requestFailed
		}
	}
}

/// Copies borrowed native callbacks, replays authoritative replacements, and drains exactly once.
@MainActor
internal final class ChromiumMediaObservation {
	private var sources: [UInt64: ChromiumMediaSource] = [:]
	private var revisions: [UInt64: UInt64] = [:]
	private var observed: Set<UInt64> = []
	private var observers: [UUID: AsyncStream<[ChromiumMediaSource]>.Continuation] = [:]
	private var activationObservers: [UUID: AsyncStream<ChromiumMediaActivation>.Continuation] = [:]
	private var pending: [UInt64: Pending] = [:]
	private var nextRequest: UInt64 = 1
	private var stopped: Bool = false

	internal init() {}

	internal func register(_ page: UInt64) {
		observed.insert(page)
	}

	internal func events() -> AsyncStream<[ChromiumMediaSource]> {
		guard !stopped
		else { return AsyncStream { $0.finish() } }

		let token = UUID()
		let (stream, continuation) = AsyncStream<[ChromiumMediaSource]>.makeStream(
			bufferingPolicy: .bufferingNewest(1)
		)
		observers[token] = continuation
		continuation.yield(snapshot)
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.observers[token] = nil
			}
		}

		return stream
	}

	internal func activations() -> AsyncStream<ChromiumMediaActivation> {
		guard !stopped
		else { return AsyncStream { $0.finish() } }

		let token = UUID()
		let (stream, continuation) = AsyncStream<ChromiumMediaActivation>.makeStream(
			bufferingPolicy: .bufferingNewest(16)
		)
		activationObservers[token] = continuation
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.activationObservers[token] = nil
			}
		}

		return stream
	}

	internal func receive(
		page: UInt64,
		native: ArxMediaSnapshot
	) {
		guard
			!stopped,
			observed.contains(page),
			native.revision > revisions[page, default: 0]
		else { return }

		revisions[page] = native.revision
		sources[page] = ChromiumMediaSource(page: page, native: native)
		publish()
	}

	internal func activate(
		page: UInt64,
		generation: UInt64
	) {
		guard !stopped, sources[page]?.generation == generation
		else { return }

		for observer in activationObservers.values {
			observer.yield(.init(page: page, generation: generation))
		}
	}

	internal func perform(
		_ source: ChromiumMediaSource,
		action: ChromiumMediaSource.Action,
		start: (UInt64) -> Void,
		cancel: @escaping @MainActor @Sendable (UInt64) -> Void
	) async throws {
		try Task.checkCancellation()
		guard !stopped
		else { throw ChromiumMediaFailure.unavailable }
		guard sources[source.page] == source
		else { throw ChromiumMediaFailure.staleSource }
		guard source.actions.contains(action)
		else { throw ChromiumMediaFailure.unsupportedAction }

		let request = nextRequest
		nextRequest += 1

		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
				guard !Task.isCancelled else {
					continuation.resume(throwing: CancellationError())
					return
				}

				pending[request] = .init(
					page: source.page,
					generation: source.generation,
					continuation: continuation
				)
				start(request)
			}
		} onCancel: { [weak self] in
			Task { @MainActor [weak self] in
				guard
					let self,
					let requestState = self.pending.removeValue(forKey: request)
				else { return }

				requestState.continuation.resume(throwing: CancellationError())
				if !self.stopped { cancel(request) }
			}
		}

		try Task.checkCancellation()
	}

	internal func complete(
		request: UInt64,
		page: UInt64,
		status: ArxMediaStatus
	) {
		guard let requestState = pending.removeValue(forKey: request)
		else { return }

		do {
			guard
				requestState.page == page,
				sources[page]?.generation == requestState.generation
			else { throw ChromiumMediaFailure.staleSource }
			if status == ARX_MEDIA_CANCELLED { throw CancellationError() }
			guard status == ARX_MEDIA_SUCCESS
			else { throw ChromiumMediaFailure(status: status) }

			requestState.continuation.resume()
		} catch {
			requestState.continuation.resume(throwing: error)
		}
	}

	internal func remove(
		page: UInt64,
		cancel: (UInt64) -> Void
	) {
		observed.remove(page)
		let hadSource = sources.removeValue(forKey: page) != nil
		revisions[page] = nil

		for request in pending.filter({ $0.value.page == page }).keys {
			pending.removeValue(forKey: request)?.continuation.resume(
				throwing: ChromiumMediaFailure.staleSource
			)
			cancel(request)
		}

		// Closing pages without media must not broadcast an unchanged snapshot.
		if hadSource { publish() }
	}

	internal func finish() {
		stopped = true
		for request in pending.values {
			request.continuation.resume(throwing: ChromiumMediaFailure.unavailable)
		}

		pending.removeAll()
		sources.removeAll()
		observed.removeAll()
		revisions.removeAll()
		publish()

		for observer in observers.values { observer.finish() }
		for observer in activationObservers.values { observer.finish() }
		observers.removeAll()
		activationObservers.removeAll()
	}

	internal func source(page: UInt64) -> ChromiumMediaSource? { sources[page] }

	private var snapshot: [ChromiumMediaSource] { sources.values.sorted { $0.page < $1.page } }

	private func publish() {
		let snapshot = snapshot
		for observer in observers.values { observer.yield(snapshot) }
	}

	private struct Pending {
		internal var page: UInt64
		internal var generation: UInt64
		internal var continuation: CheckedContinuation<Void, any Error>

		internal init(
			page: UInt64,
			generation: UInt64,
			continuation: CheckedContinuation<Void, any Error>
		) {
			self.page = page
			self.generation = generation
			self.continuation = continuation
		}
	}
}
