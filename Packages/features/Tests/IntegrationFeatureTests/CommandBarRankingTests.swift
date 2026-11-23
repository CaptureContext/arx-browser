import BrowserCore
@testable import CommandBarFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1015: history ranked by frecency, and exact command and Settings matches on top.
@Suite(.dependencies)
@MainActor
internal struct CommandBarRankingTests {
	// MARK: - Address match

	@Test
	internal func aFrequentlyTypedAddressBeatsAShorterRarelyVisitedOne() async throws {
		let rare = Self.page("rare", "https://news.com/", frecency: 1)
		let typed = Self.page("typed", "https://news.ycombinator.com/", frecency: 120)
		let index = AddressMatchIndex([rare, typed])

		expectNoDifference(index.entryID(matching: "news"), "typed")

		// Without scores the shorter address still wins, as before.
		let unscored = AddressMatchIndex([Self.page("rare", "https://news.com/"), Self.page("typed", "https://news.ycombinator.com/")])
		expectNoDifference(unscored.entryID(matching: "news"), "rare")
	}

	@Test
	internal func aSitesFrontPageLeadsUntilASlashIsTyped() async throws {
		let front = Self.page("front", "https://github.com/", frecency: 2)
		let deep = Self.page("deep", "https://github.com/arx/pulls", frecency: 90)
		let index = AddressMatchIndex([front, deep])

		expectNoDifference(index.entryID(matching: "git"), "front")
		expectNoDifference(index.entryID(matching: "github.com/"), "deep")
	}

	@Test
	internal func theFrequentPageLeadsTheResultsAndTheFieldShowsIt() async throws {
		let store = TestStore(initialState: CommandBarFeature.State()) { CommandBarFeature() }
		let entries = [
			Self.page("rare", "https://news.com/", frecency: 1),
			Self.page("typed", "https://news.ycombinator.com/", frecency: 120),
		]
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.present(.newTab, "", entries))
		await store.send(.ui(.queryChanged("news")))

		expectNoDifference(store.state.selectedID, "typed")

		// DEV-1223: the field keeps what was typed.
		expectNoDifference(store.state.query, "news")
		expectNoDifference(store.state.entries.first?.presentation.id, "typed")

