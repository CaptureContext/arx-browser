# StyleChecker

The swift-syntax rules behind `make style`. `StyleChecker.check(source:path:)` parses one file and returns its findings; `StyleRule.all` lists every rule with its ID, the guide section it comes from and what it asks for. The table is in the [package README](../../README.md#stylecheck-this-package).

One `SyntaxVisitor` walks each file and hands nodes to the rules, grouped by guide reference: `ControlFlowRules`, `OperatorRules`, `DeclarationRules`, `ArchitectureRules`. `LineRules` reads lines afterwards, skipping string literal content and block comment text the walk marked. Operators come from the parser's unfolded sequences, so custom operators need no table.

A rule reports only what the guide's examples settle without judgement: which line a part starts on, whether siblings agree, whether a declaration has a type.
