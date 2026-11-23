import Foundation

/// A presentation projection of the application's command registry.
public struct SettingsShortcut: Equatable, Identifiable, Sendable {
	public let id: String
	public let title: String
	public let keys: String
	public let searchTerms: String

	public init(
		id: String,
		title: String,
		keys: String,
		searchTerms: String
	) {
		self.id = id
		self.title = title
		self.keys = keys
		self.searchTerms = searchTerms
	}

	public func matches(_ query: String) -> Bool {
		let terms: [String] = query
			.lowercased()
			.replacingOccurrences(of: "+", with: " ")
			.split(whereSeparator: \.isWhitespace)
			.map(String.init)
		let modifiers: Set<String> = ["cmd", "command", "option", "alt", "shift", "control", "ctrl"]

		if terms.contains(where: modifiers.contains) {
			let tokens = Set(searchTerms.lowercased().split(separator: " ").map(String.init))
			return terms.allSatisfy(tokens.contains)
		}

		let searchable = [title, keys].joined(separator: " ")
		return terms.allSatisfy { searchable.localizedStandardContains($0) }
	}
}
