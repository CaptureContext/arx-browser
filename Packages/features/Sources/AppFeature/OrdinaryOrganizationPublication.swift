import BrowserCore
import Foundation

extension AppFeature.State {
	/// Publishes validated added tabs without replacing any host's existing presentation.
	/// Removals and profile moves require their own native ownership reconciliation.
	/// `windowID` is the ordinary window the new tabs were opened from, which keeps them while
	/// windows are independent (DEV-822); without one they're the main window's.
	internal mutating func publishAdditiveOrganization(
		_ organization: BrowserOrganization,
		openedIn windowID: UUID? = nil
	) {
		if let windowID, window(windowID) != nil {
			claimOpenedTabs(from: windowID, previous: workspace, current: organization)
		}
		publishOrganizationPreservingPresentations(organization)
	}

	private mutating func publishOrganizationPreservingPresentations(_ organization: BrowserOrganization) {
		workspace = organization
		unsavedOrganization = organization
		let hosts = [main.id] + windows.filter { !$0.isPrivate }.map(\.id)

		for id in hosts {
			guard var host = id == main.id ? main : windows[id: id]
			else { continue }

			var shared = organization

			for index in shared.spaces.indices {
				let space = shared.spaces[index]
				let selected = host.sidebar.organization.spaces[id: space.id]?.selectedTabID
				shared.spaces[index].selectedTabID = selected.flatMap {
					shared.canPresent($0, in: space.id) ? $0 : nil
				}
			}

			// Not a step of the window's; ⌘Z takes back only what each step changed, or, without
			// `windowUndo`, the history goes (DEV-1030).
			if host.sidebar.organization != shared || !host.sidebar.windowUndo { host.sidebar.sealUndo() }
			host.sidebar.organization = shared
			host.knownTabIDs = Set(shared.tabs.map(\.id))
			host.viewer.presentations = host.viewer.presentations.compactMap { $0.sanitized(in: shared) }

			if id == main.id { main = host } else { windows[id: id] = host }
		}
	}
}
