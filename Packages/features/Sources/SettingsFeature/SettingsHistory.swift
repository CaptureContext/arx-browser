import BrowserCore
import _ComposableArchitecture

public struct HistoryStatus: Equatable {
	public var count: Int
	public var error: String?
	public var isWorking: Bool

	public init(
		count: Int = 0,
		error: String? = nil,
		isWorking: Bool = false
	) {
		self.count = count
		self.error = error
		self.isWorking = isWorking
	}
}

@Reducer
internal struct SettingsHistory {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.requestClearHistory) { state, id in
			guard state.historyStatus[id]?.isWorking != true else { return .none }
			state.pendingHistoryClearID = id
			return .none
		}
		Pullback(\.ui.cancelClearHistory) { state in
			state.pendingHistoryClearID = nil
			return .none
		}
		Pullback(\.ui.confirmClearHistory) { state in
			guard let id = state.pendingHistoryClearID else { return .none }
			state.pendingHistoryClearID = nil
			state.historyStatus[id, default: .init()].isWorking = true
			return .send(.delegate(.clearHistory(id)))
		}
		Pullback(\.ui.retryHistory) { state, id in
			guard state.historyStatus[id]?.isWorking != true else { return .none }
			state.historyStatus[id, default: .init()].isWorking = true
			return .send(.delegate(.retryHistory(id)))
		}
	}
}
