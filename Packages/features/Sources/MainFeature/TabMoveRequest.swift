import AppUI
import BrowserCore
import Foundation
import SidebarFeature

/// Captured before confirmation. Focus or tree changes never silently change the move's source.
public struct TabMoveRequest: Equatable, Sendable {
	public var id: UUID
	public var plan: OrganizationMove
	public var selection: [SidebarItem.ID]
	public var sourceSpace: Space.ID
	public var selectedTab: BrowserCore.Tab.ID?
	public var sourcePresentations: [UUID: SourcePresentation]
	public var isUndo: Bool

	public struct SourcePresentation: Equatable, Sendable {
		public var tabID: BrowserCore.Tab.ID
		public var generation: Int

		public init(
			tabID: BrowserCore.Tab.ID,
			generation: Int
		) {
			self.tabID = tabID
			self.generation = generation
		}
	}

	public init(
		id: UUID,
		plan: OrganizationMove,
		selection: [SidebarItem.ID],
		sourceSpace: Space.ID,
		selectedTab: BrowserCore.Tab.ID?,
		sourcePresentations: [UUID: SourcePresentation] = [:],
		isUndo: Bool = false
	) {
		self.id = id
		self.plan = plan
		self.selection = selection
		self.sourceSpace = sourceSpace
		self.selectedTab = selectedTab
		self.isUndo = isUndo
		self.sourcePresentations = sourcePresentations
	}
}

public struct TabMovePicker: Equatable, Sendable {
	public var roots: [SidebarItem.ID]
	public var organization: BrowserOrganization
	public var selection: [SidebarItem.ID]

	public init(
		roots: [SidebarItem.ID],
		organization: BrowserOrganization,
		selection: [SidebarItem.ID]
	) {
		self.roots = roots
		self.organization = organization
		self.selection = selection
	}
}

extension MainFeature.State {
	public func canCommitTabMove(sourceIDs: [BrowserCore.Tab.ID]) -> Bool {
		guard let request = activeTabMove else { return false }
		return !isPrivate
		&& !isClosing
		&& transferInProgress
		&& request.plan.replacements.map(\.source.id) == sourceIDs
		&& matches(request)
	}

	internal func movePresentations(
		for plan: OrganizationMove
	) -> [UUID: TabMoveRequest.SourcePresentation] {
		let sources = Set(plan.replacements.map(\.source.id))
		return Dictionary(uniqueKeysWithValues: viewer.panes.compactMap { pane in
			guard let id = pane.item.tab?.id, sources.contains(id) else { return nil }
			return (pane.id, .init(tabID: id, generation: pane.item.generation))
		})
	}

	internal func matches(_ request: TabMoveRequest) -> Bool {
		sidebar.organization == request.plan.previous
		&& sidebar.spaceID == request.sourceSpace
		&& sidebar.moveSelection == request.selection
		&& sidebar.selectedTab?.id == request.selectedTab
		&& movePresentations(for: request.plan) == request.sourcePresentations
	}
}

extension SidebarDropTarget {
	internal var moveDestination: OrganizationMoveDestination {
		switch self {
		case .favoritesRoot: .favorites
		case .savedRoot: .savedRoot
		case .unpinnedRoot, .split: .openTabs
		case let .before(id): .before(id.savedItem)
		case let .after(id): .after(id.savedItem)
		case let .inside(.folder(id)): .folder(.init(rawValue: id))
		case .inside: .savedRoot
		}
	}
}

extension TabMoveRequest {
	/// The window's question before this move to another profile (DEV-1184): a whole space moved
	/// to the profile, or the tab, or tabs, reopened in the destination space, with that space's
	/// profile named. `nil` for a move that stays in its profile, which asks nothing.
	public var profileMoveConfirmation: ProfileMoveConfirmation.Content? {
		guard
			!plan.replacements.isEmpty,
			let space = plan.updated.spaces[id: plan.destination],
			let profile = plan.updated.profiles[id: space.profileID]
		else { return nil }

		let subject: ProfileMoveConfirmation.Content.Subject
		if let before = plan.previous.spaces[id: space.id], before.profileID != space.profileID {
			subject = .space(space.name)
		} else if plan.replacements.count > 1 {
			subject = .tabs(plan.replacements.count)
		} else {
			subject = .tab
		}
		return .init(subject: subject, spaceName: space.name, profileName: profile.name)
	}
}
