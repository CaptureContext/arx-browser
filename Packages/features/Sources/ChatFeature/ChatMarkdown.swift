import BrowserCore
import Foundation

/// An answer's Markdown as blocks, from Foundation's own GitHub-flavored Markdown parser
/// (`AttributedString(markdown:)` with full syntax): every block's place comes from its
/// `PresentationIntent`, its text keeps the inline intents (emphasis, code, strikethrough,
/// links).
internal enum ChatMarkdown {
	internal enum Block: Equatable, Sendable {
		case paragraph(AttributedString)
		case heading(level: Int, AttributedString)
		case list(List)
		case quote([Block])
		case code(language: String?, text: String)
		case table(Table)
		case rule
	}

	internal struct List: Equatable, Sendable {
		internal var isOrdered: Bool
		internal var items: [Item]

		internal struct Item: Equatable, Sendable {
			/// The item's number in an ordered list, as written: a list may start at any number.
			internal var ordinal: Int

			/// A task list item's box: `[ ]` or `[x]` at its start. Nil for any other item.
			internal var isChecked: Bool?
			internal var blocks: [Block]
		}
	}

	internal struct Table: Equatable, Sendable {
		internal enum Alignment: Equatable, Sendable {
			case leading
			case center
			case trailing
		}

		internal var alignments: [Alignment]
		internal var header: [AttributedString]

		/// Every row has a cell per column; a cell the row left out is empty.
		internal var rows: [[AttributedString]]
	}

	/// Splits Markdown into blocks. While an answer is still `isStreaming`, its unfinished tail
	/// is shown as it will settle: open emphasis and code are closed, and a table whose header is
	/// still arriving waits for its delimiter row instead of flashing as a paragraph of pipes.
	internal static func blocks(
		_ markdown: String,
		isStreaming: Bool = false
	) -> [Block] {
		let source: String = isStreaming ? settling(markdown) : lineEndingsNormalized(markdown)
		guard let attributed = parsed(source, sourcePositions: true)
		else { return source.isEmpty ? [] : [.paragraph(AttributedString(source))] }

		var pieces: [Piece] = []
		var textLines: Set<Int> = []
		for run in attributed.runs {
			let path: [PresentationIntent.IntentType] = run.presentationIntent.map { Array($0.components.reversed()) } ?? []
			pieces.append(.init(path: path, text: attributed[run.range]))
			if let position = run.markdownSourcePosition, position.startLine <= position.endLine {
				textLines.formUnion((position.startLine - 1)...(position.endLine - 1))
			}
		}
		let lines: [Substring] = source.split(separator: "\n", omittingEmptySubsequences: false)
		return blocks(pieces[...], depth: 0, source: .init(lines, textLines: textLines))
	}

	/// ``blocks(_:isStreaming:)`` off the main actor, for an answer too long to read while drawing.
	@concurrent
	internal nonisolated static func blocksOffMain(
		_ markdown: String,
		isStreaming: Bool
	) async -> [Block] {
		blocks(markdown, isStreaming: isStreaming)
	}

	// MARK: - Building the tree

	/// A run of text with its blocks, outermost first.
	private struct Piece {
		internal var path: [PresentationIntent.IntentType]
		internal var text: AttributedSubstring
	}

	/// The Markdown's lines, which the runs' source positions point into, and what a second read
	/// says about its rows of empty cells.
	private final class Source {
		internal let lines: [Substring]

