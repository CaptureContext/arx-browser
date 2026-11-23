import BrowserCore

/// The order of the sidebar's media stack and the Media page (DEV-1245): by when each tab's
/// media was opened, and nothing else. Muting, pausing and playing never move an item, and a
/// muted page that leaves its media session keeps its place while it stays listed.
///
/// Keyed by tab rather than by source, since a page that reloads or leaves its session while
/// muted comes back as a new source of the same tab.
public struct MediaStackOrder: Equatable, Sendable {
	/// Each listed tab's place: lower opened earlier.
	public private(set) var ranks: [BrowserCore.Tab.ID: UInt64]
	private var nextRank: UInt64

	public init() {
		self.ranks = [:]
		self.nextRank = 0
	}

	/// Keeps the places of `tabs` that are already listed, gives the new ones the next places
	/// in the order they come, and forgets every tab that isn't in `tabs` any more (its tab
	/// closed or its media left the page), so it goes to the end if it comes back.
	public mutating func update(listing tabs: some Sequence<BrowserCore.Tab.ID>) {
		var kept: [BrowserCore.Tab.ID: UInt64] = [:]
		for tabID in tabs where kept[tabID] == nil {
			if let rank = ranks[tabID] {
				kept[tabID] = rank
			} else {
				kept[tabID] = nextRank
				nextRank += 1
			}
		}
		ranks = kept
	}

	/// `sources` in stack order. A source whose tab isn't listed yet goes last, in the order given.
	public func sorted(_ sources: [BrowserMediaSource]) -> [BrowserMediaSource] {
		sources.enumerated()
			.sorted { lhs, rhs in
				let left = ranks[lhs.element.id.tabID] ?? .max
				let right = ranks[rhs.element.id.tabID] ?? .max
				return left == right ? lhs.offset < rhs.offset : left < right
			}
			.map(\.element)
	}
}
