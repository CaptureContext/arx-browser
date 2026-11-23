import BrowserCore
import CustomDump
import Foundation
import LiveFolderClient
import Testing

/// DEV-926: GitHub pull requests as a live folder source, through a fake transport.
internal struct LiveFolderClientTests {
	private final class Requests: @unchecked Sendable {
		private let lock: NSLock = .init()
		private var _sent: [URLRequest] = []

		internal var sent: [URLRequest] { lock.withLock { _sent } }

		internal func append(_ request: URLRequest) { lock.withLock { _sent.append(request) } }
	}

	private static let search: String = """
	{"total_count": 3, "incomplete_results": false, "items": [
		{"id": 101, "number": 12, "title": "Add live folders", "html_url": "https://github.com/arx/browser/pull/12",
		 "repository_url": "https://api.github.com/repos/arx/browser", "pull_request": {}},
		{"id": 102, "number": 3, "title": "Elsewhere", "html_url": "https://example.org/pull/3",
		 "repository_url": "https://api.github.com/repos/arx/other"},
		{"id": 103, "number": 7, "title": "Fix the build", "html_url": "https://github.com/arx/manual/pull/7",
		 "repository_url": "https://api.github.com/repos/arx/manual"}
	]}
	"""

	private static func client(
		token: String?,
		status: Int = 200,
		headers: [String: String] = [:],
		body: String = search,
		requests: Requests = .init()
	) -> LiveFolderClient {
		.running(
			accounts: .init { _ in token },
			transport: { request in
				requests.append(request)
				let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
				return (Data(body.utf8), response)
			}
		)
	}

	@Test
	internal func withoutAnAccountNothingIsAsked() async throws {
		let requests: Requests = .init()
		let client = Self.client(token: nil, requests: requests)
		#expect(await client.isAvailable(.gitHubPullRequests(.authored)) == false)
		await #expect(throws: LiveFolderFailure.notSignedIn) {
			try await client.fetch(.gitHubPullRequests(.authored))
		}
		#expect(requests.sent.isEmpty)
		// What ships until an account is decided.
		#expect(await LiveFolderClient.liveValue.isAvailable(.gitHubPullRequests(.reviewRequested)) == false)
	}

	@Test(arguments: [
		(LiveFolderSource.GitHubPullRequestFilter.authored, "is:pr is:open archived:false author:@me"),
		(.reviewRequested, "is:pr is:open archived:false review-requested:@me"),
	])
	internal func theSearchCarriesOnlyTheQueryAndTheToken(
		_ filter: LiveFolderSource.GitHubPullRequestFilter,
		_ query: String
	) async throws {
		let requests: Requests = .init()
		let client = Self.client(token: "fixture-token", requests: requests)
		let items = try await client.fetch(.gitHubPullRequests(filter))

		let request = try #require(requests.sent.first)
		let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
		#expect(components.host == "api.github.com")
		#expect(components.path == "/search/issues")
		expectNoDifference(components.queryItems?.first { $0.name == "q" }?.value, query)
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
		#expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
		#expect(!request.httpShouldHandleCookies)

		// Pages outside github.com are left out.
		expectNoDifference(items, [
			.init(id: "github-pr-101", title: "Add live folders", url: URL(string: "https://github.com/arx/browser/pull/12")!, detail: "arx/browser #12"),
			.init(id: "github-pr-103", title: "Fix the build", url: URL(string: "https://github.com/arx/manual/pull/7")!, detail: "arx/manual #7"),
		])
	}

	@Test(arguments: [
		(401, [String: String](), LiveFolderFailure.unauthorized),
		(403, ["x-ratelimit-remaining": "0"], .rateLimited),
		(403, ["x-ratelimit-remaining": "12"], .unauthorized),
		(429, [:], .rateLimited),
		(500, [:], .unexpectedResponse),
	])
	internal func failuresSayWhatWentWrong(
		_ status: Int,
		_ headers: [String: String],
		_ failure: LiveFolderFailure
	) async throws {
		let client = Self.client(token: "fixture-token", status: status, headers: headers)
		await #expect(throws: failure) {
			try await client.fetch(.gitHubPullRequests(.authored))
		}
	}

	@Test
	internal func aResponseOfAnotherShapeIsUnexpected() async throws {
		let client = Self.client(token: "fixture-token", body: #"{"message": "Not Found"}"#)
		await #expect(throws: LiveFolderFailure.unexpectedResponse) {
			try await client.fetch(.gitHubPullRequests(.authored))
		}
	}
}
