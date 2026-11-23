import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// A tab's Cast picker (DEV-927), as a sheet on the tab's window: the Chromecasts and other
/// cast devices Chrome's Media Router finds, to cast the tab or the site's own video to, and
/// what each casts now, to stop.
@Reducer
public struct CastPicker {
	@ObservableState
	public struct State: Equatable {
		public let windowID: UUID
		public let tabID: BrowserCore.Tab.ID
		public var picker: BrowserCastPicker

		public init(
			windowID: UUID,
			tabID: BrowserCore.Tab.ID,
			picker: BrowserCastPicker
		) {
			self.windowID = windowID
			self.tabID = tabID
			self.picker = picker
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
			/// Casts to the device, nil choosing as Chrome does, or clears its problem.
			case deviceChosen(String, BrowserCastPicker.Device.Mode?)
			case stopButtonTapped(route: String)
			case doneButtonTapped
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {
			/// The person closed the picker; the sheet goes.
			case closed
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.cast)
	private var cast

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.deviceChosen) { state, choice in
			let (device, mode) = choice
			guard state.picker.devices.contains(where: { $0.id == device && $0.canChoose })
			else { return .none }

			let tabID = state.tabID

			// The engine closes the picker once casting starts.
			MainActor.assumeIsolated { [cast] in _ = cast.choose(tabID, device, mode) }
			return .none
		}

		Pullback(\.ui.stopButtonTapped) { state, route in
			guard state.picker.devices.contains(where: { $0.route == route }) else { return .none }

			let tabID = state.tabID
			MainActor.assumeIsolated { [cast] in _ = cast.stop(tabID, route) }
			return .none
		}

		Pullback(\.ui.doneButtonTapped) { state in
			let tabID = state.tabID

			// A site's request that chose nothing fails, as when Chrome's dialog closes.
			MainActor.assumeIsolated { [cast] in cast.close(tabID) }
			return .send(.delegate(.closed))
		}
	}
}
