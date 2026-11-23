import BrowserCore
import Foundation
import _Dependencies

/// One application-owned queue; presentation and page lifetimes do not own transfers.
public struct BrowserDownloadsClient: Sendable {
	public var configure: @MainActor @Sendable (BrowserOrganization) async throws -> Void
	public var events: @MainActor @Sendable () -> AsyncStream<DownloadQueue>
	public var activeCount: @MainActor @Sendable () -> Int

	/// Transfers in progress, paused ones included, that a quit would lose: private ones, and those
	/// Chromium couldn't continue where they stopped (no strong validator, or a server refusing
	/// ranges). Read synchronously from the engine, like `activeCount` (DEV-1130). The quit
	/// confirmation asks about them even when its warning is off (DEV-966).
	public var unresumableCount: @MainActor @Sendable () -> Int
	public var snapshot: @MainActor @Sendable () -> DownloadQueue
	public var cancel: @MainActor @Sendable (BrowserDownload.ID) throws -> Void
	public var cancelAll: @MainActor @Sendable () throws -> Void
	public var open: @MainActor @Sendable (BrowserDownload.ID) throws -> Void
	public var reveal: @MainActor @Sendable (BrowserDownload.ID) throws -> Void

	/// Downloads an http(s) URL into an ordinary profile with Chromium's usual checks
	/// and destination. Returns once the transfer exists; it then continues in the queue.
	public var start: @MainActor @Sendable (Profile.ID, URL) async throws -> BrowserDownload.ID

	/// Removes these transfers from the Downloads list if they're finished, as Clear
	/// Browsing Data does. Files stay; transfers in progress stay. Returns how many
	/// were removed, and throws when the list couldn't be saved.
	public var removeHistory: @MainActor @Sendable (Set<BrowserDownload.ID>) throws -> Int

	/// Pauses an in-progress transfer, or resumes a paused or resumable interrupted one (DEV-892).
	public var setPaused: @MainActor @Sendable (BrowserDownload.ID, Bool) throws -> Void

	/// Moves a finished download's file to the Trash and removes it from the list (DEV-892).
	public var moveToTrash: @MainActor @Sendable (BrowserDownload.ID) throws -> Void

	/// Remove from List (DEV-892): forgets a finished transfer here and in Chromium's history, so it
	/// stays gone after a relaunch. Throws `unavailable` with an engine that can't do that.
	public var removeFromList: @MainActor @Sendable (BrowserDownload.ID) throws -> Void

	public init(
		configure: @escaping @MainActor @Sendable (BrowserOrganization) async throws -> Void = { _ in },
		events: @escaping @MainActor @Sendable () -> AsyncStream<DownloadQueue> = { .finished },
		activeCount: @escaping @MainActor @Sendable () -> Int = { 0 },
		unresumableCount: @escaping @MainActor @Sendable () -> Int = { 0 },
		snapshot: @escaping @MainActor @Sendable () -> DownloadQueue = { .init() },
		cancel: @escaping @MainActor @Sendable (BrowserDownload.ID) throws -> Void = { _ in
			throw Failure.unavailable
		},
		cancelAll: @escaping @MainActor @Sendable () throws -> Void = { throw Failure.unavailable },
		open: @escaping @MainActor @Sendable (BrowserDownload.ID) throws -> Void = { _ in
			throw Failure.unavailable
		},
		reveal: @escaping @MainActor @Sendable (BrowserDownload.ID) throws -> Void = { _ in
			throw Failure.unavailable
		},
		start: @escaping @MainActor @Sendable (Profile.ID, URL) async throws -> BrowserDownload.ID = { _, _ in
			throw Failure.unavailable
		},
		removeHistory: @escaping @MainActor @Sendable (Set<BrowserDownload.ID>) throws -> Int = { _ in 0 },
		setPaused: @escaping @MainActor @Sendable (BrowserDownload.ID, Bool) throws -> Void = { _, _ in
			throw Failure.unavailable
		},
		moveToTrash: @escaping @MainActor @Sendable (BrowserDownload.ID) throws -> Void = { _ in
			throw Failure.unavailable
		},
		removeFromList: @escaping @MainActor @Sendable (BrowserDownload.ID) throws -> Void = { _ in
			throw Failure.unavailable
		}
	) {
		self.configure = configure
		self.events = events
		self.activeCount = activeCount
		self.unresumableCount = unresumableCount
		self.snapshot = snapshot
		self.cancel = cancel
		self.cancelAll = cancelAll
		self.open = open
		self.reveal = reveal
		self.start = start
		self.removeHistory = removeHistory
		self.setPaused = setPaused
		self.moveToTrash = moveToTrash
		self.removeFromList = removeFromList
	}

	public enum Failure: Error, Equatable, LocalizedError {
		case unavailable
		case missingDownload
		case notOpenable
		case fileMissing
		case couldNotOpen

		/// Chromium refused the request before a transfer existed.
		case couldNotStart

		/// The server didn't answer within 30 seconds.
		case startTimedOut

		/// The transfer can't be paused or resumed now.
		case notResumable

		/// Finder couldn't move the file to the Trash.
		case couldNotTrash

		/// Chromium doesn't know the transfer yet, for example right after launch.
		case notRemovable

		public var errorDescription: String? {
			switch self {
			case .unavailable: "Downloads require the Arx engine."
			case .missingDownload: "This download is no longer available."
			case .notOpenable: "Only completed, safe downloads can be opened."
			case .fileMissing: "The downloaded file was moved or deleted."
			case .couldNotOpen: "macOS could not open this file. Try showing it in Finder."
			case .couldNotStart: "The download couldn't start."
			case .startTimedOut: "The server didn't respond in time."
			case .notResumable: "This download can't be paused or resumed now."
			case .couldNotTrash: "The file couldn't be moved to the Trash."
			case .notRemovable: "Arx can't remove this download yet. Try again in a moment."
			}
		}
	}
}

extension BrowserDownloadsClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserDownloads: BrowserDownloadsClient {
		get { self[BrowserDownloadsClient.self] }
		set { self[BrowserDownloadsClient.self] = newValue }
	}
}
