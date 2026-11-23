import BrowserCore
import BrowserMediaClient
import ChromiumEngine
import Foundation

/// Maps native ordinary-page identities to the existing tab registry. Retained independently of views.
@MainActor
internal final class ChromiumMediaAdapter {
	private struct Owner {
		internal var tabID: Tab.ID
		internal var profileID: Profile.ID
		internal var isPrivate: Bool

		internal init(
			tabID: Tab.ID,
			profileID: Profile.ID,
			isPrivate: Bool
		) {
			self.tabID = tabID
			self.profileID = profileID
			self.isPrivate = isPrivate
		}
	}

	private var owners: [UInt64: Owner] = [:]
	private var native: [ChromiumMediaSource] = []
	private var snapshot: BrowserMediaSnapshot = .init(revision: 1)
	private var observers: [UUID: AsyncStream<BrowserMediaSnapshot>.Continuation] = [:]
	private var activationObservers: [UUID: AsyncStream<BrowserMediaSource.ID>.Continuation] = [:]
	private var stopped: Bool = false
	private var tasks: [Task<Void, Never>] = []
	private let isCurrent: @MainActor @Sendable (UInt64, BrowserMediaSource.ID) -> Bool
	private let perform: @MainActor @Sendable (
		UInt64,
		BrowserMediaRequest,
		ChromiumMediaSource.Action
	) async throws -> Void
	private let readPosition: @MainActor @Sendable (UInt64) -> ChromiumMediaPosition?
	private let setMuted: @MainActor @Sendable (UInt64, Bool) throws -> Void
	private let supportsVolume: @MainActor @Sendable () -> Bool
	private let setVolume: @MainActor @Sendable (UInt64, Double) throws -> Void

	/// Tracks pages play outside Chromium (DEV-1147), by tab.
	private var outside: [Tab.ID: OutsideChromiumMedia] = [:]

	/// Each outside track's source revision, raised whenever what the app shows of it changes.
	private var outsideRevisions: [Tab.ID: UInt64] = [:]
	private var lastOutsideRevision: UInt64 = 0

	/// Hands a control for an outside track to its page's own player; false when the tab has none.
	internal var performOutside: (@MainActor @Sendable (Tab.ID, BrowserMediaSource.Action) -> Bool)?

	/// Marks an outside track's source generation, apart from every generation Chromium gives.
	internal static let outsideGeneration: UInt64 = 1 << 63

	internal init(
		isCurrent: @escaping @MainActor @Sendable (
			UInt64,
			BrowserMediaSource.ID
		) -> Bool = { _, _ in false },
		perform: @escaping @MainActor @Sendable (
			UInt64,
			BrowserMediaRequest,
			ChromiumMediaSource.Action
		) async throws -> Void,
		position: @escaping @MainActor @Sendable (UInt64) -> ChromiumMediaPosition? = { _ in nil },
		setMuted: @escaping @MainActor @Sendable (UInt64, Bool) throws -> Void = { _, _ in
			throw ChromiumMediaFailure.unavailable
		},
		supportsVolume: @escaping @MainActor @Sendable () -> Bool = { false },
		setVolume: @escaping @MainActor @Sendable (UInt64, Double) throws -> Void = { _, _ in
			throw ChromiumMediaFailure.unavailable
		}
	) {
		self.isCurrent = isCurrent
		self.perform = perform
		self.readPosition = position
		self.setMuted = setMuted
		self.supportsVolume = supportsVolume
		self.setVolume = setVolume
	}

	deinit {
		for task in tasks { task.cancel() }
	}

