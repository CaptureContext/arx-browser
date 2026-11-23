import Foundation

/// Settings edits are applied to the latest workspace as a validated transaction.
public enum OrganizationChange: Equatable, Sendable {
	case createProfile(Profile.ID, name: String)
	case renameProfile(Profile.ID, name: String)
	case setSearchEngine(Profile.ID, SearchEngine)

	/// `nil` goes back to the default interval; ``TabArchiveInterval/never`` stops archiving the
	/// profile's tabs automatically (DEV-1326).
	case setTabArchiveInterval(Profile.ID, TabArchiveInterval?)
	case setRemoteSearchSuggestions(Profile.ID, Bool)
	case setShowsFullURL(Profile.ID, Bool)

	/// The profile's unread badges (DEV-1258); nil follows the browser default.
	case setProfileUnreadBadges(Profile.ID, UnreadBadgeVisibility?)

	/// `false` makes the profile "this Mac only" (DEV-981).
	case setSyncsWithICloud(Profile.ID, Bool)

	/// Adds a ``KeptLoadedSite`` to the profile's sites that never unload, or removes it (DEV-932).
	case setKeptLoadedSite(Profile.ID, site: String, kept: Bool)

	/// Settings' edit form for a kept-loaded site (DEV-1001): removes `site` from the first
	/// profile and adds `newSite` to `newProfile`, in one change.
	case replaceKeptLoadedSite(Profile.ID, site: String, newProfile: Profile.ID, newSite: String)

	/// Turns dark pages off for a site in the profile, or back on (DEV-1020). Turning a site on
	/// also removes the parent site that turned it off, as `help.example.com` under
	/// `example.com`.
	case setDarkPageSite(Profile.ID, site: String, off: Bool)
	case setProfileAppearance(Profile.ID, AppearanceOverride)
	case setSpaceAppearance(Space.ID, AppearanceOverride)
	case removeProfile(Profile.ID)
	case createSpace(Space.ID, profileID: Profile.ID, name: String, icon: SpaceIcon?)

	/// A nil icon is none of the space's own: it shows a dot (DEV-1251).
	case updateSpace(Space.ID, profileID: Profile.ID, name: String, icon: SpaceIcon?)
	case removeSpace(Space.ID)
	case moveSpace(Space.ID, before: Space.ID?)
}

public enum OrganizationChangeError: Error, Equatable, Sendable {
	case emptyName
	case missingItem
	case lastProfile
	case profileHasSpaces
	case lastSpace

	/// Not a site ``KeptLoadedSite`` can keep.
	case invalidSite
}

extension BrowserOrganization {
	/// Profile reassignment copies only durable tab metadata into new session identities.
	/// The caller must obtain close approval for removed identities before publishing this snapshot.
	public func applying(
		_ change: OrganizationChange,
		uuid: () -> UUID
	) throws -> Self {
		var result = self
		result.legacyProfileID = legacyProfileID ?? profiles.first?.id
		try result.update { organization in
			try organization.apply(change, uuid: uuid)
		}
		return result
	}

