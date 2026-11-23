import BrowserCore
import CommandBarFeature

extension LittleArxFeature {
	/// A command bar belongs to the temporary session that presented it.
	public struct CommandBarContext: Equatable, Sendable {
		public let tabID: BrowserCore.Tab.ID
		public let profileID: Profile.ID
		public let spaceID: Space.ID
		public let viewerTabID: BrowserCore.Tab.ID?
		public let generation: Int
		public let isCommandOnly: Bool
		public let mode: CommandBarFeature.Mode
		public let presentationID: Int

		public init(
			window: LittleArxFeature.State,
			mode: CommandBarFeature.Mode
		) {
			self.tabID = window.tab.id
			self.profileID = window.tab.profileID
			self.spaceID = window.spaceID
			self.viewerTabID = window.viewer.tab?.id
			self.generation = window.viewer.generation
			self.isCommandOnly = window.isCommandOnly
			self.mode = mode
			self.presentationID = window.commandBar.focusRequest + 1
		}

		public func matches(_ window: LittleArxFeature.State) -> Bool {
			window.peekID == nil
			&& !window.isClosing
			&& !window.isSwitchingProfile
			&& !window.isPromoting
			&& window.tab.id == tabID
			&& window.tab.profileID == profileID
			&& window.spaceID == spaceID
			&& window.viewer.tab?.id == viewerTabID
			&& window.viewer.generation == generation
			&& window.isCommandOnly == isCommandOnly
			&& window.commandBar.focusRequest == presentationID
		}

		internal func matches(
			_ window: LittleArxFeature.State,
			execution: CommandBarFeature.Execution
		) -> Bool {
			matches(window) && execution.mode == mode && execution.presentationID == presentationID
		}
	}
}

extension LittleArxFeature.State {
	internal mutating func invalidateCommandBar() {
		commandBarContext = nil
		profilePicker = nil
		commandBar.isPresented = false
		if commandBar.focusRequest > 0 { commandBar.focusRequest += 1 }
	}
}
