import AppUI
import Foundation
import _ComposableArchitecture

/// Battery Saver turning on or off (DEV-915), as the engine reports it.
@CasePathable
public enum BatterySaverAction: Sendable {
	case changed(isActive: Bool)
}

/// Says so in the main window's sidebar when Battery Saver turns on, as Ardia's toast does.
@Reducer
internal struct BatterySaverNotice {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.batterySaver.changed) { state, isActive in
			guard isActive, state.windowIsOpen else { return .none }
			state.main.sidebar.message = String.localized(.appUI.batterySaver.on)
			return .none
		}
	}
}
