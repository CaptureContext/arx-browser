import BrowserCore
import Foundation
import Testing

@testable import WebKitBrowserEngine

/// One tab's history across its two engines (DEV-1293), as the router joins it.
internal struct SharedHistoryTests {
	private func entry(
		_ id: Int,
		_ address: String,
		current: Bool = false
	) -> BrowserNavigation.Entry {
		.init(id: id, url: URL(string: "https://\(address)/")!, title: address, isCurrent: current)
	}

	private func session(
		_ entries: [BrowserNavigation.Entry],
		current: Int,
		boundary: Int? = nil
	) -> SharedHistory.WebKitSession {
		.init(state: nil, entries: entries, current: current, boundary: boundary, returnURL: nil, previousURL: nil)
	}

	@Test
	internal func aWebKitPageLeftFromALaterEntryKeepsTheEntriesUpToIt() {
		// W1, W2, then the Chromium page, reached from W1 through the history list.
		let pages = [entry(-1, "w1", current: true), entry(0, "w2")]
		let behind = SharedHistory.WebKitNeighbor(session: session(pages, current: 0, boundary: 1), side: .behind)

		#expect(behind.entries.map(\.url.host) == ["w2", "w1"])
		// Back reaches W2 first: one entry ahead of the one WebKit shows when it's restored.
		#expect(behind.offset(to: 0) == 1)
		#expect(behind.offset(to: 1) == 0)
	}

	@Test
	internal func theWebKitPageAheadTakesThePlaceOfChromiumsEntriesPastTheAnchor() {
		var ahead = SharedHistory.WebKitNeighbor(
			session: session([entry(0, "w1", current: true), entry(1, "w2")], current: 0),
			side: .ahead
		)
		ahead.anchor = .init(entryID: 1, neighbors: [2])
		let navigation = BrowserNavigation(
			url: URL(string: "https://home/")!,
			history: [entry(1, "home", current: true), entry(2, "player")]
		)

		let joined = SharedHistory.joined(navigation, behind: nil, ahead: ahead)

		#expect(joined.canGoForward)
		#expect(joined.history.map(\.id) == [1, SharedHistory.aheadID, SharedHistory.aheadID + 1])
		// A link from the anchor replaces what was ahead of it.
		let moved = BrowserNavigation(
			url: URL(string: "https://story/")!,
			history: [entry(1, "home"), entry(3, "story", current: true)]
		)
		#expect(!ahead.holds(in: moved.history))
		#expect(SharedHistory.joined(moved, behind: nil, ahead: ahead).history.map(\.id) == [1, 3])
	}
}
