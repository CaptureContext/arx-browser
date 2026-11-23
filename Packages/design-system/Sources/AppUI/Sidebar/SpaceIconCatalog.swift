import BrowserCore
import Foundation

/// What the space icon picker offers, and how a search reaches it.
public enum SpaceIconCatalog {
	public static let symbols: [String] = [
		"star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill",
		"lightbulb.fill", "seal.fill", "square.grid.2x2.fill", "circle.grid.3x3.fill", "square.stack.3d.up.fill", "cylinder.split.1x2.fill", "tray.2.fill", "square.on.square",
		"folder.fill", "tray.full.fill", "calendar", "envelope.fill", "checkmark.square.fill", "doc.fill", "book.fill", "bubble.left.fill",
		"person.2.fill", "terminal.fill", "hammer.fill", "square.fill", "circle.fill", "moon.fill", "sun.max.fill", "sparkles",
		"globe", "globe.americas.fill", "leaf.fill", "cloud.fill", "pawprint.fill", "basket.fill", "gift.fill", "bed.double.fill",
		"fork.knife", "dumbbell.fill", "airplane", "music.note", "paintpalette.fill", "video.fill", "bandage.fill", "chevron.left.forwardslash.chevron.right",
		"baseball.fill", "map.fill", "flame.fill", "gamecontroller.fill", "graduationcap.fill", "hand.thumbsup.fill", "tram.fill", "car.fill",
		"bicycle", "cart.fill", "creditcard.fill", "banknote.fill", "chart.bar.fill", "briefcase.fill", "house.fill", "building.2.fill",
		"camera.fill", "photo.fill", "film.fill", "headphones", "mic.fill", "tv.fill", "desktopcomputer", "laptopcomputer",
		"iphone", "gearshape.fill", "wrench.and.screwdriver.fill", "paperclip", "link", "lock.fill", "key.fill", "shield.fill",
		"newspaper.fill", "pencil", "scissors", "ruler.fill", "cup.and.saucer.fill", "wineglass.fill", "carrot.fill", "tree.fill",
		"mountain.2.fill", "drop.fill", "snowflake", "tortoise.fill", "hare.fill", "ant.fill", "ladybug.fill", "fish.fill",
		// Spaces saved before the wider catalog keep their own choice selectable.
		"square.stack", "briefcase", "house", "book", "leaf", "heart", "star", "gamecontroller",
	]

	public static let emoji: [Character] = {
		let ranges: [ClosedRange<UInt32>] = [
			0x1F600...0x1F64F,
			0x1F900...0x1F9FF,
			0x1F300...0x1F5FF,
			0x1F680...0x1F6FF,
			0x1FA70...0x1FAFF,
			0x2600...0x27BF,
		]
		return ranges.flatMap { range in
			range.compactMap { value -> Character? in
				guard
					let scalar = Unicode.Scalar(value),
					scalar.properties.isEmojiPresentation,
					!scalar.properties.isEmojiModifier
				else { return nil }
				return Character(scalar)
			}
		}
	}()

	/// Names a person would search for that a symbol's own name doesn't contain.
	private static let synonyms: [String: String] = [
		"house.fill": "home",
		"house": "home",
		"briefcase.fill": "work job",
		"briefcase": "work job",
		"chevron.left.forwardslash.chevron.right": "code developer",
		"terminal.fill": "code console",
		"gamecontroller.fill": "game play",
		"gamecontroller": "game play",
		"cart.fill": "shop store",
		"basket.fill": "shop store",
		"creditcard.fill": "money pay",
		"banknote.fill": "money pay",
		"airplane": "plane travel",
		"tram.fill": "train travel",
		"fork.knife": "food restaurant",
		"graduationcap.fill": "school study",
		"paintpalette.fill": "art design",
		"bubble.left.fill": "chat message",
		"envelope.fill": "mail email",
		"doc.fill": "file document",
		"gearshape.fill": "settings",
		"person.2.fill": "people team",
	]

	public static func symbols(matching query: String) -> [String] {
		filtered(symbols, query: query) { title(ofSymbol: $0) + " " + (synonyms[$0] ?? "") }
	}

	public static func emoji(matching query: String) -> [Character] {
		filtered(emoji, query: query, name: title(ofEmoji:))
	}

	public static func title(ofSymbol symbol: String) -> String {
		symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ")
	}

	public static func title(ofEmoji emoji: Character) -> String {
		emoji.unicodeScalars.first?.properties.name?.lowercased() ?? ""
	}

	private static func filtered<Item>(
		_ items: [Item],
		query: String,
		name: (Item) -> String
	) -> [Item] {
		let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
		guard !terms.isEmpty else { return items }
		return items.filter { item in
			let name = name(item).lowercased()
			return terms.allSatisfy { name.contains($0) }
		}
	}
}
