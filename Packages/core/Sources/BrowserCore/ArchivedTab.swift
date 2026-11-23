import Foundation

/// Durable metadata for a successfully closed unpinned tab, never renderer state.
public struct ArchivedTab: Identifiable, Equatable, Codable, Sendable {
	public typealias ID = BrowserID<Self>

	public let id: ID
	public let groupID: UUID
	public let closedAt: Date
	public let originalSpaceID: Space.ID
	public let originalSpaceName: String
	public let originalIndex: Int
	public let tab: Tab

	public init(
		id: ID,
		groupID: UUID,
		closedAt: Date,
		originalSpaceID: Space.ID,
		originalSpaceName: String,
		originalIndex: Int,
		tab: Tab
	) {
		self.id = id
		self.groupID = groupID
		self.closedAt = closedAt
		self.originalSpaceID = originalSpaceID
		self.originalSpaceName = originalSpaceName
		self.originalIndex = originalIndex
		self.tab = tab
	}

	public func matches(_ query: String) -> Bool {
		let terms = query.split(whereSeparator: \.isWhitespace)
		let text = [
			tab.displayTitle,
			tab.restoration.url.absoluteString,
			originalSpaceName,
		].joined(separator: " ")
		return terms.allSatisfy { text.localizedStandardContains($0) }
	}
}

public enum TabArchiveError: Error, LocalizedError, Equatable, Sendable {
	case invalidEntry
	case missingDestination
	case missingEntry
	case profileMismatch

	public var errorDescription: String? {
		switch self {
		case .invalidEntry: "The archive contains an invalid or duplicate entry."
		case .missingDestination: "The original space is unavailable. Choose another space."
		case .missingEntry: "This archive entry is no longer available."
		case .profileMismatch: "The destination profile has changed. Choose a destination again."
		}
	}
}

extension BrowserOrganization {
	/// Capture metadata before closing; publish these entries only after close approval and completion.
	public func archiveEntries(
		for ids: [Tab.ID],
		closedAt: Date,
		groupID: UUID,
		uuid: () -> UUID
	) -> [ArchivedTab] {
		let selected = Set(ids)
		return spaces.flatMap { space in
			space.unpinnedTabs.enumerated().compactMap { index, id in
				guard
					selected.contains(id),
					let tab = tabs[id: id],
					tab.savedDestination == nil
				else { return nil }
				return ArchivedTab(
					id: .init(rawValue: uuid()),
					groupID: groupID,
					closedAt: closedAt,
					originalSpaceID: space.id,
					originalSpaceName: space.name,
					originalIndex: index,
					tab: tab.archived
				)
			}
		}
	}

	/// The caller has closed these sessions. Keep saved pins and Favorites outside the archive.
	public mutating func archiveClosedTabs(_ entries: [ArchivedTab]) throws {
		try update { organization in

			// Archiving an entry only moves that entry's tab, so one location pass serves the batch.
			let locations = organization.tabLocations
			for entry in entries {
				guard
					locations[entry.tab.id] == .unpinned(entry.originalSpaceID),
					let tab = organization.tabs[id: entry.tab.id],
					tab.savedDestination == nil,
					tab.profileID == entry.tab.profileID
				else { continue }
				organization.tabs.remove(id: tab.id)
				for index in organization.spaces.indices {
					organization.spaces[index].unpinnedTabs.removeAll { $0 == tab.id }
					if organization.spaces[index].selectedTabID == tab.id {
						organization.spaces[index].selectedTabID = nil
					}
				}
				organization.archive.append(.init(
					id: entry.id,
					groupID: entry.groupID,
					closedAt: entry.closedAt,
					originalSpaceID: entry.originalSpaceID,
					originalSpaceName: entry.originalSpaceName,
					originalIndex: entry.originalIndex,
					tab: tab.archived
				))
			}
		}
	}

