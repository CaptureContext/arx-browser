import StyleChecker
import Testing

/// The calls-and-operators reference's examples, and the ternary part of control-flow.
internal struct OperatorRuleTests {
	// MARK: - Ternaries

	@Test
	internal func guideCorrectTernariesPass() {
		let source: String = """
			func correct() -> Int? {
				let value = condition
				? true
				: false

				let value = condition ? true : false

				return isPrimeRequred
				? (isRandom ? primeCandidates.random() : primeCandidates.first)
				: (isRandom ? allCandidates.random() : allCandidates.first)
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func continuationIndentedTernary() {
		let source: String = """
			func wrong() {
				let value = condition
					? true
					: false
			}
			"""

		#expect(lines(.ternaryIndentation, in: source) == [3, 4])
	}

	@Test
	internal func unparenthesizedNesting() {
		let source: String = """
			func wrong() {
				let value = input == .zero
				? 0 : input == .one
				? 1 : .max

				let other = isFirst ? isRandom ? a : b : c
			}
			"""

		#expect(lines(.ternaryNesting, in: source) == [4, 6])
	}

	// MARK: - Operators

	@Test
	internal func guideCorrectOperatorChainsPass() {
		let source: String = """
			func correct() {
				let value = condition1
				&& (
					condition2
					|| condition3
					|| condition4
				)
				&& !condition5

				let f = f3
				<<< f2
				<<< f1
				<<< f0

				let value = condition1 && (condition2 || condition3)
				let f = f3 <<< f2 <<< f1 <<< f0
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func trailingOperators() {
		let source: String = """
			func wrong() {
				let value = condition1 && (
					condition2 ||
					condition3 ||
					condition4
				) && condition5

				let f = f3 <<<
				f2 <<<
				f1 <<<
				f0

				let value = condition ?
				true :
				false
			}
			"""

		#expect(lines(.trailingOperator, in: source) == [3, 4, 8, 9, 10, 13, 14])
	}

	// MARK: - Calls

	@Test
	internal func guideCorrectCallsPass() {
		let source: String = """
			func correct() {
				print(sum(2, 2))
				super.viewDidAppear(animated: animated)

				let cardView: CardView = .init(
					model: cardModel,
					style: cardStyle
				)

				someFunction(
					arg1: 0,
					arg2: 1
				)

				run(after: 2, perform: {
					work()
				})
			}

			func sendRequest(
				_ request: URLRequest,
				using session: URLSession
			) async throws -> (Data, Response) {
				try await session.data(for: request)
			}

			func sum(_ a: Int, _ b: Int) -> Int { a + b }
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func objectiveCStyleAlignment() {
		let source: String = """
			func wrong() {
				someFunction(arg1: 0,
					arg2: 1)
			}

			func sendRequest(_ request: URLRequest,
				using session: URLSession) {}
			"""

		#expect(lines(.argumentAlignment, in: source) == [2, 6])
	}
}
