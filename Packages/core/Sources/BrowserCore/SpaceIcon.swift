/// Portable space presentation; renderer and profile ownership are independent of the icon.
///
/// A symbol's name or an emoji. Snapshots store the same plain string the older closed set did.
public struct SpaceIcon: RawRepresentable, Hashable, Codable, Sendable {
	public static let stack: Self = .init(symbol: "square.stack")
	public static let briefcase: Self = .init(symbol: "briefcase")
	public static let house: Self = .init(symbol: "house")
	public static let code: Self = .init(symbol: "chevron.left.forwardslash.chevron.right")
	public static let book: Self = .init(symbol: "book")
	public static let globe: Self = .init(symbol: "globe")
	public static let leaf: Self = .init(symbol: "leaf")
	public static let heart: Self = .init(symbol: "heart")
	public static let star: Self = .init(symbol: "star")
	public static let music: Self = .init(symbol: "music.note")
	public static let game: Self = .init(symbol: "gamecontroller")
	public static let plane: Self = .init(symbol: "airplane")

	/// What a space with no icon of its own shows (DEV-1251): the dot the collapsed space switcher
	/// draws. Only for drawing; a space without a chosen icon stores none.
	public static let dot: Self = .init(symbol: "arx.dot")

	public let rawValue: String

	public init?(rawValue: String) {
		guard !rawValue.isEmpty else { return nil }
		self.rawValue = rawValue
	}

	public init(symbol: String) {
		self.rawValue = symbol
	}

	public init(emoji: Character) {
		self.rawValue = String(emoji)
	}

	/// Symbol names are always ASCII, and no emoji starts with it.
	public var isEmoji: Bool {
		rawValue.unicodeScalars.first?.isASCII == false
	}

	/// For places that can only draw a symbol.
	public var symbolName: String {
		if self == .dot { return "circle.fill" }
		return isEmoji ? Self.stack.rawValue : rawValue
	}
}