		/// Every row of empty cells, by its line (0-based), with the table its mark landed in, and
		/// the table each line's first text is in. An empty row has no text for the parser to
		/// report, so the Markdown is read again, once for every table, with a mark in each such
		/// row's first cell: a row belongs to a table if its mark lands there, whatever its outer
		/// pipes and indentation, and not in a quote, indented code or another block after it.
		/// Each mark is known by its line, so the same character elsewhere doesn't count. Only a
		/// line the first read found no text on is marked: a lone `|` that ends a table is text
		/// there, and the mark mustn't turn it into a row.
		internal private(set) lazy var emptyRows: (marks: [Int: Int], tables: [Int: Int]) = {
			let mark: Character = "\u{E000}"
			var probe: [Substring] = lines
			var marked: Set<Int> = []
			for (index, row) in lines.enumerated() where !textLines.contains(index) && ChatMarkdown.isEmptyRow(row) {
				guard let pipe = row.firstIndex(of: "|") else { continue }
				probe[index] = row[...pipe] + String(mark) + row[row.index(after: pipe)...]
				marked.insert(index)
			}
			guard
				!marked.isEmpty,
				let attributed = ChatMarkdown.parsed(probe.joined(separator: "\n"), sourcePositions: true)
			else { return ([:], [:]) }

			var marks: [Int: Int] = [:]
			var tables: [Int: Int] = [:]
			for run in attributed.runs {
				guard
					let start = run.markdownSourcePosition?.startLine,
					let table = run.presentationIntent?.components.first(where: {
						if case .table = $0.kind { true } else { false }
					})?.identity
				else { continue }

				let line: Int = start - 1
				if tables[line] == nil { tables[line] = table }
				if marked.contains(line), attributed[run.range].characters.contains(mark) {
					marks[line] = table
				}
			}
			return (marks, tables)
		}()

		/// The lines (0-based) the first read found text on.
		private let textLines: Set<Int>

		internal init(
			_ lines: [Substring],
			textLines: Set<Int>
		) {
			self.lines = lines
			self.textLines = textLines
		}
	}

	/// The pieces at `depth` grouped by the block they share there, in order.
	private static func groups(
		_ pieces: ArraySlice<Piece>,
		depth: Int
	) -> [(intent: PresentationIntent.IntentType?, pieces: ArraySlice<Piece>)] {
		var groups: [(intent: PresentationIntent.IntentType?, pieces: ArraySlice<Piece>)] = []
		var start: Int = pieces.startIndex
		while start < pieces.endIndex {
			let intent: PresentationIntent.IntentType? = pieces[start].path[safe: depth]
			var end: Int = start + 1
			while end < pieces.endIndex, pieces[end].path[safe: depth]?.identity == intent?.identity {
				end += 1
			}
			groups.append((intent, pieces[start..<end]))
			start = end
		}
		return groups
	}

	/// `source` is the Markdown's lines, which the runs' source positions point into.
	private static func blocks(
		_ pieces: ArraySlice<Piece>,
		depth: Int,
		source: Source
	) -> [Block] {
		groups(pieces, depth: depth).compactMap { intent, pieces in
			guard let intent else {
				// Raw HTML has no block of its own: it's shown as the text it is.
				return .paragraph(text(pieces))
			}

			switch intent.kind {
			case .paragraph:
				return .paragraph(text(pieces))

			case let .header(level):
				return .heading(level: level, text(pieces))

			case let .codeBlock(language):
				return .code(language: language.flatMap { $0.isEmpty ? nil : $0 }, text: plain(pieces).trailingNewlineTrimmed)

			case .blockQuote:
				return .quote(blocks(pieces, depth: depth + 1, source: source))

			case .orderedList, .unorderedList:
				let items: [List.Item] = groups(pieces, depth: depth + 1).map { item, pieces in
					var ordinal: Int = 1
					if case let .listItem(number)? = item?.kind { ordinal = number }
					var blocks: [Block] = blocks(pieces, depth: depth + 2, source: source)
					let isChecked: Bool? = taskBox(&blocks, from: pieces.first, depth: depth + 2, source: source)
					return .init(ordinal: ordinal, isChecked: isChecked, blocks: blocks)
				}
				return .list(.init(isOrdered: intent.kind == .orderedList, items: items))

			case let .table(columns):
				return .table(table(pieces, columns: columns, depth: depth, source: source))

			case .thematicBreak:
				return .rule

			default:
				// Rows, cells and items only appear inside their own blocks.
				return .paragraph(text(pieces))
			}
		}
	}

