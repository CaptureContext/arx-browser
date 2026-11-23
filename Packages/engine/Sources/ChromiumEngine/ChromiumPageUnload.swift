import Darwin

/// DEV-873. Why the app unloads a page; the engine applies Chrome's rules for that reason.
/// Raw values are `PageUnloadReason` in `Native/page_unload_bridge.h`.
public enum ChromiumPageUnloadReason: UInt32, Equatable, Sendable {
	/// Hidden longer than Settings allow (Chrome's proactive rules).
	case inactive = 0

	/// The system is under critical memory pressure (Chrome's urgent rules).
	case memoryPressure = 1

	/// The window that held the page closed (DEV-1104): sound, picture in picture (which the
	/// engine ends first), capture, notifications and live connections don't keep it. An engine
	/// built before it answers `unavailable`.
	case windowClosed = 2

	/// As ``windowClosed``, for a page whose unsaved input the person let go (DEV-1107): the
	/// window asked the page's before-unload question before closing and they chose Leave, or
	/// the page had nothing to ask. Unsaved input doesn't keep it. An engine built before it
	/// answers `unavailable`.
	case windowClosedAnswered = 3
}

/// DEV-873. Why the engine kept a page loaded. Raw values are `PageUnloadBlocker` in
/// `Native/page_unload_bridge.h`.
public struct ChromiumPageUnloadBlockers: OptionSet, Equatable, Hashable, Sendable {
	public let rawValue: UInt32

	public init(rawValue: UInt32) {
		self.rawValue = rawValue
	}

	/// Chrome's discard eligibility: sound, picture in picture, form input, a PDF,
	/// notifications, capture, devices, an extension's opt-out and the like.
	public static let chrome: Self = .init(rawValue: 1 << 0)

	/// Shown in a window.
	public static let visible: Self = .init(rawValue: 1 << 1)

	/// DevTools or another debugger is attached.
	public static let developerTools: Self = .init(rawValue: 1 << 2)
	public static let audible: Self = .init(rawValue: 1 << 3)
	public static let pictureInPicture: Self = .init(rawValue: 1 << 4)

	/// A capturer holds the page.
	public static let captured: Self = .init(rawValue: 1 << 5)

	/// Loading or committing a navigation.
	public static let loading: Self = .init(rawValue: 1 << 6)

	/// Already unloaded, crashed or not loaded yet.
	public static let noDocument: Self = .init(rawValue: 1 << 7)

	/// The engine's performance manager doesn't know the page.
	public static let unknownPage: Self = .init(rawValue: 1 << 8)

	/// Holds a WebSocket or WebTransport connection, which unloading would end (DEV-879). The
	/// same check keeps the page out of infinite tabs freezing.
	public static let liveConnection: Self = .init(rawValue: 1 << 9)

	/// Form input or other edits the page hasn't saved, reported for a closed window
	/// (DEV-1104); the other reasons report it as ``chrome``.
	public static let unsavedInput: Self = .init(rawValue: 1 << 10)
}

/// DEV-873. What asking the engine to unload a page did.
public enum ChromiumPageUnloadOutcome: Equatable, Sendable {
	/// The renderer's document is gone; the page keeps its address, title and history and
	/// loads again when it's shown or restored.
	case unloaded
	case alreadyUnloaded

	/// Kept loaded, for these reasons.
	case refused(ChromiumPageUnloadBlockers)

	/// Loading or committing; ask again later.
	case busy

	/// The engine doesn't run, doesn't know the page or can't unload pages.
	case unavailable

	internal init(
		status: Int32,
		blockers: UInt32
	) {
		switch status {
		case 0: self = .unloaded
		case 2: self = .alreadyUnloaded
		case 3: self = .refused(.init(rawValue: blockers))
		case 4: self = .busy
		default: self = .unavailable
		}
	}
}

