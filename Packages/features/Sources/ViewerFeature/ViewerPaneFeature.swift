import Foundation
import ViewerItemFeature
import _ComposableArchitecture

/// A placement owns observation and presentation, never the native tab session.
@Reducer
public struct ViewerPaneFeature {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public let id: UUID
		public var item: ViewerItemFeature.State

		public init(
			id: UUID,
			item: ViewerItemFeature.State = .init()
		) {
			self.id = id
			self.item = item
		}
	}

	@CasePathable
	public enum Action: Sendable {
		/// The pane's item, which owns everything the pane does; the pane only places it.
		case item(ViewerItemFeature.Action)
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
		Scope(state: \.item, action: \.item) { ViewerItemFeature() }
	}
}
