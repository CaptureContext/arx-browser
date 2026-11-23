import BrowserCore
import Foundation
import SearchSuggestionsClient
import Testing

@Suite
internal struct SearchSuggestionsTests {
	@Test
	internal func requestsGoogleWithoutCookies() throws {
		let request = try #require(SearchSuggestionsClient.request(for: "swift & arc", engine: .google, language: "en"))
		let url = try #require(request.url)
		let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

		#expect(components.host == "suggestqueries.google.com")
		#expect(components.path == "/complete/search")
		#expect(components.queryItems?.first { $0.name == "q" }?.value == "swift & arc")
		#expect(components.queryItems?.first { $0.name == "client" }?.value == "firefox")
		#expect(components.queryItems?.first { $0.name == "hl" }?.value == "en")
		#expect(!request.httpShouldHandleCookies)
	}

	@Test(arguments: SearchEngine.allCases)
	internal func eachProviderUsesItsOwnService(_ engine: SearchEngine) async throws {
		let request = SearchSuggestionsClient.request(for: "c++ & arc", engine: engine, language: "en")
		if engine == .kagi || engine == .perplexity {
			#expect(request == nil)
			return
		}

		let actual = try #require(request)
		let url = try #require(actual.url)
		let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
		let hosts: [SearchEngine: String] = [
			.google: "suggestqueries.google.com", .duckDuckGo: "duckduckgo.com",
			.bing: "api.bing.com", .brave: "search.brave.com",
			.ecosia: "ac.ecosia.org", .startpage: "www.startpage.com",
		]
		#expect(components.host == hosts[engine])
		#expect(components.queryItems?.first { $0.name == (engine == .bing ? "query" : "q") }?.value == "c++ & arc")
		#expect(!actual.httpShouldHandleCookies)
		#expect(actual.cachePolicy == .reloadIgnoringLocalCacheData)
		#expect(actual.value(forHTTPHeaderField: "Authorization") == nil)
		#expect(actual.value(forHTTPHeaderField: "Cookie") == nil)
		#expect(url.query(percentEncoded: true)?.contains("c%2B%2B") == true)
	}

	@Test
	internal func plusSignsStayPlusSigns() throws {
		let request = try #require(SearchSuggestionsClient.request(for: "c++ 1+1", engine: .google, language: nil))
		let query = try #require(request.url?.query(percentEncoded: true))

		#expect(query.contains("q=c%2B%2B%201%2B1"))
		#expect(!query.contains("+"))
	}

	@Test
	internal func readsSuggestionsInOrder() throws {
		let data = Data(#"["arc", ["arc browser", " ", "arcade", 4], [], {"google:suggesttype": []}]"#.utf8)

		#expect(try SearchSuggestionsClient.suggestions(from: data) == ["arc browser", "arcade"])
	}

	@Test
	internal func rejectsAnotherShape() {
		#expect(throws: SearchSuggestionsClient.Failure.unexpectedResponse) {
			try SearchSuggestionsClient.suggestions(from: Data(#"{"q": "arc"}"#.utf8))
		}
		#expect(throws: SearchSuggestionsClient.Failure.unexpectedResponse) {
			try SearchSuggestionsClient.suggestions(from: Data(#"["arc"]"#.utf8))
		}
	}

	@Test
	internal func automatedRunsNeverAsk() {
		#expect(SearchSuggestionsClient.isAvailable(environment: [:], arguments: ["Arx"]))
		#expect(!SearchSuggestionsClient.isAvailable(environment: ["XCTestBundlePath": "/x"], arguments: ["Arx"]))
		#expect(!SearchSuggestionsClient.isAvailable(environment: ["ARX_ENGINE_PROFILE": "/p"], arguments: ["Arx"]))
		#expect(!SearchSuggestionsClient.isAvailable(environment: ["ARX_SKIP_REMOTE_SUGGESTIONS": "1"], arguments: ["Arx"]))
		#expect(!SearchSuggestionsClient.isAvailable(environment: [:], arguments: ["Arx", "--headless"]))
		#expect(!SearchSuggestionsClient.isAvailable(environment: [:], arguments: ["Arx", "--arx-smoke"]))
	}

	@Test
	internal func testsNeverAsk() {
		#expect(!SearchSuggestionsClient.testValue.isAvailable)
	}
}
