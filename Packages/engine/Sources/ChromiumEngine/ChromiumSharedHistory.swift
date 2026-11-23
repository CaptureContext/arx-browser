import Foundation

/// `bool ArxEngineSetPageSharedHistory(uint64_t page, bool back, bool forward)` (DEV-1293): main
/// thread. Says the tab's other engine has a page right behind or ahead of this page's current
/// entry, so the page's swipe offers that way, and released there calls the handler below instead
/// of navigating. False for a page the engine doesn't know. Outside the ABI table, like the other
/// optional exports: an older engine's swipe reaches only the page's own history.
internal typealias ChromiumSetPageSharedHistoryFunction = @convention(c) (UInt64, Bool, Bool) -> Bool

internal let ChromiumSetPageSharedHistorySymbol: String = "ArxEngineSetPageSharedHistory"

/// `void ArxEngineSetSharedHistoryHandler(handler, context)` (DEV-1293): main thread. The handler
/// hears a swipe released toward the other engine's page, with the page and -1 for back or 1 for
/// forward.
internal typealias ChromiumSharedHistoryHandler = @convention(c) (UnsafeMutableRawPointer?, UInt64, Int32) -> Void

internal typealias ChromiumSetSharedHistoryHandlerFunction = @convention(c) (
	ChromiumSharedHistoryHandler?,
	UnsafeMutableRawPointer?
) -> Void

internal let ChromiumSetSharedHistoryHandlerSymbol: String = "ArxEngineSetSharedHistoryHandler"

@MainActor
private var sharedHistoryHandlers: [ObjectIdentifier: (ChromiumPage, Bool) -> Void] = [:]

extension ChromiumRuntime {
	/// Whether this engine's swipe can reach the other engine's page (DEV-1293).
	public var supportsSharedHistory: Bool {
		optionalExports.setPageSharedHistory != nil && optionalExports.setSharedHistoryHandler != nil
	}

	/// Whether the tab's other engine has a page right behind or ahead of `page`'s current entry.
	/// False when the engine can't say it or doesn't know the page.
	@discardableResult
	public func setSharedHistory(
		_ page: ChromiumPage,
		back: Bool,
		forward: Bool
	) -> Bool {
		guard
			state == .running,
			pages[page.id] === page,
			let set = optionalExports.setPageSharedHistory
		else { return false }

		return set(page.id, back, forward)
	}

	/// Hears each swipe released toward the other engine's page: the page, and true for forward.
	/// Nil stops.
	public func observeSharedHistorySwipes(_ handler: ((ChromiumPage, Bool) -> Void)?) {
		guard let setHandler = optionalExports.setSharedHistoryHandler else { return }

		sharedHistoryHandlers[ObjectIdentifier(self)] = handler
		guard handler != nil else {
			setHandler(nil, nil)
			return
		}

		setHandler(
			{ context, page, direction in
				MainActor.assumeIsolated { ChromiumRuntime.sharedHistorySwiped(context, page, direction) }
			},
			Unmanaged.passUnretained(self).toOpaque()
		)
	}

	private static func sharedHistorySwiped(
		_ context: UnsafeMutableRawPointer?,
		_ page: UInt64,
		_ direction: Int32
	) {
		guard let context, direction == -1 || direction == 1 else { return }

		let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
		guard
			let owner = runtime.pages[page],
			let handler = sharedHistoryHandlers[ObjectIdentifier(runtime)]
		else { return }

		handler(owner, direction == 1)
	}
}