	private mutating func apply(
		_ change: OrganizationChange,
		uuid: () -> UUID
	) throws {
		switch change {
		case let .createProfile(id, name):
			profiles.append(.init(id: id, name: try nonemptyName(name)))

		case let .renameProfile(id, name):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			profiles[index].name = try nonemptyName(name)

		case let .setSearchEngine(id, engine):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			profiles[index].searchEngine = engine

		case let .setTabArchiveInterval(id, interval):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			profiles[index].tabArchiveInterval = interval

		case let .setRemoteSearchSuggestions(id, isEnabled):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			profiles[index].remoteSearchSuggestions = isEnabled

		case let .setShowsFullURL(id, showsFullURL):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			profiles[index].showsFullURL = showsFullURL

		case let .setProfileUnreadBadges(id, visibility):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			profiles[index].unreadBadges = visibility

		case let .setSyncsWithICloud(id, syncs):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			profiles[index].syncsWithICloud = syncs ? nil : false

		case let .setKeptLoadedSite(id, site, kept):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			guard let site = KeptLoadedSite.site(from: site)
			else { throw OrganizationChangeError.invalidSite }
			profiles[index].keptLoadedSites = KeptLoadedSite.sites(
				profiles[index].keptLoadedSites,
				setting: site,
				kept: kept
			)

		case let .setDarkPageSite(id, site, off):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			guard let site = KeptLoadedSite.site(from: site)
			else { throw OrganizationChangeError.invalidSite }
			if off {
				profiles[index].darkPagesOffSites = KeptLoadedSite.sites(
					profiles[index].darkPagesOffSites,
					setting: site,
					kept: true
				)
			} else {
				let remaining = (profiles[index].darkPagesOffSites ?? []).filter { off in
					site != off && !site.hasSuffix("." + off)
				}
				profiles[index].darkPagesOffSites = remaining.isEmpty ? nil : remaining
			}

		case let .replaceKeptLoadedSite(id, site, newID, newSite):
			guard
				let index = profiles.index(id: id),
				let newIndex = profiles.index(id: newID)
			else { throw OrganizationChangeError.missingItem }
			guard
				let site = KeptLoadedSite.site(from: site),
				let newSite = KeptLoadedSite.site(from: newSite)
			else { throw OrganizationChangeError.invalidSite }
			profiles[index].keptLoadedSites = KeptLoadedSite.sites(
				profiles[index].keptLoadedSites,
				setting: site,
				kept: false
			)
			profiles[newIndex].keptLoadedSites = KeptLoadedSite.sites(
				profiles[newIndex].keptLoadedSites,
				setting: newSite,
				kept: true
			)

		case let .setProfileAppearance(id, appearance):
			guard let index = profiles.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			profiles[index].appearance = appearance.isEmpty ? nil : appearance

		case let .setSpaceAppearance(id, appearance):
			guard let index = spaces.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			spaces[index].appearance = appearance.isEmpty ? nil : appearance

		case let .removeProfile(id):
			guard profiles.ids.contains(id)
			else { throw OrganizationChangeError.missingItem }
			guard profiles.count > 1 else { throw OrganizationChangeError.lastProfile }
			guard !spaces.contains(where: { $0.profileID == id })
			else { throw OrganizationChangeError.profileHasSpaces }

			profiles.removeAll { $0.id == id }
			tabs.removeAll { $0.profileID == id }

		case let .createSpace(id, profileID, name, icon):
			spaces.append(.init(
				id: id,
				profileID: profileID,
				name: try nonemptyName(name),
				icon: icon
			))

		case let .updateSpace(id, profileID, name, icon):
			guard let index = spaces.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			spaces[index].name = try nonemptyName(name)
			spaces[index].icon = icon
			if spaces[index].profileID != profileID {
				reassignSpace(at: index, to: profileID, uuid: uuid)
			}

		case let .removeSpace(id):
			guard spaces.ids.contains(id)
			else { throw OrganizationChangeError.missingItem }
			guard spaces.count > 1 else { throw OrganizationChangeError.lastSpace }
			let removed = Set(tabs(in: id).map(\.id))
			tabs.removeAll { removed.contains($0.id) }
			folders.removeAll { $0.spaceID == id }
			spaces.removeAll { $0.id == id }

		case let .moveSpace(id, destination):
			guard let index = spaces.index(id: id)
			else { throw OrganizationChangeError.missingItem }
			guard destination != id else { return }
			let space = spaces.remove(at: index)
			if let destination {
				guard let insertion = spaces.index(id: destination)
				else { throw OrganizationChangeError.missingItem }
				spaces.insert(space, at: insertion)

			} else {
				spaces.append(space)
			}
		}
	}

	public func tabs(in spaceID: Space.ID) -> [Tab] {
		tabs.filter {
			switch location(of: $0.id) {
			case .pinned(spaceID, _), .unpinned(spaceID): true
			default: false
			}
		}
	}

	private mutating func reassignSpace(
		at index: Int,
		to profileID: Profile.ID,
		uuid: () -> UUID
	) {
		let space = spaces[index]
		let originals = tabs(in: space.id)
		let replacements = Dictionary(uniqueKeysWithValues: originals.map {
			($0.id, Tab.ID(rawValue: uuid()))
		})

		func replacing(_ items: [SavedItem]) -> [SavedItem] {
			items.map { item in
				guard case let .tab(id) = item, let replacement = replacements[id]
				else { return item }

				return .tab(replacement)
			}
		}

		for tabIndex in tabs.indices {
			let tab = tabs[tabIndex]
			guard let replacement = replacements[tab.id] else { continue }
			tabs[tabIndex] = .init(
				id: replacement,
				profileID: profileID,
				savedDestination: tab.savedDestination,
				restoration: tab.restoration,
				customTitle: tab.customTitle,
				icon: tab.icon,
				automationClientID: tab.automationClientID,
				movedFrom: [tab.id] + tab.movedFrom
			)
		}
		for folderIndex in folders.indices where folders[folderIndex].spaceID == space.id {
			folders[folderIndex].children = replacing(folders[folderIndex].children)
		}
		spaces[index] = .init(
			id: space.id,
			profileID: profileID,
			name: space.name,
			icon: space.icon,
			appearance: space.appearance,
			savedItems: replacing(space.savedItems),
			unpinnedTabs: space.unpinnedTabs.compactMap { replacements[$0] },
			selectedTabID: space.selectedTabID.flatMap { replacements[$0] }
		)
	}

	private func nonemptyName(_ value: String) throws -> String {
		let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { throw OrganizationChangeError.emptyName }
		return name
	}
}
