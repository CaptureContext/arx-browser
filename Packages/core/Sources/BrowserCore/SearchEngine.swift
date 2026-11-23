import Foundation

/// Where a profile sends text that isn't an address.
public enum SearchEngine: String, CaseIterable, Codable, Sendable {
	case google
	case duckDuckGo
	case bing
	case brave
	case kagi
	case ecosia
	case startpage
	case perplexity

	public var title: String {
		switch self {
		case .google: "Google"
		case .duckDuckGo: "DuckDuckGo"
		case .bing: "Bing"
		case .brave: "Brave Search"
		case .kagi: "Kagi"
		case .ecosia: "Ecosia"
		case .startpage: "Startpage"
		case .perplexity: "Perplexity"
		}
	}

	/// A provider's public, anonymous OpenSearch suggestion service. No fallback provider.
	/// Kagi and Perplexity have no anonymous suggestion endpoint configured.
	public var suggestionEndpoint: URL? {
		let address: String? = switch self {
		case .google: "https://suggestqueries.google.com/complete/search?client=firefox"
		case .duckDuckGo: "https://duckduckgo.com/ac/?type=list"
		case .bing: "https://api.bing.com/osjson.aspx"
		case .brave: "https://search.brave.com/api/suggest?rich=false"
		case .ecosia: "https://ac.ecosia.org/autocomplete?type=list"
		case .startpage: "https://www.startpage.com/osuggestions"
		case .kagi, .perplexity: nil
		}
		return address.flatMap(URL.init(string:))
	}

	private var endpoint: (host: String, path: String) {
		switch self {
		case .google: ("www.google.com", "/search")
		case .duckDuckGo: ("duckduckgo.com", "/")
		case .bing: ("www.bing.com", "/search")
		case .brave: ("search.brave.com", "/search")
		case .kagi: ("kagi.com", "/search")
		case .ecosia: ("www.ecosia.org", "/search")
		case .startpage: ("www.startpage.com", "/search")
		case .perplexity: ("www.perplexity.ai", "/search")
		}
	}

	public func url(for query: String) -> URL? {
		var components = URLComponents()
		components.scheme = "https"
		components.host = endpoint.host
		components.path = endpoint.path
		components.queryItems = [.init(name: "q", value: query)]
		return components.url
	}
}
