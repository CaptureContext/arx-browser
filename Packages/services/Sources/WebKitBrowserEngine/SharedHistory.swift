import BrowserCore
import Foundation

/// One tab's history across its two engines (DEV-1293). A tab shows one engine's page at a time,
/// and the other engine's page is closed, so the router keeps what that page had and offers it
/// as Back or Forward from the page shown, in the history list as well.
///
/// The entries it adds have ids far outside both engines' own: WebKit numbers its entries by
/// their offset from the current one and Chromium by small positive ids.
internal enum SharedHistory {
	/// The first entry ahead of the shown page's own; the next ones count up from it.
	internal static let aheadID: Int = 1 << 40

	/// The first entry behind the shown page's own; the earlier ones count down from it.
	internal static let behindID: Int = -(1 << 40)

	/// How far ahead (0 for the nearest) an entry id is, nil for an id of the engine's own.
	internal static func aheadIndex(_ id: Int) -> Int? {
		id >= aheadID ? id - aheadID : nil
	}

	/// How far behind (0 for the nearest) an entry id is, nil for an id of the engine's own.
	internal static func behindIndex(_ id: Int) -> Int? {
		id <= behindID ? behindID - id : nil
	}

	/// A WebKit page's history, kept while the tab shows Chromium.
	internal struct WebKitSession {
		/// WebKit's own saved back and forward list (`WKWebView.interactionState`); nil when it
		/// had none, and the page then loads its current address afresh.
		internal var state: Any?

		/// WebKit's entries in order, as its `navigation.history` listed them.
		internal var entries: [BrowserNavigation.Entry]

		/// The index of the entry it showed.
		internal var current: Int

		/// The index of the last entry before the Chromium page the tab left it for: the one it
		/// showed, or a later one when it went to that page from its history list.
		internal var boundary: Int

		/// Where Back from its first entry went, and the page it then stepped back to.
		internal var returnURL: URL?
		internal var previousURL: URL?

		/// How many entries back from `returnURL` the reopened page steps to `previousURL`;
		/// negative steps forward.
		internal var returnSteps: Int

		internal init(
			state: Any?,
			entries: [BrowserNavigation.Entry],
			current: Int,
			boundary: Int? = nil,
			returnURL: URL?,
			previousURL: URL?,
			returnSteps: Int = 1
		) {
			self.state = state
			self.entries = entries
			self.current = current
			self.boundary = boundary ?? current
			self.returnURL = returnURL
			self.previousURL = previousURL
			self.returnSteps = returnSteps
		}

		/// The entries Forward reaches from a Chromium page before it, nearest first: all of them,
		/// as Back left WebKit from its first entry.
		internal var ahead: [BrowserNavigation.Entry] { entries }

		/// The entries Back reaches from a Chromium page after it, nearest first: the last one before
		/// that page and those before it; leaving it for another page dropped those after.
		internal var behind: [BrowserNavigation.Entry] {
			entries.indices.contains(boundary) ? Array(entries[...boundary].reversed()) : []
		}
	}

	/// A Chromium page a WebKit page can go forward to: where it reopens, and what the history list
	/// calls it.
	internal struct ChromiumPage: Equatable {
		internal var url: URL
		internal var title: String

		/// Where the page reopens, with its saved history: the entry it showed, `stepsBack` entries
		/// after `url`'s.
		internal var reopenURL: URL
		internal var stepsBack: Int

		internal init(
			url: URL,
			title: String,
			reopenURL: URL? = nil,
			stepsBack: Int = 0
		) {
			self.url = url
			self.title = title
			self.reopenURL = reopenURL ?? url
			self.stepsBack = stepsBack
		}
	}

	/// The Chromium history entry a WebKit session sits next to, and its neighbors on that side as
	/// they were: a new navigation from there replaces them, and the session with them.
	internal struct Anchor: Equatable {
		internal var entryID: Int
		internal var neighbors: [Int]

		internal init(
			entryID: Int,
			neighbors: [Int]
		) {
			self.entryID = entryID
			self.neighbors = neighbors
		}
	}

	internal enum Side {
		case behind
		case ahead
	}