	internal var client: BrowserMediaClient {
		.init(
			isAvailable: true,
			events: { [self] in events() },
			activations: { [self] in activations() },
			isSourceCurrent: { [self] id in
				guard
					!stopped,
					id.generation != 0,
					let page = owners.first(where: {
						$0.value.tabID == id.tabID
						&& $0.value.profileID == id.profileID
						&& !$0.value.isPrivate
					})?.key
				else { return false }

				if Self.isOutside(id) { return snapshot.sources.contains { $0.id == id } }
				return isCurrent(page, id)
			},
			perform: { [self] request in
				try Task.checkCancellation()
				guard
					let source = snapshot.sources.first(where: { $0.id == request.sourceID }),
					request.isValid(for: source),
					!source.isPrivate,
					let page = owners.first(where: {
						$0.value.tabID == source.id.tabID
						&& $0.value.profileID == source.id.profileID
						&& !$0.value.isPrivate
					})?.key
				else { throw BrowserMediaClient.Failure.staleSource }

				let action: ChromiumMediaSource.Action
				switch request.action {
				case .play: action = .play
				case .pause: action = .pause
				case .enterPictureInPicture: action = .enterPictureInPicture
				case .exitPictureInPicture: action = .exitPictureInPicture
				case .enterAutomaticPictureInPicture: action = .enterAutomaticPictureInPicture
				case .seek: action = .seek
				case .nextTrack: action = .nextTrack
				case .previousTrack: action = .previousTrack
				case .toggleMicrophone: action = .toggleMicrophone
				case .toggleCamera: action = .toggleCamera
				case .hangUp: action = .hangUp
				}

				do {
					if Self.isOutside(source.id) {
						// The page's own player takes it, as it takes Now Playing's commands.
						guard performOutside?(source.id.tabID, request.action) == true
						else { throw BrowserMediaClient.Failure.staleSource }
					} else {
						try await perform(page, request, action)
					}
					try Task.checkCancellation()
					guard snapshot.sources.contains(where: { $0.id == source.id })
					else { throw BrowserMediaClient.Failure.staleSource }
				} catch let failure as ChromiumMediaFailure {
					throw Self.failure(failure)
				}
			},
			position: { [self] tabID in
				guard
					!stopped,
					let match = ordinaryPage(tabID),
					let value = readPosition(match.page)
				else { return nil }

				// A track played outside Chromium is the tab's source; Chromium has no position for it.
				if let source = snapshot.sources.first(where: { $0.id.tabID == match.owner.tabID && Self.isOutside($0.id) }) {
					return .init(sourceID: source.id, isMuted: value.isMuted)
				}

				// The engine's generation names a source only while this snapshot has it.
				let sourceID = snapshot.sources.first(where: {
					$0.id.tabID == match.owner.tabID
					&& $0.id.profileID == match.owner.profileID
					&& $0.id.generation == value.generation
				})?.id
				return .init(
					sourceID: sourceID,
					isMuted: value.isMuted,
					position: sourceID == nil ? nil : value.position,
					duration: sourceID == nil ? nil : value.duration,
					playbackRate: sourceID == nil ? nil : value.playbackRate
				)
			},
			setMuted: { [self] tabID, isMuted in
				guard !stopped, let match = ordinaryPage(tabID)
				else { throw BrowserMediaClient.Failure.staleSource }

				do {
					try setMuted(match.page, isMuted)
				} catch let failure as ChromiumMediaFailure {
					throw Self.failure(failure)
				}
			},
			supportsVolume: { [self] in !stopped && supportsVolume() },
			setVolume: { [self] tabID, volume in
				guard !stopped, let match = ordinaryPage(tabID)
				else { throw BrowserMediaClient.Failure.staleSource }

				do {
					try setVolume(match.page, volume)
				} catch let failure as ChromiumMediaFailure {
					throw Self.failure(failure)
				}
			}
		)
	}

	private func ordinaryPage(_ tabID: Tab.ID) -> (page: UInt64, owner: Owner)? {
		owners.first(where: { $0.value.tabID == tabID && !$0.value.isPrivate })
			.map { (page: $0.key, owner: $0.value) }
	}

	internal func start(
		events: AsyncStream<[ChromiumMediaSource]>,
		activations: AsyncStream<ChromiumMediaActivation>
	) {
		guard tasks.isEmpty else { return }

		tasks = [
			Task { [weak self] in
				for await values in events {
					guard !Task.isCancelled else { return }
					self?.receive(values)
				}

				self?.finish()
			},
			Task { [weak self] in
				for await activation in activations {
					guard !Task.isCancelled else { return }
					self?.activate(activation)
				}
			},
		]
	}

	internal func register(
		page: UInt64,
		tabID: Tab.ID,
		profileID: Profile.ID,
		isPrivate: Bool
	) {
		owners[page] = .init(tabID: tabID, profileID: profileID, isPrivate: isPrivate)
		receive(native)
	}

	internal func remove(page: UInt64) {
		owners[page] = nil
		receive(native.filter { $0.page != page })
	}

	/// The tracks pages play outside Chromium now, by tab (DEV-1147).
	internal func setOutside(_ media: [Tab.ID: OutsideChromiumMedia]) {
		guard media != outside else { return }

		for (tabID, value) in media where outside[tabID] != value {
			lastOutsideRevision += 1
			outsideRevisions[tabID] = lastOutsideRevision
		}
		outsideRevisions = outsideRevisions.filter { media[$0.key] != nil }
		outside = media
		receive(native)
	}

	private static func isOutside(_ id: BrowserMediaSource.ID) -> Bool {
		id.generation & outsideGeneration != 0
	}