	private static func table(
		_ pieces: ArraySlice<Piece>,
		columns: [PresentationIntent.TableColumn],
		depth: Int,
		source: Source
	) -> Table {
		let alignments: [Table.Alignment] = columns.map { column in
			switch column.alignment {
			case .center: .center
			case .right: .trailing
			default: .leading
			}
		}
		let empty: [AttributedString] = Array(repeating: .init(), count: columns.count)
		var header: [AttributedString] = empty
		var rows: [[AttributedString]] = []
		for (row, pieces) in groups(pieces, depth: depth + 1) {
			var cells: [AttributedString] = empty
			for (cell, pieces) in groups(pieces, depth: depth + 2) {
				guard
					case let .tableCell(column)? = cell?.kind,
					cells.indices.contains(column)
				else { continue }

				cells[column] = text(pieces)
			}
			switch row?.kind {
			case .tableHeaderRow:
				header = cells
			case let .tableRow(number):
				// A row of empty cells has no runs: the numbers of the rows around it leave its gap.
				while rows.count < number - 1 {
					rows.append(empty)
				}
				rows.append(cells)
			default:
				continue
			}
		}

		// Empty rows at the end leave no gap: they're the lines of bare pipes after the last
		// line with text, past the delimiter row when there's no other, that the parser counts
		// in this table whatever their outer pipes and indentation.
		if
			var next = pieces.compactMap({ $0.text.runs.first?.markdownSourcePosition?.endLine }).max(),
			let headerLine = pieces.compactMap({ $0.text.runs.first?.markdownSourcePosition?.startLine }).min()
		{
			if rows.isEmpty { next += 1 }
			let probe = source.emptyRows
			if let table = probe.tables[headerLine - 1] {
				while probe.marks[next] == table {
					rows.append(empty)
					next += 1
				}
			}
		}
		return .init(alignments: alignments, header: header, rows: rows)
	}

	/// The pieces' text with their inline intents, links and nothing else.
	private static func text(_ pieces: ArraySlice<Piece>) -> AttributedString {
		var text: AttributedString = .init()
		for piece in pieces {
			text.append(piece.text)
		}
		var cleaned: AttributedString = .init()
		for run in text.runs {
			var part: AttributedString = .init(text[run.range].characters)
			part.inlinePresentationIntent = run.inlinePresentationIntent

			// Only web links are followed; anything else stays plain text. Images show their
			// description and are never loaded, since answers can repeat untrusted page content.
			if let link = run.link, link.hasWebScheme {
				part.link = link
			}
			cleaned.append(part)
		}
		return cleaned
	}

	private static func plain(_ pieces: ArraySlice<Piece>) -> String {
		pieces.map { String($0.text.characters) }.joined()
	}

	/// A table row of empty cells: nothing but pipes and spaces, after the quote markers and
	/// indentation of the blocks it's in.
	private static func isEmptyRow(_ line: Substring) -> Bool {
		let row: Substring = line.drop { $0 == ">" || $0.isWhitespace }
		return row.first == "|" && row.allSatisfy { $0 == "|" || $0.isWhitespace }
	}

	/// Takes a task list item's `[ ]` or `[x]` off its first paragraph. Only a box written as one
	/// counts: the source must have it where the paragraph starts, so `` `[x]` `` and `\[x]` stay
	/// text.
	private static func taskBox(
		_ blocks: inout [Block],
		from first: Piece?,
		depth: Int,
		source: Source
	) -> Bool? {
		guard
			case let .paragraph(text)? = blocks.first,
			let first,
			first.path[safe: depth]?.kind == .paragraph,
			let run = first.text.runs.first,
			run.inlinePresentationIntent?.contains(.code) != true,
			let position = run.markdownSourcePosition,
			source.lines.indices.contains(position.startLine - 1)
		else { return nil }

		let written: Substring.UTF8View = source.lines[position.startLine - 1].utf8.dropFirst(position.startColumn - 1)
		guard ["[ ] ", "[x] ", "[X] "].contains(where: { written.starts(with: $0.utf8) })
		else { return nil }

		let characters: String = .init(text.characters.prefix(4))
		let isChecked: Bool
		switch characters {
		case "[ ] ": isChecked = false
		case "[x] ", "[X] ": isChecked = true
		default: return nil
		}
		blocks[0] = .paragraph(AttributedString(text[text.index(text.startIndex, offsetByCharacters: 4)...]))
		return isChecked
	}

	// MARK: - Streaming

