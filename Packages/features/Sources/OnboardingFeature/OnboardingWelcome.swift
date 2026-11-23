import _ComposableArchitecture

/// The first page: the Arx logo, the wordmark, a tagline and Get Started.
///
/// Its entrance animation is view-local, so nothing per-frame goes through the store.
@Reducer
public struct OnboardingWelcome {
	@ObservableState
	public struct State: Equatable, Sendable {
		public init() {}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case getStarted
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {
			/// Get Started finished the welcome step.
			case finished
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.getStarted) { _ in
			.send(.delegate(.finished))
		}
	}
}
