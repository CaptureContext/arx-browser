import Foundation

/// Helium's !bang list, bundled as `Bangs.tsv` and indexed for per-keystroke lookups.
///
/// The list resolves after the user's own shortcuts: see `target(for:shortcuts:)`.
/// It is read from the app bundle only; nothing is fetched.
public final class BangCatalog: Sendable {
	public static func == (lhs: BangCatalog, rhs: BangCatalog) -> Bool { lhs === rhs }

	/// Bangs in source order, which ranks popular sites first.
	public let bangs: [Bang]

	/// Every keyword, sorted for prefix search, with the index of its bang.
	private let keywords: [(keyword: String, index: Int)]
	private let indexByKeyword: [String: Int]

	/// Lowercased names, parallel to `bangs`, for Settings search.
	private let searchNames: [String]

	public init(parsing text: String) {
		var bangs: [Bang] = []
		var keywords: [(keyword: String, index: Int)] = []
		var indexByKeyword: [String: Int] = [:]
		for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
			guard !line.hasPrefix("#") else { continue }

			let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
			guard
				fields.count == 4,
				!fields[1].isEmpty,
				fields[3].components(separatedBy: "{query}").count == 2
			else { continue }

			let index = bangs.count
			let lineKeywords = fields[0]
				.split(separator: " ")
				.map { $0.lowercased() }
				.filter { indexByKeyword[$0] == nil }
			guard !lineKeywords.isEmpty else { continue }

			for keyword in lineKeywords {
				indexByKeyword[keyword] = index
				keywords.append((keyword, index))
			}
			bangs.append(.init(
				name: String(fields[1]),
				keywords: lineKeywords,
				template: String(fields[3]),
				opensHomepage: fields[2] == "1"
			))
		}
		keywords.sort { $0.keyword < $1.keyword }

		self.bangs = bangs
		self.keywords = keywords
		self.indexByKeyword = indexByKeyword
		self.searchNames = bangs.map { $0.name.lowercased() }
	}

	public static let empty: BangCatalog = .init(parsing: "")

	public var keywordCount: Int { keywords.count }

	/// Reads the bundled snapshot off the caller's actor.
	@concurrent
	public static func bundled() async throws -> BangCatalog {
		guard let url = Bundle.module.url(forResource: "Bangs", withExtension: "tsv")
		else { throw Failure.missingResource }

		return BangCatalog(parsing: try String(contentsOf: url, encoding: .utf8))
	}

	public func bang(for keyword: String) -> Bang? {
		indexByKeyword[keyword.lowercased()].map { bangs[$0] }
	}

	/// The user's shortcut owns its keyword, even while disabled; the bundled list answers the rest.
	public func target(
		for keyword: String,
		shortcuts: [SearchShortcut]
	) -> BangTarget? {
		let keyword = keyword.lowercased()
		if let shortcut = shortcuts.first(where: { $0.id == keyword }) {
			return shortcut.isEnabled ? .shortcut(shortcut) : nil
		}

		return bang(for: keyword).map { .bundled(keyword: keyword, $0) }
	}

	/// Keywords starting with `prefix`, most popular bang first, then shortest keyword.
	public func matches(
		prefix: String,
		limit: Int
	) -> [Match] {
		guard limit > 0 else { return [] }

		let prefix = prefix.lowercased()
		guard !prefix.isEmpty else {
			return bangs.prefix(limit).map { Match(keyword: $0.keywords[0], bang: $0) }
		}

		var lower = 0
		var upper = keywords.count
		while lower < upper {
			let middle = (lower + upper) / 2
			if keywords[middle].keyword < prefix {
				lower = middle + 1
			} else {
				upper = middle
			}
		}

		// A bounded insertion keeps the best `limit` matches; a one-letter prefix scans
		// about a thousand keywords and sorts none of them.
		var best: [(keyword: String, index: Int)] = []
		var position = lower
		while position < keywords.count, keywords[position].keyword.hasPrefix(prefix) {
			let candidate = keywords[position]
			position += 1
			let isBetter: ((keyword: String, index: Int)) -> Bool = { other in
				(candidate.index, candidate.keyword.count) < (other.index, other.keyword.count)
			}
			guard best.count < limit || isBetter(best[best.count - 1]) else { continue }

			let insertion = best.firstIndex(where: isBetter) ?? best.count
			best.insert(candidate, at: insertion)
			if best.count > limit { best.removeLast() }
		}

		return best.map { Match(keyword: $0.keyword, bang: bangs[$0.index]) }
	}

	/// Bangs whose name contains `text` or whose keyword starts with it, in source order.
	public func search(
		_ text: String,
		limit: Int
	) -> [Bang] {
		let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let keyword = query.hasPrefix("!") ? String(query.dropFirst()) : query
		guard !keyword.isEmpty else { return Array(bangs.prefix(limit)) }

		var result: [Bang] = []
		for (index, bang) in bangs.enumerated() {
			let isMatch = searchNames[index].contains(keyword)
			|| bang.keywords.contains { $0.hasPrefix(keyword) }

			guard isMatch else { continue }

			result.append(bang)
			if result.count == limit { break }
		}
		return result
	}
}

