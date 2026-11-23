import BrowserCore
import Foundation
import _Dependencies

/// Search suggestions from the profile's selected provider for text typed in the command bar.
///
/// Only the typed text leaves the Mac: the request carries no cookies, no credentials and
/// nothing about the page or the profile. Profiles turn it off in Settings, and private
/// windows never ask.
public struct SearchSuggestionsClient: Sendable {
	/// Whether this run may ask at all. Test, smoke and headless runs never do.
	public var isAvailable: Bool

	/// Suggestions for `query`, best first.
	public var fetch: @Sendable (_ query: String, _ engine: SearchEngine) async throws -> [String]

	public init(
		isAvailable: Bool,
		fetch: @escaping @Sendable (_ query: String, _ engine: SearchEngine) async throws -> [String]
	) {
		self.isAvailable = isAvailable
		self.fetch = fetch
	}
}

extension SearchSuggestionsClient {
	public enum Failure: Error, Equatable, Sendable {
		case unexpectedResponse
	}

	/// The selected provider's endpoint, without cookies or a fallback to another provider.
	public static func request(
		for query: String,
		engine: SearchEngine,
		language: String? = Locale.current.language.languageCode?.identifier
	) -> URLRequest? {
		guard
			let endpoint = engine.suggestionEndpoint,
			var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
		else { return nil }

		var items: [URLQueryItem] = components.queryItems ?? []
		items.append(.init(name: engine == .bing ? "query" : "q", value: query))
		if engine == .google, let language { items.append(.init(name: "hl", value: language)) }
		components.queryItems = items

		// URLComponents leaves `+`, which the endpoint reads as a space: `c++` would become `c  `.
		let encoded: String? = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
		components.percentEncodedQuery = encoded
		guard let url = components.url else { return nil }

		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
		request.httpShouldHandleCookies = false
		return request
	}

	/// Reads `["query", ["suggestion", …], …]`, keeping non-empty suggestions in order.
	public static func suggestions(from data: Data) throws -> [String] {
		guard
			let array = try JSONSerialization.jsonObject(with: data) as? [Any],
			array.count >= 2,
			let suggestions = array[1] as? [Any]
		else { throw Failure.unexpectedResponse }

		return suggestions.compactMap { value in
			guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
			else { return nil }
			return text
		}
	}

	/// Whether a launch may send typed text to the provider.
	public static func isAvailable(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		let automationKeys: [String] = [
			"ARX_SKIP_REMOTE_SUGGESTIONS",
			"ARX_ENGINE_PROFILE",
			"XCTestConfigurationFilePath",
			"XCTestBundlePath",
			"XCTestSessionIdentifier",
		]
		guard automationKeys.allSatisfy({ environment[$0] == nil })
		else { return false }

		return !arguments.dropFirst().contains { argument in
			argument == "--headless" || argument.hasPrefix("--arx-")
		}
	}

	public static var live: Self {
		let configuration: URLSessionConfiguration = .ephemeral
		configuration.httpCookieStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.urlCredentialStorage = nil
		configuration.urlCache = nil
		let session = URLSession(configuration: configuration)
		let process = ProcessInfo.processInfo

		return .init(
			isAvailable: isAvailable(environment: process.environment, arguments: process.arguments),
			fetch: { query, engine in
				guard let request = request(for: query, engine: engine) else { return [] }

				let (data, response) = try await session.data(for: request)
				guard (response as? HTTPURLResponse)?.statusCode == 200
				else { throw Failure.unexpectedResponse }

				return try suggestions(from: data)
			}
		)
	}
}

extension SearchSuggestionsClient: DependencyKey {
	public static var liveValue: Self { .live }

	/// Unavailable, so a command bar under test never asks unless the test supplies a client.
	public static var testValue: Self {
		.init(isAvailable: false, fetch: { _, _ in [] })
	}

	public static var previewValue: Self {
		.init(isAvailable: false, fetch: { _, _ in [] })
	}
}

extension DependencyValues {
	public var searchSuggestions: SearchSuggestionsClient {
		get { self[SearchSuggestionsClient.self] }
		set { self[SearchSuggestionsClient.self] = newValue }
	}
}
