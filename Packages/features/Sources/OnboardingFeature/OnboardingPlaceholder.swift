import BrowserCore
import _ComposableArchitecture

/// Stands in for a step whose page hasn't been built yet.
///
/// It has nothing to finish, so it never records its step: Continue and Skip both
/// only move on, and the real page later decides what finishing means.
@Reducer
public struct OnboardingPlaceholder {
	@ObservableState
	public struct State: Equatable, Sendable {
		public var step: OnboardingStep

		public init(step: OnboardingStep) {
			self.step = step
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		EmptyReducer()
	}
}
