import BrowserCore
import Foundation

extension BrowserOrganization {
	/// Validates the destination and every route before anything is read or written.
	public func validateMigrationDestination(_ destination: MigrationDestination) throws {
		guard
			profiles.contains(where: { $0.id == destination.profileID }),
			spaces.contains(where: { $0.id == destination.spaceID && $0.profileID == destination.profileID })
		else { throw MigrationFailure.invalidDestination }

		for route in destination.profileRoutes.values {
			guard case let .existingProfile(profileID) = route else { continue }
			guard profiles.contains(where: { $0.id == profileID })
			else { throw MigrationFailure.invalidDestination }
		}

		for route in destination.routes.values + [destination.defaultRoute].compactMap({ $0 }) {
			switch route {
			case .newProfile:
				continue

			case let .newSpace(profileID):
				guard profiles.contains(where: { $0.id == profileID })
				else { throw MigrationFailure.invalidDestination }

			case let .existingSpace(profileID, spaceID):
				guard spaces.contains(where: { $0.id == spaceID && $0.profileID == profileID })
				else { throw MigrationFailure.invalidDestination }
			}
		}
	}

	/// Whether this item already reached where it would go now.
	internal func hasImported(
		_ item: MigrationItem,
		into destination: MigrationDestination,
		ledger: MigrationLedger
	) -> Bool {
		let target = migrationTarget(
			for: item,
			destination: destination,
			ledger: ledger
		)
		guard let target else { return false }

		return ledger.importedItems[target]?.contains(item.key.ledgerValue) == true
	}

	/// Maps one batch into this organization as a single validated edit, recording it
	/// in `ledger`. Existing items are never renamed, moved or removed, and repeated
	/// URLs stay where the source has them.
	public func applyingMigration(
		_ batch: MigrationBatch,
		ledger: inout MigrationLedger,
		makeID: () -> UUID
	) throws -> Self {
		try validateMigrationDestination(batch.destination)
		var result = self
		var updatedLedger = ledger
		if let key = batch.preferencesKey { updatedLedger.recordApplied(key) }
		try result.update { organization in
			withoutActuallyEscaping(makeID) { makeID in
				var run: MigrationImport = .init(
					organization: organization,
					ledger: updatedLedger,
					batch: batch,
					makeID: makeID
				)
				run.run()
				organization = run.organization
				updatedLedger = run.ledger
			}
		}
		ledger = updatedLedger
		return result
	}

	/// The history in a committed batch, by the profile each entry went to.
	///
	/// Call it on the organization and ledger `applyingMigration` returned, which have
	/// any profile the batch created. Entry IDs are placeholders: the history store
	/// keeps one entry per URL and gives new ones their own.
	public func migrationHistory(
		_ batch: MigrationBatch,
		ledger: MigrationLedger
	) -> [Profile.ID: [BrowsingHistoryEntry]] {
		guard batch.category == .history else { return [:] }

		var result: [Profile.ID: [BrowsingHistoryEntry]] = [:]
		for item in batch.items {
			guard
				let url = item.url,
				let lastVisited = item.lastVisited,
				let profileID = migrationProfile(
					for: item.profile,
					destination: batch.destination,
					ledger: ledger
				)
			else { continue }

			result[profileID, default: []].append(
				.init(
					id: UUID(uuidString: item.key.sourceItemID) ?? UUID(),
					url: url,
					title: item.title,
					lastVisited: lastVisited,
					visitCount: item.visitCount ?? 1,
					typedCount: item.typedCount ?? 0
				)
			)
		}
		return result
	}

	/// The Arx profile that receives a source profile's data under `destination`: the
	/// routed or current profile, or the one an earlier run created for it. Nil while a new
	/// profile for it doesn't exist yet. Passwords and sign-ins follow it (DEV-650).
	///
	/// `MigrationSourceProfile.wholeSource` stands for a source without profiles of its
	/// own. Its data goes where the import puts items without a profile: the
	/// destination's profile (DEV-844).
	public func receivingProfile(
		forSourceProfile id: String,
		destination: MigrationDestination,
		ledger: MigrationLedger
	) -> Profile? {
		let source: MigrationSourceProfile? = id == MigrationSourceProfile.wholeSource
		? nil
		: .init(id: id, name: id)
		return migrationProfile(
			for: source,
			destination: destination,
			ledger: ledger
		)
		.flatMap { profiles[id: $0] }
	}

