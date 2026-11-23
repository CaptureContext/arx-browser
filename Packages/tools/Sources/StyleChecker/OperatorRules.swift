import SwiftSyntax

// Rules from the guide's calls-and-operators reference and the ternary part of control-flow.
// Operators are read from the parser's unfolded sequences, so no operator table is needed and
// custom operators such as `<<<` are checked like the standard ones.

extension StyleVisitor {
	// MARK: - Operators

	internal func checkOperators(_ node: SequenceExprSyntax) {
		let expressionIndentation: Substring = file.indentation(ofLine: file.startLine(of: node))
		var ternaryCount: Int = 0

		for element in node.elements {
			if let binary = element.as(BinaryOperatorExprSyntax.self) {
				checkTrailing(binary.operator)
			}

			guard let ternary = element.as(UnresolvedTernaryExprSyntax.self) else { continue }

			ternaryCount += 1

			// ❌ let value = input == .zero
			// ? 0 : input == .one
			// ? 1 : .max
			let nestsInThenBranch: Bool = ternary.thenExpression
				.as(SequenceExprSyntax.self)?
				.elements
				.contains { $0.is(UnresolvedTernaryExprSyntax.self) }
				?? false

			if ternaryCount > 1 || nestsInThenBranch {
				file.report(.ternaryNesting, at: ternary.questionMark.positionAfterSkippingLeadingTrivia)
			}

			for token in [ternary.questionMark, ternary.colon] {
				checkTrailing(token)

				// ❌ let value = condition
				// 	? true
				// 	: false
				let isMisaligned: Bool = file.startsLine(token)
				&& file.indentation(ofLine: file.startLine(of: token)) != expressionIndentation

				if isMisaligned {
					file.report(
						.ternaryIndentation,
						at: token.positionAfterSkippingLeadingTrivia,
						message: StyleRule.ternaryIndentation.summary
						+ " The expression starts at an indentation of \(expressionIndentation.count) characters."
					)
				}
			}
		}
	}

	// ❌ let value = condition1 && (
	// 	condition2 ||
	// 	condition3
	// ) && condition5
	private func checkTrailing(_ token: TokenSyntax) {
		guard file.endsLine(token) else { return }

		file.report(
			.trailingOperator,
			at: token.positionAfterSkippingLeadingTrivia,
			message: "`\(token.text)` ends its line; lead the continuation line with it instead."
		)
	}

	// MARK: - Calls

	// ❌ someFunction(arg1: 0
	// 	arg2: 1)
	internal func checkArguments(_ node: FunctionCallExprSyntax) {
		guard let leftParen = node.leftParen else { return }
		checkAlignment(open: leftParen, starts: node.arguments.map { file.startLine(of: $0) })
	}

	internal func checkParameters(_ node: FunctionParameterClauseSyntax) {
		checkAlignment(open: node.leftParen, starts: node.parameters.map { file.startLine(of: $0) })
	}

	private func checkAlignment(
		open: TokenSyntax,
		starts: [Int]
	) {
		let openLine: Int = file.startLine(of: open)

		guard
			starts.count > 1,
			starts[0] == openLine,
			starts.dropFirst().contains(where: { $0 > openLine })
		else { return }

		file.report(.argumentAlignment, at: open.positionAfterSkippingLeadingTrivia)
	}
}
