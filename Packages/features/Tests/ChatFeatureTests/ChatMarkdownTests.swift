import CustomDump
import Foundation
import Testing

@testable import ChatFeature

/// DEV-998: an answer's Markdown as blocks, from Foundation's GitHub-flavored parser.
@Suite
internal struct ChatMarkdownTests {
	@Test
	internal func headingsParagraphsAndRulesAreBlocksOfTheirOwn() {
		let blocks = ChatMarkdown.blocks("# Title\n\nSome text\nand more.\n\n---\n\n### Small")
		#expect(blocks.count == 4)
		#expect(Self.heading(blocks[0]) == .init(level: 1, text: "Title"))
		#expect(Self.text(blocks[1]) == "Some text and more.")
		#expect(blocks[2] == .rule)
		#expect(Self.heading(blocks[3]) == .init(level: 3, text: "Small"))
	}

	@Test
	internal func inlineStylesAndWebLinksAreKept() throws {
		let blocks = ChatMarkdown.blocks(
			"**Bold**, *em*, `code`, ~~gone~~, [web](https://example.com), [script](javascript:alert(1)) and ![a picture](https://example.com/a.png)"
		)
		guard case let .paragraph(text)? = blocks.first
		else { Issue.record("Expected a paragraph"); return }

		#expect(String(text.characters) == "Bold, em, code, gone, web, script and a picture")
		let intents: [String: InlinePresentationIntent] = Dictionary(
			text.runs.compactMap { run in
				run.inlinePresentationIntent.map { (String(text[run.range].characters), $0) }
			},
			uniquingKeysWith: { first, _ in first }
		)
		#expect(intents["Bold"] == .stronglyEmphasized)
		#expect(intents["em"] == .emphasized)
		#expect(intents["code"] == .code)
		#expect(intents["gone"] == .strikethrough)
		let links: [String: URL] = Dictionary(
			text.runs.compactMap { run in
				run.link.map { (String(text[run.range].characters), $0) }
			},
			uniquingKeysWith: { first, _ in first }
		)

		// Only web links are followed, and images are never loaded.
		expectNoDifference(links, ["web": URL(string: "https://example.com")!])
		#expect(text.runs.allSatisfy { $0.imageURL == nil })
	}

	@Test
	internal func listsNestAndKeepTheirNumbersAndTaskBoxes() throws {
		let blocks = ChatMarkdown.blocks("3. three\n4. four\n   - nested\n     1. deep\n\n- [ ] to do\n- [x] done")
		guard case let .list(ordered)? = blocks.first, case let .list(tasks)? = blocks.last
		else { Issue.record("Expected two lists"); return }

		#expect(ordered.isOrdered)
		#expect(ordered.items.map(\.ordinal) == [3, 4])
		guard case let .list(nested)? = ordered.items[1].blocks.last
		else { Issue.record("Expected a nested list"); return }

		#expect(!nested.isOrdered)
		#expect(Self.text(nested.items[0].blocks[0]) == "nested")
		guard case let .list(deep)? = nested.items[0].blocks.last
		else { Issue.record("Expected a list in the nested list"); return }

		#expect(deep.isOrdered)
		#expect(Self.text(deep.items[0].blocks[0]) == "deep")

		#expect(tasks.items.map(\.isChecked) == [false, true])
		#expect(tasks.items.map { Self.text($0.blocks[0]) } == ["to do", "done"])
	}

	/// Only a box written as one is a task: one in code or escaped stays text.
	@Test
	internal func onlyWrittenBoxesAreTasks() {
		let blocks = ChatMarkdown.blocks("- `[x]` code\n- \\[x] escaped\n- é [ ] later\n- [X] real")
		guard case let .list(list)? = blocks.first
		else { Issue.record("Expected a list"); return }

		#expect(list.items.map(\.isChecked) == [nil, nil, nil, true])
		#expect(list.items.map { Self.text($0.blocks[0]) } == ["[x] code", "[x] escaped", "é [ ] later", "real"])
	}

