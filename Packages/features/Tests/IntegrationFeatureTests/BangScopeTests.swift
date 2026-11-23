import BrowserCore
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1321: a bundled bang and a person's search shortcut are entered and used the same way.
/// `!keyword` then Return, Tab or Space, or choosing its row, scopes the field to the site; a
/// query after it searches at once; Return in an empty scope opens the site's front page; and a
/// person's shortcut owns its keyword.
@Suite(.dependencies)
@MainActor
internal struct BangScopeTests {
	/// `yt` is bundled only; `docs` is the person's own; `gmail` is bundled with no homepage.
	private static let bangs: BangCatalog = .init(parsing: """
	yt youtube\tYouTube\t1\thttps://www.youtube.com/results?search_query={query}
	gmail\tGmail\t0\thttps://mail.google.com/mail/#search/{query}
	docs\tBundled Docs\t1\thttps://bundled.example/docs?q={query}
	""")

	private static let docs: SearchShortcut = .init(
		name: "CaptureContext Docs",
		keyword: "docs",
		template: "https://capturecontext.dev/docs?q={query}",
		homepage: URL(string: "https://capturecontext.dev/docs")
	)

	// MARK: - Ways into a scope

	@Test(arguments: ["yt", "docs"])
	internal func bangThenReturnScopes(_ keyword: String) async {
		let store = store(query: "!" + keyword)
		let row = store.state.entries.first
		expectNoDifference(row?.intent, .useShortcut(keyword))

		await store.send(.ui(.selected(row?.presentation.id ?? "")))
		expectNoDifference(store.state.siteSearchKeyword, keyword)
		expectNoDifference(store.state.query, "")
		#expect(store.state.isPresented)
	}

	@Test(arguments: ["yt", "docs"])
	internal func bangThenTabScopes(_ keyword: String) async {
		let store = store(query: "!" + keyword)
		expectNoDifference(store.state.pendingShortcutKeyword, keyword)

		await store.send(.ui(.tabPressed))
		expectNoDifference(store.state.siteSearchKeyword, keyword)
		expectNoDifference(store.state.query, "")
	}

	@Test(arguments: ["yt", "docs"])
	internal func bangThenSpaceScopes(_ keyword: String) async {
		let store = store(query: "")
		await store.send(.ui(.queryChanged("!" + keyword)))
		await store.send(.ui(.queryChanged("!" + keyword + " ")))
		expectNoDifference(store.state.siteSearchKeyword, keyword)
		expectNoDifference(store.state.query, "")
	}

	/// A person's keyword then Tab scopes; a bundled keyword without `!` stays text, since
	/// bundled keywords include ordinary words, so Tab goes on to chat.
	@Test
	internal func keywordThenTabScopesOnlyAPersonsShortcut() async {
		let own = store(query: "docs")
		await own.send(.ui(.tabPressed))
		expectNoDifference(own.state.siteSearchKeyword, "docs")

		let bundled = store(query: "yt")
		expectNoDifference(bundled.state.pendingShortcutKeyword, nil)
	}

	/// Choosing a row from the `!` list scopes too.
	@Test
	internal func choosingABangFromTheListScopes() async {
		let store = store(query: "!y")
		let row = store.state.entries.first { $0.intent == .useShortcut("yt") }
		await store.send(.ui(.selected(row?.presentation.id ?? "")))
		expectNoDifference(store.state.siteSearchKeyword, "yt")
	}

	// MARK: - Searching

	@Test(arguments: [
		("yt", "https://www.youtube.com/results?search_query=lofi"),
		("docs", "https://capturecontext.dev/docs?q=lofi"),
	])
	internal func aQueryAfterTheBangSearchesAtOnce(_ keyword: String, _ url: String) async {
		let store = store(query: "!" + keyword + " lofi")
		let row = store.state.entries.first
		expectNoDifference(row?.intent, .open(URL(string: url)!))

		await store.send(.ui(.selected(row?.presentation.id ?? "")))
		#expect(!store.state.isPresented)
		await store.receive(\.delegate.execute)
	}

	@Test
	internal func aQueryInTheScopeSearchesTheSite() async {
		let store = store(query: "!yt")
		await store.send(.ui(.tabPressed))
		await store.send(.ui(.queryChanged("lofi")))
		expectNoDifference(
			store.state.entries.first?.intent,
			.open(URL(string: "https://www.youtube.com/results?search_query=lofi")!)
		)
	}

	// MARK: - The front page

	@Test(arguments: [
		("yt", "https://www.youtube.com/"),
		("docs", "https://capturecontext.dev/docs"),
		// No homepage in the bundled list: the front page of the site its template searches.
		("gmail", "https://mail.google.com/"),
	])
	internal func returnInAnEmptyScopeOpensTheFrontPage(_ keyword: String, _ url: String) async {
		let store = store(query: "!" + keyword)
		await store.send(.ui(.tabPressed))
		let row = store.state.entries.first
		expectNoDifference(row?.intent, .open(URL(string: url)!))
		expectNoDifference(store.state.selectedID, row?.presentation.id)

		await store.send(.ui(.selected(row?.presentation.id ?? "")))
		#expect(!store.state.isPresented)
		await store.receive(\.delegate.execute)
	}

	// MARK: - Owning a keyword

	/// The person's `docs` wins over the bundled `!docs`.
	@Test
	internal func aPersonsShortcutOverridesTheBundledBang() {
		let state = store(query: "!docs swift").state
		expectNoDifference(
			state.entries.first?.intent,
			.open(URL(string: "https://capturecontext.dev/docs?q=swift")!)
		)
	}

	/// A disabled shortcut still owns its keyword, so the bundled bang doesn't answer it.
	@Test
	internal func aDisabledShortcutStillOwnsItsKeyword() {
		var disabled = Self.docs
		disabled.isEnabled = false
		let state = store(query: "!docs", shortcuts: [disabled]).state
		#expect(state.entries.allSatisfy { $0.intent != .useShortcut("docs") })
		expectNoDifference(state.pendingShortcutKeyword, nil)
	}

	/// Arx starts with no shortcuts of its own: the bundled bangs cover those sites.
	@Test
	internal func arxStartsWithNoSearchShortcuts() {
		expectNoDifference(BrowserPreferences().searchShortcuts, [])
	}

	// MARK: - Fixture

	private func store(
		query: String,
		shortcuts: [SearchShortcut] = [BangScopeTests.docs]
	) -> TestStoreOf<CommandBarFeature> {
		let document = WorkspaceDocument.unsaved(BrowserPreferences(searchShortcuts: shortcuts))
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			var state = CommandBarFeature.State(isPresented: true, mode: .newTab, bangs: Self.bangs)
			state.query = query
			state.selectedID = state.entries.first?.presentation.id
			return state
		}
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
