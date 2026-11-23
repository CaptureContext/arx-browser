# arx-tools
Developer tools that run on the repository, not in the app. Requires macOS 27 or later and Swift 6.4.
## Boundaries

May depend on swift-syntax. Must not depend on the app's packages, and no app target links it.
## Targets
- [StyleCheck](Sources/StyleCheck/README.md): the `make style` command-line checker.
- [StyleChecker](Sources/StyleChecker/README.md): the rules StyleCheck runs.
- [StyleCheckerTests](Tests/StyleCheckerTests/README.md): the rules against the style guide's own examples.

## Style checks

`make style` (DEV-1280) runs three tools and prints every finding as a warning, `path:line:column: warning: [rule] message`, or as a GitHub annotation when `GITHUB_ACTIONS` is true. All three get the same explicit list of files: Arx's Swift files as Git lists them (tracked, or new and not ignored), never `Forks/`, the vendored `Files.swift`, or anything under `.build`, `build`, `vendor` or another dependency or build folder; SwiftLint gets the production part of that list. The summary gives each tool's version and how many files it checked, and names the binary when its version isn't the one `mise.toml` pins. It exits 0 whatever they find and fails only when a tool crashes. A missing `swiftformat` or `swiftlint` is reported as skipped; `mise install` installs the versions pinned in `mise.toml`. Nothing is rewritten. `make check` and CI don't fail on findings.

Every rule states something the `swift-style` guide states, or `.agents/AGENTS.md` for the architecture rules. Where the guide asks for judgement ("use blank lines to reveal semantic structure, not mechanically", "do not flatten intentional layouts into formatter defaults"), nothing checks it.

### SwiftFormat (`.swiftformat`, lint mode)

| Rule | Guide |
| --- | --- |
| `trailingSpace`, `linebreakAtEndOfFile` | fundamentals › Indentation (`.editorconfig`) |
| `blockComments` | runtime-practices › Comments: `//` or `///`, not `/* */` |
| `typeSugar` | declarations › General rules: `Value?`, `[Value]`, `[Key: Value]` |
| `hoistPatternLet` | control-flow › Switch: `case let .x(value)` |
| `redundantGet` | declarations › General rules: no `get` in a read-only property |

No rule that wraps or indents is on: those would rewrite intentional layouts.

### SwiftLint (`.swiftlint.yml`, production sources only)

| Rule | Guide |
| --- | --- |
| `explicit_acl` | declarations › General rules: access control in production code |
| `modifier_order` | declarations › Declaration structure: access modifier, `override`, `static`/`final` |

Tests, scripts and manifests aren't production code, so SwiftLint skips them. `modifier_order` compares only the modifiers the guide orders.

### StyleCheck (this package)

