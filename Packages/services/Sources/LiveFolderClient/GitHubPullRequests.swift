import BrowserCore
import Foundation

/// GitHub's pull requests as a live folder source (DEV-926), through the REST search API:
/// `is:pr is:open archived:false` with `author:@me` or `review-requested:@me`, most
/// recently updated first, at most 50.
///
/// Only the token and the query leave the Mac. Checks, stacks and drafts aren't read yet.
public enum GitHubPullRequests {
	public static let endpoint: URL = URL(string: "https://api.github.com/search/issues")!
	public static let pageSize: Int = 50

	public static func query(_ filter: LiveFolderSource.GitHubPullRequestFilter) -> String {
		let who: String = switch filter {
		case .authored: "author:@me"
		case .reviewRequested: "review-requested:@me"
		}
		return "is:pr is:open archived:false \(who)"
	}

	public static func request(
		_ filter: LiveFolderSource.GitHubPullRequestFilter,
		token: String
	) -> URLRequest {
		var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
		components.queryItems = [
			.init(name: "q", value: query(filter)),
			.init(name: "sort", value: "updated"),
			.init(name: "order", value: "desc"),
			.init(name: "per_page", value: "\(pageSize)"),
		]
		var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
		request.httpShouldHandleCookies = false
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
		request.setValue("Arx", forHTTPHeaderField: "User-Agent")
		return request
	}

	/// The pull requests in a search response: each one's title, page and `owner/repo #number`.
	public static func items(
		_ data: Data,
		response: URLResponse
	) throws(LiveFolderFailure) -> [LiveFolderItem] {
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		switch status {
		case 200: break
		case 401: throw .unauthorized
		case 403, 429:
			// GitHub answers 403 both for a missing scope and for the rate limit.
			let remaining = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining")
			throw status == 429 || remaining == "0" ? .rateLimited : .unauthorized
		default: throw .unexpectedResponse
		}

		guard
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let entries = object["items"] as? [[String: Any]]
		else { throw .unexpectedResponse }

		return entries.compactMap { entry in
			guard
				let id = (entry["id"] as? NSNumber)?.int64Value,
				let title = entry["title"] as? String,
				let link = entry["html_url"] as? String,
				let url = URL(string: link),
				url.scheme == "https",
				url.host() == "github.com"
			else { return nil }

			// `https://api.github.com/repos/owner/repo` names the repository.
			let repository = (entry["repository_url"] as? String)
				.flatMap(URL.init(string:))
				.map { $0.pathComponents.suffix(2).joined(separator: "/") }
			let number = (entry["number"] as? NSNumber).map { "#\($0.intValue)" }
			let detail = [repository, number].compactMap { $0 }.joined(separator: " ")
			return .init(id: "github-pr-\(id)", title: title, url: url, detail: detail)
		}
	}
}
