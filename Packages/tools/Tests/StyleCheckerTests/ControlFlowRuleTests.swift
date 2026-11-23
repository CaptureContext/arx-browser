import StyleChecker
import Testing

/// The control-flow reference's own examples, wrapped in functions so they parse.
internal struct ControlFlowRuleTests {
	// MARK: - Guard

	@Test
	internal func guideCorrectGuardsPass() {
		let source: String = """
			func correct() throws -> Int? {
				guard let self else { return }

				guard let self
				else { return }

				guard let first = candidates.first(where: condition)
				else { throw LocalError.noMatchingCandidatesFound }

				guard let self else {
					logger.logError("self is missing")
					service.cleanup()
					return
				}

				guard let self else {
					throw LocalError.somthingUnexpectedHappened
				}

				guard
					let self,
					let firstInt,
					firstInt.isMultiple(of: 2)
				else { return nil }

				guard
					let self,
					let firstInt,
					firstInt.isMultiple(of: 2)
				else {
					logger.logError("something went wrong")
					service.cleanup()
					throw LocalError.unexpectedFailure
				}

				guard input.someConditionThatMustBeSatisfied()
				else { return cleanup() }

				guard input.someConditionThatMustBeSatisfied() else {
					// custom logic or multiple external calls
					return
				}

				guard isNumber, isFinite
				else { return nil }

				guard
					input.firstCondition,
					input.secondCondition
				else {
					// some more work
					return
				}

				guard let self else {
					// custom logic or multiple external calls
					return nil
				}
			}
			"""

		let guardRules: Set<String> = [
			StyleRule.guardConditionOnKeywordLine.id,
			StyleRule.guardSplitElseBlock.id,
			StyleRule.guardTrivialElseBlock.id,
		]

		#expect(ruleIDs(in: source).isDisjoint(with: guardRules))
	}

	@Test
	internal func firstConditionOnTheGuardLine() {
		let source: String = """
			func wrong() -> Int? {
				guard let self,
					let firstInt,
					firstInt.isMultiple(of: 2)
				else { return nil }
			}
			"""

		#expect(lines(.guardConditionOnKeywordLine, in: source) == [2])
	}

	@Test
	internal func multilineElseUnderAConditionOnTheGuardLine() {
		let source: String = """
			func wrong() throws {
				guard let pattern = loadAHAPPattern(named: "ShieldTransient")
				else {
					throw Failure.couldNotLoadAHAPPPattern
				}
			}
			"""

		#expect(lines(.guardSplitElseBlock, in: source) == [3])
	}

	@Test
	internal func trivialExitInAnExpandedElse() {
		let source: String = """
			func wrong() -> Int? {
				guard let self else {
					return nil
				}

				for value in values {
					guard value.isValid else {
						continue
					}
				}
			}
			"""

		#expect(lines(.guardTrivialElseBlock, in: source) == [2, 7])
	}

	@Test
	internal func leavesJudgementCallsAlone() {
		// The guide marks these wrong because of length and balance, which it leaves to the reader.
		let source: String = """
			func judgement() throws {
				guard let pattern = loadAHAPPattern(named: "ShieldTransient") else { return }

				guard let self
				else { throw LocalError.somthingUnexpectedHappened }
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	// MARK: - If

	@Test
	internal func guideCorrectIfsPass() {
		let source: String = """
			func correct() {
				if exitEarly { return }

				if isNumber, isFinite {
					work()
				} else {
					otherWork()
				}

				let isOddNumberValidAndCached = cache.contains(number)
				&& validate(number)
				&& !number.isMultiple(of: 2)

				if isOddNumberValidAndCached {
					work()
				}

				if condition {
					complexLogic()

				} else if otherCondition {
					simpleSibling()

				} else {
					otherWork()
				}
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func multilineConditionList() {
		let source: String = """
			func wrong() {
				if
					state.isReady,
					state.spaces.isEmpty
				{
					state.spaceMove = nil
				}

				if state.isReady,
					state.spaces.isEmpty {
					state.spaceMove = nil
				}
			}
			"""

		#expect(lines(.ifMultilineConditions, in: source) == [2, 9])
	}

	@Test
	internal func multilineBindingListTakesTheGuardLayout() {
		let source: String = """
			func right() {
				if
					let spaceID = state.spaceMove,
					state.spaces[id: spaceID] == nil
				{
					state.spaceMove = nil
				}

				if
					case let .open(id) = state.mode,
					id == target
				{
					close()
				}
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func expandedChainSeparatesEveryBranch() {
		let source: String = """
			func wrong() {
				if condition {
					complexLogic()

				} else if otherCondition {
					simpleSibling()
				} else {
					otherWork()
				}
			}
			"""

		#expect(lines(.ifChainSeparation, in: source) == [7])
	}

	@Test
	internal func ternaryPreferredToAOneLineIfExpression() {
		let source: String = """
			let output: String = if forceUppercase { string.uppercased() } else { string }
			let mode: Mode? = if case let .copy(mode) = item { mode } else { nil }
			let value = forceUppercase ? string.uppercased() : string
			"""

		#expect(lines(.ifExpressionAssignment, in: source) == [1])
	}

	// MARK: - Switch

	@Test
	internal func guideCorrectSwitchesPass() {
		let source: String = """
			func correct() {
				switch self {
				case .normal: .normal
				case .custom: .custom
				}

				switch action {
				case .someWork:
					someWork()
				case .someOtherWork:
					someOtherWork()
				}

				switch action {
				case .someWork1:
					someWork1()

				case .someWork2:
					someWork2()

				case .someWork3:
					// a comment above the case keeps the blank line before it
					someWork3()
				}

				let value: Int = switch input {
				case .zero: 0
				case .one: 1
				case .max: .max
				}
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func expandedSwitchSeparatesEveryCase() {
		let source: String = """
			func wrong() {
				switch action {
				case .someWork1:
					someWork1()

				case .someWork2:
					someWork2()
				case .someWork3:
					someWork3()

				// The comment belongs to the case, so the blank line before it counts.
				case .someWork4:
					someWork4()
				}
			}
			"""

		#expect(lines(.switchCaseSeparation, in: source) == [8])
	}
}
