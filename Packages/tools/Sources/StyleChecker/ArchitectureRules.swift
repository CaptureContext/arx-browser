import SwiftSyntax

// The Composable Architecture conventions written in `.agents/AGENTS.md`: feature actions in
// `ui`, `event`, `delegate` and `observation` domains, and `Pullback` handlers instead of one
// `Reduce` that switches over every action.

extension StyleVisitor {
	internal static let actionDomains: [String] = ["ui", "event", "delegate", "observation"]

	private static func isReducer(_ attributes: AttributeListSyntax) -> Bool {
		attributes.contains { element in
			guard let attribute = element.as(AttributeSyntax.self) else { return false }
			return attribute.attributeName.trimmedDescription == "Reducer"
		}
	}

	// MARK: - Reducer conventions

	// ❌ @Reducer struct CounterReducer
	internal func checkReducerName(_ name: TokenSyntax, attributes: AttributeListSyntax) {
		guard Self.isReducer(attributes), name.text.hasSuffix("Reducer"), name.text != "Reducer" else { return }
		file.report(.reducerNameSuffix, at: name.positionAfterSkippingLeadingTrivia)
	}

	// ❌ func reduce(into state: inout State, action: Action) -> Effect<Action>
	internal func checkLegacyReduce(_ node: FunctionDeclSyntax) {
		guard node.name.text == "reduce" else { return }

		let labels: [String] = node.signature.parameterClause.parameters.map(\.firstName.text)
		guard labels == ["into", "action"] else { return }

		file.report(.legacyReduceInto, at: node.name.positionAfterSkippingLeadingTrivia)
	}

	// ❌ WithViewStore(store, observe: { $0 }) { viewStore in … }
	internal func checkLegacyViewStore(_ token: TokenSyntax) {
		guard
			token.tokenKind == .identifier("ViewStore") || token.tokenKind == .identifier("WithViewStore")
		else { return }

		file.report(.legacyViewStore, at: token.positionAfterSkippingLeadingTrivia)
	}

	// MARK: - Action domains

	internal func checkActionDomains(_ node: StructDeclSyntax) {
		checkReducerName(node.name, attributes: node.attributes)
		guard Self.isReducer(node.attributes) else { return }

		// Reducers that compose a parent's domain declare `typealias Action` and have no enum to check.
		let action: EnumDeclSyntax? = node.memberBlock.members
			.lazy
			.compactMap { $0.decl.as(EnumDeclSyntax.self) }
			.first { $0.name.text == "Action" }

		guard let action else { return }

		let conformsToEquatable: Bool = action.inheritanceClause?.inheritedTypes.contains {
			$0.type.trimmedDescription == "Equatable"
		} == true

		if conformsToEquatable {
			file.report(.reducerActionEquatable, at: action.name.positionAfterSkippingLeadingTrivia)
		}

		let caseNames: Set<String> = .init(
			action.memberBlock.members
				.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
				.flatMap(\.elements)
				.map(\.name.text)
		)

		let missing: [String] = Self.actionDomains.filter { !caseNames.contains($0) }
		guard !missing.isEmpty else { return }

		file.report(
			.actionDomains,
			at: action.name.positionAfterSkippingLeadingTrivia,
			message: "`\(node.name.text).Action` has no "
			+ missing.map { "`\($0)`" }.joined(separator: ", ")
			+ " domain; keep all four, empty when unused."
		)
	}

	// MARK: - Reduce

	// ❌ Reduce { state, action in
	// 	switch action {
	internal func checkReduce(_ node: FunctionCallExprSyntax) {
		guard node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Reduce"
		else { return }

		let closure: ClosureExprSyntax? = node.trailingClosure
		?? node.arguments.first?.expression.as(ClosureExprSyntax.self)

		guard
			let closure,
			let actionName = Self.actionParameterName(closure)
		else { return }

		let switches: [SwitchExprSyntax] = closure.statements.flatMap { statement in
			statement.tokens(viewMode: .sourceAccurate)
				.filter { $0.tokenKind == .keyword(.switch) }
				.compactMap { $0.parent?.as(SwitchExprSyntax.self) }
		}

		for switchExpression in switches {
			let subject: String? = switchExpression.subject.as(DeclReferenceExprSyntax.self)?.baseName.text
			guard subject == actionName else { continue }

			file.report(.reduceSwitch, at: switchExpression.switchKeyword.positionAfterSkippingLeadingTrivia)
		}
	}

	/// The name of a reducer closure's second parameter, the action, unless it's ignored.
	private static func actionParameterName(_ closure: ClosureExprSyntax) -> String? {
		let names: [String] = switch closure.signature?.parameterClause {
		case let .simpleInput(parameters):
			parameters.map(\.name.text)

		case let .parameterClause(clause):
			clause.parameters.map { ($0.secondName ?? $0.firstName).text }

		case nil:
			[]
		}

		guard names.count == 2, names[1] != "_" else { return nil }
		return names[1]
	}
}
