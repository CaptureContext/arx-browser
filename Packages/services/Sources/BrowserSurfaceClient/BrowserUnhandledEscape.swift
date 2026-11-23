import AppKit
import BrowserCore

/// The supplied predicate must be rechecked before deferred UI work mutates its
/// source. Returning true only accepts the unhandled key; it grants no close.
public typealias BrowserUnhandledEscapeHandler = @MainActor @Sendable (
	_ sourceIsCurrent: @escaping @MainActor @Sendable () -> Bool
) -> Bool

/// Actual native-host identity prevents old SwiftUI teardown from unbinding a
/// replacement host for the same tab. Entries never own their NSView.
@MainActor
public final class BrowserUnhandledEscapeHosts {
	private final class Entry {
		internal weak var host: NSView?
		internal let tabID: BrowserCore.Tab.ID
		internal let handler: BrowserUnhandledEscapeHandler

		internal init(
			host: NSView,
			tabID: BrowserCore.Tab.ID,
			handler: @escaping BrowserUnhandledEscapeHandler
		) {
			self.host = host
			self.tabID = tabID
			self.handler = handler
		}
	}

	private var entries: [ObjectIdentifier: Entry] = [:]

	public init() {}

	public func bind(
		_ tabID: BrowserCore.Tab.ID,
		to host: NSView,
		handler: BrowserUnhandledEscapeHandler?
	) {
		entries = entries.filter { $0.value.host != nil }
		entries[ObjectIdentifier(host)] = handler.map {
			.init(host: host, tabID: tabID, handler: $0)
		}
	}

	public func accept(
		_ tabID: BrowserCore.Tab.ID,
		in host: NSView,
		sourceIsCurrent: @escaping @MainActor @Sendable () -> Bool
	) -> Bool {
		guard
			let entry = entries[ObjectIdentifier(host)],
			entry.host === host,
			entry.tabID == tabID,
			sourceIsCurrent()
		else { return false }

		return entry.handler { [weak self, weak entry] in
			guard
				let self,
				let entry,
				let host = entry.host,
				self.entries[ObjectIdentifier(host)] === entry
			else { return false }

			return sourceIsCurrent()
		}
	}
}