	/// Archives a page that was never in the organization, such as a closed Little Arx page
	/// (DEV-728), so Recently Closed can reopen it as an unpinned tab of `spaceID`. Nothing
	/// in the organization moves. Archived entries never reopen on their own.
	///
	/// Pages that aren't http(s), or whose space is gone or belongs to another profile,
	/// are left out without an error.
	@discardableResult
	public mutating func archiveDetachedTab(
		_ tab: Tab,
		spaceID: Space.ID,
		closedAt: Date,
		groupID: UUID,
		id: ArchivedTab.ID
	) throws -> Bool {
		guard
			let space = spaces[id: spaceID],
			space.profileID == tab.profileID,
			tabs[id: tab.id] == nil,
			!archive.contains(where: { $0.id == id || $0.tab.id == tab.id }),
			tab.restoration.url.hasWebScheme
		else { return false }

		let detached = Tab(
			id: tab.id,
			profileID: tab.profileID,
			restoration: tab.restoration,
			customTitle: tab.customTitle,
			automationClientID: tab.automationClientID
		)
		try update { organization in
			organization.archive.append(.init(
				id: id,
				groupID: groupID,
				closedAt: closedAt,
				originalSpaceID: space.id,
				originalSpaceName: space.name,
				originalIndex: space.unpinnedTabs.count,
				tab: detached
			))
		}
		return true
	}

	/// Produces a candidate transaction. Commit it only after every required session opens.
	/// Fresh session identities let concurrent attempts roll back without closing each other's pages.
	public func restoringArchive(
		_ ids: [ArchivedTab.ID],
		to destination: ArchiveDestination? = nil,
		uuid: () -> UUID
	) throws -> Self {
		let selected = Set(ids)
		let entries = archive.filter { selected.contains($0.id) }
		guard !entries.isEmpty, entries.count == selected.count
		else { throw TabArchiveError.missingEntry }
		var result = self
		var reservedIDs = Set(tabs.map(\.id) + archive.map(\.tab.id))
		try result.update { organization in
			for entry in entries {
				let spaceID = destination?.spaceID ?? entry.originalSpaceID
				guard let index = organization.spaces.index(id: spaceID)
				else { throw TabArchiveError.missingDestination }
				let profileID = destination?.profileID ?? entry.tab.profileID
				guard organization.spaces[index].profileID == profileID
				else { throw TabArchiveError.profileMismatch }

				let id = Tab.ID(rawValue: uuid())
				guard reservedIDs.insert(id).inserted
				else { throw TabArchiveError.invalidEntry }

				let tab = Tab(
					id: id,
					profileID: profileID,
					restoration: entry.tab.restoration,
					customTitle: entry.tab.customTitle,
					automationClientID: entry.tab.automationClientID
				)
				organization.tabs.append(tab)
				let restoresOriginalPlacement = spaceID == entry.originalSpaceID
				&& profileID == entry.tab.profileID
				let insertion = restoresOriginalPlacement
				? min(entry.originalIndex, organization.spaces[index].unpinnedTabs.count)
				: organization.spaces[index].unpinnedTabs.count
				organization.spaces[index].unpinnedTabs.insert(tab.id, at: insertion)
				organization.spaces[index].selectedTabID = tab.id
			}
			organization.archive.removeAll { selected.contains($0.id) }
		}
		return result
	}

	internal func validateArchive() throws {
		WorkProbe.record(.archiveValidation)
		var identities: Set<ArchivedTab.ID> = []
		var tabIdentities: Set<Tab.ID> = []
		for entry in archive {
			guard
				identities.insert(entry.id).inserted,
				tabIdentities.insert(entry.tab.id).inserted,
				entry.tab.savedDestination == nil,
				entry.originalIndex >= 0,
				entry.closedAt.timeIntervalSinceReferenceDate.isFinite
			else { throw TabArchiveError.invalidEntry }
		}
	}
}

extension Tab {
	/// The tab as Tab Archive keeps it: without the icon chosen for it, which goes when the tab
	/// closes (DEV-1251). The window's ⌘Z puts the tab itself back, icon and all.
	fileprivate var archived: Self {
		var tab = self
		tab.icon = nil
		return tab
	}
}
