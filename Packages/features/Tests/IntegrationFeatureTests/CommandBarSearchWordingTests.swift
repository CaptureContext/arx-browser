import BrowserCore
import CommandBarFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1319: a search says Search, in its row and in its actions; a page still says Open.
@Suite(.dependencies)
@MainActor
internal struct CommandBarSearchWordingTests {
	private let profile: Profile.ID = .init(rawValue: UUID(1))
	private let space: Space.ID = .init(rawValue: UUID(2))
	private let tabID: BrowserCore.Tab.ID = .init(rawValue: UUID(3))
	private let pageURL: URL = URL(string: "https://capturecontext.dev/page")!

	// MARK: - Searches

	/// Typed text that isn't a link has one row, its search, which says Search and searches.
	@Test
	internal func theTypedSearchSaysSearch() {
		let state = state(query: "arx browser", mode: .currentTab)
		let entry = entry("destination", in: state)

		#expect(entry.isSearch)
		expectNoDifference(entry.presentation.actionTitle, "Search")
		expectNoDifference(
			state.actions(for: entry).map(\.title),
			["Search", "Search in New Tab", "Search in Peek", "Search in Little Arx", "Copy URL"]
		)
		expectNoDifference(state.actions(for: entry).first?.symbol, "magnifyingglass")
	}

	@Test
	internal func aSuggestionSaysSearch() {
		var state = state(query: "asd", mode: .newTab)
		state.suggestions = ["asda"]
		state.suggestionsQuery = "asd"
		let entry = entry("suggestion-asda", in: state)

		#expect(entry.isSearch)
		expectNoDifference(entry.presentation.actionTitle, "Search")

		// "asd" can be an address too, which ⌘↩ opens as is (DEV-1319).
		expectNoDifference(
			state.actions(for: entry).map(\.title),
			["Search", "Open as is", "Search in Peek", "Search in Little Arx"]
		)
	}

	/// A typed link opens in its own row, and its search follows, saying Search.
	@Test
	internal func aTypedLinkOpensAndItsSearchSaysSearch() {
		let state = state(query: "example.org", mode: .newTab)
		let link = entry("destination", in: state)
		let search = entry("search-typed", in: state)

		#expect(!link.isSearch)
		expectNoDifference(link.presentation.actionTitle, "Command")
		expectNoDifference(state.actions(for: link).first?.title, "Open")
		#expect(search.isSearch)
		expectNoDifference(search.presentation.actionTitle, "Search")
		expectNoDifference(state.actions(for: search).first?.title, "Search")
	}

	// MARK: - Pages and the rest

	@Test
	internal func aPageFromHistoryStillSaysOpen() {
		let state = state(query: "history", mode: .currentTab)
		let entry = entry("history", in: state)

		#expect(!entry.isSearch)
		expectNoDifference(
			state.actions(for: entry).prefix(5).map(\.title),
			["Open", "Open as is", "Open in New Tab", "Open in Peek", "Open in Little Arx"]
		)
	}

	@Test
	internal func anOpenTabStillSwitches() {
		let state = state(query: "tab", mode: .newTab)
		let entry = entry("tab", in: state)

		expectNoDifference(
			state.actions(for: entry).prefix(4).map(\.title),
			["Switch to Tab", "Open as is", "Open in New Tab", "Open in Peek"]
		)
	}

	@Test
	internal func aCommandKeepsItsName() {
		let state = state(query: "Side", mode: .commands)
		expectNoDifference(state.actions(for: entry("command", in: state)).map(\.title), ["Sidebar", "Open as is"])
	}

	// MARK: - Fixture

	private func state(
		query: String,
		mode: CommandBarFeature.Mode
	) -> CommandBarFeature.State {
		.init(query: query, mode: mode, candidates: candidates())
	}

	private func entry(
		_ id: String,
		in state: CommandBarFeature.State
	) -> CommandBarFeature.Entry {
		guard let entry = state.entries.first(where: { $0.presentation.id == id }) else {
			Issue.record("No \(id) in \(state.entries.map(\.presentation.id))")
			return .init(presentation: .init(id: id, title: id, actionTitle: "", symbol: ""), intent: .toggleSidebar)
		}
		return entry
	}

	private func candidates() -> [CommandBarFeature.Entry] {
		[
			.init(
				presentation: .init(
					id: "tab",
					title: "tab",
					subtitle: pageURL.absoluteString,
					actionTitle: "Switch to Tab",
					symbol: "globe",
					siteIcon: .init(profileID: profile.rawValue, pageURL: pageURL)
				),
				intent: .selectTab(tabID),
				destination: .tab(profile, .unpinned(space))
			),
			.init(
				presentation: .init(
					id: "history",
					title: "history",
					subtitle: "https://example.com/a",
					actionTitle: "Open URL",
					symbol: "clock.arrow.circlepath"
				),
				intent: .openHistory(.init(
					id: UUID(10),
					profileID: profile,
					spaceID: space,
					url: URL(string: "https://example.com/a")!
				))
			),
			.init(
				presentation: .init(id: "command", title: "Sidebar", actionTitle: "Command", symbol: "sidebar.left"),
				intent: .toggleSidebar
			),
		]
	}
}
