import DefaultBrowserClient
import _ComposableArchitecture

/// The Default Browser row: shows whether Arx opens links from other apps and offers
/// Make Default when it doesn't. Checks again whenever the app becomes active.
@Reducer
internal struct SettingsDefaultBrowser {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.defaultBrowser)
	private var defaultBrowser

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.checkDefaultBrowser) { _ in
			check()
		}

		Pullback(\.event.applicationBecameActive) { state in
			guard !state.isRequestingDefaultBrowser else { return .none }

			return check()
		}

		Pullback(\.event.defaultBrowserChecked) { state, status in
			state.defaultBrowser = status
			if status == .isDefault {
				state.defaultBrowserOutcome = nil
			}
			return .none
		}

		Pullback(\.ui.makeDefaultBrowser) { state in
			guard
				case .otherBrowser = state.defaultBrowser,
				!state.isRequestingDefaultBrowser
			else { return .none }

			state.isRequestingDefaultBrowser = true
			state.defaultBrowserOutcome = nil
			return .merge(
				.cancel(id: Cancellation.check),
				.run { [defaultBrowser] send in
					await send(.event(.defaultBrowserRequestFinished(defaultBrowser.makeDefault())))
				}
			)
		}

		Pullback(\.event.defaultBrowserRequestFinished) { state, outcome in
			state.isRequestingDefaultBrowser = false
			state.defaultBrowserOutcome = outcome
			switch outcome {
			case .accepted, .alreadyDefault:
				state.defaultBrowser = .isDefault
				return .none

			case .declined:
				return check()

			case .unavailable:
				state.defaultBrowser = .unavailable
				return .none
			}
		}
	}

	private func check() -> Effect<Action> {
		.run { [defaultBrowser] send in
			await send(.event(.defaultBrowserChecked(defaultBrowser.status())))
		}
		.cancellable(id: Cancellation.check, cancelInFlight: true)
	}

	private enum Cancellation: Hashable {
		case check
	}
}