| ID | Guide | Reports |
| --- | --- | --- |
| `guard-condition-on-keyword-line` | control-flow › Guard | a guard whose conditions take several lines with the first on the `guard` line |
| `guard-split-else-block` | control-flow › Guard | `else` on its own line with a multiline body under a condition that starts on the `guard` line |
| `guard-trivial-else-block` | control-flow › Conditional statements, Guard | a multiline `else` holding only `return`, `return nil`, `return .none`, `break` or `continue` and no comment |
| `if-multiline-conditions` | control-flow › If | an `if` list of boolean conditions over several lines (a list with a binding, `if let` or `if case`, may take the guard's layout) |
| `if-chain-separation` | control-flow › Vertical whitespace | an `if` chain with a blank line before some `} else` and not others |
| `switch-case-separation` | control-flow › Vertical whitespace, Switch | a switch with a blank line before some cases and not others (a comment above a case belongs to it) |
| `ternary-indentation` | calls-and-operators › Operators | a `?` or `:` starting a line indented differently from the line its expression starts on |
| `ternary-nesting` | control-flow › Ternary operators | a ternary nested in another without parentheses |
| `if-expression-assignment` | control-flow › Ternary operators | a one-line `if` expression assigned where a ternary would do (not `if let` or `if case`) |
| `dense-span` | control-flow › Vertical whitespace | 120 or more lines in a row with no empty line, except a run of guards; string literal content doesn't count |
| `trailing-operator` | calls-and-operators › Operators | a line ending with a binary operator, `?` or `:` |
| `argument-alignment` | calls-and-operators › Function calls | a call or parameter list with the first item on the `(` line and a later one below it |
| `attribute-own-line` | declarations › General rules | a declaration attribute sharing its line (imports, parameters and types excepted) |
| `attributed-declaration-spacing` | declarations › General rules | an attributed declaration without a blank line before it or after it |
| `swiftui-state-qualified` | declarations › General rules | `@State` instead of `@SwiftUI.State` |
| `explicit-property-type` | declarations › General rules | a property whose type is inferred from its value, unless the value is a configuring call with a trailing closure; local variables are exempt |
| `tab-indentation` | fundamentals › Indentation | a space in a line's indentation, outside string literals and block comments |
| `comment-spacing` | runtime-practices › Comments | a comment that follows code in its scope with no blank line before it (first line of a scope, expression continuations, attributes and directives are exempt) |
| `documentation-parameters` | runtime-practices › Comments | a `- Parameter` entry instead of a `- Parameters` list |
| `action-domains` | AGENTS.md, feature actions | a `@Reducer` struct's `Action` missing `ui`, `event`, `delegate` or `observation` |
| `reduce-switch` | AGENTS.md, feature actions | a `Reduce` closure switching over its action instead of `Pullback` handlers |
| `reducer-name-suffix` | swift-composable-architecture, basic feature | a `@Reducer` type named `…Reducer` |
| `reducer-action-equatable` | swift-composable-architecture, basic feature | a `@Reducer` struct's `Action` conforming to `Equatable` (an `Action` enum outside a reducer is exempt) |
| `legacy-view-store` | swift-composable-architecture, SwiftUI | `ViewStore` or `WithViewStore` |
| `legacy-reduce-into` | swift-composable-architecture, basic feature | a `reduce(into:action:)` method instead of a `body` |

`StyleCheck --list-rules` prints the same list. Run it alone with `swift run --package-path Packages/tools StyleCheck [--github] PATH...`.

### Where a tool disagreed with a skill (22 November, DEV-1280 follow-up)

The skills win; each row says how the disagreement was settled. Run on 2,169 files before and after: 99 SwiftLint, 1 SwiftFormat and 894 StyleCheck findings became 99, 1 and 729.

| Tool and rule | Disagreement | Settled |
| --- | --- | --- |
| StyleCheck `if-multiline-conditions` | Flagged 108 of 119 `if` lists that bind (`if\n\tlet a = …,\n\tb == c\n{`). The guide says to extract a named value, which a binding can't be, and says to "apply the same visual-separation approach to other conditional statements" as it gives `guard`. | Lists with a binding are exempt; boolean-only lists are still reported (11). |
| StyleCheck `dense-span` | 75 lines is a mechanical count, and the guide says blank lines must reveal structure "not mechanically" and not be added when they say nothing. Most hits were enum case tables, `init` assignments and parameter lists. | Threshold 120 (85 findings became 25). |
| SwiftLint `explicit_acl` | Flags `private(set) var x` for its getter. The guide asks for an access modifier on every declaration. | Kept: write `internal private(set) var`. |
| SwiftLint `modifier_order` | None: `override internal` is the wrong order for "access modifier, `override`, `static`/`final`". | Kept. |
| SwiftFormat `typeSugar` | None: `Optional<NSWindow>(x)` becomes `NSWindow?(x)`. | Kept. |
| SwiftFormat rules not enabled | `redundantSelf` (the guide requires `self` in initializers and where a method calls `super`), `redundantType` (the guide wants explicit types), `indent` and `wrap*` (the guide's layouts). | Left off, as before. |
| Silent on a skill rule | The TCA skill forbids `ViewStore`/`WithViewStore`, `reduce(into:)`, a `Reducer` suffix and an `Equatable` `Action`. | The four `reducer-*` and `legacy-*` rules above. They found three `reduce(into:)` implementations. |

Skill rules no tool checks, because they need intent or types: a struct's stored properties without default values and a designated initializer (the skill examples and TCA's `State` disagree, see the audit), explicit `self` in initializers, abbreviations and vague type names, `final` classes, `try?` against `withErrorReporting`, and grouping and alphabetizing in a reducer.

### Left out on purpose

- Line length, one-line guards that are too long, and when an `else`, a case or an `if` branch is complex enough to expand: the guide decides these by balance and weight.
- Where blank lines go, beyond the 75-line span and sibling consistency.
- SwiftFormat's `acronyms`: it reports system and Chromium names such as `kCFStringEncodingInvalidId` that Arx can't rename.
- SwiftFormat's `wrapAttributes`: it splits closure types such as `@MainActor @Sendable () async -> T` in a property's type.
- SwiftFormat's `indent`, `wrap*` and `modifierOrder` rules: they re-indent, rewrap, or duplicate `modifier_order`.
- SwiftLint's `explicit_type_interface`: it can't exempt property wrappers and macros, which the guide does, so StyleCheck checks property types instead. Its `attributes` rule keeps variable attributes on their line by default, against the guide; `syntactic_sugar` and `implicit_getter` repeat SwiftFormat rules.
- SwiftLint's naming rules (`identifier_name`, `type_name`): they judge length, and the guide allows short names in small functions.
- `try?` and `final` classes: the guide prefers IssueReporting and `final` by intent, which a tool can't see.
