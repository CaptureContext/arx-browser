import BrowserCore
@testable import CommandBarFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-978: opening what's typed, when it's a link, and a plain search for it always come within
/// the first 5 rows, behind only an exact alias, the completed page and the instant rows.
@Suite(.dependencies)
@MainActor
internal struct CommandBarTypedRowsTests {
	@Test(arguments: [CommandBarFeature.Mode.newTab, .currentTab])
	internal func aLinkWithManyMatchesOpensThenSearchesWithinTheFirstFive(mode: CommandBarFeature.Mode) {
		let state = Self.state(mode, query: "google.com", candidates: Self.googlePages())
		let ids = state.entries.map(\.presentation.id)

		let open = ids.firstIndex(of: "destination") ?? 99
		let search = ids.firstIndex(of: "search-typed") ?? 99
		#expect(open < 5 && search < 5)
		#expect(open < search)
		expectNoDifference(Array(ids.prefix(2)), ["destination", "search-typed"])
		expectNoDifference(
			state.entries.first { $0.presentation.id == "destination" }?.intent,
			.open(URL(string: "https://google.com")!)
		)
		expectNoDifference(
			state.entries.first { $0.presentation.id == "search-typed" }?.intent,
			.open(SearchEngine.google.url(for: "google.com")!)
		)

		// The tabs and history that mention it follow.
		#expect(ids.count > 5)
	}

	@Test(arguments: [CommandBarFeature.Mode.newTab, .currentTab])
	internal func aPlainWordSearchesFirst(mode: CommandBarFeature.Mode) {
		let state = Self.state(mode, query: "google", candidates: Self.googlePages())
		let ids = state.entries.map(\.presentation.id)

		// Text that isn't a link has its search only, as the open row.
		expectNoDifference(ids.first, "destination")
		#expect(!ids.contains("search-typed"))
		expectNoDifference(state.entries.first?.intent, .open(SearchEngine.google.url(for: "google")!))
	}

	@Test
	internal func aLocalServerIsALinkOverPlainHTTP() {
		let state = Self.state(.newTab, query: "localhost:3000", candidates: [])
		expectNoDifference(state.entries.first?.intent, .open(URL(string: "http://localhost:3000")!))
		expectNoDifference(state.entries.map(\.presentation.id), ["destination", "search-typed"])
		expectNoDifference(
			CommandBarFeature.State.destination("LocalHost/admin"),
			URL(string: "http://LocalHost/admin")
		)

		// A dotted path or query stays on plain HTTP.
		for typed in ["localhost:3000/index.html", "localhost/path.js", "localhost:8080/?v=1.2"] {
			expectNoDifference(CommandBarFeature.State.destination(typed), URL(string: "http://" + typed), "\(typed)")
		}

		// A word that only starts like it is a search.
		expectNoDifference(
			CommandBarFeature.State.destination("localhosts"),
			SearchEngine.google.url(for: "localhosts")
		)
	}

	@Test
	internal func theMatchedPageStillLeads() {
		var pages = Self.googlePages()
		pages.append(Self.page("home", "Google", "https://google.com/"))
		let state = Self.state(.newTab, query: "google.co", candidates: pages)
		let ids = state.entries.map(\.presentation.id)

		expectNoDifference(state.addressMatchID, "home")
		expectNoDifference(Array(ids.prefix(3)), ["home", "destination", "search-typed"])
	}

	@Test
	internal func anExactAliasStillLeads() {
		var candidates = Self.googlePages()
		candidates.append(.init(
			presentation: .init(id: "command-pin", title: "Pin Tab", actionTitle: "Command", symbol: "pin", alias: "goo"),
			intent: .command(.pinTab)
		))
		let state = Self.state(.newTab, query: "goo", candidates: candidates)
		expectNoDifference(Array(state.entries.map(\.presentation.id).prefix(2)), ["command-pin", "destination"])
	}