	/// The Arx profile an applied item landed in, so per-profile data such as its icon
	/// follows it there and nowhere else (DEV-897). Nil while its space or profile doesn't
	/// exist.
	public func receivingProfile(
		for item: MigrationItem,
		destination: MigrationDestination,
		ledger: MigrationLedger
	) -> Profile.ID? {
		if item.key.category == .favorites || item.key.category == .history {
			return migrationProfile(for: item.profile, destination: destination, ledger: ledger)
		}
		guard let space = item.space else { return destination.profileID }

		switch destination.route(for: space) {
		case nil:
			return destination.profileID

		case let .existingSpace(profileID, _):
			return profileID

		case .newProfile, .newSpace:
			return ledger.createdSpaces[space.id].flatMap { spaces[id: $0]?.profileID }
		}
	}

	/// The space or profile an item lands in, if it exists yet.
	fileprivate func migrationTarget(
		for item: MigrationItem,
		destination: MigrationDestination,
		ledger: MigrationLedger
	) -> String? {
		if item.key.category == .favorites || item.key.category == .history {
			return migrationProfile(
				for: item.profile,
				destination: destination,
				ledger: ledger
			)?.rawValue.uuidString
		}
		guard let space = item.space else { return destination.spaceID.rawValue.uuidString }

		switch destination.route(for: space) {
		case nil:
			return destination.spaceID.rawValue.uuidString

		case let .existingSpace(_, spaceID):
			return spaceID.rawValue.uuidString

		case .newProfile, .newSpace:
			guard
				let created = ledger.createdSpaces[space.id],
				spaces.contains(where: { $0.id == created })
			else { return nil }

			return created.rawValue.uuidString
		}
	}

	/// The profile a source profile's favorites go to: the new profile if any of its
	/// spaces asks for one, otherwise the profile its first routed space lands in.
	fileprivate func migrationProfile(
		for source: MigrationSourceProfile?,
		destination: MigrationDestination,
		ledger: MigrationLedger
	) -> Profile.ID? {
		guard let source else { return destination.profileID }

		switch destination.favoritesRoute(for: source) {
		case nil:
			return destination.profileID

		case let .newSpace(profileID), let .existingSpace(profileID, _):
			return profileID

		case .newProfile:
			guard
				let created = ledger.createdProfiles[source.id],
				profiles.contains(where: { $0.id == created })
			else { return nil }

			return created
		}
	}
}

extension MigrationDestination {
	fileprivate func route(for space: MigrationSourceSpace) -> MigrationRoute? {
		routes[space.id] ?? profileRoute(for: space.profile) ?? defaultRoute
	}

	fileprivate func favoritesRoute(for profile: MigrationSourceProfile) -> MigrationRoute? {
		let routed = routes.keys.sorted().compactMap { id -> MigrationRoute? in
			id.hasPrefix(profile.id + MigrationBrowserSources.spaceSeparator) ? routes[id] : nil
		}
		if routed.contains(.newProfile) { return .newProfile }
		return routed.first ?? profileRoute(for: profile) ?? defaultRoute
	}

	/// A mapped source profile's spaces go into its new profile, or become new spaces in
	/// the existing one.
	private func profileRoute(for profile: MigrationSourceProfile) -> MigrationRoute? {
		switch profileRoutes[profile.id] {
		case nil: nil
		case .newProfile: .newProfile
		case let .existingProfile(id): .newSpace(id)
		}
	}

	/// The name a new profile for this source profile gets.
	fileprivate func newProfileName(for profile: MigrationSourceProfile) -> String {
		guard
			case let .newProfile(name) = profileRoutes[profile.id],
			case let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines),
			!trimmed.isEmpty
		else { return profile.name }

		return trimmed
	}
}

extension MigrationLedger {
	/// Settings apply to the whole app, so they're recorded under one place.
	private static let preferencesTarget: String = "preferences"

	internal func hasApplied(_ key: MigrationItemKey) -> Bool {
		importedItems[Self.preferencesTarget]?.contains(key.ledgerValue) == true
	}

	fileprivate mutating func recordApplied(_ key: MigrationItemKey) {
		importedItems[Self.preferencesTarget, default: []].insert(key.ledgerValue)
	}
}

extension MigrationItemKey {
	fileprivate var ledgerValue: String {
		[sourceID.rawValue, category.rawValue, sourceItemID].joined(separator: "\u{1F}")
	}
}

/// One batch being applied. Lookups keep the source's order: a folder or space is
/// created where its first item appears.
private struct MigrationImport {
	/// Folders made for sources that have no folder of their own in the target.
	private var wrappers: [String: Folder.ID]

