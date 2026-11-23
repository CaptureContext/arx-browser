import SwiftSyntax

// Rules from the guide's control-flow reference. Each checks only what its examples settle
// without judgement: which line a part starts on, and whether siblings agree with each other.
// How long a one-line guard may be, or when a branch is complex enough to expand, is left alone.

extension StyleVisitor {
	// MARK: - Guard

	internal func checkGuard(_ node: GuardStmtSyntax) {
		let guardLine: Int = file.startLine(of: node.guardKeyword)
		let conditionsStartOnGuardLine: Bool = node.conditions.first
			.map { file.startLine(of: $0) == guardLine }
			?? false

		// ❌ guard let self,
		// 	let firstInt,
		// 	firstInt.isMultiple(of: 2)
		// else { return nil }
		let laterCondition: ConditionElementSyntax? = node.conditions
			.dropFirst()
			.first { file.startLine(of: $0) > guardLine }

		if conditionsStartOnGuardLine, laterCondition != nil {
			file.report(.guardConditionOnKeywordLine, at: node.guardKeyword.positionAfterSkippingLeadingTrivia)
		}

		let elseLine: Int = file.startLine(of: node.elseKeyword)
		let bodyIsMultiline: Bool = file.startLine(of: node.body.leftBrace) < file.startLine(of: node.body.rightBrace)

		// ❌ guard let pattern = loadAHAPPattern(named: "ShieldTransient")
		// else {
		// 	throw Failure.couldNotLoadAHAPPPattern
		// }
		if conditionsStartOnGuardLine, elseLine > file.endLine(of: node.conditions), bodyIsMultiline {
			file.report(.guardSplitElseBlock, at: node.elseKeyword.positionAfterSkippingLeadingTrivia)
		}

		// ❌ guard let self else {
		// 	return nil
		// }
		if bodyIsMultiline, Self.isTrivialExit(node.body) {
			file.report(.guardTrivialElseBlock, at: node.elseKeyword.positionAfterSkippingLeadingTrivia)
		}
	}

	/// A block whose only content is `return`, `return nil`, `return .none`, `break` or `continue`,
	/// with no comment that would explain why it was expanded.
	private static func isTrivialExit(_ block: CodeBlockSyntax) -> Bool {
		guard
			block.statements.count == 1,
			let statement = block.statements.first,
			!block.leftBrace.trailingTrivia.contains(where: \.isComment),
			!statement.leadingTrivia.contains(where: \.isComment),
			!statement.trailingTrivia.contains(where: \.isComment),
			!block.rightBrace.leadingTrivia.contains(where: \.isComment)
		else { return false }

		switch Syntax(statement.item).as(SyntaxEnum.self) {
		case let .returnStmt(returnStatement):
			guard let expression = returnStatement.expression else { return true }
			if expression.is(NilLiteralExprSyntax.self) { return true }

			guard let member = expression.as(MemberAccessExprSyntax.self)
			else { return false }

			return member.base == nil && member.declName.baseName.text == "none"

		case let .breakStmt(breakStatement):
			return breakStatement.label == nil

		case let .continueStmt(continueStatement):
			return continueStatement.label == nil

		default:
			return false
		}
	}

	// MARK: - If

	internal func checkIf(_ node: IfExprSyntax) {
		checkIfConditions(node)

		// `else if` is an `if` nested in its parent's else; the chain is checked once, from its head.
		let isChainHead: Bool = node.parent?.as(IfExprSyntax.self)?.elseBody?.id != node.id
		guard isChainHead else { return }

		checkIfChainSeparation(node)
		checkIfExpressionAssignment(node)
	}

	// ❌ if
	// 	state.isReady,
	// 	state.spaces[id: spaceID] == nil
	// {
	//
	// A list with a binding (`if let`, `if case`) can't be extracted into a named value, so it
	// may take the guard's layout: "apply the same visual-separation approach to other
	// conditional statements" (control-flow › Conditional statements).
	private func checkIfConditions(_ node: IfExprSyntax) {
		guard node.conditions.count > 1 else { return }

		let bindsValues: Bool = node.conditions.contains { element in
			switch element.condition {
			case .optionalBinding, .matchingPattern: true
			case .expression, .availability: false
			}
		}

		guard !bindsValues else { return }

		let ifLine: Int = file.startLine(of: node.ifKeyword)
		let spansLines: Bool = node.conditions.contains { file.startLine(of: $0) != ifLine }

		if spansLines {
			file.report(.ifMultilineConditions, at: node.ifKeyword.positionAfterSkippingLeadingTrivia)
		}
	}

	private func checkIfChainSeparation(_ head: IfExprSyntax) {
		var elses: [(keyword: TokenSyntax, isSeparated: Bool)] = []
		var current: IfExprSyntax? = head

		while let branch = current, let elseKeyword = branch.elseKeyword {
			let braceLine: Int = file.startLine(of: branch.body.rightBrace)
			elses.append((elseKeyword, file.isBlank(line: braceLine - 1)))
			current = branch.elseBody?.as(IfExprSyntax.self)
		}

		let hasSeparatedBranch: Bool = elses.contains(where: \.isSeparated)
		guard hasSeparatedBranch else { return }

		for (keyword, isSeparated) in elses where !isSeparated {
			file.report(
				.ifChainSeparation,
				at: keyword.positionAfterSkippingLeadingTrivia,
				message: "This `} else` has no blank line before it while another branch of the chain has one; "
				+ "an expanded chain separates every branch."
			)
		}
	}

	// ❌ let output: String = if forceUppercase { string.uppercased() } else { string }
	// `if let` and `if case` bind values a ternary can't, so only plain conditions count.
	private func checkIfExpressionAssignment(_ node: IfExprSyntax) {
		guard
			node.parent?.is(InitializerClauseSyntax.self) == true,
			node.conditions.allSatisfy(Self.isPlainCondition),
			let elseBlock = node.elseBody?.as(CodeBlockSyntax.self),
			Self.isSingleExpression(node.body),
			Self.isSingleExpression(elseBlock),
			file.startLine(of: node) == file.endLine(of: node)
		else { return }

		file.report(.ifExpressionAssignment, at: node.ifKeyword.positionAfterSkippingLeadingTrivia)
	}

	private static func isPlainCondition(_ element: ConditionElementSyntax) -> Bool {
		guard case .expression = element.condition else { return false }
		return true
	}

	private static func isSingleExpression(_ block: CodeBlockSyntax) -> Bool {
		block.statements.count == 1 && block.statements.first?.item.is(ExprSyntax.self) == true
	}

	// MARK: - Switch

	internal func checkSwitch(_ node: SwitchExprSyntax) {
		var cases: [SwitchCaseSyntax] = []

		for element in node.cases {
			// Cases inside `#if` have the directive's lines around them; leave such switches alone.
			guard let switchCase = element.as(SwitchCaseSyntax.self) else { return }
			cases.append(switchCase)
		}

		let followers: ArraySlice<SwitchCaseSyntax> = cases.dropFirst()
		let separation: [Bool] = followers.map { file.isBlank(line: file.firstLineIncludingComments(of: $0) - 1) }
		guard separation.contains(true), separation.contains(false) else { return }

		for (switchCase, isSeparated) in zip(followers, separation) where !isSeparated {
			file.report(
				.switchCaseSeparation,
				at: switchCase.positionAfterSkippingLeadingTrivia,
				message: "This case has no blank line before it while another case of the switch has one; "
				+ "an expanded switch separates every case after the first."
			)
		}
	}
}