	@Test
	internal func theCalculatorAndCreateRowsStillLead() {
		let sum = Self.state(.newTab, query: "12*7", candidates: [])
		let sumIDs = sum.entries.map(\.presentation.id)
		expectNoDifference(sumIDs.first, CommandBarFeature.State.calculatorEntryID)
		expectNoDifference(sumIDs.dropFirst().first, "destination")

		let create = Self.state(.newTab, query: "new doc", candidates: [])
		let createIDs = create.entries.map(\.presentation.id)
		let open = createIDs.firstIndex(of: "destination") ?? 99
		#expect(createIDs.prefix(open).allSatisfy { $0.hasPrefix("create-") })
		#expect(open > 0 && open < 5)
	}

	/// Every quick-create target has a whole title in the catalog instead of "New %@" around its
	/// English name (DEV-1291).
	@Test
	internal func everyCreateRowHasItsOwnTitle() {
		let titles: [String: String] = Dictionary(
			uniqueKeysWithValues: QuickCreate.targets.compactMap { target in
				Self.state(.newTab, query: target.host, candidates: [])
					.entries
					.first { $0.presentation.id == "create-" + target.host }
					.map { (target.host, $0.presentation.title) }
			}
		)
		expectNoDifference(titles.count, QuickCreate.targets.count)
		expectNoDifference(titles["docs.new"], "New Google Docs Document")
		expectNoDifference(titles["linear.new"], "New Linear Issue")
		#expect(titles.values.allSatisfy { $0.hasPrefix("New ") && !$0.contains("%") })
	}

	@Test
	internal func commandsKeepTheirLeadInCommandsMode() {
		var candidates = Self.googlePages()
		candidates.insert(contentsOf: (0..<4).map { index in
			.init(
				presentation: .init(id: "command-\(index)", title: "google.com command \(index)", actionTitle: "Command", symbol: "command"),
				intent: .command(.newTab)
			)
		}, at: 0)
		let state = Self.state(.commands, query: "google.com", candidates: candidates)
		let ids = state.entries.map(\.presentation.id)

		// ⌘K's commands come first, and the typed rows still make the first 5.
		expectNoDifference(Array(ids.prefix(5)), ["command-0", "command-1", "command-2", "destination", "search-typed"])
	}

	@Test
	internal func aPrefilledAddressKeepsItsRowAtTheEnd() {
		var state = Self.state(.currentTab, query: "https://capturecontext.dev/", candidates: Self.googlePages())
		state.prefilledQuery = state.query
		let ids = state.entries.map(\.presentation.id)

		expectNoDifference(ids.last, "destination")
		#expect(!ids.contains("search-typed"))
	}

	@Test
	internal func typingSelectsTheOpenRowSoReturnOpensTheLink() async {
		var state = CommandBarFeature.State(mode: .newTab, candidates: Self.googlePages())
		state.isPresented = true
		let store = TestStore(initialState: state) { CommandBarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.queryChanged("google.com")))
		expectNoDifference(store.state.selectedID, "destination")
	}

	// MARK: - Fixtures

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

	/// Tabs and history that mention google.com without being it, as in Max's screenshot. None
	/// starts with it, so the field completes nothing.
	private static func googlePages() -> [CommandBarFeature.Entry] {
		[
			("calendar", "Google Calendar", "https://calendar.google.com/"),
			("forms", "Google Forms", "https://docs.google.com/forms"),
			("news-1", "arx - Google News", "https://news.google.com/search?q=arx"),
			("news-2", "swift - Google News", "https://news.google.com/search?q=swift"),
			("mail", "Inbox - Gmail", "https://mail.google.com/mail"),
			("drive", "My Drive - Google Drive", "https://drive.google.com/"),
			("meet", "Google Meet", "https://meet.google.com/"),
		].map(page)
	}

	private static func page(
		_ id: String,
		_ title: String,
		_ address: String
	) -> CommandBarFeature.Entry {
		.init(
			presentation: .init(id: id, title: title, subtitle: address, actionTitle: "Open", symbol: "globe"),
			intent: .open(URL(string: address)!)
		)
	}
}