	/// The Markdown an unfinished answer settles to, as far as its tail can tell. Only the tail
	/// changes: everything before it is already what it will be.
	internal static func settling(_ markdown: String) -> String {
		let markdown: String = lineEndingsNormalized(markdown)
		var lines: [Substring] = markdown.split(separator: "\n", omittingEmptySubsequences: false)
		let tail: [PresentationIntent.Kind] = lastBlocks(markdown)

		// Code is drawn as written, open or not, fenced in a list or a quote or indented: a tail
		// in code is left as it is.
		if tail.contains(where: \.isCodeBlock) { return markdown }

		// A table's header, and its delimiter row while it's arriving, read as a paragraph of
		// pipes until the delimiter row is whole: they wait for it. A tail already in a table is
		// one of its rows.
		let end: Int = lines.last?.isEmpty == true ? lines.count - 1 : lines.count
		let line: (Int) -> Substring? = { index in
			index >= 0 && index < end ? lines[index] : nil
		}
		if !tail.contains(where: \.isTable), let last = line(end - 1) {
			let before: Substring? = line(end - 2)
			if isHeader(last), !(before.map(hasPipe) ?? false) {
				lines.removeSubrange((end - 1)...)
			} else if
				let before,
				isHeader(before),
				!(line(end - 3).map(hasPipe) ?? false),
				isArrivingDelimiterRow(last),
				!isDelimiterRow(last, columns: cells(before).count)
			{
				lines.removeSubrange((end - 2)...)
			}
		}
		let held: String = lines.joined(separator: "\n")

		// Emphasis, strikethrough and code still open in the last paragraph.
		guard let last = lines.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) })
		else { return held }

		let first: Int = lines[..<last].lastIndex(where: { $0.allSatisfy(\.isWhitespace) }).map { $0 + 1 } ?? 0
		let closing: Closing = closingMarks(lines[first...last].joined(separator: "\n"))

		// A mark can't close after a space.
		var text: Substring = lines[last]
		while text.last?.isWhitespace == true { text.removeLast() }
		guard !closing.code.isEmpty || !closing.spans.isEmpty
		else { return held }

		// Closed only when the parser agrees the marks were open: `2 ** 3` or a link to `/**`
		// show their marks either way. The code span first, then each span around it, innermost
		// first, each kept only when it takes marks away, so no closer adds a stray `**`.
		// Only the innermost few spans are tried, each read with the whole answer for its lists and
		// link references: a paragraph of literal marks, like `2 ** 3 ~~ 4` over and over, would
		// otherwise be read once per mark.
		var settled: String = held
		var settledMarks: Int = literalMarks(held)
		var suffix: String = ""
		for marks in [closing.code] + closing.spans.prefix(maximumClosedSpans) where !marks.isEmpty {
			var closedLines: [Substring] = lines
			closedLines[last] = text + suffix + marks
			let closed: String = closedLines.joined(separator: "\n")
			let closedMarks: Int = literalMarks(closed)

			// A closer that adds a mark is text, like `2 ** 3`; the spans outside it still close.
			guard closedMarks < settledMarks else { continue }
			suffix += marks
			settled = closed
			settledMarks = closedMarks
		}
		return settled
	}

	/// How many open bold and strikethrough spans a streaming paragraph closes, innermost first.
	/// Real answers nest two or three; the rest stay as written until the answer completes.
	internal static let maximumClosedSpans: Int = 4

	/// What closes a paragraph's open spans: an unfinished code span's backticks, and the bold
	/// and strikethrough marks around it.
	private struct Closing {
		internal var code: String

		/// Innermost first.
		internal var spans: [String]
	}

	/// The Markdown parsed with GitHub-flavored syntax, failing soft.
	private static func parsed(
		_ markdown: String,
		sourcePositions: Bool = false
	) -> AttributedString? {
		let options: AttributedString.MarkdownParsingOptions = .init(
			allowsExtendedAttributes: false,
			interpretedSyntax: .full,
			failurePolicy: .returnPartiallyParsedIfPossible,
			appliesSourcePositionAttributes: sourcePositions
		)
		return try? AttributedString(markdown: markdown, options: options)
	}

	/// The blocks the Markdown's last text is in, innermost first.
	private static func lastBlocks(_ markdown: String) -> [PresentationIntent.Kind] {
		guard
			let attributed = parsed(markdown),
			let last = attributed.runs.last(where: { run in
				!attributed[run.range].characters.allSatisfy(\.isWhitespace)
			})
		else { return [] }

		return last.presentationIntent?.components.map(\.kind) ?? []
	}

	/// How many emphasis, strikethrough and code marks show as text once the Markdown is drawn.
	private static func literalMarks(_ markdown: String) -> Int {
		guard let attributed = parsed(markdown)
		else { return .max }

		let text: String = .init(attributed.characters)
		return text.components(separatedBy: "**").count + text.components(separatedBy: "~~").count + text.count { $0 == "`" }
	}

	private static func lineEndingsNormalized(_ markdown: String) -> String {
		markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
	}

	/// The marks that close what's still open in a paragraph, innermost first: a code span, then
	/// bold and strikethrough in the reverse order they opened, so `**bold `co` closes as
	/// `**bold `co`**` and `~~strike **bold` as `~~strike **bold**~~`. Escaped marks and marks
	/// inside code don't count.
	private static func closingMarks(_ paragraph: String) -> Closing {
		var open: [String] = []
		var openCode: Int?
		var index: String.Index = paragraph.startIndex
		while index < paragraph.endIndex {
			let character: Character = paragraph[index]
			let next: String.Index = paragraph.index(after: index)
			if character == "\\", openCode == nil, next < paragraph.endIndex, paragraph[next].isEscapable {
				index = paragraph.index(after: next)
				continue
			}
			if character == "`" {
				let run: Substring = paragraph[index...].prefix { $0 == "`" }
				if let code = openCode {
					if run.count == code { openCode = nil }
				} else {
					openCode = run.count
				}
				index = run.endIndex
				continue
			}
			if openCode == nil, let mark = ["**", "~~"].first(where: { paragraph[index...].hasPrefix($0) }) {
				// A mark closes the span opened last; otherwise it opens one inside it, as
				// `**outer ~~strike **inner**` does.
				if open.last == mark {
					open.removeLast()
				} else {
					open.append(mark)
				}
				index = paragraph.index(index, offsetBy: 2)
				continue
			}
			index = next
		}
		return .init(
			code: openCode.map { String(repeating: "`", count: $0) } ?? "",
			spans: open.reversed()
		)
	}

	/// A line that could start a table: it starts with a pipe.
	private static func isHeader(_ line: Substring) -> Bool {
		line.drop { $0 == " " }.first == "|"
	}

	private static func hasPipe(_ line: Substring) -> Bool {
		pipeSeparated(line).count > 1
	}

	/// A delimiter row as it arrives: pipes, dashes and colons.
	private static func isArrivingDelimiterRow(_ line: Substring) -> Bool {
		!line.allSatisfy(\.isWhitespace) && line.allSatisfy { "|-: ".contains($0) }
	}

	/// The line split at its pipes, except escaped ones.
	private static func pipeSeparated(_ line: Substring) -> [String] {
		var parts: [String] = [""]
		var isEscaped: Bool = false
		for character in line {
			if !isEscaped, character == "|" {
				parts.append("")
				continue
			}
			parts[parts.count - 1].append(character)
			isEscaped = !isEscaped && character == "\\"
		}
		return parts
	}

	/// A row's cells, without its outer pipes.
	private static func cells(_ line: Substring) -> [String] {
		var cells: [String] = pipeSeparated(line).map { $0.trimmingCharacters(in: .whitespaces) }
		if cells.first?.isEmpty == true { cells.removeFirst() }
		if cells.last?.isEmpty == true { cells.removeLast() }
		return cells
	}

	/// A table's delimiter row: dashes, maybe between colons, for every column. Its outer pipes
	/// are optional.
	private static func isDelimiterRow(_ line: Substring, columns: Int) -> Bool {
		let cells: [String] = cells(line)
		return cells.count == columns && cells.allSatisfy { cell in
			var dashes: Substring = cell[...]
			if dashes.first == ":" { dashes.removeFirst() }
			if dashes.last == ":" { dashes.removeLast() }
			return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
		}
	}
}

extension PresentationIntent.Kind {
	fileprivate var isCodeBlock: Bool {
		if case .codeBlock = self { true } else { false }
	}

	fileprivate var isTable: Bool {
		if case .table = self { true } else { false }
	}
}

extension Character {
	/// ASCII punctuation, which a backslash escapes in Markdown.
	fileprivate var isEscapable: Bool {
		isASCII && (isPunctuation || isSymbol)
	}
}

extension Array {
	fileprivate subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}

extension String {
	fileprivate var trailingNewlineTrimmed: String {
		hasSuffix("\n") ? String(dropLast()) : self
	}
}
