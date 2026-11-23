import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

extension AppFeature.State {
	/// The sheet for `event`'s request, on the window showing its tab. Nil when no window shows
	/// it, or another request's sheet is up: that request is cancelled.
	internal func deviceChooserPrompt(for event: BrowserDeviceChooserEvent) -> DeviceChooserPrompt.State? {
		guard
			!shouldQuit,
			let chooser = event.chooser,
			deviceChooser == nil || deviceChooser?.tabID == event.tabID,
			let windowID = windowShowing(event.tabID)
		else { return nil }

		return .init(windowID: windowID, tabID: event.tabID, chooser: chooser)
	}
}

/// Device requests reach their tab's window as a sheet (DEV-905).
@Reducer
internal struct DeviceChooserRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.deviceChoosers)
	private var deviceChoosers

	internal var body: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.deviceChoosers.observe) { _ in
				.run { [deviceChoosers] send in
					for await event in await deviceChoosers.events() {
						await send(.deviceChoosers(.changed(event)))
					}
				}
				.cancellable(id: Cancellation.observe, cancelInFlight: true)
			}

			Pullback(\.deviceChoosers.changed) { state, event in
				guard let chooser = event.chooser else {
					// The page closed its request, or it was answered.
					if state.deviceChooser?.tabID == event.tabID { state.deviceChooser = nil }
					return .none
				}
				if var current = state.deviceChooser, current.tabID == event.tabID, current.chooser.token == chooser.token {
					// Indices may now name other devices: a changed list clears the choice.
					if current.chooser.options != chooser.options { current.selection = [] }
					current.chooser = chooser
					state.deviceChooser = current
					return .none
				}
				guard let prompt = state.deviceChooserPrompt(for: event) else {
					let (tabID, token) = (event.tabID, chooser.token)
					MainActor.assumeIsolated { [deviceChoosers] in _ = deviceChoosers.answer(tabID, token, 0, []) }
					return .none
				}
				state.deviceChooser = prompt
				return .none
			}

			Pullback(\.deviceChooser.delegate.answered) { state in
				state.deviceChooser = nil
				return .none
			}
		}
		.ifLet(\.deviceChooser, action: \.deviceChooser) { DeviceChooserPrompt() }
	}

	private enum Cancellation: Hashable {
		case observe
	}
}
