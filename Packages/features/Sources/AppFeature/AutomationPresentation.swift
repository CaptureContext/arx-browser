import BrowserCore
import Foundation
import MainFeature
import ViewerFeature
import _ComposableArchitecture

extension BrowserAutomation {
	/// `requestID` is the agent's request the change carries out, which makes it the agent's ⌘Z
	/// step with `ARX_WINDOW_UNDO`; without one, such as Keep Tab, it's no step (DEV-1030).
	internal func commit(
		_ organization: BrowserOrganization,
		for requestID: UUID?,
		state: inout State
	) -> Effect<Action> {
		// These operations add or move folders/tabs within one profile. They do not
		// remove profiles, and must preserve every host's own valid selection. Tabs they
		// open or unpin have no window but the one that shows them (DEV-822).
		let step = state.windowUndo
		? requestID.flatMap { undoStep(from: state.workspace, to: organization, for: $0, state: state) }
		: nil
		state.claimOpenedTabs(from: state.main.id, previous: state.workspace, current: organization)
		if let clientID = requestID.flatMap({ state.automation.pending[$0]?.request.clientID }) {
			state.noteAgentOrganization(from: state.workspace, to: organization, clientID: clientID)
		}
		state.workspace = organization
		state.unsavedOrganization = organization
		let hosts = [state.main.id] + state.windows.filter { !$0.isPrivate }.map(\.id)
		for id in hosts {
			guard var host = id == state.main.id ? state.main : state.windows[id: id]
			else { continue }

			var shared = organization
			for index in shared.spaces.indices {
				let space = shared.spaces[index]
				let selected = host.sidebar.organization.spaces[id: space.id]?.selectedTabID
				shared.spaces[index].selectedTabID = selected.flatMap { tabID in
					shared.canPresent(tabID, in: space.id) ? tabID : nil
				}
			}

			if state.windowUndo {
				// The agent's change is a step of its own in every window (DEV-1030).
				if host.sidebar.organization != shared { host.sidebar.sealUndo() }
				host.sidebar.organization = shared
				if let step { host.sidebar.appendUndo(step) }
			} else if id == state.main.id {
				host.sidebar.edit { $0 = shared }
			} else {
				host.sidebar.organization = shared
				host.sidebar.sealUndo()
			}

			host.knownTabIDs = Set(shared.tabs.map(\.id))
			host.viewer.presentations = host.viewer.presentations.compactMap { $0.sanitized(in: shared) }

			if id == state.main.id {
				state.main = host
			} else {
				state.windows[id: id] = host
			}
		}

		// Remove invalid placements at the commit boundary. Queuing a reconciliation
		// snapshot here could overwrite a newer selection or attach one session twice.
		var effects: [Effect<Action>] = []
		for id in hosts {
			guard let host = id == state.main.id ? state.main : state.windows[id: id]
			else { continue }

			let invalid = host.viewer.panes.filter { pane in
				pane.item.tab.map { !organization.canPresent($0.id, in: host.sidebar.spaceID) } ?? false
			}
			for pane in invalid {
				let current = id == state.main.id ? state.main : state.windows[id: id]
				let viewerAction: ViewerFeature.Action = current?.viewer.isSplit == true
				? .ui(.closePane(pane.id))
				: .show(nil, in: pane.id)
				let action = MainFeature.Action.viewer(viewerAction)
				let routed: AppFeature.Action = id == state.main.id
				? .main(action)
				: .windows(.element(id: id, action: action))
				effects.append(AppFeature()._reduce(into: &state, action: routed))
			}
		}
		return .merge(effects + [.send(.delegate(.save(organization)))])
	}

	/// The agent's change as ⌘Z takes it back, saying whose it was (DEV-1030). A space it deleted
	/// can come back for the grace period.
	internal func undoStep(
		from previous: BrowserOrganization,
		to organization: BrowserOrganization,
		for requestID: UUID,
		state: State
	) -> OrganizationUndo? {
		guard previous != organization else { return nil }

		let clientID = state.automation.pending[requestID]?.request.clientID
		let client = state.automationPreferences.clients.first { $0.id == clientID }
		let removedSpaces = previous.spaces.ids.subtracting(organization.spaces.ids)
		return .init(
			before: previous,
			after: organization,
			spaceID: removedSpaces.count == 1 ? removedSpaces.first : nil,
			author: .agent(client?.name ?? String.localized(.appUI.automation.unknownClient)),
			expiresAt: removedSpaces.isEmpty ? nil : now.addingTimeInterval(OrganizationUndo.deletedSpaceGracePeriod),
			openTabOwners: state.openTabOwners(removedFrom: previous, in: organization),
			restoresSelection: false
		)
	}
}
