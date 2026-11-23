import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct BangCatalogTests {
	private static let fixture: String = """
	# Comment lines carry provenance and the licence.
	g goog google\tGoogle\t1\thttps://www.google.com/search?q={query}
	gh git\tGitHub\t1\thttps://github.com/search?q={query}
	ga\tGoogle Analytics\t0\thttps://analytics.google.com/#q={query}
	GOOG gx\tDuplicate keyword\t1\thttps://duplicate.example/?q={query}
	broken\tNo placeholder\t1\thttps://broken.example/
	вики\tВикипедия\t1\thttps://ru.wikipedia.org/w/index.php?search={query}
	"""

	@Test
	internal func parsingKeepsSourceOrderAndFirstOwnerOfEachKeyword() async throws {
		let catalog = BangCatalog(parsing: Self.fixture)

		expectNoDifference(catalog.bangs.map(\.name), ["Google", "GitHub", "Google Analytics", "Duplicate keyword", "Википедия"])
		expectNoDifference(catalog.bangs[3].keywords, ["gx"])
		expectNoDifference(catalog.keywordCount, 8)
		expectNoDifference(catalog.bang(for: "GOOG")?.name, "Google")
		expectNoDifference(catalog.bang(for: "ВИКИ")?.name, "Википедия")
		#expect(catalog.bang(for: "broken") == nil)
	}

	@Test
	internal func destinationsEncodeQueriesAndOpenHomepagesOnlyWhenAllowed() async throws {
		let catalog = BangCatalog(parsing: Self.fixture)
		let google = try #require(catalog.bang(for: "g"))
		let analytics = try #require(catalog.bang(for: "ga"))

		expectNoDifference(
			try google.destination(for: "swift & 東京/50%+#"),
			URL(string: "https://www.google.com/search?q=swift%20%26%20%E6%9D%B1%E4%BA%AC%2F50%25%2B%23")
		)
		expectNoDifference(try analytics.destination(for: "a b"), URL(string: "https://analytics.google.com/#q=a%20b"))
		expectNoDifference(try google.destination(for: ""), URL(string: "https://www.google.com/"))
		#expect(throws: SearchShortcut.Failure.queryRequired) { try analytics.destination(for: "") }
	}

	@Test
	internal func userShortcutsOwnTheirKeywordsEvenWhenDisabled() async throws {
		let catalog = BangCatalog(parsing: Self.fixture)
		var mine = SearchShortcut(name: "Mine", keyword: "G", template: "https://mine.example/?q={query}")

		expectNoDifference(catalog.target(for: "G", shortcuts: [mine]), .shortcut(mine))
		expectNoDifference(
			try catalog.target(for: "g", shortcuts: [mine])?.destination(for: "x"),
			URL(string: "https://mine.example/?q=x")
		)
		mine.isEnabled = false
		#expect(catalog.target(for: "g", shortcuts: [mine]) == nil)
		expectNoDifference(catalog.target(for: "Goog", shortcuts: [mine])?.name, "Google")
		expectNoDifference(catalog.target(for: "goog", shortcuts: [mine])?.id, "goog")
		#expect(catalog.target(for: "missing", shortcuts: []) == nil)
	}

	@Test
	internal func prefixMatchesRankPopularBangsThenShortKeywords() async throws {
		let catalog = BangCatalog(parsing: Self.fixture)

		expectNoDifference(catalog.matches(prefix: "g", limit: 4).map(\.keyword), ["g", "goog", "google", "gh"])
		expectNoDifference(catalog.matches(prefix: "GO", limit: 10).map(\.keyword), ["goog", "google"])
		expectNoDifference(catalog.matches(prefix: "", limit: 2).map(\.keyword), ["g", "gh"])
		expectNoDifference(catalog.matches(prefix: "z", limit: 3), [])
		expectNoDifference(catalog.matches(prefix: "g", limit: 0), [])
	}

	@Test
	internal func searchMatchesNamesAndKeywordPrefixes() async throws {
		let catalog = BangCatalog(parsing: Self.fixture)

		expectNoDifference(catalog.search("google", limit: 10).map(\.name), ["Google", "Google Analytics"])
		expectNoDifference(catalog.search("!gi", limit: 10).map(\.name), ["GitHub"])
		expectNoDifference(catalog.search("  ", limit: 2).map(\.name), ["Google", "GitHub"])
		expectNoDifference(catalog.search("g", limit: 1).map(\.name), ["Google"])
	}

	@Test
	internal func bundledSnapshotResolvesCommonBangsOffline() async throws {
		let catalog = try await BangCatalog.bundled()

		#expect(catalog.bangs.count > 10_000)
		#expect(catalog.keywordCount > 13_000)
		let expected: [String: String] = [
			"g": "https://www.google.com/search?q=swift%20actors",
			"ddg": "https://duckduckgo.com/?q=swift%20actors",
			"mdn": "https://developer.mozilla.org/search?q=swift%20actors",
			"w": "https://wikipedia.org/w/index.php?search=swift%20actors",
		]
		for (keyword, url) in expected {
			let target = try #require(catalog.target(for: keyword, shortcuts: []))
			expectNoDifference(try target.destination(for: "swift actors").absoluteString, url)
		}

		// A person's own shortcut keeps its destination on a clash (DEV-1321).
		let own = SearchShortcut(
			name: "Wikipedia",
			keyword: "w",
			template: "https://en.wikipedia.org/w/index.php?search={query}"
		)
		expectNoDifference(
			try catalog.target(for: "w", shortcuts: [own])?.destination(for: "swift").absoluteString,
			"https://en.wikipedia.org/w/index.php?search=swift"
		)

		// Every bundled template produces a valid web URL.
		for bang in catalog.bangs {
			#expect((try? bang.destination(for: "a/b c")) != nil, "\(bang.name): \(bang.template)")
		}
	}

	/// A bang's site is its template's front page, whether or not an empty query opens it, and
	/// its icon is whatever is stored for that page (DEV-1311).
	@Test
	internal func aBangsSiteIsItsTemplatesFrontPage() async throws {
		let catalog = BangCatalog(parsing: Self.fixture)

		expectNoDifference(catalog.bang(for: "gh")?.site, URL(string: "https://github.com/"))
		expectNoDifference(catalog.bang(for: "ga")?.site, URL(string: "https://analytics.google.com/"))
		expectNoDifference(catalog.target(for: "g", shortcuts: [])?.site, URL(string: "https://www.google.com/"))

		let shortcut = SearchShortcut(name: "Docs", keyword: "docs", template: "HTTPS://docs.example:8443/find?q={query}")
		expectNoDifference(shortcut.site, URL(string: "https://docs.example:8443/"))
		expectNoDifference(BangTarget.shortcut(shortcut).site, shortcut.site)

		// A host built from the query, or a template that isn't a web address, has no one site.
		expectNoDifference(SearchShortcut.site(ofTemplate: "https://{query}.example/"), nil)
		expectNoDifference(SearchShortcut.site(ofTemplate: "ftp://files.example/?q={query}"), nil)
		expectNoDifference(SearchShortcut.site(ofTemplate: "not a url {query}"), nil)
	}

	@Test
	internal func dumpsShowTheCatalogSizeOnly() async throws {
		var dump = ""
		customDump(BangCatalog(parsing: Self.fixture), to: &dump)
		#expect(dump.contains("bangs: 5"))
		#expect(dump.count < 200)
	}
}