extension BangCatalog {
	public struct Bang: Equatable, Sendable {
		public var name: String

		/// Lowercased, in source order; the first is the primary keyword.
		public var keywords: [String]

		/// An HTTP(S) URL with one `{query}`, checked by `make bangs`.
		public var template: String

		/// Whether an empty query opens the template's origin.
		public var opensHomepage: Bool

		public init(
			name: String,
			keywords: [String],
			template: String,
			opensHomepage: Bool
		) {
			self.name = name
			self.keywords = keywords
			self.template = template
			self.opensHomepage = opensHomepage
		}

		public var homepage: URL? {
			guard
				opensHomepage,
				let parts = URLComponents(string: template.replacingOccurrences(of: "{query}", with: "")),
				let scheme = parts.scheme,
				let host = parts.host
			else { return nil }

			var origin = URLComponents()
			origin.scheme = scheme
			origin.host = host
			origin.port = parts.port
			origin.path = "/"
			return origin.url
		}

		/// The front page of the site this bang searches, whose stored icon stands for it in the
		/// command bar (DEV-1311).
		public var site: URL? { SearchShortcut.site(ofTemplate: template) }

		public func destination(for query: String) throws -> URL {
			guard !query.isEmpty else {
				guard let homepage else { throw SearchShortcut.Failure.queryRequired }
				return homepage
			}

			guard
				let encoded = SearchShortcut.encode(query),
				let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)),
				url.hasWebScheme,
				url.host() != nil
			else { throw SearchShortcut.Failure.invalidDefinition }

			return url
		}
	}

	public struct Match: Equatable, Sendable {
		public var keyword: String
		public var bang: Bang

		public init(
			keyword: String,
			bang: Bang
		) {
			self.keyword = keyword
			self.bang = bang
		}
	}

	public enum Failure: Error {
		case missingResource
	}
}

extension BangCatalog: Equatable {}

extension BangCatalog: CustomReflectable {
	/// Dumps and test diffs show the size, not thirteen thousand keywords.
	public var customMirror: Mirror {
		Mirror(self, children: ["bangs": bangs.count, "keywords": keywords.count], displayStyle: .class)
	}
}

/// What a `!keyword` resolves to: the user's shortcut, or a bang from the bundled list.
public enum BangTarget: Equatable, Sendable {
	case shortcut(SearchShortcut)
	case bundled(keyword: String, BangCatalog.Bang)

	/// The lowercased keyword.
	public var id: String {
		switch self {
		case let .shortcut(shortcut): shortcut.id
		case let .bundled(keyword, _): keyword
		}
	}

	public var keyword: String {
		switch self {
		case let .shortcut(shortcut): shortcut.keyword
		case let .bundled(keyword, _): keyword
		}
	}

	public var name: String {
		switch self {
		case let .shortcut(shortcut): shortcut.name
		case let .bundled(_, bang): bang.name
		}
	}

	/// The front page of the site it searches (DEV-1311).
	public var site: URL? {
		switch self {
		case let .shortcut(shortcut): shortcut.site
		case let .bundled(_, bang): bang.site
		}
	}

	public func destination(for query: String) throws -> URL {
		switch self {
		case let .shortcut(shortcut): try shortcut.destination(for: query)
		case let .bundled(_, bang): try bang.destination(for: query)
		}
	}
}