	/// A WebKit session next to the Chromium page the tab shows.
	internal struct WebKitNeighbor {
		internal var session: WebKitSession
		internal var side: Side

		/// Nil until the Chromium page shows the entry it sits next to.
		internal var anchor: Anchor?

		/// The entry the reopened page stepped back from, which isn't the anchor.
		internal var steppedFrom: Int?

		internal init(
			session: WebKitSession,
			side: Side
		) {
			self.session = session
			self.side = side
		}

		internal var entries: [BrowserNavigation.Entry] {
			side == .ahead ? session.ahead : session.behind
		}

		/// The WebKit offset from its current entry to the one `index` entries away.
		internal func offset(to index: Int) -> Int {
			side == .ahead ? index - session.current : session.boundary - index - session.current
		}

		/// The anchor's index in `history`, nil when the history no longer has it as it was.
		internal func anchorIndex(in history: [BrowserNavigation.Entry]) -> Int? {
			guard let anchor, let index = history.firstIndex(where: { $0.id == anchor.entryID }) else { return nil }
			let neighbors = side == .ahead ? history[(index + 1)...].map(\.id) : history[..<index].map(\.id)
			return neighbors == anchor.neighbors ? index : nil
		}

		/// Whether the Chromium page still has the anchor with its neighbors; true before the
		/// anchor is known.
		internal func holds(in history: [BrowserNavigation.Entry]) -> Bool {
			anchor == nil || anchorIndex(in: history) != nil
		}

		/// Whether the Chromium page shows the anchor, where Back or Forward crosses to WebKit.
		/// Before the anchor is known, the page shows it.
		internal func isAtAnchor(_ navigation: BrowserNavigation) -> Bool {
			guard let anchor else { return true }
			guard anchorIndex(in: navigation.history) != nil else { return false }
			return navigation.history.first(where: \.isCurrent)?.id == anchor.entryID
		}

		/// The anchor at `navigation`'s current entry once it has committed there; nil while the
		/// page still loads, shows its initial blank page or hasn't stepped back yet.
		internal func anchored(at navigation: BrowserNavigation) -> Anchor? {
			guard
				!navigation.isLoading,
				navigation.errorCode == nil,
				let index = navigation.history.firstIndex(where: \.isCurrent),
				navigation.history[index].url == navigation.url,
				navigation.history[index].url.hasWebScheme,
				navigation.history[index].id != steppedFrom
			else { return nil }

			let history = navigation.history
			let neighbors = side == .ahead ? history[(index + 1)...].map(\.id) : history[..<index].map(\.id)
			return .init(entryID: history[index].id, neighbors: neighbors)
		}
	}

	/// A Chromium page's navigation with the WebKit sessions on either side of it, which take the
	/// place of the Chromium entries past the anchor on their side.
	internal static func joined(
		_ navigation: BrowserNavigation,
		behind: WebKitNeighbor?,
		ahead: WebKitNeighbor?
	) -> BrowserNavigation {
		var navigation = navigation
		var history = navigation.history
		guard let current = history.firstIndex(where: \.isCurrent) else { return navigation }

		if let ahead, ahead.holds(in: history) {
			let index = ahead.anchorIndex(in: history) ?? current
			let entries = ahead.entries.enumerated().map { offset, entry in
				BrowserNavigation.Entry(id: aheadID + offset, url: entry.url, title: entry.title, isCurrent: false)
			}
			if index >= current, !entries.isEmpty {
				history = Array(history[...index]) + entries
				navigation.canGoForward = true
			}
		}
		if let behind, behind.holds(in: history) {
			let index = behind.anchorIndex(in: history) ?? (history.firstIndex(where: \.isCurrent) ?? current)
			let entries = behind.entries.enumerated().map { offset, entry in
				BrowserNavigation.Entry(id: behindID - offset, url: entry.url, title: entry.title, isCurrent: false)
			}
			if index <= (history.firstIndex(where: \.isCurrent) ?? current), !entries.isEmpty {
				history = entries.reversed() + Array(history[index...])
				navigation.canGoBack = true
			}
		}
		navigation.history = history
		return navigation
	}
}
