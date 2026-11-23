import SwiftParser
import SwiftSyntax

/// Checks Swift source against the rules in `StyleRule.all`.
///
/// Every finding is advisory: the checker reports where code departs from a shape the
/// swift-style guide or `.agents/AGENTS.md` states, and decides nothing the guide leaves to judgement.
public enum StyleChecker {
	/// How many lines in a row without an empty line make `dense-span` report.
	public static let denseSpanLength: Int = 120

	/// Findings for one file, ordered by position.
	///
	/// - Parameters:
	///   - source: The file's text.
	///   - path: The path printed with each finding.
	public static func check(
		source: String,
		path: String
	) -> [StyleFinding] {
		let tree: SourceFileSyntax = Parser.parse(source: source)
		let file: SourceContext = .init(
			tree: tree,
			source: source,
			path: path
		)

		let visitor: StyleVisitor = .init(file: file)
		visitor.walk(tree)
		file.checkLines()

		return file.findings.sorted { lhs, rhs in
			(lhs.line, lhs.column, lhs.rule.id) < (rhs.line, rhs.column, rhs.rule.id)
		}
	}
}

// MARK: - Source context

/// One file's lines, positions and findings, shared by the syntax and line rules.
internal final class SourceContext {
	internal let path: String
	internal let lines: [Substring]
	internal private(set) var findings: [StyleFinding] = []

	/// Lines that hold data or prose rather than code: the inside of multiline string literals
	/// and of block comments. Line rules leave them alone.
	internal var protectedLines: Set<Int> = []

	private let converter: SourceLocationConverter

	internal init(
		tree: SourceFileSyntax,
		source: String,
		path: String
	) {
		self.path = path
		self.converter = .init(fileName: path, tree: tree)

		// `\r\n` is one Character, so splitting on newline Characters ends lines where
		// `SourceLocationConverter` does, for LF, CRLF and CR files alike.
		self.lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
	}

	// MARK: Positions

	internal func line(of position: AbsolutePosition) -> Int {
		converter.location(for: position).line
	}

	internal func startLine(of node: some SyntaxProtocol) -> Int {
		line(of: node.positionAfterSkippingLeadingTrivia)
	}

	internal func endLine(of node: some SyntaxProtocol) -> Int {
		line(of: node.endPositionBeforeTrailingTrivia)
	}

	/// The first line of a node counting the comments right above it, so a blank line
	/// before a documented declaration is looked for above its documentation.
	internal func firstLineIncludingComments(of node: some SyntaxProtocol) -> Int {
		var offset: Int = node.position.utf8Offset

		for piece in node.leadingTrivia {
			if piece.isComment { return line(of: AbsolutePosition(utf8Offset: offset)) }
			offset += piece.sourceLength.utf8Length
		}

		return startLine(of: node)
	}

	/// Whether the token is the first one on its line.
	internal func startsLine(_ token: TokenSyntax) -> Bool {
		guard let previous = token.previousToken(viewMode: .sourceAccurate)
		else { return true }

		return endLine(of: previous) < startLine(of: token)
	}

	/// Whether the token is the last one on its line.
	internal func endsLine(_ token: TokenSyntax) -> Bool {
		guard let next = token.nextToken(viewMode: .sourceAccurate)
		else { return true }

		return next.tokenKind == .endOfFile || startLine(of: next) > endLine(of: token)
	}

	// MARK: Lines

	/// The text of a 1-based line, or nil outside the file.
	internal func text(ofLine line: Int) -> Substring? {
		lines.indices.contains(line - 1) ? lines[line - 1] : nil
	}

	internal func isBlank(line: Int) -> Bool {
		guard let text = text(ofLine: line) else { return false }
		return text.allSatisfy(\.isWhitespace)
	}

	internal func indentation(ofLine line: Int) -> Substring {
		text(ofLine: line)?.prefix { $0 == " " || $0 == "\t" } ?? ""
	}

	internal func protect(lines range: ClosedRange<Int>) {
		protectedLines.formUnion(range)
	}

	// MARK: Findings

	internal func report(
		_ rule: StyleRule,
		at position: AbsolutePosition,
		message: String? = nil
	) {
		let location: SourceLocation = converter.location(for: position)
		report(
			rule,
			line: location.line,
			column: location.column,
			message: message
		)
	}

	internal func report(
		_ rule: StyleRule,
		line: Int,
		column: Int,
		message: String? = nil
	) {
		findings.append(.init(
			rule: rule,
			path: path,
			line: line,
			column: column,
			message: message ?? rule.summary
		))
	}
}