	@Test
	internal func quotesNest() {
		let blocks = ChatMarkdown.blocks("> outer\n> > inner")
		guard case let .quote(outer)? = blocks.first
		else { Issue.record("Expected a quote"); return }

		#expect(Self.text(outer[0]) == "outer")
		guard case let .quote(inner)? = outer.last
		else { Issue.record("Expected a quote in the quote"); return }

		#expect(Self.text(inner[0]) == "inner")
	}

	@Test
	internal func codeBlocksKeepTheirLanguageAndText() {
		let blocks = ChatMarkdown.blocks("```swift\nlet x = 1\n  indented()\n```\n\n```\nplain\n```")
		#expect(blocks == [
			.code(language: "swift", text: "let x = 1\n  indented()"),
			.code(language: nil, text: "plain"),
		])
	}

	@Test
	internal func tablesKeepTheirHeaderAlignmentAndEveryColumn() {
		let blocks = ChatMarkdown.blocks("| Left | Center | Right |\n|:--|:-:|--:|\n| a | **b** | `c` |\n| only one |\n|  | middle |  |")
		guard case let .table(table)? = blocks.first
		else { Issue.record("Expected a table"); return }

		#expect(table.alignments == [.leading, .center, .trailing])
		#expect(table.header.map { String($0.characters) } == ["Left", "Center", "Right"])
		expectNoDifference(
			table.rows.map { $0.map { String($0.characters) } },
			[["a", "b", "c"], ["only one", "", ""], ["", "middle", ""]]
		)
	}

	/// A row of empty cells has no text for the parser to report, wherever it is.
	@Test
	internal func rowsOfEmptyCellsAreKept() {
		let rows = { (markdown: String) -> [[String]] in
			guard let table = Self.firstTable(ChatMarkdown.blocks(markdown))
			else { return [] }

			return table.rows.map { $0.map { String($0.characters) } }
		}
		expectNoDifference(rows("| A | B |\n|---|---|\n| | |\n|x|y|\n| |  |\n\nAfter"), [["", ""], ["x", "y"], ["", ""]])
		expectNoDifference(rows("| A | B |\n|---|---|\n| | |"), [["", ""]])
		expectNoDifference(rows("| A | B |\n|---|---|"), [])

		// Nor is indented code after it, or a line outside the list a table is in.
		expectNoDifference(rows("|A|B|\n|-|-|\n|x|y|\n    | | |"), [["x", "y"]])

		// A table that starts on a list item's line keeps the rows under it.
		expectNoDifference(rows("- | A | B |\n  |---|---|\n  | | |"), [["", ""]])

		// A quote after the table isn't one of its rows.
		expectNoDifference(rows("|A|B|\n|-|-|\n|x|y|\n> | | |"), [["x", "y"]])
		expectNoDifference(rows("|A|B|\r\n|-|-|\r\n| | |\r\n|x|y|"), [["", ""], ["x", "y"]])

		// In a quote, the row's quote marker isn't a cell.
		expectNoDifference(rows("> | A | B |\n> |---|---|\n> |x|y|\n> | | |\n>\n> After"), [["x", "y"], ["", ""]])

		// DEV-1031: outer pipes and indentation don't decide; the parser does.
		expectNoDifference(rows("|A|B|\n|-|-|\na | b\n| | |"), [["a", "b"], ["", ""]])
		expectNoDifference(rows("|A|B|\n|-|-|\n| a | b |\n  | | |"), [["a", "b"], ["", ""]])

		// A lone pipe that ends a table stays text, and the empty row after it isn't the table's.
		expectNoDifference(rows("|A|B|\n|-|-|\na | b\n|\n  | | |"), [["a", "b"]])

		// The probe's own mark elsewhere in the answer doesn't decide.
		expectNoDifference(rows("|A|B|\n|-|-|\n|x|y|\n| | |\n\n\u{E000}"), [["x", "y"], ["", ""]])

		// Many empty rows are read in one pass.
		let many: String = "|A|B|\n|-|-|\n|x|y|\n" + String(repeating: "| | |\n", count: 500)
		let started: ContinuousClock.Instant = .now
		expectNoDifference(rows(many).count, 501)
		#expect(started.duration(to: .now) < .seconds(1))
		// Many tables share that pass.
		let tables: String = .init(repeating: "|A|B|\n|-|-|\n|x|y|\n| | |\n\n", count: 100)
		let tablesStarted: ContinuousClock.Instant = .now
		let read: [ChatMarkdown.Block] = ChatMarkdown.blocks(tables)
		#expect(read.count == 100)
		#expect(read.allSatisfy { if case let .table(table) = $0 { table.rows.count == 2 } else { false } })
		#expect(tablesStarted.duration(to: .now) < .seconds(1))
		// While it streams, too.
		guard case let .table(streaming)? = ChatMarkdown.blocks("|A|B|\n|-|-|\na | b\n| | |", isStreaming: true).first
		else { Issue.record("Expected a table"); return }

		expectNoDifference(streaming.rows.map { $0.map { String($0.characters) } }, [["a", "b"], ["", ""]])
	}

	/// A read always finishes and shows; of the text that arrives meanwhile, only the newest is
	/// read next.
	@MainActor
	@Test
	internal func theReaderShowsEveryReadAndThenTheNewestText() async {
		let reader: ChatMarkdownReader = .init()
		let first: ChatMarkdownReader.Source = .init(markdown: "# One", isStreaming: true)
		let newest: ChatMarkdownReader.Source = .init(markdown: "# One\n\n| a | b |\n|---|---|\n| 1 | 2 |", isStreaming: false)
		reader.read(first)
		reader.read(.init(markdown: "# One\n\n| a |", isStreaming: true))
		reader.read(newest)
		await reader.reading?.value
		#expect(reader.latest?.source == newest)
		#expect(reader.latest?.blocks == ChatMarkdown.blocks(newest.markdown))
		#expect(reader.reading == nil)

		// Text already read isn't read again.
		reader.read(newest)
		#expect(reader.reading == nil)
	}

	@Test
	internal func aLongAnswerIsReadTheSameOffTheMainActor() async {
		let markdown: String = .init(repeating: "## Part\n\n| a | b |\n|---|--:|\n| 1 | **2** |\n\n- [x] done\n\n", count: 200)
		let offMain: [ChatMarkdown.Block] = await ChatMarkdown.blocksOffMain(markdown, isStreaming: true)
		#expect(offMain == ChatMarkdown.blocks(markdown, isStreaming: true))
		#expect(offMain.count == 600)
	}

	// MARK: - Streaming

	@Test
	internal func anUnfinishedTailSettlesAsItWill() {
		#expect(ChatMarkdown.settling("Some **bold") == "Some **bold**")
		#expect(ChatMarkdown.settling("Some **bold ") == "Some **bold**")
		#expect(ChatMarkdown.settling("a `co") == "a `co`")
		#expect(ChatMarkdown.settling("a `**` b ~~gone") == "a `**` b ~~gone~~")
		#expect(ChatMarkdown.settling("**done** and *it*") == "**done** and *it*")
		// The open mark is in the last paragraph, whatever blank lines follow it.
		#expect(ChatMarkdown.settling("Done.\n\nStill **coming\n") == "Done.\n\nStill **coming**\n")
		#expect(ChatMarkdown.settling("Still **coming\nover lines") == "Still **coming\nover lines**")
		// Marks the parser shows as text either way stay as written.
		#expect(ChatMarkdown.settling("Python: 2 ** 3 = 8.") == "Python: 2 ** 3 = 8.")
		#expect(ChatMarkdown.settling("[docs](https://example.com/**)") == "[docs](https://example.com/**)")
		// Escaped marks are text, and marks in code don't count.
		#expect(ChatMarkdown.settling(#"Show \** literally."#) == #"Show \** literally."#)
		#expect(ChatMarkdown.settling(#"Keep \~~ and `**` as they are"#) == #"Keep \~~ and `**` as they are"#)
		#expect(ChatMarkdown.settling("Run ``a ` b`` and **go") == "Run ``a ` b`` and **go**")
		#expect(ChatMarkdown.settling("Run ``a ` b") == "Run ``a ` b``")
		// An open code block is already drawn as one.
		#expect(ChatMarkdown.settling("```py\nprint(**") == "```py\nprint(**")
		// Code in a list or a quote, or indented, is left as written too.
		#expect(ChatMarkdown.settling("- Step\n\n  ```sh\n  echo **") == "- Step\n\n  ```sh\n  echo **")
		#expect(ChatMarkdown.settling("> ```\n> a `b") == "> ```\n> a `b")
		#expect(ChatMarkdown.settling("Text\n\n    indented **code") == "Text\n\n    indented **code")
		// Only a fence like the opening one closes it.
		#expect(ChatMarkdown.settling("```markdown\n~~~\n| Name | Value |") == "```markdown\n~~~\n| Name | Value |")
		#expect(ChatMarkdown.settling("````\n```\n**x") == "````\n```\n**x")
		#expect(ChatMarkdown.settling("```\ncode\n```\n\n**x") == "```\ncode\n```\n\n**x**")
	}

	/// DEV-1031: every open span closes, innermost first, around an unfinished code span too.
	@Test
	internal func nestedUnfinishedSpansAllSettle() throws {
		#expect(ChatMarkdown.settling("**bold `co") == "**bold `co`**")
		#expect(ChatMarkdown.settling("~~strike **bold") == "~~strike **bold**~~")
		#expect(ChatMarkdown.settling("**bold ~~strike") == "**bold ~~strike~~**")
		// Arithmetic before real spans gets no closer of its own.
		#expect(ChatMarkdown.settling("2 ** 3 ~~strike **bold") == "2 ** 3 ~~strike **bold**~~")
		#expect(ChatMarkdown.settling("~~strike 2 ** 3") == "~~strike 2 ** 3~~")
		// A finished inner span keeps the outer ones in their order.
		#expect(ChatMarkdown.settling("**outer ~~strike **inner**") == "**outer ~~strike **inner**~~**")
		// A code span closes even when the bold before it is literal text.
		#expect(ChatMarkdown.settling("Python: 2 ** 3 = 8. Run `co") == "Python: 2 ** 3 = 8. Run `co`")
		#expect(ChatMarkdown.settling("Python: 2 ** 3 = 8. Run ``co") == "Python: 2 ** 3 = 8. Run ``co``")
		// A span that closed doesn't count, whatever the other's order.
		#expect(ChatMarkdown.settling("**a ~~b** c") == "**a ~~b** c")

		guard case let .paragraph(text)? = ChatMarkdown.blocks("~~strike **bold", isStreaming: true).first
		else { Issue.record("Expected a paragraph"); return }

		#expect(String(text.characters) == "strike bold")
		let bold = try #require(text.runs.first { String(text[$0.range].characters) == "bold" })
		#expect(bold.inlinePresentationIntent == [.strikethrough, .stronglyEmphasized])

		guard case let .paragraph(code)? = ChatMarkdown.blocks("**bold `co", isStreaming: true).first
		else { Issue.record("Expected a paragraph"); return }

		#expect(String(code.characters) == "bold co")
		#expect(code.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
	}

	/// A paragraph of literal marks is read a bounded number of times while it streams: the span
	/// still open at its end closes, and the arithmetic stays as written. A closer is judged with
	/// the answer around it, its lists and link references.
	@Test
	internal func aParagraphOfLiteralMarksSettlesInBoundedReads() {
		let literal: String = String(repeating: "2 ** 3 ~~ 4 ", count: 300)
		#expect(ChatMarkdown.settling(literal) == literal)
		#expect(ChatMarkdown.settling(literal + "**bold") == literal + "**bold**")
		let earlier: String = String(repeating: "A finished paragraph with **bold**.\n\n", count: 50)
		#expect(ChatMarkdown.settling(earlier + "Still **coming") == earlier + "Still **coming**")
		#expect(ChatMarkdown.settling("- item\n\n    **bold") == "- item\n\n    **bold**")
		#expect(ChatMarkdown.settling("[ref]: https://example.com\n\n[**x][ref]") == "[ref]: https://example.com\n\n[**x][ref]")
	}

	@Test
	internal func aTableWaitsForItsDelimiterRow() {
		#expect(ChatMarkdown.settling("Intro\n\n| a | b |") == "Intro\n")
		#expect(ChatMarkdown.settling("Intro\n\n| a | b |\n|---|") == "Intro\n")
		// A single dash is enough for a column.
		#expect(ChatMarkdown.settling("Intro\n\n| a | b |\n|---|-") == "Intro\n\n| a | b |\n|---|-")
		#expect(ChatMarkdown.settling("| a | b |\n|---|---|") == "| a | b |\n|---|---|")
		#expect(ChatMarkdown.settling("| a | b |\n|---|---|\n| 1 |") == "| a | b |\n|---|---|\n| 1 |")
		// A header still arriving at a line's end waits too.
		#expect(ChatMarkdown.settling("Intro\n\n| a | b |\n") == "Intro\n")
		// Escaped pipes are text, not columns.
		#expect(ChatMarkdown.settling(#"| A \| B | C |"# + "\n|---|---|") == #"| A \| B | C |"# + "\n|---|---|")
		// Body rows after a delimiter row without outer pipes stay.
		#expect(ChatMarkdown.settling("| A | B |\n---|---\n| x | y |") == "| A | B |\n---|---\n| x | y |")
		// A row without pipes still belongs to its table, and so does the next.
		#expect(ChatMarkdown.settling("|A|B|\n|-|-|\na\n|x|y|") == "|A|B|\n|-|-|\na\n|x|y|")
		// Windows line endings read as any others.
		#expect(ChatMarkdown.settling("|A|B|\r\n|-|-|\r\n|x|y|") == "|A|B|\n|-|-|\n|x|y|")
		// Outer pipes are optional on the delimiter row.
		#expect(ChatMarkdown.settling("| A | B |\n|---|---\n|x|y|") == "| A | B |\n|---|---\n|x|y|")
		#expect(ChatMarkdown.settling("| A | B |\n|---|-:-") == "")
		guard case .table? = ChatMarkdown.blocks("| a | b |\n|---|---|\n| 1 | 2", isStreaming: true).first
		else { Issue.record("Expected a table"); return }
	}

	@Test
	internal func aFinishedAnswerIsDrawnAsWritten() {
		#expect(ChatMarkdown.blocks("Some **bold", isStreaming: false).first.flatMap(Self.text) == "Some **bold")
		#expect(ChatMarkdown.blocks("Some **bold", isStreaming: true).first.flatMap(Self.text) == "Some bold")
	}

	// MARK: - Helpers

	private struct Heading: Equatable {
		var level: Int
		var text: String
	}

	private static func heading(_ block: ChatMarkdown.Block) -> Heading? {
		guard case let .heading(level, text) = block
		else { return nil }

		return .init(level: level, text: String(text.characters))
	}

	/// The first table, also in a quote or a list.
	private static func firstTable(_ blocks: [ChatMarkdown.Block]) -> ChatMarkdown.Table? {
		for block in blocks {
			switch block {
			case let .table(table):
				return table
			case let .quote(blocks):
				if let table = firstTable(blocks) { return table }
			case let .list(list):
				for item in list.items {
					if let table = firstTable(item.blocks) { return table }
				}
			default:
				continue
			}
		}
		return nil
	}

	private static func text(_ block: ChatMarkdown.Block) -> String? {
		guard case let .paragraph(text) = block
		else { return nil }

		return String(text.characters)
	}
}
