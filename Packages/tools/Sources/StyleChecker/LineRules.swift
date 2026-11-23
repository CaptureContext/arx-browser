import SwiftSyntax

// Rules read from the file's lines once the syntax walk has marked which lines hold string
// literal content or block comment text.

extension StyleVisitor {
	internal func protectMultilineString(_ node: StringLiteralExprSyntax) {
		guard node.openingQuote.tokenKind == .multilineStringQuote else { return }

		let contentStart: Int = file.startLine(of: node.openingQuote) + 1
		let contentEnd: Int = file.startLine(of: node.closingQuote) - 1
		guard contentStart <= contentEnd else { return }

		file.protect(lines: contentStart...contentEnd)
	}

	internal func protectBlockComments(_ token: TokenSyntax) {
		protectBlockComments(in: token.leadingTrivia, from: token.position)
		protectBlockComments(in: token.trailingTrivia, from: token.endPositionBeforeTrailingTrivia)
	}

	private func protectBlockComments(
		in trivia: Trivia,
		from start: AbsolutePosition
	) {
		var offset: Int = start.utf8Offset

		for piece in trivia {
			let length: Int = piece.sourceLength.utf8Length
			defer { offset += length }

			switch piece {
			case .blockComment, .docBlockComment:
				let firstLine: Int = file.line(of: AbsolutePosition(utf8Offset: offset))
				let lastLine: Int = file.line(of: AbsolutePosition(utf8Offset: offset + length))
				if firstLine < lastLine { file.protect(lines: (firstLine + 1)...lastLine) }

			default:
				continue
			}
		}
	}
}

extension SourceContext {
	internal func checkLines() {
		checkDenseSpans()
		checkIndentation()
		checkDocumentationParameters()
		checkCommentSpacing()
	}

	// MARK: - Dense spans

	// Max's heuristic from the guide's Vertical whitespace section: blank lines reveal paragraphs,
	// so a long run without one probably hides them. Guard lines don't count toward the length,
	// as the guide lets a sequence of simple guards run uninterrupted, wherever it sits.
	private func checkDenseSpans() {
		var spanStart: Int? = nil

		for line in 1...(lines.count + 1) {
			let isDense: Bool = !protectedLines.contains(line) && !isBlank(line: line) && line <= lines.count

			if isDense {
				if spanStart == nil { spanStart = line }
				continue
			}

			guard let start = spanStart else { continue }
			spanStart = nil

			let length: Int = line - start
			let guardLines: Int = (start..<line).count { index in
				text(ofLine: index)?.drop { $0.isWhitespace }.hasPrefix("guard ") == true
			}

			guard length - guardLines >= StyleChecker.denseSpanLength else { continue }

			report(
				.denseSpan,
				line: start,
				column: 1,
				message: "\(length) lines in a row with no empty line (\(StyleChecker.denseSpanLength) or more): "
				+ "the code is probably too condensed to show its paragraphs."
			)
		}
	}

	// MARK: - Indentation

	private func checkIndentation() {
		for (index, text) in lines.enumerated() {
			let line: Int = index + 1
			guard !protectedLines.contains(line), !isBlank(line: line) else { continue }

			let leading: Substring = indentation(ofLine: line)
			guard let space = leading.firstIndex(of: " ") else { continue }

			report(
				.tabIndentation,
				line: line,
				column: text.distance(from: text.startIndex, to: space) + 1
			)
		}
	}

	// MARK: - Documentation

	// ❌ /// - Parameter path: The relative path of the file to look for.
	private func checkDocumentationParameters() {
		for (index, text) in lines.enumerated() where !protectedLines.contains(index + 1) {
			let content: Substring = text.drop { $0.isWhitespace }
			guard content.hasPrefix("///") else { continue }

			let entry: Substring = content.dropFirst(3).drop { $0.isWhitespace }
			guard entry.lowercased().hasPrefix("- parameter ") else { continue }

			report(
				.documentationParameters,
				line: index + 1,
				column: text.distance(from: text.startIndex, to: content.startIndex) + 1
			)
		}
	}

	// MARK: - Comment spacing

	// ❌ let value: Int
	// /// Explains the next one.
	// let other: Int
	//
	// A comment that starts a block of comments, a documentation comment included, stands off
	// from the code above it. The first line of a scope, a line that continues an expression, an
	// attribute and a compiler directive are exempt.
	private func checkCommentSpacing() {
		let continuing: [Character] = ["{", "(", "[", ",", ":", "+", "-", "*", "/", "&", "|", "=", ".", "<", "\\"]

		guard lines.count > 1 else { return }

		for line in 2...lines.count {
			guard !protectedLines.contains(line), !protectedLines.contains(line - 1) else { continue }

			let current: Substring = text(ofLine: line).map { $0.drop { $0.isWhitespace } } ?? ""
			guard current.hasPrefix("//") else { continue }

			let previous: Substring = text(ofLine: line - 1).map { $0.drop { $0.isWhitespace } } ?? ""
			guard
				!previous.isEmpty,
				!previous.hasPrefix("//"),
				!previous.hasPrefix("@"),
				!previous.hasPrefix("#"),
				!previous.hasPrefix("*/"),
				let last = previous.last,
				!continuing.contains(last),
				!previous.hasSuffix("->")
			else { continue }

			report(.commentSpacing, line: line, column: 1)
		}
	}
}
