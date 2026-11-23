import DefaultBrowserClient
import _ComposableArchitecture

/// "Links from other apps": makes Arx the default browser.
///
/// The step finishes only when Arx actually is the default, either after the person
/// confirms macOS's prompt or because it already was. Declining keeps the page open
/// and records nothing; Not Now (the footer's Skip) moves on without recording either.
@Reducer
public struct OnboardingDefaultBrowser {
	@ObservableState
	public struct State: Equatable, Sendable {
		/// The last status read from the system; `nil` until the page first checks.
		public var status: DefaultBrowserClient.Status?

		/// Whether macOS's confirmation may be showing.
		public var isRequesting: Bool

		/// The result of the last Make Default, so a declined prompt can be explained.
		public var outcome: DefaultBrowserClient.Outcome?

		public init(
			status: DefaultBrowserClient.Status? = nil,
			isRequesting: Bool = false,
			outcome: DefaultBrowserClient.Outcome? = nil
		) {
			self.status = status
			self.isRequesting = isRequesting
			self.outcome = outcome
		}

		/// Whether Make Default is offered: Arx isn't the default and the system can be asked.
		public var canMakeDefault: Bool {
			guard case .otherBrowser = status
			else { return false }

			return true
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// The page appeared; reads the current default.
			case task

			/// Make Default, also on Return.
			case makeDefault
		}

		@CasePathable
		public enum Event: Sendable {
			/// The app became active again; the person may have changed the default in System Settings.
			case applicationBecameActive
			case statusChecked(DefaultBrowserClient.Status)
			case requestFinished(DefaultBrowserClient.Outcome)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// Make Default left Arx as the default; the parent records the step and moves on.
			case madeDefault

			/// Arx turned out to be the default already; the parent records the step and stays.
			case foundDefault
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.defaultBrowser)
	private var defaultBrowser

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.task) { _ in
			check()
		}

		Pullback(\.event.applicationBecameActive) { state in
			guard !state.isRequesting else { return .none }

			return check()
		}

		Pullback(\.event.statusChecked) { state, status in
			let wasDefault: Bool = state.status == .isDefault
			state.status = status
			guard status == .isDefault, !wasDefault
			else { return .none }

			return .send(.delegate(.foundDefault))
		}

		Pullback(\.ui.makeDefault) { state in
			guard state.canMakeDefault, !state.isRequesting
			else { return .none }

			state.isRequesting = true
			state.outcome = nil

			// The page can't be left while this runs, so it isn't cancellable;
			// a check still in flight would only report the old status.
			return .merge(
				.cancel(id: Cancellation.check),
				.run { [defaultBrowser] send in
					await send(.event(.requestFinished(defaultBrowser.makeDefault())))
				}
			)
		}

		Pullback(\.event.requestFinished) { state, outcome in
			state.isRequesting = false
			state.outcome = outcome
			switch outcome {
			case .accepted, .alreadyDefault:
				state.status = .isDefault
				return .send(.delegate(.madeDefault))

			case .declined:
				return check()

			case .unavailable:
				state.status = .unavailable
				return .none
			}
		}
	}

	/// Cancels a pending status check, so leaving the page drops its result.
	public static func cancelInFlightWork<Action>() -> Effect<Action> {
		.cancel(id: Cancellation.check)
	}

	private func check() -> Effect<Action> {
		.run { [defaultBrowser] send in
			await send(.event(.statusChecked(defaultBrowser.status())))
		}
		.cancellable(id: Cancellation.check, cancelInFlight: true)
	}

	private enum Cancellation: Hashable {
		case check
	}
}
