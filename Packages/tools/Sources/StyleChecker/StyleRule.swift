/// One check and the place in the style guide, or in `.agents/AGENTS.md`, that it comes from.
public struct StyleRule: Hashable, Sendable {
	/// Stable kebab-case name printed in brackets with every finding.
	public let id: String

	/// The guide reference and section the rule enforces, such as `control-flow › Guard`.
	public let section: String

	/// What a finding asks for, in one sentence.
	public let summary: String

	public init(
		id: String,
		section: String,
		summary: String
	) {
		self.id = id
		self.section = section
		self.summary = summary
	}
}

// MARK: - Catalog

extension StyleRule {
	// MARK: Control flow

	public static let guardConditionOnKeywordLine: StyleRule = .init(
		id: "guard-condition-on-keyword-line",
		section: "swift-style control-flow › Guard (never use these shapes)",
		summary: "When a guard's conditions take several lines, put the first one on the line after `guard` too."
	)

	public static let guardSplitElseBlock: StyleRule = .init(
		id: "guard-split-else-block",
		section: "swift-style control-flow › Guard (never use these shapes)",
		summary: "An `else` on its own line under a condition that starts on the guard line takes a one-line body; write `guard condition else {` or move the conditions below `guard`."
	)

	public static let guardTrivialElseBlock: StyleRule = .init(
		id: "guard-trivial-else-block",
		section: "swift-style control-flow › Conditional statements, Guard",
		summary: "A bare return, `return nil`, `return .none`, `break` or `continue` stays on the `else` line: `else { return }`."
	)

	public static let ifMultilineConditions: StyleRule = .init(
		id: "if-multiline-conditions",
		section: "swift-style control-flow › If",
		summary: "Avoid multiline boolean condition lists in `if`: keep short conditions on one line, or extract a named local value. A list with a binding may take the guard's layout."
	)

	public static let ifChainSeparation: StyleRule = .init(
		id: "if-chain-separation",
		section: "swift-style control-flow › Vertical whitespace, Switch",
		summary: "Separate an `if` chain's branches consistently: a blank line before every `} else` or before none."
	)

	public static let switchCaseSeparation: StyleRule = .init(
		id: "switch-case-separation",
		section: "swift-style control-flow › Vertical whitespace, Switch",
		summary: "Separate a switch's cases consistently: a blank line before every case after the first, or before none."
	)

	public static let ternaryIndentation: StyleRule = .init(
		id: "ternary-indentation",
		section: "swift-style calls-and-operators › Operators",
		summary: "Align a multiline ternary's `?` and `:` with the line its expression starts on, not with continuation indentation."
	)

	public static let ternaryNesting: StyleRule = .init(
		id: "ternary-nesting",
		section: "swift-style control-flow › Ternary operators",
		summary: "Parenthesize a ternary nested in another one, or use a `switch` for the mapping."
	)

	public static let ifExpressionAssignment: StyleRule = .init(
		id: "if-expression-assignment",
		section: "swift-style control-flow › Ternary operators",
		summary: "Prefer a ternary to a one-line `if` expression for a simple assignment."
	)

	public static let denseSpan: StyleRule = .init(
		id: "dense-span",
		section: "swift-style control-flow › Vertical whitespace",
		summary: "120 or more lines in a row with no empty line: the code is probably too condensed to show its paragraphs."
	)

	public static let commentSpacing: StyleRule = .init(
		id: "comment-spacing",
		section: "arx-browser swift-style runtime-practices › Comments",
		summary: "Leave a blank line before a comment that starts a block of comments, unless it opens a scope or continues an expression."
	)

	// MARK: Calls and operators

	public static let trailingOperator: StyleRule = .init(
		id: "trailing-operator",
		section: "swift-style calls-and-operators › Operators",
		summary: "Lead continuation lines with their operators instead of ending a line with one."
	)

