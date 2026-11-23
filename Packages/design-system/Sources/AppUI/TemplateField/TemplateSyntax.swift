import Foundation

/// A value a template can substitute, such as `{path}`.
public struct TemplatePlaceholder: Identifiable, Equatable, Sendable {
	public var name: String
	public var title: String
	public var symbol: String

	public init(
		name: String,
		title: String,
		symbol: String
	) {
		self.name = name
		self.title = title
		self.symbol = symbol
	}

	public var id: String { name }
}

/// Where placeholders are in a template and what could complete one. Offsets are UTF-16, as in AppKit's text system.
public enum TemplateSyntax {
	public struct Token: Equatable, Sendable {
		public var range: NSRange
		public var name: String
		public var isClosed: Bool

		public init(
			range: NSRange,
			name: String,
			isClosed: Bool
		) {
			self.range = range
			self.name = name
			self.isClosed = isClosed
		}
	}

	/// The placeholder being typed at the caret.
	public struct Completion: Equatable, Sendable {
		public var start: Int
		public var prefix: String

		public init(
			start: Int,
			prefix: String
		) {
			self.start = start
			self.prefix = prefix
		}
	}

	public static func tokens(in text: String) -> [Token] {
		let units = Array(text.utf16)
		var tokens: [Token] = []
		var index = 0
		while index < units.count {
			guard units[index] == brace.open else {
				index += 1
				continue
			}
			var end = index + 1
			while end < units.count, units[end] != brace.close, units[end] != brace.open { end += 1 }
			let isClosed = end < units.count && units[end] == brace.close
			let nameEnd = end
			let length = (isClosed ? end + 1 : end) - index
			let token: Token = .init(
				range: NSRange(location: index, length: length),
				name: String(decoding: units[(index + 1)..<nameEnd], as: UTF16.self),
				isClosed: isClosed
			)
			tokens.append(token)
			index += length
		}
		return tokens
	}

	public static func completion(
		in text: String,
		caret: Int
	) -> Completion? {
		let units = Array(text.utf16)
		guard caret <= units.count else { return nil }
		var index = caret - 1
		while index >= 0 {
			let unit = units[index]
			if unit == brace.open {
				let prefix = String(decoding: units[(index + 1)..<caret], as: UTF16.self)
				return .init(start: index, prefix: prefix)
			}
			guard
				let scalar = Unicode.Scalar(unit),
				CharacterSet.alphanumerics.contains(scalar)
			else { return nil }
			index -= 1
		}
		return nil
	}

	/// Each placeholder fills one place in a URL, so one already used isn't offered again.
	public static func options(
		for completion: Completion,
		from placeholders: [TemplatePlaceholder],
		in text: String
	) -> [TemplatePlaceholder] {
		let usedTokens = tokens(in: text).filter { token in
			token.isClosed && token.range.location != completion.start
		}
		let used: Set<String> = Set(usedTokens.map(\.name))
		let prefix = completion.prefix.lowercased()
		return placeholders.filter { placeholder in
			let matchesPrefix = prefix.isEmpty
			|| placeholder.name.hasPrefix(prefix)
			|| placeholder.title.lowercased().hasPrefix(prefix)

			return !used.contains(placeholder.name) && matchesPrefix
		}
	}

	/// Writes the whole placeholder over what was typed, including a closing brace already there.
	public static func accepting(
		_ placeholder: TemplatePlaceholder,
		for completion: Completion,
		in text: String,
		caret: Int
	) -> (text: String, caret: Int) {
		let units = Array(text.utf16)
		let tail = caret < units.count && units[caret] == brace.close ? caret + 1 : caret
		let replacement = Array("{\(placeholder.name)}".utf16)
		let result = Array(units[..<completion.start]) + replacement + Array(units[tail...])
		return (String(decoding: result, as: UTF16.self), completion.start + replacement.count)
	}

	private static let brace: (open: UInt16, close: UInt16) = (
		open: UInt16(UInt8(ascii: "{")),
		close: UInt16(UInt8(ascii: "}"))
	)
}
