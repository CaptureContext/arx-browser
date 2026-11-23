import SwiftSyntax

/// Walks a file once and hands each node to the rules that look at its kind.
///
/// Overrides live here because extensions can't override; the rules themselves are in the
/// extensions next to this file, one per guide reference.
internal final class StyleVisitor: SyntaxVisitor {
	internal let file: SourceContext

	internal init(file: SourceContext) {
		self.file = file
		super.init(viewMode: .sourceAccurate)
	}

	internal override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
		checkGuard(node)
		return .visitChildren
	}

	internal override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
		checkIf(node)
		return .visitChildren
	}

	internal override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
		checkSwitch(node)
		return .visitChildren
	}

	internal override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
		checkOperators(node)
		return .visitChildren
	}

	internal override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
		checkArguments(node)
		checkReduce(node)
		return .visitChildren
	}

	internal override func visit(_ node: FunctionParameterClauseSyntax) -> SyntaxVisitorContinueKind {
		checkParameters(node)
		return .visitChildren
	}

	internal override func visit(_ node: AttributeListSyntax) -> SyntaxVisitorContinueKind {
		checkAttributePlacement(node)
		return .visitChildren
	}

	internal override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
		checkStateAttribute(node)
		return .visitChildren
	}

	internal override func visit(_ node: MemberBlockItemListSyntax) -> SyntaxVisitorContinueKind {
		checkAttributedSpacing(node.map { Syntax($0.decl) })
		return .visitChildren
	}

	internal override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
		checkAttributedSpacing(node.map { Syntax($0.item) })
		return .visitChildren
	}

	internal override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
		checkPropertyType(node)
		return .visitChildren
	}

	internal override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
		checkActionDomains(node)
		return .visitChildren
	}

	internal override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
		checkReducerName(node.name, attributes: node.attributes)
		return .visitChildren
	}

	internal override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
		checkLegacyReduce(node)
		return .visitChildren
	}

	internal override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
		protectMultilineString(node)
		return .visitChildren
	}

	internal override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
		protectBlockComments(token)
		checkLegacyViewStore(token)
		return .visitChildren
	}
}