	/// A tab's outside track stands in for whatever Chromium reports of that tab, such as an
	/// element the bridge silenced: one source per tab. A private tab's never shows.
	private func withOutside(_ sources: [BrowserMediaSource]) -> [BrowserMediaSource] {
		guard !stopped, !outside.isEmpty
		else { return sources }

		var merged = sources
		for (tabID, media) in outside.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }) {
			guard
				let owner = ordinaryPage(tabID)?.owner,
				let revision = outsideRevisions[tabID]
			else { continue }

			merged.removeAll { $0.id.tabID == tabID }
			merged.append(.init(
				id: .init(
					tabID: tabID,
					profileID: owner.profileID,
					generation: Self.outsideGeneration | media.track
				),
				revision: revision,
				title: media.title,
				artist: media.artist,
				site: media.site,
				playback: media.playback,
				actions: media.actions
			))
		}
		return merged
	}

	internal func receive(_ values: [ChromiumMediaSource]) {
		native = values
		let sources: [BrowserMediaSource] = values.compactMap { value in
			guard let owner = owners[value.page], !owner.isPrivate
			else { return nil }

			let playback: BrowserMediaSource.Playback = switch value.playback {
			case .playing: .playing
			case .paused: .paused
			case .inactive: .inactive
			}

			return .init(
				id: .init(
					tabID: owner.tabID,
					profileID: owner.profileID,
					generation: value.generation
				),
				revision: value.revision,
				title: value.title,
				artist: value.artist,
				artwork: value.artwork,
				site: value.origin.flatMap(MediaSite.init),
				hasVideo: value.hasVideo,
				playback: playback,
				actions: Set(value.actions.map { action in
					switch action {
					case .play: .play
					case .pause: .pause
					case .enterPictureInPicture: .enterPictureInPicture
					case .exitPictureInPicture: .exitPictureInPicture
					case .enterAutomaticPictureInPicture: .enterAutomaticPictureInPicture
					case .seek: .seek
					case .nextTrack: .nextTrack
					case .previousTrack: .previousTrack
					case .toggleMicrophone: .toggleMicrophone
					case .toggleCamera: .toggleCamera
					case .hangUp: .hangUp
					}
				}),
				isInPictureInPicture: value.isInPictureInPicture,
				call: value.isCall ? .init(
					isMicrophoneOn: Self.isOn(value.microphone),
					isCameraOn: Self.isOn(value.camera)
				) : nil
			)
		}

		let next = BrowserMediaSnapshot(revision: snapshot.revision + 1, sources: withOutside(sources))
		let published = next.isValid ? next : BrowserMediaSnapshot(revision: next.revision)

		// Each snapshot becomes a store action. A page opening or closing without media, or a
		// native change Arx doesn't keep, leaves the sources as they were (DEV-945).
		guard published.sources != snapshot.sources else { return }

		snapshot = published
		for observer in observers.values { observer.yield(snapshot) }
	}

	private static func isOn(_ state: ChromiumMediaSource.DeviceState) -> Bool? {
		switch state {
		case .on: true
		case .off: false
		case .unknown: nil
		}
	}

	/// Whether a tab plays media or shows it in Picture in Picture.
	internal func isActive(tabID: Tab.ID) -> Bool {
		snapshot.sources.contains { source in
			source.id.tabID == tabID && (source.playback == .playing || source.isInPictureInPicture)
		}
	}

	internal func activate(_ activation: ChromiumMediaActivation) {
		guard
			let owner = owners[activation.page],
			!owner.isPrivate,
			let source = snapshot.sources.first(where: {
				$0.id.tabID == owner.tabID
				&& $0.id.profileID == owner.profileID
				&& $0.id.generation == activation.generation
			})
		else { return }

		for observer in activationObservers.values { observer.yield(source.id) }
	}

	private func events() -> AsyncStream<BrowserMediaSnapshot> {
		guard !stopped else { return .finished }

		let token = UUID()
		let (stream, continuation) = AsyncStream<BrowserMediaSnapshot>.makeStream(
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

	private func activations() -> AsyncStream<BrowserMediaSource.ID> {
		guard !stopped else { return .finished }

		let token = UUID()
		let (stream, continuation) = AsyncStream<BrowserMediaSource.ID>.makeStream(
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

	private func finish() {
		stopped = true
		receive([])
		for observer in observers.values { observer.finish() }
		for observer in activationObservers.values { observer.finish() }
		observers.removeAll()
		activationObservers.removeAll()
	}

	private static func failure(_ value: ChromiumMediaFailure) -> BrowserMediaClient.Failure {
		switch value {
		case .unavailable: .unavailable
		case .staleSource: .staleSource
		case .unsupportedAction: .unsupportedAction
		case .timedOut: .timedOut
		case .requestFailed: .requestFailed
		}
	}
}
