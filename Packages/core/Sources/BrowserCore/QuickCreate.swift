import Foundation

/// The command bar's quick-create rows (DEV-895): "new doc", "create sheet" or a bare
/// `.new` domain lists the services that make a new document, meeting or issue at a
/// `.new` address. A constant table; nothing is looked up.
public enum QuickCreate {
	public struct Target: Equatable, Identifiable, Sendable {
		/// The `.new` host, which is also the target's identity.
		public var host: String
		public var title: String

		/// Words that find it after "new" or "create", most specific first.
		public var keywords: [String]
		public var symbol: String

		public var id: String { host }

		public init(
			host: String,
			title: String,
			keywords: [String],
			symbol: String
		) {
			self.host = host
			self.title = title
			self.keywords = keywords
			self.symbol = symbol
		}

		public var url: URL {
			URL(string: "https://" + host)!
		}
	}

	public static let targets: [Target] = [
		.init(host: "docs.new", title: "Google Docs document", keywords: ["doc", "docs", "document", "google"], symbol: "doc.text"),
		.init(host: "sheets.new", title: "Google Sheets spreadsheet", keywords: ["sheet", "sheets", "spreadsheet", "google"], symbol: "tablecells"),
		.init(host: "slides.new", title: "Google Slides presentation", keywords: ["slide", "slides", "presentation", "deck", "google"], symbol: "rectangle.on.rectangle"),
		.init(host: "forms.new", title: "Google Forms form", keywords: ["form", "forms", "survey", "google"], symbol: "list.bullet.rectangle"),
		.init(host: "meet.new", title: "Google Meet meeting", keywords: ["meeting", "meet", "call", "video", "google"], symbol: "video"),
		.init(host: "cal.new", title: "Google Calendar event", keywords: ["event", "calendar", "cal", "meeting", "google"], symbol: "calendar"),
		.init(host: "notion.new", title: "Notion page", keywords: ["notion", "page", "note"], symbol: "doc.richtext"),
		.init(host: "linear.new", title: "Linear issue", keywords: ["linear", "issue", "ticket"], symbol: "checklist"),
		.init(host: "jira.new", title: "Jira issue", keywords: ["jira", "issue", "ticket"], symbol: "checklist"),
		.init(host: "confluence.new", title: "Confluence page", keywords: ["confluence", "page", "wiki"], symbol: "doc.richtext"),
		.init(host: "gist.new", title: "GitHub gist", keywords: ["gist", "github", "snippet"], symbol: "chevron.left.forwardslash.chevron.right"),
		.init(host: "repo.new", title: "GitHub repository", keywords: ["repo", "repository", "github"], symbol: "folder"),
		.init(host: "figma.new", title: "Figma design file", keywords: ["figma", "design"], symbol: "paintbrush"),
		.init(host: "figjam.new", title: "FigJam board", keywords: ["figjam", "board", "whiteboard"], symbol: "scribble"),
		.init(host: "word.new", title: "Word document", keywords: ["word", "document", "doc", "microsoft"], symbol: "doc.text"),
		.init(host: "excel.new", title: "Excel workbook", keywords: ["excel", "workbook", "spreadsheet", "sheet", "microsoft"], symbol: "tablecells"),
		.init(host: "powerpoint.new", title: "PowerPoint presentation", keywords: ["powerpoint", "presentation", "deck", "slide", "microsoft"], symbol: "rectangle.on.rectangle"),
	]

	/// The words that start a request.
	public static let verbs: [String] = ["new", "create"]

	/// What `text` asks to create, best match first.
	///
	/// - "new" or "create" alone lists every target.
	/// - "new doc" lists targets with a keyword or title word starting with "doc", exact
	///   keywords first.
	/// - A bare `.new` domain ("docs.new", "excalidraw.new") is that domain: the known target,
	///   or a target named after it.
	public static func targets(for text: String) -> [Target] {
		let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if let target = domain(input) { return [target] }

		let words = input.split(whereSeparator: \.isWhitespace).map(String.init)
		guard let verb = words.first, verbs.contains(verb) else { return [] }

		let wanted = words.dropFirst().joined(separator: " ")
		guard !wanted.isEmpty else { return targets }

		// An exact keyword, then a keyword it starts, then a word of the title; the table's
		// order within each.
		var ranked: [(target: Target, rank: Int, order: Int)] = []
		for (order, target) in targets.enumerated() {
			let rank: Int? = if target.keywords.contains(wanted) {
				0
			} else if target.keywords.contains(where: { $0.hasPrefix(wanted) }) {
				1
			} else if target.title.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(wanted) }) {
				2
			} else {
				nil
			}
			guard let rank else { continue }

			ranked.append((target, rank, order))
		}
		return ranked
			.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
			.map(\.target)
	}

	/// A bare `.new` domain: letters, digits and hyphens, then `.new`.
	private static func domain(_ input: String) -> Target? {
		guard input.hasSuffix(".new") else { return nil }

		let name = input.dropLast(4)
		let isLabel = !name.isEmpty
		&& name.count <= 63
		&& !name.hasPrefix("-")
		&& !name.hasSuffix("-")
		&& name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
		guard isLabel else { return nil }

		if let known = targets.first(where: { $0.host == input }) { return known }
		return .init(host: input, title: input, keywords: [], symbol: "plus.square")
	}
}
