import Foundation

/// What a page says it has unread (DEV-907): nothing, something (a dot), or a count.
public enum UnreadBadge: Equatable, Hashable, Codable, Sendable {
	case none
	case dot
	case count(Int)

	/// Counts above this show as "999+".
	public static let maximumCount: Int = 999

	/// The badge a page title reports, as many sites put their unread count in it: "(3) Home / X",
	/// "Inbox (3) - Mail", "[3] Chat", or a leading "•" or "●" for unread without a count. A
	/// count of zero, or a title without one, reports nothing.
	public init(title: String) {
		let title = title.trimmingCharacters(in: .whitespaces)
		if let count = Self.leadingCount(title) ?? Self.labelledCount(title) {
			self = count > 0 ? .count(count) : .none
		} else if let first = title.first, ["•", "●"].contains(first), title.count > 1 {
			self = .dot
		} else {
			self = .none
		}
	}

	/// The Badging API's report: `navigator.setAppBadge()` with no number is a dot, a number a
	/// count, and zero or `clearAppBadge()` nothing.
	public init(appBadge count: UInt64?) {
		guard let count else {
			self = .dot
			return
		}

		self = count == 0 ? .none : .count(Int(min(count, UInt64(Int.max))))
	}

	public var isVisible: Bool { self != .none }

	/// "(3) …", "(99+) …" or "[3] …" at the start.
	private static func leadingCount(_ title: String) -> Int? {
		guard let open = title.first, open == "(" || open == "[" else { return nil }

		let close: Character = open == "(" ? ")" : "]"
		guard let end = title.firstIndex(of: close) else { return nil }

		return number(title[title.index(after: title.startIndex)..<end])
	}

	/// "Inbox (3) - …" or "Inbox (3)": a one-word label, the count in parentheses, then a separator
	/// or the end, as mail and chat sites write it.
	private static func labelledCount(_ title: String) -> Int? {
		guard
			let open = title.firstIndex(of: "("),
			open > title.startIndex,
			title.distance(from: title.startIndex, to: open) <= 24,
			let close = title[open...].firstIndex(of: ")")
		else { return nil }

		// One word, as "Inbox" or "Chat", so a name such as "The Beatles (1968)" isn't a count.
		let label = title[..<open]
		guard
			label.last == " ",
			label.dropLast().allSatisfy(\.isLetter)
		else { return nil }

		let rest = title[title.index(after: close)...].trimmingCharacters(in: .whitespaces)
		guard rest.isEmpty || ["-", "–", "—", "|", "·"].contains(where: rest.hasPrefix)
		else { return nil }

		return number(title[title.index(after: open)..<close])
	}

	private static func number(_ text: Substring) -> Int? {
		var digits = text.trimmingCharacters(in: .whitespaces)
		if digits.hasSuffix("+") { digits.removeLast() }
		guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isASCII), let value = Int(digits)
		else { return nil }

		return value
	}
}

extension Tab {
	/// The site whose unread badges Settings can hide (DEV-907): the page's host, without "www.".
	public var unreadBadgeHost: String? {
		Self.unreadBadgeHost(of: restoration.url)
	}

	public static func unreadBadgeHost(of url: URL) -> String? {
		guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }

		if host.hasPrefix("www.") { host.removeFirst(4) }
		return host
	}
}