/// DEV-873. The engine's tab unloading exports, outside the ABI table like DEV-800's volume,
/// so an engine built before them still loads and only can't unload pages. Main thread.
internal struct ChromiumPageUnloadFunctions {
	/// `int32_t ArxEngineUnloadPage(uint64_t page, uint32_t reason, uint32_t *blockers)`.
	internal typealias Unload = @convention(c) (UInt64, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32

	/// `bool ArxEnginePageIsUnloaded(uint64_t page)`.
	internal typealias IsUnloaded = @convention(c) (UInt64) -> Bool

	/// `bool ArxEngineRestoreUnloadedPage(uint64_t page)`.
	internal typealias Restore = @convention(c) (UInt64) -> Bool

	internal static let unloadSymbol: String = "ArxEngineUnloadPage"
	internal static let isUnloadedSymbol: String = "ArxEnginePageIsUnloaded"
	internal static let restoreSymbol: String = "ArxEngineRestoreUnloadedPage"

	/// `uint32_t ArxEnginePageUnloadBlockers(uint64_t page, uint32_t reason)` (DEV-1107).
	internal typealias Blockers = @convention(c) (UInt64, UInt32) -> UInt32

	/// `int32_t ArxEngineUnloadAnsweredPage(uint64_t page, uint32_t *blockers)` (DEV-1107).
	internal typealias UnloadAnswered = @convention(c) (UInt64, UnsafeMutablePointer<UInt32>?) -> Int32

	internal static let blockersSymbol: String = "ArxEnginePageUnloadBlockers"
	internal static let unloadAnsweredSymbol: String = "ArxEngineUnloadAnsweredPage"

	internal let unload: Unload
	internal let isUnloaded: IsUnloaded
	internal let restore: Restore

	/// Newer than the other three (DEV-1107): nil on an engine built before them, which closes
	/// windows without asking their pages.
	internal let blockers: Blockers?
	internal let unloadAnswered: UnloadAnswered?

	internal init(
		unload: Unload,
		isUnloaded: IsUnloaded,
		restore: Restore,
		blockers: Blockers? = nil,
		unloadAnswered: UnloadAnswered? = nil
	) {
		self.unload = unload
		self.isUnloaded = isUnloaded
		self.restore = restore
		self.blockers = blockers
		self.unloadAnswered = unloadAnswered
	}

	/// The first three, or nil; the DEV-1107 pair when the engine has both.
	internal static func load(from handle: UnsafeMutableRawPointer) -> Self? {
		guard
			let unload = dlsym(handle, unloadSymbol),
			let isUnloaded = dlsym(handle, isUnloadedSymbol),
			let restore = dlsym(handle, restoreSymbol)
		else { return nil }

		let blockers = dlsym(handle, blockersSymbol)
		let unloadAnswered = dlsym(handle, unloadAnsweredSymbol)
		let answers = blockers != nil && unloadAnswered != nil
		return .init(
			unload: unsafeBitCast(unload, to: Unload.self),
			isUnloaded: unsafeBitCast(isUnloaded, to: IsUnloaded.self),
			restore: unsafeBitCast(restore, to: Restore.self),
			blockers: answers ? blockers.map { unsafeBitCast($0, to: Blockers.self) } : nil,
			unloadAnswered: answers ? unloadAnswered.map { unsafeBitCast($0, to: UnloadAnswered.self) } : nil
		)
	}
}

extension ChromiumRuntime {
	/// Whether this engine can unload pages to free memory (DEV-873).
	public var supportsPageUnloading: Bool { pageUnloading != nil }

	/// Unloads a hidden page in place, when the engine's rules allow it: Chromium drops its
	/// document and renderer memory, and keeps its address, title, icon and back/forward list.
	/// The page loads again when its view is shown or ``restoreUnloadedPage(_:)`` asks.
	public func unload(
		_ page: ChromiumPage,
		reason: ChromiumPageUnloadReason
	) -> ChromiumPageUnloadOutcome {
		guard let pageUnloading else { return .unavailable }

		if reason == .windowClosedAnswered {
			guard let unloadAnswered = pageUnloading.unloadAnswered else { return .unavailable }

			let result = performIfOpen(on: page) { _, id in
				var blockers: UInt32 = 0
				let status = unloadAnswered(id, &blockers)
				return ChromiumPageUnloadOutcome(status: status, blockers: blockers)
			}
			return result ?? .unavailable
		}

		let result = performIfOpen(on: page) { _, id in
			var blockers: UInt32 = 0
			let status = pageUnloading.unload(id, reason.rawValue, &blockers)
			return ChromiumPageUnloadOutcome(status: status, blockers: blockers)
		}
		return result ?? .unavailable
	}

	/// Whether this engine can say which pages a closing window must ask first, and unload them
	/// once answered (DEV-1107).
	public var supportsAnsweredUnloads: Bool { pageUnloading?.unloadAnswered != nil }

	/// What would keep the page loaded if it were unloaded for `reason` now, without unloading
	/// it (DEV-1107). Nil with an engine built before it, or for a closed page.
	public func unloadBlockers(
		_ page: ChromiumPage,
		reason: ChromiumPageUnloadReason
	) -> ChromiumPageUnloadBlockers? {
		guard let blockers = pageUnloading?.blockers else { return nil }

		return performIfOpen(on: page) { _, id in
			ChromiumPageUnloadBlockers(rawValue: blockers(id, reason.rawValue))
		}
	}

	/// Whether the page is unloaded and hasn't started loading again.
	public func isUnloaded(_ page: ChromiumPage) -> Bool {
		guard let pageUnloading else { return false }

		return performIfOpen(on: page) { _, id in pageUnloading.isUnloaded(id) } ?? false
	}

	/// Ends the page's video or document picture in picture without unloading it (DEV-1128), as
	/// closing the window that owns its tab does while an agent keeps the page loaded. False when
	/// there was none, or with an engine built before it.
	@discardableResult
	public func endPictureInPicture(_ page: ChromiumPage) -> Bool {
		guard let end = optionalExports.endPictureInPicture else { return false }

		return performIfOpen(on: page) { _, id in end(id) } ?? false
	}

	/// Starts loading an unloaded page's current entry while it stays hidden. False when it
	/// wasn't unloaded.
	@discardableResult
	public func restoreUnloadedPage(_ page: ChromiumPage) -> Bool {
		guard let pageUnloading else { return false }

		return performIfOpen(on: page) { _, id in pageUnloading.restore(id) } ?? false
	}
}
