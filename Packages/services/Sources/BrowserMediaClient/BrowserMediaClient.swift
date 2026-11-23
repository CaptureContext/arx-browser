import BrowserCore
import Foundation
import _Dependencies

/// Owns native media observation, not media playback or a second renderer.
public struct BrowserMediaClient: Sendable {
	public var availability: @MainActor @Sendable () -> Bool
	public var events: @MainActor @Sendable () -> AsyncStream<BrowserMediaSnapshot>
	public var activations: @MainActor @Sendable () -> AsyncStream<BrowserMediaSource.ID>

	/// Revalidates native identity synchronously; cached observation alone cannot authorize focus.
	public var isSourceCurrent: @MainActor @Sendable (BrowserMediaSource.ID) -> Bool

	public var perform: @MainActor @Sendable (BrowserMediaRequest) async throws -> Void

	/// Reads a tab's media position and audio mute once; nil when the tab has no
	/// observed ordinary page.
	public var position: @MainActor @Sendable (Tab.ID) -> BrowserMediaPosition?

	/// Mutes or unmutes an ordinary tab's audio.
	public var setMuted: @MainActor @Sendable (Tab.ID, Bool) throws -> Void

	/// Whether the engine can scale a tab's audio (DEV-800). Engines built before it can't.
	public var supportsVolume: @MainActor @Sendable () -> Bool

	/// Scales an ordinary tab's audio output, 0 to 1, on top of the page's own volume.
	public var setVolume: @MainActor @Sendable (Tab.ID, Double) throws -> Void

	public init(
		isAvailable: Bool = false,
		availability: (@MainActor @Sendable () -> Bool)? = nil,
		events: @escaping @MainActor @Sendable () -> AsyncStream<BrowserMediaSnapshot> = { .finished },
		activations: @escaping @MainActor @Sendable () -> AsyncStream<BrowserMediaSource.ID> = { .finished },
		isSourceCurrent: @escaping @MainActor @Sendable (BrowserMediaSource.ID) -> Bool = { _ in false },
		perform: @escaping @MainActor @Sendable (BrowserMediaRequest) async throws -> Void = { _ in
			throw Failure.unavailable
		},
		position: @escaping @MainActor @Sendable (Tab.ID) -> BrowserMediaPosition? = { _ in nil },
		setMuted: @escaping @MainActor @Sendable (Tab.ID, Bool) throws -> Void = { _, _ in
			throw Failure.unavailable
		},
		supportsVolume: @escaping @MainActor @Sendable () -> Bool = { false },
		setVolume: @escaping @MainActor @Sendable (Tab.ID, Double) throws -> Void = { _, _ in
			throw Failure.unavailable
		}
	) {
		self.availability = availability ?? { isAvailable }
		self.events = events
		self.activations = activations
		self.isSourceCurrent = isSourceCurrent
		self.perform = perform
		self.position = position
		self.setMuted = setMuted
		self.supportsVolume = supportsVolume
		self.setVolume = setVolume
	}

	@MainActor
	public var isAvailable: Bool { availability() }

	public enum Failure: Error, Equatable, Sendable {
		case unavailable
		case staleSource
		case unsupportedAction
		case requestFailed
		case timedOut
	}
}

extension BrowserMediaClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserMedia: BrowserMediaClient {
		get { self[BrowserMediaClient.self] }
		set { self[BrowserMediaClient.self] = newValue }
	}
}
