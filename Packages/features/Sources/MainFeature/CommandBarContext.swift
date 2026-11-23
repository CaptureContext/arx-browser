import BrowserCore
import CommandBarFeature
import Foundation

/// Source identity captured when presenting a command bar; focus changes do not retarget it.
public struct CommandBarContext: Equatable, Sendable {
	public let paneID: UUID
	public let tabID: BrowserCore.Tab.ID?
	public let generation: Int
	public let spaceID: Space.ID
	public let profileID: Profile.ID
	public let mode: CommandBarFeature.Mode
	public let presentationID: Int

	public init?(
		window: MainFeature.State,
		paneID: UUID,
		mode: CommandBarFeature.Mode
	) {
		guard let pane = window.viewer.panes[id: paneID] else { return nil }
		self.paneID = paneID
		self.tabID = pane.item.tab?.id
		self.generation = pane.item.generation
		self.spaceID = window.sidebar.spaceID
		self.profileID = window.sidebar.space.profileID
		self.mode = mode
		self.presentationID = window.commandBar.focusRequest + 1
	}

	public func matches(_ window: MainFeature.State) -> Bool {
		guard
			!window.isClosing,
			let pane = window.viewer.panes[id: paneID],
			window.commandBar.focusRequest == presentationID,
			window.sidebar.spaceID == spaceID,
			window.sidebar.space.profileID == profileID,
			pane.item.tab?.id == tabID,
			pane.item.generation == generation,
			pane.item.tab == nil || pane.item.tab?.profileID == profileID
		else { return false }
		return true
	}

	internal func matches(
		_ window: MainFeature.State,
		execution: CommandBarFeature.Execution
	) -> Bool {
		guard
			matches(window),
			execution.presentationID == presentationID,
			execution.mode == mode
		else { return false }

		// An action on a result runs only while the result itself still stands (DEV-810).
		if let origin = execution.origin, !stands(origin, in: window) { return false }
		return stands(execution.entry, in: window)
	}

	/// Whether a listed result still names what it did: a tab where it was, a space or folder
	/// in its profile.
	private func stands(
		_ entry: CommandBarFeature.Entry,
		in window: MainFeature.State
	) -> Bool {
		let organization = window.sidebar.organization
		switch (entry.intent, entry.destination) {
		case let (.selectSpace(id), .space(profile)):
			return organization.spaces[id: id]?.profileID == profile

		case let (.revealFolder(id), .folder(space, profile)):
			return organization.folders[id: id]?.spaceID == space
			&& organization.spaces[id: space]?.profileID == profile

		case let (.selectTab(id), .tab(profile, location)):
			return profile == profileID
			&& organization.tabs[id: id]?.profileID == profile
			&& organization.location(of: id) == location

		case (.selectSpace, _), (.revealFolder, _), (.selectTab, _): return false

		default: return true
		}
	}
}
