import LittleArxFeature
import MainFeature

extension AppFeature {
	/// Optional provenance for accepted command-bar results; native menus use their ordinary target.
	public enum CommandSource: Equatable, Sendable {
		case main(CommandBarContext)
		case little(LittleArxFeature.CommandBarContext)

		internal func matches(
			_ state: AppFeature.State,
			target: CommandTarget
		) -> Bool {
			guard case let .window(id, paneID) = target else { return false }

			switch self {
			case let .main(source):
				guard paneID == source.paneID else { return false }
				if id == state.main.id { return state.windowIsOpen && source.matches(state.main) }
				return state.windows[id: id].map { source.matches($0) } ?? false

			case let .little(source):
				guard paneID == nil else { return false }
				return state.littleWindows[id: id].map { source.matches($0) } ?? false
			}
		}
	}
}