	/// Tab Archive groups for source groups that aren't Arx group IDs.
	private var archiveGroups: [String: UUID]
	internal var organization: BrowserOrganization
	internal var ledger: MigrationLedger
	internal let batch: MigrationBatch
	internal let makeID: () -> UUID

	internal init(
		organization: BrowserOrganization,
		ledger: MigrationLedger,
		batch: MigrationBatch,
		makeID: @escaping () -> UUID
	) {
		self.organization = organization
		self.ledger = ledger
		self.batch = batch
		self.makeID = makeID
		self.wrappers = [:]
		self.archiveGroups = [:]
	}

	internal mutating func run() {
		for item in batch.items {
			switch (item.kind, batch.category) {
			case (.profile, _): importProfile(item)
			case (.space, _): importSpace(item)
			case (.folder, _): importFolder(item)
			case (.tab, .favorites): importFavorite(item)
			case (.tab, .bookmarks): importPinned(item)
			case (.tab, .openTabs): importRegular(item)
			case (.tab, .archivedTabs): importArchived(item)
			case (.tab, .history): importHistory(item)
			case (.tab, .extensions), (.tab, .preferences): break
			}
		}
	}

	private mutating func importProfile(_ item: MigrationItem) {
		let profileID = profile(for: item.profile)
		record(item, in: profileID.rawValue.uuidString)
	}

	private mutating func importSpace(_ item: MigrationItem) {
		let (spaceID, _) = target(for: item.space)
		record(item, in: spaceID.rawValue.uuidString)
	}

	private mutating func importFolder(_ item: MigrationItem) {
		let (spaceID, _) = target(for: item.space)
		var parent = wrapper(for: item, in: spaceID)
		for folder in item.folders {
			parent = self.folder(folder, parent: parent, in: spaceID)
		}
		record(item, in: spaceID.rawValue.uuidString)
	}

	private mutating func importFavorite(_ item: MigrationItem) {
		guard let url = item.url else { return }

		let profileID = profile(for: item.profile)
		let tab = savedTab(item, url: url, profileID: profileID)
		organization.tabs.append(tab)
		if let index = organization.profiles.index(id: profileID) {
			organization.profiles[index].favorites.append(tab.id)
		}
		record(item, in: profileID.rawValue.uuidString)
	}

	private mutating func importRegular(_ item: MigrationItem) {
		guard let url = item.url else { return }

		let (spaceID, profileID) = target(for: item.space)
		let tab: Tab = .init(
			id: .init(rawValue: makeID()),
			profileID: profileID,
			restoration: .init(title: item.title, url: url),
			customTitle: item.customTitle,
			icon: item.tabIcon
		)
		organization.tabs.append(tab)
		if let index = organization.spaces.index(id: spaceID) {
			organization.spaces[index].unpinnedTabs.append(tab.id)
		}
		record(item, in: spaceID.rawValue.uuidString)
	}

	/// A closed tab joins the Tab Archive of the space its source space maps to,
	/// keeping when it closed and where it was.
	private mutating func importArchived(_ item: MigrationItem) {
		guard let url = item.url, let archived = item.archived else { return }

		let (spaceID, profileID) = target(for: item.space)
		let groupID = UUID(uuidString: archived.groupID) ?? archiveGroups[archived.groupID] ?? makeID()
		archiveGroups[archived.groupID] = groupID
		organization.archive.append(
			.init(
				id: .init(rawValue: makeID()),
				groupID: groupID,
				closedAt: archived.closedAt,
				originalSpaceID: spaceID,
				originalSpaceName: organization.spaces[id: spaceID]?.name ?? item.space?.name ?? "",
				originalIndex: archived.index,
				tab: .init(
					id: .init(rawValue: makeID()),
					profileID: profileID,
					restoration: .init(title: item.title, url: url),
					customTitle: item.customTitle
				)
			)
		)
		record(item, in: spaceID.rawValue.uuidString)
	}

	/// History has its own store: the organization only gains the profile it goes to.
	/// AppFeature writes the entries from `migrationHistory(_:ledger:)`.
	private mutating func importHistory(_ item: MigrationItem) {
		let profileID = profile(for: item.profile)
		record(item, in: profileID.rawValue.uuidString)
	}

	private mutating func importPinned(_ item: MigrationItem) {
		guard let url = item.url else { return }

		let (spaceID, profileID) = target(for: item.space)
		let tab = savedTab(item, url: url, profileID: profileID)
		organization.tabs.append(tab)

		var parent = wrapper(for: item, in: spaceID)
		for folder in item.folders {
			parent = self.folder(folder, parent: parent, in: spaceID)
		}
		place(.tab(tab.id), in: parent, space: spaceID)
		record(item, in: spaceID.rawValue.uuidString)
	}

