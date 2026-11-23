import StyleChecker
import Testing

/// The Composable Architecture conventions in `.agents/AGENTS.md`.
internal struct ArchitectureRuleTests {
	@Test
	internal func conventionalFeaturePasses() {
		let source: String = """
			@Reducer
			public struct DownloadsFeature {
				@CasePathable
				public enum Action: Sendable {
					case soundOutcomes
					case ui(UI)
					case event(Event)
					case delegate(Delegate)
					case observation(ObservationAction<Observation>)

					public enum UI: Sendable {}

					public enum Event: Sendable {}

					public enum Delegate: Sendable {}

					public enum Observation: Sendable {}
				}

				public var body: some ReducerOf<Self> {
					Pullback(\\.ui.openDownloads) { state in
						state.isPresented = true
						return .none
					}

					Reduce { state, _ in
						state.publish()
						return .none
					}

					Reduce { state, action in
						guard action.is(\\.main.ui.task) else { return .none }
						return state.load()
					}
				}
			}

			@Reducer
			internal struct AppDownloads {
				internal typealias Action = AppFeature.Action
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}

	@Test
	internal func missingActionDomains() {
		let source: String = """
			@Reducer
			public struct FloatingSiteMenu {
				public enum Action: Sendable {
					case siteMenu(SiteMenuFeature.Action)
					case ui(UI)
					case delegate(Delegate)
				}
			}
			"""

		let findings: [StyleFinding] = StyleChecker.check(source: source, path: "Example.swift")
			.filter { $0.rule == .actionDomains }

		#expect(findings.map(\.line) == [3])
		#expect(findings.first?.message.contains("`event`, `observation`") == true)
	}

	@Test
	internal func switchOverActionsInReduce() {
		let source: String = """
			@Reducer
			public struct MainFeature {
				public var body: some ReducerOf<Self> {
					Reduce { state, action in
						switch action {
						case .ui(.appeared):
							return .none

						default:
							return .none
						}
					}

					Reduce { state, action in
						switch state.mode {
						case .idle: return .none
						case .busy: return .none
						}
					}
				}
			}
			"""

		#expect(lines(.reduceSwitch, in: source) == [5])
	}

	@Test
	internal func legacyTCAConventions() {
		let source: String = """
			@Reducer
			public struct CounterReducer {
				public enum Action: Equatable, Sendable {
					case ui(UI)
					case event(Event)
					case delegate(Delegate)
					case observation(Observation)

					public enum UI: Sendable {}

					public enum Event: Sendable {}

					public enum Delegate: Sendable {}

					public enum Observation: Sendable {}
				}

				public func reduce(into state: inout State, action: Action) -> Effect<Action> {
					.none
				}
			}

			struct CounterView {
				var body: some View {
					WithViewStore(store, observe: { $0 }) { viewStore in
						Text("\\(viewStore.count)")
					}
				}
			}
			"""

		#expect(lines(.reducerNameSuffix, in: source) == [2])
		#expect(lines(.reducerActionEquatable, in: source) == [3])
		#expect(lines(.legacyReduceInto, in: source) == [18])
		#expect(lines(.legacyViewStore, in: source) == [25])
	}

	@Test
	internal func actionEnumsOutsideReducersMayBeEquatable() {
		let source: String = """
			public struct DownloadsPage: View {
				public enum Action: Equatable, Sendable {
					case open
				}
			}
			"""

		#expect(ruleIDs(in: source).isEmpty)
	}
}
