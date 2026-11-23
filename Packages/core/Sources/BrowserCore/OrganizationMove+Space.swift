import Foundation

extension BrowserOrganization {
	/// Plans moving a whole space into another profile as one tree move.
	///
	/// The space's pinned items, folders and open tabs move through ``moving(_:to:in:unpinning:newTabID:)``,
	/// so every tab gets a fresh destination-profile identity and the move can be staged, confirmed and undone
	/// like any other cross-profile move. Favorites belong to the source profile and stay there.
	public func movingSpace(
		_ spaceID: Space.ID,
		toProfile profileID: Profile.ID,
		newTabID: () -> Tab.ID
	) throws -> OrganizationMove {
		try validate()
		guard let source = spaces[id: spaceID]
		else { throw OrganizationMoveError.missingSource }

		guard profiles.ids.contains(profileID), source.profileID != profileID
		else { throw OrganizationMoveError.invalidDestination }

		let roots = source.savedItems + source.unpinnedTabs.map(SavedItem.tab)

		// Stage the content in an empty space of the destination profile, then hand it back to the original space.
		var stagingID = Space.ID(rawValue: UUID())
		while spaces.ids.contains(stagingID) { stagingID = .init(rawValue: UUID()) }
		var staged = self
		staged.spaces.append(.init(id: stagingID, profileID: profileID, name: source.name))
		let move = roots.isEmpty
		? nil
		: try staged.moving(roots, to: .spaceRoot, in: stagingID, newTabID: newTabID)

		var updated = move?.updated ?? staged
		guard let stagingIndex = updated.spaces.index(id: stagingID)
		else { throw OrganizationMoveError.invalidDestination }
		let content = updated.spaces.remove(at: stagingIndex)
		guard let index = updated.spaces.index(id: spaceID)
		else { throw OrganizationMoveError.missingSource }
		for folder in updated.folders.indices where updated.folders[folder].spaceID == stagingID {
			updated.folders[folder].spaceID = spaceID
		}
		let replacements = move?.replacements ?? []
		let mapping = Dictionary(uniqueKeysWithValues: replacements.map { ($0.source.id, $0.destination.id) })
		updated.spaces[index] = .init(
			id: spaceID,
			profileID: profileID,
			name: source.name,
			icon: source.icon,
			appearance: source.appearance,
			savedItems: content.savedItems,
			unpinnedTabs: content.unpinnedTabs,
			selectedTabID: source.selectedTabID.map { mapping[$0] ?? $0 }
		)

		// A selected favorite stays with the source profile, so the moved space loses that selection.
		if let selected = updated.spaces[index].selectedTabID {
			switch updated.location(of: selected) {
			case .pinned(spaceID, _), .unpinned(spaceID): break
			case .favorite(profileID): break
			default: updated.spaces[index].selectedTabID = nil
			}
		}
		try updated.validate()
		return .init(
			previous: self,
			updated: updated,
			roots: move?.roots ?? [],
			destination: spaceID,
			replacements: replacements,
			movedTabIDs: move?.movedTabIDs ?? []
		)
	}
}
