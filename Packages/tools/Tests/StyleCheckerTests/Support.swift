import StyleChecker

/// The lines where `rule` reports in `source`.
internal func lines(
	_ rule: StyleRule,
	in source: String
) -> [Int] {
	StyleChecker.check(source: source, path: "Example.swift")
		.filter { $0.rule == rule }
		.map(\.line)
}

/// Every rule that reports in `source`, by ID.
internal func ruleIDs(in source: String) -> Set<String> {
	Set(StyleChecker.check(source: source, path: "Example.swift").map(\.rule.id))
}
