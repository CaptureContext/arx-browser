import Foundation

extension BrowserNavigation {
	/// DEV-1016. Why the page's renderer last ended, and whether it keeps ending.
	public struct RendererEnd: Equatable, Sendable {
		public enum Cause: String, Codable, Equatable, Sendable {
			case crashed
			case outOfMemory

			/// The system or another process killed it: on a Mac, usually memory running low.
			case killed

			/// Arx ended it: the page had stopped answering (DEV-1009).
			case endedByArx
			case launchFailed
			case other
		}

		public var cause: Cause

		/// The page's renderer ends so far, counting this one.
		public var number: UInt32
		public var exitCode: Int32

		/// Other pages' renderers ended within a tenth of a second too: something they share
		/// went, such as the GPU or network process, rather than this page.
		public var isShared: Bool

		/// This page's renderer ended three times within a minute on its own: it keeps crashing
		/// or running out of memory, and reloading again won't help.
		public var isRepeated: Bool

		public init(
			cause: Cause,
			number: UInt32,
			exitCode: Int32 = 0,
			isShared: Bool = false,
			isRepeated: Bool = false
		) {
			self.cause = cause
			self.number = number
			self.exitCode = exitCode
			self.isShared = isShared
			self.isRepeated = isRepeated
		}
	}
}

/// DEV-1016. Renderer ends across pages: ends within a tenth of a second
/// of each other share a cause and count for no page, and a page whose renderer ended three
/// times within a minute on its own keeps ending. Ends Arx asked for don't count. An end is
/// known by its tab, the engine page that drew it and its number there, so a tab whose page
/// was made again (Retry) keeps its streak.
public struct RendererEndHistory: Equatable, Sendable {
	public static let together: TimeInterval = 0.1
	public static let window: TimeInterval = 60
	public static let limit: Int = 3

	private struct Entry: Equatable, Sendable {
		var tab: Tab.ID
		var page: UInt64
		var number: UInt32
		var at: TimeInterval
		var counts: Bool

		/// Another page's end came within `together`. Kept on the entry, so closing that page
		/// doesn't make this end count again.
		var isShared: Bool
	}

	private struct Last: Equatable, Sendable {
		var page: UInt64
		var number: UInt32
		var isShared: Bool
	}

	private var entries: [Entry]

	/// Each tab's last recorded end and whether it was shared, kept past the window, so
	/// reading the same end again later neither records it as a new one nor forgets that it
	/// was shared.
	private var recorded: [Tab.ID: Last]

	public init() {
		self.entries = []
		self.recorded = [:]
	}

	/// Notes a renderer end once, by its page and number; ends older than the window go.
	/// Returns the other tabs whose earlier ends this one made shared, for the app to tell
	/// them again.
	@discardableResult
	public mutating func record(
		tab: Tab.ID,
		page: UInt64 = 0,
		number: UInt32,
		at time: TimeInterval,
		counts: Bool
	) -> Set<Tab.ID> {
		entries.removeAll { time - $0.at > Self.window + Self.together }
		if let last = recorded[tab], last.page == page, last.number == number { return [] }
		var changed: Set<Tab.ID> = []
		var isShared = false
		for index in entries.indices
		where entries[index].tab != tab && abs(entries[index].at - time) <= Self.together {
			isShared = true
			if !entries[index].isShared {
				entries[index].isShared = true
				changed.insert(entries[index].tab)
			}
			let other = entries[index]
			if let last = recorded[other.tab], last.page == other.page, last.number == other.number {
				recorded[other.tab]?.isShared = true
			}
		}
		entries.append(.init(tab: tab, page: page, number: number, at: time, counts: counts, isShared: isShared))
		recorded[tab] = .init(page: page, number: number, isShared: isShared)
		return changed
	}

	/// The tab's last recorded end number, if any.
	public func lastNumber(of tab: Tab.ID) -> UInt32? {
		recorded[tab]?.number
	}

	/// Whether another tab's renderer ended within a tenth of a second of this end.
	public func isShared(
		tab: Tab.ID,
		page: UInt64 = 0,
		number: UInt32
	) -> Bool {
		if let entry = entries.first(where: { $0.tab == tab && $0.page == page && $0.number == number }) {
			return entry.isShared
		}
		guard let last = recorded[tab], last.page == page, last.number == number else { return false }
		return last.isShared
	}

	/// Whether the tab's renderer ended `limit` times within the window before `time`, each
	/// on its own and none of them asked for, whichever of its pages drew them.
	public func isRepeated(
		tab: Tab.ID,
		at time: TimeInterval
	) -> Bool {
		let own = entries.filter { entry in
			entry.tab == tab && entry.counts && time - entry.at <= Self.window && !entry.isShared
		}
		return own.count >= Self.limit
	}

	/// The tab's page closed. Its ends stay until they leave the window, so a page made again
	/// for the same tab (Retry) keeps counting, and other tabs' ends keep their classification.
	public mutating func forget(_ tab: Tab.ID) {
		recorded[tab] = nil
	}
}
