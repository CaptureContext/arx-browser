import BrowserCore
import Foundation

extension BrowserAutomation {
	internal func moveFolder(
		_ command: AutomationCommand,
		organization: inout BrowserOrganization
	) throws -> UUID {
		guard
			let source = organization.folders.first(where: { $0.id.rawValue == command.targetID }),
			let sourceSpace = organization.spaces[id: source.spaceID],
			let destinationID = command.destinationID
		else { throw AutomationFailure.invalidRequest }

		let destination: Space?
		let placement: OrganizationMoveDestination

		if let folder = organization.folders.first(where: { $0.id.rawValue == destinationID }) {
			destination = organization.spaces[id: folder.spaceID]
			placement = .folder(folder.id)

		} else {
			destination = organization.spaces.first { $0.id.rawValue == destinationID }
			placement = .savedRoot
		}

		guard let destination else { throw AutomationFailure.invalidRequest }
		guard sourceSpace.profileID == destination.profileID
		else { throw AutomationFailure.crossProfileTransferUnsupported }

		let move = try organization.moving(
			[.folder(source.id)],
			to: placement,
			in: destination.id,
			newTabID: { .init(rawValue: uuid()) }
		)
		guard move.replacements.isEmpty
		else { throw AutomationFailure.unsupported }

		organization = move.updated
		return source.id.rawValue
	}
}

extension AppFeature.State {
	internal func automationFolderMoveValidation(
		_ command: AutomationCommand,
		client: AutomationClient
	) -> AutomationFailure? {
		guard
			let folder = workspace.folders.first(where: { $0.id.rawValue == command.targetID }),
			let source = workspace.spaces[id: folder.spaceID],
			let destinationID = command.destinationID
		else { return .invalidRequest }

		let destinationFolder = workspace.folders.first { $0.id.rawValue == destinationID }
		let destination = destinationFolder.flatMap { workspace.spaces[id: $0.spaceID] }
		?? workspace.spaces.first { $0.id.rawValue == destinationID }

		guard let destination else { return .invalidRequest }
		guard source.profileID == destination.profileID
		else { return .crossProfileTransferUnsupported }
		guard
			AutomationAccess.permitsSpace(source.id, client: client, organization: workspace),
			AutomationAccess.permitsSpace(destination.id, client: client, organization: workspace)
		else { return .denied }

		// Folder grants currently come from Spaces. Keep the subtree check explicit so
		// a future narrower scope cannot authorize moving excluded descendants.
		for item in workspace.descendants(of: folder.id) {
			switch item {
			case let .tab(id):
				guard
					workspace.tabs[id: id]?.profileID == source.profileID,
					AutomationAccess.permitsTab(id, client: client, organization: workspace)
				else { return .denied }

			case let .folder(id):
				guard workspace.folders[id: id]?.spaceID == source.id
				else { return .denied }
			}
		}

		return nil
	}
}
