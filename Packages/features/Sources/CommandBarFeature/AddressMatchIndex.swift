import Foundation

/// The page addresses of a command bar's candidates, sorted for prefix search, to find the page
/// the typed text leads toward. That page leads the results and is highlighted, so Return opens
/// it; the field still shows only what was typed (DEV-1223).
///
/// It's built once per presentation, so each keystroke is a binary search plus a scan of the
/// addresses that start with the query.
public struct AddressMatchIndex: Equatable, Sendable {
	private struct Key: Equatable, Sendable {
		internal var folded: String
		internal var text: String
		internal var rank: Int
		internal var entryID: String

		/// The candidate's history score (DEV-1015).
		internal var frecency: Double
	}

	private var keys: [Key]

	public static let empty: Self = .init([])

	public init(_ candidates: [CommandBarFeature.Entry]) {
		var keys: [Key] = []
		for (rank, candidate) in candidates.enumerated() {
			guard let url = candidate.pageURL else { continue }

			for text in Self.forms(of: url) {
				keys.append(.init(
					folded: text.lowercased(),
					text: text,
					rank: rank,
					entryID: candidate.presentation.id,
					frecency: candidate.frecency
				))
			}
		}
		keys.sort { ($0.folded, $0.rank) < ($1.folded, $1.rank) }
		self.keys = keys
	}

	/// The candidate whose listed address starts with `typed`, ignoring case, that the person
	/// most likely means (DEV-1015): while no `/` is typed, a site's front page before its other
	/// pages; then the higher history score, so a frequently typed address beats a shorter one
	/// rarely visited; then the shorter address; then the earlier candidate. Text with spaces and
	/// `!bangs` never match.
	public func entryID(matching typed: String) -> String? {
		guard
			!typed.isEmpty,
			!typed.hasPrefix("!"),
			!typed.contains(where: \.isWhitespace)
		else { return nil }

		let folded = typed.lowercased()
		var lower = 0
		var upper = keys.count
		while lower < upper {
			let middle = (lower + upper) / 2
			if keys[middle].folded < folded {
				lower = middle + 1
			} else {
				upper = middle
			}
		}

		let prefersFrontPages = !typed.contains("/")
		var best: Key?
		var position = lower
		while position < keys.count, keys[position].folded.hasPrefix(folded) {
			let key = keys[position]
			position += 1
			guard key.text.count >= typed.count else { continue }

			if let current = best, !Self.ranks(key, before: current, prefersFrontPages: prefersFrontPages) { continue }
			best = key
		}
		return best?.entryID
	}

	/// Whether `key` is the better match than `current`.
	private static func ranks(
		_ key: Key,
		before current: Key,
		prefersFrontPages: Bool
	) -> Bool {
		if prefersFrontPages {
			let isFrontPage = !key.text.contains("/")
			if isFrontPage != !current.text.contains("/") { return isFrontPage }
		}
		if key.frecency != current.frecency { return key.frecency > current.frecency }
		return (key.text.count, key.rank) < (current.text.count, current.rank)
	}

	/// How a person types toward a web page: without the scheme and `www.`, with `www.`, and in full.
	/// A site's front page drops its trailing slash.
	internal static func forms(of url: URL) -> [String] {
		guard
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			url.host() != nil,
			url.user() == nil
		else { return [] }

		let full = url.absoluteString
		let separator = scheme + "://"
		guard full.lowercased().hasPrefix(separator) else { return [full] }

		var bare = String(full.dropFirst(separator.count))
		if bare.hasSuffix("/"), url.path() == "/", url.query() == nil, url.fragment() == nil {
			bare.removeLast()
		}
		guard bare.lowercased().hasPrefix("www.") else { return [bare, full] }

		return [String(bare.dropFirst(4)), bare, full]
	}
}

extension CommandBarFeature.Entry {
	/// The web page this entry opens or switches to, if any.
	public var pageURL: URL? {
		switch intent {
		case let .open(url): url
		case let .openHistory(selection): selection.url
		case .selectTab: presentation.siteIcon?.pageURL
		default: nil
		}
	}
}
