import Foundation

extension BrowserOrganization {
	public func validate() throws {
		try validate(includingArchive: true)
	}

	/// Validates everything but, when `includingArchive` is false, the archive: an edit that left
	/// the archive as it was can't have made it invalid (DEV-947).
	internal func validate(includingArchive: Bool) throws {
		if let retired = profiles.first(where: { retiredProfileIDs.contains($0.id) }) {
			throw ValidationError.retiredProfile(retired.id)
		}
		if includingArchive { try validateArchive() }

		// Identified arrays can't hold duplicate identities, so they are the lookup index.
		for space in self.spaces {
			guard profiles[id: space.profileID] != nil
			else { throw ValidationError.missingProfile(space.profileID) }
		}
		for folder in self.folders {
			guard spaces[id: folder.spaceID] != nil
			else { throw ValidationError.missingSpace(folder.spaceID) }
		}
		for tab in self.tabs {
			guard profiles[id: tab.profileID] != nil
			else { throw ValidationError.missingProfile(tab.profileID) }
		}
		try validateFolderCycles(folders)

		// Each tab's one location, recorded while placing it, so checking selections needs no
		// search of the whole organization per space.
		var placedTabs: [Tab.ID: TabLocation] = [:]
		var placedFolders: Set<Folder.ID> = []

		func placeTab(
			_ id: Tab.ID,
			profileID: Profile.ID,
			saved: Bool,
			at location: TabLocation
		) throws {
			guard let tab = tabs[id: id]
			else { throw ValidationError.missingTab(id) }
			guard tab.profileID == profileID
			else { throw ValidationError.tabProfileMismatch(id) }
			guard (tab.savedDestination != nil) == saved
			else { throw ValidationError.invalidSavedDestination(id) }
			guard placedTabs.updateValue(location, forKey: id) == nil
			else { throw ValidationError.multipleTabLocations(id) }
		}

		func placeItems(
			_ items: [SavedItem],
			in space: Space,
			folder: Folder.ID?
		) throws {
			for item in items {
				switch item {
				case let .tab(id):
					try placeTab(id, profileID: space.profileID, saved: true, at: .pinned(space.id, folder: folder))

				case let .folder(id):
					guard let folder = folders[id: id]
					else { throw ValidationError.missingFolder(id) }
					guard folder.spaceID == space.id
					else { throw ValidationError.folderSpaceMismatch(id) }
					guard placedFolders.insert(id).inserted
					else { throw ValidationError.multipleFolderLocations(id) }
				}
			}
		}

		for profile in self.profiles {
			for id in profile.favorites {
				try placeTab(id, profileID: profile.id, saved: true, at: .favorite(profile.id))
			}
		}
		for space in self.spaces {
			try placeItems(space.savedItems, in: space, folder: nil)
			for id in space.unpinnedTabs {
				try placeTab(id, profileID: space.profileID, saved: false, at: .unpinned(space.id))
			}
		}
		for folder in self.folders {
			guard let space = spaces[id: folder.spaceID]
			else { throw ValidationError.missingSpace(folder.spaceID) }
			try placeItems(folder.children, in: space, folder: folder.id)
		}
		for folder in self.folders where !placedFolders.contains(folder.id) {
			throw ValidationError.unplacedFolder(folder.id)
		}
		for tab in self.tabs where placedTabs[tab.id] == nil {
			throw ValidationError.unplacedTab(tab.id)
		}
		for space in self.spaces {
			guard let selected = space.selectedTabID else { continue }
			let allowed: Bool = switch placedTabs[selected] {
			case let .favorite(profileID): profileID == space.profileID
			case let .pinned(spaceID, _), let .unpinned(spaceID): spaceID == space.id
			case nil: false
			}
			guard allowed
			else { throw ValidationError.invalidSelection(space.id, selected) }
		}
	}

