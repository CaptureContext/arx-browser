import Foundation

/// Resolves a local search URL. Identity and browser-profile routing are separate concerns.
public struct SearchShortcut: Identifiable, Codable, Equatable, Sendable {
	public var id: String { keyword.lowercased() }
	public var name: String
	public var keyword: String
	public var template: String
	public var homepage: URL?
	public var isEnabled: Bool

	public init(
		name: String,
		keyword: String,
		template: String,
		homepage: URL? = nil,
		isEnabled: Bool = true
	) {
		self.name = name
		self.keyword = keyword
		self.template = template
		self.homepage = homepage
		self.isEnabled = isEnabled
	}

	public enum Failure: Error {
		case invalidDefinition
		case duplicateKeyword
		case queryRequired
	}

	public func validate() throws {
		let keywordCharacters: CharacterSet = .init(
			charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
		)
		guard
			!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			!keyword.isEmpty,
			keyword.unicodeScalars.allSatisfy(keywordCharacters.contains),
			template.components(separatedBy: "{query}").count == 2
		else { throw Failure.invalidDefinition }
		let sentinel = "ARXQUERYPLACEHOLDER"
		let sentinelTemplate = template.replacingOccurrences(of: "{query}", with: sentinel)
		guard
			!template.contains(sentinel),
			let parts = URLComponents(string: sentinelTemplate),
			["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
			let host = parts.host,
			!host.isEmpty,
			!host.contains(sentinel),
			parts.user == nil,
			parts.password == nil,
			parts.fragment?.contains(sentinel) != true
		else { throw Failure.invalidDefinition }
		let queryValue = parts.queryItems?
			.contains { $0.value == sentinel && !$0.name.contains(sentinel) } ?? false
		let pathSegment = parts.path.split(separator: "/").contains(Substring(sentinel))
		guard queryValue || pathSegment else { throw Failure.invalidDefinition }
		if let homepage {
			guard
				homepage.hasWebScheme,
				homepage.host() != nil
			else { throw Failure.invalidDefinition }
		}
	}

	/// The front page of the site this shortcut searches, whose stored icon stands for it in the
	/// command bar (DEV-1311).
	public var site: URL? { Self.site(ofTemplate: template) }

	/// The front page of the site a search template belongs to: `https://github.com/` for
	/// `https://github.com/search?q={query}`. Nil unless the template is an HTTP(S) address whose
	/// host doesn't depend on the query.
	public static func site(ofTemplate template: String) -> URL? {
		let sentinel = "ARXQUERYPLACEHOLDER"
		guard
			let parts = URLComponents(string: template.replacingOccurrences(of: "{query}", with: sentinel)),
			let scheme = parts.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			let host = parts.host,
			!host.isEmpty,
			!host.contains(sentinel)
		else { return nil }

		var site = URLComponents()
		site.scheme = scheme
		site.host = host
		site.port = parts.port
		site.path = "/"
		return site.url
	}

	public func destination(for query: String) throws -> URL {
		try validate()
		guard !query.isEmpty else {
			guard let homepage else { throw Failure.queryRequired }
			return homepage
		}
		guard
			let encoded = Self.encode(query),
			let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
		else { throw Failure.invalidDefinition }
		return url
	}

	/// Percent-encodes everything but RFC 3986 unreserved characters, so the result is
	/// safe as a query value, a path segment or a fragment.
	internal static func encode(_ query: String) -> String? {
		let unreserved: CharacterSet = .init(
			charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
		)
		return query.addingPercentEncoding(withAllowedCharacters: unreserved)
	}
}
