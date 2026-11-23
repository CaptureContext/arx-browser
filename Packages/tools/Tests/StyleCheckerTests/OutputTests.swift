import StyleChecker
import Testing

/// How findings print, and the rule catalog every finding names.
internal struct OutputTests {
	private static let finding: StyleFinding = .init(
		rule: .denseSpan,
		path: "Sources/A, B.swift",
		line: 12,
		column: 3,
		message: "80% condensed:\nsplit it"
	)

	@Test
	internal func plainWarning() {
		#expect(
			Self.finding.formatted(.plain)
			== "Sources/A, B.swift:12:3: warning: [dense-span] 80% condensed:\nsplit it"
		)
	}

	@Test
	internal func gitHubAnnotation() {
		#expect(
			Self.finding.formatted(.github)
			== "::warning file=Sources/A%2C B.swift,line=12,col=3,title=dense-span::80%25 condensed:%0Asplit it"
		)
	}

	@Test
	internal func everyRuleHasAUniqueIDAndASection() {
		let ids: [String] = StyleRule.all.map(\.id)

		#expect(Set(ids).count == ids.count)
		#expect(StyleRule.all.allSatisfy { !$0.section.isEmpty && !$0.summary.isEmpty })
	}
}
