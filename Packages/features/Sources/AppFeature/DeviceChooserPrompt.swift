import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// A page's request for a USB, HID, serial or Bluetooth device (DEV-905), as a sheet on the
/// page's window: the matching devices, Connect and Cancel, and Scan Again for Bluetooth.
@Reducer
public struct DeviceChooserPrompt {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public let windowID: UUID
		public let tabID: BrowserCore.Tab.ID
		public var chooser: BrowserDeviceChooser
		public var selection: Set<Int>

		public init(
			windowID: UUID,
			tabID: BrowserCore.Tab.ID,
			chooser: BrowserDeviceChooser,
			selection: Set<Int> = []
		) {
			self.windowID = windowID
			self.tabID = tabID
			self.chooser = chooser
			self.selection = selection
		}

		public var id: UInt64 { chooser.token }

		public var canConnect: Bool {
			!selection.isEmpty && (chooser.allowsMultiple || selection.count == 1)
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
			case selectionChanged(Set<Int>)
			case connectButtonTapped
			case cancelButtonTapped
			case scanAgainButtonTapped
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {
			/// The person answered; the sheet closes.
			case answered
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.deviceChoosers)
	private var deviceChoosers

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.selectionChanged) { state, selection in
			let valid = selection.filter { state.chooser.options.indices.contains($0) }
			state.selection = state.chooser.allowsMultiple ? valid : Set(valid.sorted().suffix(1))
			return .none
		}

		Pullback(\.ui.connectButtonTapped) { state in
			guard state.canConnect else { return .none }
			let (tabID, token, revision, indices) = (
				state.tabID, state.chooser.token, state.chooser.revision, state.selection.sorted()
			)
			let answered = MainActor.assumeIsolated { [deviceChoosers] in
				deviceChoosers.answer(tabID, token, revision, indices)
			}

			// The list changed under the choice: the sheet stays for the person to choose again.
			guard answered else {
				state.selection = []
				return .none
			}
			return .send(.delegate(.answered))
		}

		Pullback(\.ui.cancelButtonTapped) { state in
			let (tabID, token) = (state.tabID, state.chooser.token)
			MainActor.assumeIsolated { [deviceChoosers] in _ = deviceChoosers.answer(tabID, token, 0, []) }
			return .send(.delegate(.answered))
		}

		Pullback(\.ui.scanAgainButtonTapped) { state in
			let (tabID, token) = (state.tabID, state.chooser.token)
			MainActor.assumeIsolated { [deviceChoosers] in _ = deviceChoosers.scanAgain(tabID, token) }
			return .none
		}
	}
}
