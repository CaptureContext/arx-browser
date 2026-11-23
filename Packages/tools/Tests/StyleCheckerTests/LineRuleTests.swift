import Foundation
import StyleChecker
import Testing

/// Rules read from lines: dense spans, tab indentation and documentation comments.
internal struct LineRuleTests {
	// MARK: - Dense spans

	@Test
	internal func denseSpanReportsItsFirstLine() {
		let statements: [String] = (0..<StyleChecker.denseSpanLength).map { "\tlet value\($0) = \($0)" }
		let source: String = (["func dense() {"] + statements + ["}"]).joined(separator: "\n")

		let findings: [StyleFinding] = StyleChecker.check(source: source, path: "Example.swift")
			.filter { $0.rule == .denseSpan }

		#expect(findings.map(\.line) == [1])
		#expect(findings.first?.message.hasPrefix("\(StyleChecker.denseSpanLength + 2) lines in a row") == true)
	}

	@Test
	internal func shorterSpansAndBlankLinesPass() {
		let paragraph: [String] = (0..<40).map { "\tlet value\($0) = \($0)" }
		let source: String = (["func paragraphs() {"] + paragraph + [""] + paragraph + ["}"]).joined(separator: "\n")

		#expect(lines(.denseSpan, in: source).isEmpty)
	}

	@Test
	internal func guardsMayRunUninterrupted() {
		let guards: [String] = (0..<80).map { "guard value\($0) else { return }" }
		let body: [String] = guards.map { "\t\($0)" }
		let function: [String] = ["func validate() {"] + body + ["\treturn", "}"]

		#expect(lines(.denseSpan, in: guards.joined(separator: "\n")).isEmpty)
		#expect(lines(.denseSpan, in: function.joined(separator: "\n")).isEmpty)
	}

	@Test
	internal func stringLiteralContentIsNotCode() {
		let text: [String] = (0..<80).map { "  /// - Parameter line\($0): text" }
		let source: String = (["let text: String = \"\"\""] + text + ["\"\"\""]).joined(separator: "\n")

		#expect(lines(.denseSpan, in: source).isEmpty)
		#expect(lines(.tabIndentation, in: source).isEmpty)
		#expect(lines(.documentationParameters, in: source).isEmpty)
	}

	// MARK: - Indentation

	@Test
	internal func spacesInIndentation() {
		let source: String = [
			"func indented() {",
			"\tlet tabs: Int = 0",
			"    let spaces: Int = 0",
			"\t  let aligned: Int = 0",
			"\t/* a block comment",
			"\t   keeps its own alignment */",
			"}",
		].joined(separator: "\n")

		#expect(lines(.tabIndentation, in: source) == [3, 4])
		#expect(lines(.tabIndentation, in: source.replacingOccurrences(of: "\n", with: "\r\n")) == [3, 4])
	}

	// MARK: - Documentation

	@Test
	internal func singleParameterEntries() {
		let source: String = """
			/// Return whether this folder contains a file at a given path.
			/// - parameter path: The relative path of the file to look for.
			func containsFile(at path: String) -> Bool { true }

			/// Return whether this folder contains a file at a given path.
			///
			/// - Parameters:
			///   - path: The relative path of the file to look for.
			func containsFile(at path: String) -> Bool { true }
			"""

		#expect(lines(.documentationParameters, in: source) == [2])
	}

	@Test
	internal func commentsStandOffFromCodeAbove() {
		let source: String = """
			struct Client {
				/// First in its scope.
				var load: Int
				/// Needs a blank line.
				var save: Int

				/// Has one.
				var clear: Int
				// A line comment too.
				var remove: Int
				var task: Task<Void, Never>?
				/// After an optional or generic type.
				var count: Int
				var values: [Int] = [
					1,
					// Inside a list.
					2
				]
			}
			"""

		#expect(lines(.commentSpacing, in: source) == [4, 9, 12])
	}
}