	private func savedTab(
		_ item: MigrationItem,
		url: URL,
		profileID: Profile.ID
	) -> Tab {
		Tab(
			id: .init(rawValue: makeID()),
			profileID: profileID,
			savedDestination: .init(title: item.title, url: url),
			restoration: .init(title: item.currentTitle ?? item.title, url: item.currentURL ?? url),
			customTitle: item.customTitle,
			icon: item.tabIcon
		)
	}

	private mutating func record(
		_ item: MigrationItem,
		in target: String
	) {
		ledger.importedItems[target, default: []].insert(item.key.ledgerValue)
	}

	// MARK: - Targets

	private mutating func profile(for source: MigrationSourceProfile?) -> Profile.ID {
		let existing = organization.migrationProfile(
			for: source,
			destination: batch.destination,
			ledger: ledger
		)
		if let existing { return existing }
		guard let source else { return batch.destination.profileID }

		return createProfile(source)
	}

	private mutating func createProfile(_ source: MigrationSourceProfile) -> Profile.ID {
		let id: Profile.ID = .init(rawValue: makeID())
		organization.profiles.append(
			.init(
				id: id,
				name: batch.destination.newProfileName(for: source),
				searchEngine: source.searchEngine,
				appearance: source.appearance
			)
		)
		ledger.createdProfiles[source.id] = id
		return id
	}

	private mutating func target(for source: MigrationSourceSpace?) -> (Space.ID, Profile.ID) {
		let fallback = (batch.destination.spaceID, batch.destination.profileID)
		guard
			let source,
			let route = batch.destination.route(for: source)
		else { return fallback }

		let profileID: Profile.ID
		switch route {
		case let .existingSpace(profile, space):
			return (space, profile)

		case let .newSpace(profile):
			profileID = profile

		case .newProfile:
			if let created = ledger.createdProfiles[source.profile.id], organization.profiles.ids.contains(created) {
				profileID = created
			} else {
				profileID = createProfile(source.profile)
			}
		}

		if let created = ledger.createdSpaces[source.id], organization.spaces.ids.contains(created) {
			return (created, profileID)
		}
		let id: Space.ID = .init(rawValue: makeID())
		organization.spaces.append(
			.init(
				id: id,
				profileID: profileID,
				name: source.name,
				icon: source.icon.flatMap(SpaceIcon.init(rawValue:)),
				appearance: source.appearance
			)
		)
		ledger.createdSpaces[source.id] = id
		return (id, profileID)
	}

	// MARK: - Folders

	/// A new space takes the source's items directly. An existing one keeps them
	/// together in a folder, so they don't mix with what's already there.
	private mutating func wrapper(
		for item: MigrationItem,
		in spaceID: Space.ID
	) -> Folder.ID? {
		if let space = item.space {
			switch batch.destination.route(for: space) {
			case .newProfile, .newSpace:
				return nil

			case .existingSpace, nil:
				return folder(
					.init(id: "space:" + space.id, name: space.name),
					parent: nil,
					in: spaceID
				)
			}
		}
		return folder(
			.init(id: "source:" + item.key.sourceID.rawValue, name: batch.sourceName),
			parent: nil,
			in: spaceID
		)
	}

	private mutating func folder(
		_ source: MigrationSourceFolder,
		parent: Folder.ID?,
		in spaceID: Space.ID
	) -> Folder.ID {
		let key = [batch.sourceKey, spaceID.rawValue.uuidString, source.id].joined(separator: "\u{1F}")
		let existing = wrappers[key] ?? ledger.createdFolders[key]
		if let existing, organization.folders[id: existing]?.spaceID == spaceID { return existing }

		let id: Folder.ID = .init(rawValue: makeID())
		organization.folders.append(
			.init(
				id: id,
				spaceID: spaceID,
				name: source.name,
				isExpanded: source.isExpanded
			)
		)
		place(.folder(id), in: parent, space: spaceID)
		wrappers[key] = id
		ledger.createdFolders[key] = id
		return id
	}

	private mutating func place(
		_ item: SavedItem,
		in parent: Folder.ID?,
		space spaceID: Space.ID
	) {
		if let parent, let index = organization.folders.index(id: parent) {
			organization.folders[index].children.append(item)
		} else if let index = organization.spaces.index(id: spaceID) {
			organization.spaces[index].savedItems.append(item)
		}
	}
}

extension MigrationBatch {
	fileprivate var sourceKey: String {
		items.first?.key.sourceID.rawValue ?? sourceName
	}
}