	/// Clears every space's selection of a tab the space can't show: one placed in another space,
	/// a Favorite of another profile, or one the organization no longer holds. Clearing loses
	/// nothing, so a save repairs it instead of refusing the whole workspace (DEV-1261).
	///
	/// - Returns: The selections it cleared.
	@discardableResult
	public mutating func repairSelections() -> [SelectionRepair] {
		let locations = tabLocations
		var repairs: [SelectionRepair] = []
		for index in spaces.indices {
			let space = spaces[index]
			guard let selected = space.selectedTabID else { continue }

			let allowed: Bool = switch locations[selected] {
			case let .favorite(profileID): profileID == space.profileID
			case let .pinned(spaceID, _), let .unpinned(spaceID): spaceID == space.id
			case nil: false
			}
			guard !allowed else { continue }

			spaces[index].selectedTabID = nil
			repairs.append(.init(spaceID: space.id, tabID: selected))
		}
		return repairs
	}

	/// Checks transient ownership without putting sessions in the durable snapshot.
	public func validate(sessions: [BrowsingSession]) throws {
		try validate()
		var sessionIDs: Set<BrowsingSession.ID> = []
		var loadedTabs: Set<Tab.ID> = []
		for session in sessions {
			guard sessionIDs.insert(session.id).inserted
			else { throw ValidationError.duplicateSession(session.id) }
			guard loadedTabs.insert(session.tabID).inserted
			else { throw ValidationError.multipleSessions(session.tabID) }
			guard let tab = tabs[id: session.tabID]
			else { throw ValidationError.missingTab(session.tabID) }
			guard tab.profileID == session.profileID
			else { throw ValidationError.sessionProfileMismatch(session.id) }
		}
	}

	private func validateFolderCycles(_ folders: IdentifiedArrayOf<Folder>) throws {
		var visiting: Set<Folder.ID> = []
		var finished: Set<Folder.ID> = []
		for folder in self.folders {
			var stack: [(id: Folder.ID, leaving: Bool)] = [(folder.id, false)]
			while let (id, leaving) = stack.popLast() {
				if leaving {
					visiting.remove(id)
					finished.insert(id)
					continue
				}
				if finished.contains(id) { continue }
				guard visiting.insert(id).inserted
				else { throw ValidationError.folderCycle(id) }
				guard let current = folders[id: id]
				else { throw ValidationError.missingFolder(id) }
				stack.append((id, true))
				for case let .folder(child) in current.children.reversed() {
					stack.append((child, false))
				}
			}
		}
	}
}

extension BrowserOrganization {
	public enum ValidationError: Error, Equatable, Sendable {
		case retiredProfile(Profile.ID)
		case duplicateProfile(Profile.ID)
		case duplicateSpace(Space.ID)
		case duplicateFolder(Folder.ID)
		case duplicateTab(Tab.ID)
		case duplicateSession(BrowsingSession.ID)
		case missingProfile(Profile.ID)
		case missingSpace(Space.ID)
		case missingFolder(Folder.ID)
		case missingTab(Tab.ID)
		case tabProfileMismatch(Tab.ID)
		case folderSpaceMismatch(Folder.ID)
		case sessionProfileMismatch(BrowsingSession.ID)
		case invalidSavedDestination(Tab.ID)
		case multipleTabLocations(Tab.ID)
		case multipleFolderLocations(Folder.ID)
		case multipleSessions(Tab.ID)
		case folderCycle(Folder.ID)
		case unplacedFolder(Folder.ID)
		case unplacedTab(Tab.ID)
		case invalidSelection(Space.ID, Tab.ID)
	}

	/// A space's selection `repairSelections()` cleared.
	public struct SelectionRepair: Equatable, Sendable {
		public let spaceID: Space.ID
		public let tabID: Tab.ID

		public init(
			spaceID: Space.ID,
			tabID: Tab.ID
		) {
			self.spaceID = spaceID
			self.tabID = tabID
		}
	}
}
