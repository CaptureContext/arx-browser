import BrowserCore
import Foundation

extension LittleArxFeature {
	/// Close authority belongs to one request and the exact temporary viewer it approved.
	public struct CloseRequest: Equatable, Sendable {
		public let id: UUID
		public let tabID: BrowserCore.Tab.ID
		public let profileID: Profile.ID
		public let generation: Int

		/// Arx is archiving the idle window on its own (DEV-1138), not closing it for the person.
		public let isAutomatic: Bool

		internal init(
			id: UUID,
			window: State,
			isAutomatic: Bool = false
		) {
			self.id = id
			self.tabID = window.tab.id
			self.profileID = window.tab.profileID
			self.generation = window.viewer.generation
			self.isAutomatic = isAutomatic
		}

		public func matches(_ window: State) -> Bool {
			window.peekID == nil
			&& window.tab.id == tabID
			&& window.tab.profileID == profileID
			&& window.viewer.generation == generation
		}
	}
}