		// DEV-978: the typed text's own rows stay within the first five.
		let ids = store.state.entries.map(\.presentation.id)
		#expect((ids.firstIndex(of: "destination") ?? 99) < CommandBarFeature.State.typedRowsWithin)
	}

	// MARK: - Exact matches

	@Test(arguments: [CommandBarFeature.Mode.newTab, .currentTab, .commands])
	internal func anExactSettingsMatchLeadsHistoryAndSuggestions(mode: CommandBarFeature.Mode) async throws {
		var state = Self.state(mode, query: "haptics", candidates: [
			Self.page("history", "https://haptics.example/", title: "Haptics feedback guide", frecency: 50),
			Self.setting("setting-row/advanced/haptics", "Haptics", state: "On"),
		])
		state.suggestsRemotely = true
		state.suggestions = ["haptics meaning"]
		state.suggestionsQuery = "haptics"

		expectNoDifference(state.entries.first?.presentation.id, "setting-row/advanced/haptics")
		expectNoDifference(state.entries.first?.presentation.state, "On")
		expectNoDifference(state.exactMatch?.intent, .openSettings("row/advanced/haptics"))
	}

	@Test
	internal func anExactCommandMatchLeadsAndIsHighlighted() async throws {
		let store = TestStore(initialState: CommandBarFeature.State()) { CommandBarFeature() }
		let entries = [
			Self.page("history", "https://reload.example/", title: "Reload Page Tips", frecency: 80),
			.command(.reload, bindings: []),
		]
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.present(.newTab, "", entries))
		await store.send(.ui(.queryChanged(BrowserCommand.reload.title.uppercased())))

		expectNoDifference(store.state.entries.first?.intent, .command(.reload))
		expectNoDifference(store.state.selectedID, "command-" + BrowserCommand.reload.rawValue)
	}

	@Test
	internal func settingsRowsAnswerTypedTextOnly() async throws {
		let rows = [Self.setting("setting-row/advanced/haptics", "Haptics", keywords: ["vibration"])]

		#expect(Self.state(.commands, query: "", candidates: rows).entries.isEmpty)
		expectNoDifference(
			Self.state(.commands, query: "vibra", candidates: rows).entries.first?.presentation.id,
			"setting-row/advanced/haptics"
		)

		// A keyword needs three letters, as in Settings' own search.
		#expect(!Self.state(.commands, query: "vi", candidates: rows).entries.contains { $0.isSetting })
	}

	// MARK: - Typed visits

	@Test
	internal func openingATypedLinkOrTheCompletionIsATypedAddress() async throws {
		let page = Self.page("typed", "https://news.ycombinator.com/", frecency: 120)

		let completing = Self.state(.newTab, query: "news.y", candidates: [page])
		#expect(completing.isTypedAddress(page))

		let link = Self.state(.newTab, query: "example.org", candidates: [page])
		let open = try #require(link.entries.first { $0.presentation.id == "destination" })
		#expect(link.isTypedAddress(open))
		// The plain search for the same text isn't an address.
		let search = try #require(link.entries.first { $0.presentation.id == "search-typed" })
		#expect(!link.isTypedAddress(search))

		let words = Self.state(.newTab, query: "weather today", candidates: [page])
		let wordSearch = try #require(words.entries.first { $0.presentation.id == "destination" })
		#expect(!words.isTypedAddress(wordSearch))
		// A page merely listed, not completed, wasn't typed toward; a history result taken from
		// the field was asked for.
		#expect(!words.isTypedAddress(page))
		let history = CommandBarFeature.Entry(
			presentation: .init(id: "history-1", title: "Hacker News", actionTitle: "Open", symbol: "clock"),
			intent: .open(URL(string: "https://news.ycombinator.com/")!)
		)
		#expect(words.isTypedAddress(history))

		// Nor is an address the field was opened with.
		var prefilled = Self.state(.currentTab, query: "https://news.ycombinator.com/", candidates: [page])
		prefilled.prefilledQuery = prefilled.query
		#expect(!prefilled.isTypedAddress(page))
	}

	@Test
	internal func openingACompletedTabInANewTabIsATypedVisit() async throws {
		let tab = CommandBarFeature.Entry(
			presentation: .init(
				id: "tab",
				title: "Hacker News",
				actionTitle: "Switch",
				symbol: "globe",
				siteIcon: .init(profileID: UUID(0), pageURL: URL(string: "https://news.ycombinator.com/")!)
			),
			intent: .selectTab(.init(rawValue: UUID(1)))
		)
		var initial = Self.state(.commands, query: "news", candidates: [tab])
		initial.selectedID = "tab"
		let store = TestStore(initialState: initial) { CommandBarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.actionRequested("open-new-tab")))
		var opened = tab
		opened.intent = .openInNewTab(URL(string: "https://news.ycombinator.com/")!)
		let execution = CommandBarFeature.Execution(entry: opened, mode: .commands, presentationID: 0, origin: tab, isTypedAddress: true)
		await store.receive(\.delegate.execute, execution)

		// Switching to it loads nothing, so it isn't a visit.
		var switching = Self.state(.commands, query: "news", candidates: [tab])
		switching.selectedID = "tab"
		let switchStore = TestStore(initialState: switching) { CommandBarFeature() }
		switchStore.exhaustivity = .off(showSkippedAssertions: false)
		await switchStore.send(.ui(.selected("tab")))
		await switchStore.receive(\.delegate.execute, .init(entry: tab, mode: .commands, presentationID: 0))
	}

	// MARK: - Helpers

	private static func state(
		_ mode: CommandBarFeature.Mode,
		query: String,
		candidates: [CommandBarFeature.Entry]
	) -> CommandBarFeature.State {
		var state = CommandBarFeature.State(mode: mode, candidates: candidates)
		state.isPresented = true
		state.query = query
		return state
	}

	private static func page(
		_ id: String,
		_ address: String,
		title: String? = nil,
		frecency: Double = 0
	) -> CommandBarFeature.Entry {
		.init(
			presentation: .init(id: id, title: title ?? id, subtitle: address, actionTitle: "Open", symbol: "globe"),
			intent: .open(URL(string: address)!),
			frecency: frecency
		)
	}

	private static func setting(
		_ id: String,
		_ title: String,
		state: String? = nil,
		keywords: [String] = []
	) -> CommandBarFeature.Entry {
		.init(
			presentation: .init(
				id: id,
				title: title,
				subtitle: "Settings › Advanced",
				actionTitle: "Show in Settings",
				symbol: "gearshape",
				state: state
			),
			intent: .openSettings(String(id.dropFirst("setting-".count))),
			keywords: keywords
		)
	}
}