	public static let argumentAlignment: StyleRule = .init(
		id: "argument-alignment",
		section: "swift-style calls-and-operators › Function calls (Objective-C-style alignment)",
		summary: "Put every argument or parameter on its own line after the opening parenthesis, or all of them on its line."
	)

	// MARK: Declarations

	public static let attributeOwnLine: StyleRule = .init(
		id: "attribute-own-line",
		section: "swift-style declarations › General rules",
		summary: "Put every attribute on its own line."
	)

	public static let attributedDeclarationSpacing: StyleRule = .init(
		id: "attributed-declaration-spacing",
		section: "swift-style declarations › General rules",
		summary: "Separate an attributed declaration from adjacent declarations with a blank line."
	)

	public static let swiftUIStateQualified: StyleRule = .init(
		id: "swiftui-state-qualified",
		section: "swift-style declarations › General rules",
		summary: "Qualify SwiftUI state as `@SwiftUI.State`."
	)

	public static let explicitPropertyType: StyleRule = .init(
		id: "explicit-property-type",
		section: "swift-style declarations › General rules",
		summary: "Give a property an explicit type, unless a property wrapper or macro decides it or the right side names the type of a configuring call."
	)

	// MARK: Fundamentals and comments

	public static let tabIndentation: StyleRule = .init(
		id: "tab-indentation",
		section: "swift-style fundamentals › Indentation (.editorconfig)",
		summary: "Indent with tabs, as `.editorconfig` says."
	)

	public static let documentationParameters: StyleRule = .init(
		id: "documentation-parameters",
		section: "swift-style runtime-practices › Comments",
		summary: "Prefer a `- Parameters` list to individual `- Parameter` entries, even for one parameter."
	)

	// MARK: Architecture

	public static let actionDomains: StyleRule = .init(
		id: "action-domains",
		section: ".agents/AGENTS.md (feature actions)",
		summary: "Give a reducer's actions the `ui`, `event`, `delegate` and `observation` domains, keeping empty domains."
	)

	public static let reduceSwitch: StyleRule = .init(
		id: "reduce-switch",
		section: ".agents/AGENTS.md (feature actions)",
		summary: "Handle actions with `Pullback` handlers instead of switching over them in a `Reduce`."
	)

	public static let reducerNameSuffix: StyleRule = .init(
		id: "reducer-name-suffix",
		section: "swift-composable-architecture (basic feature)",
		summary: "Don't append `Reducer` to a `@Reducer` type's name."
	)

	public static let reducerActionEquatable: StyleRule = .init(
		id: "reducer-action-equatable",
		section: "swift-composable-architecture (basic feature)",
		summary: "Don't conform a reducer's `Action` to `Equatable`."
	)

	public static let legacyViewStore: StyleRule = .init(
		id: "legacy-view-store",
		section: "swift-composable-architecture (SwiftUI)",
		summary: "Don't use `ViewStore` or `WithViewStore`; read the store directly."
	)

	public static let legacyReduceInto: StyleRule = .init(
		id: "legacy-reduce-into",
		section: "swift-composable-architecture (basic feature)",
		summary: "Don't implement `reduce(into:action:)`; compose a `body`."
	)

	/// Every rule, in the order the README lists them.
	public static let all: [StyleRule] = [
		.guardConditionOnKeywordLine,
		.guardSplitElseBlock,
		.guardTrivialElseBlock,
		.ifMultilineConditions,
		.ifChainSeparation,
		.switchCaseSeparation,
		.ternaryIndentation,
		.ternaryNesting,
		.ifExpressionAssignment,
		.denseSpan,
		.commentSpacing,
		.trailingOperator,
		.argumentAlignment,
		.attributeOwnLine,
		.attributedDeclarationSpacing,
		.swiftUIStateQualified,
		.explicitPropertyType,
		.tabIndentation,
		.documentationParameters,
		.actionDomains,
		.reduceSwitch,
		.reducerNameSuffix,
		.reducerActionEquatable,
		.legacyViewStore,
		.legacyReduceInto,
	]
}
