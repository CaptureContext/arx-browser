import BrowserCore
import Foundation

/// A `BrowserOrganization` as the organization database's rows, and back.
///
/// Ordered arrays become ``FractionalIndex`` positions. Building rows from a new value reuses the
/// previous rows' positions for every item still in order, so a move or an insertion rewrites only
/// the rows it touched.
public struct OrganizationRows: Equatable, Sendable {
	public var profiles: [UUID: ProfileRecord]
	public var spaces: [UUID: SpaceRecord]
	public var folders: [UUID: FolderRecord]
	public var pinnedTabs: [UUID: PinnedTabRecord]
	public var favorites: [UUID: FavoriteRecord]
	public var retiredProfiles: [UUID: RetiredProfileRecord]
	public var spaceStates: [UUID: SpaceStateRecord]
	public var folderStates: [UUID: FolderStateRecord]
	public var tabStates: [UUID: TabStateRecord]
	public var regularTabs: [UUID: RegularTabRecord]

	/// Tab Archive's entries, kept in `arx-archive.sqlite` (DEV-983).
	public var archivedTabs: [UUID: ArchiveEntryRecord]
	public var splitGroups: [UUID: SplitGroupRecord]
	public var tabGroups: [UUID: TabGroupRecord]
	public var legacyProfileID: UUID?

	/// The "this Mac only" profiles, whose rows live in `arx-organization-local.sqlite` (DEV-981).
	public var localProfileIDs: Set<UUID>

	/// The synced rows profiles turned "this Mac only" had then, which this Mac doesn't show while
	/// they're local, wherever another Mac moves them (their baselines, DEV-981).
	public var shadowedIDs: Set<UUID> = []

	public init(
		profiles: [UUID: ProfileRecord] = [:],
		spaces: [UUID: SpaceRecord] = [:],
		folders: [UUID: FolderRecord] = [:],
		pinnedTabs: [UUID: PinnedTabRecord] = [:],
		favorites: [UUID: FavoriteRecord] = [:],
		retiredProfiles: [UUID: RetiredProfileRecord] = [:],
		spaceStates: [UUID: SpaceStateRecord] = [:],
		folderStates: [UUID: FolderStateRecord] = [:],
		tabStates: [UUID: TabStateRecord] = [:],
		regularTabs: [UUID: RegularTabRecord] = [:],
		archivedTabs: [UUID: ArchiveEntryRecord] = [:],
		splitGroups: [UUID: SplitGroupRecord] = [:],
		tabGroups: [UUID: TabGroupRecord] = [:],
		legacyProfileID: UUID? = nil,
		localProfileIDs: Set<UUID> = []
	) {
		self.profiles = profiles
		self.spaces = spaces
		self.folders = folders
		self.pinnedTabs = pinnedTabs
		self.favorites = favorites
		self.retiredProfiles = retiredProfiles
		self.spaceStates = spaceStates
		self.folderStates = folderStates
		self.tabStates = tabStates
		self.regularTabs = regularTabs
		self.archivedTabs = archivedTabs
		self.splitGroups = splitGroups
		self.tabGroups = tabGroups
		self.legacyProfileID = legacyProfileID
		self.localProfileIDs = localProfileIDs
	}

	/// The rows for `organization`, keeping `previous`'s positions where the order allows.
	///
	/// - Parameters:
	///   - archiveIsUnchanged: the archive equals the one `previous` was built from, so its
	///     rows are reused rather than encoded again; the archive grows without bound (DEV-947).
	public init(
		_ organization: BrowserOrganization,
		previous: Self = .init(),
		archiveIsUnchanged: Bool = false
	) throws {
		self.init()
		self.legacyProfileID = (organization.legacyProfileID ?? organization.profiles.first?.id)?.rawValue
		self.localProfileIDs = Set(organization.profiles.filter(\.isThisMacOnly).map(\.id.rawValue))
		for id in organization.retiredProfileIDs {
			retiredProfiles[id.rawValue] = .init(id: id.rawValue)
		}
		try addProfiles(organization, previous: previous)
		try addSpaces(organization, previous: previous)
		try addTabs(organization, previous: previous)
		try addLocalLists(organization, previous: previous, archiveIsUnchanged: archiveIsUnchanged)
	}

	// MARK: - Building rows

	private mutating func addProfiles(
		_ organization: BrowserOrganization,
		previous: Self
	) throws {
		let positions: [String] = OrderedPositions.assign(
			organization.profiles.map(\.id.rawValue),
			previous: previous.profiles.mapValues(\.position)
		)
		for (profile, position) in zip(organization.profiles, positions) {
			profiles[profile.id.rawValue] = .init(
				id: profile.id.rawValue,
				name: profile.name,
				searchEngine: profile.searchEngine?.rawValue,
				appearance: try JSONColumn.encode(profile.appearance),
				tabArchiveInterval: profile.tabArchiveInterval?.rawValue,
				remoteSearchSuggestions: profile.remoteSearchSuggestions,
				showsFullURL: profile.showsFullURL,
				keptLoadedSites: try JSONColumn.encode(profile.keptLoadedSites),
				darkPagesOffSites: try JSONColumn.encode(profile.darkPagesOffSites),
				unreadBadges: profile.unreadBadges?.rawValue,
				position: position,
				isStarter: previous.profiles[profile.id.rawValue]?.isStarter ?? false
			)

			let favoritePositions: [String] = OrderedPositions.assign(
				profile.favorites.map(\.rawValue),
				previous: previous.favorites.filter { $0.value.profileID == profile.id.rawValue }.mapValues(\.position)
			)
			for (tabID, position) in zip(profile.favorites, favoritePositions) {
				guard let destination = organization.tabs[id: tabID]?.savedDestination
				else { continue }

				favorites[tabID.rawValue] = .init(
					id: tabID.rawValue,
					profileID: profile.id.rawValue,
					title: destination.title,
					url: destination.url.absoluteString,
					iconURL: destination.iconURL?.absoluteString,
					customTitle: organization.tabs[id: tabID]?.customTitle,
					icon: try JSONColumn.encode(organization.tabs[id: tabID]?.icon),
					position: position
				)
			}
		}
	}

	private mutating func addSpaces(
		_ organization: BrowserOrganization,
		previous: Self
	) throws {
		let positions: [String] = OrderedPositions.assign(
			organization.spaces.map(\.id.rawValue),
			previous: previous.spaces.mapValues(\.position)
		)
		let previousItems: [SavedItemKey: (container: Container, position: String)] = previous.savedItemPositions
		for (space, position) in zip(organization.spaces, positions) {
			spaces[space.id.rawValue] = .init(
				id: space.id.rawValue,
				profileID: space.profileID.rawValue,
				name: space.name,
				icon: try JSONColumn.encode(space.icon),
				appearance: try JSONColumn.encode(space.appearance),
				position: position,
				isStarter: previous.spaces[space.id.rawValue]?.isStarter ?? false
			)
			if let selected = space.selectedTabID {
				spaceStates[space.id.rawValue] = .init(id: space.id.rawValue, selectedTabID: selected.rawValue)
			}
			try addSavedItems(space.savedItems, in: .init(spaceID: space.id.rawValue, folderID: nil), organization, previousItems)

			let regularPositions: [String] = OrderedPositions.assign(
				space.unpinnedTabs.map(\.rawValue),
				previous: previous.regularTabs.filter { $0.value.spaceID == space.id.rawValue }.mapValues(\.position)
			)
			for (tabID, position) in zip(space.unpinnedTabs, regularPositions) {
				regularTabs[tabID.rawValue] = .init(
					id: tabID.rawValue,
					spaceID: space.id.rawValue,
					customTitle: organization.tabs[id: tabID]?.customTitle,
					icon: try JSONColumn.encode(organization.tabs[id: tabID]?.icon),
					position: position
				)
			}
		}

		let ordinals: [String] = OrderedPositions.assign(
			organization.folders.map(\.id.rawValue),
			previous: previous.folderStates.mapValues(\.ordinal)
		)
		for (folder, ordinal) in zip(organization.folders, ordinals) {
			folderStates[folder.id.rawValue] = .init(
				id: folder.id.rawValue,
				isExpanded: folder.isExpanded,
				ordinal: ordinal
			)
			try addSavedItems(
				folder.children,
				in: .init(spaceID: folder.spaceID.rawValue, folderID: folder.id.rawValue),
				organization,
				previousItems
			)
		}
	}

	private mutating func addSavedItems(
		_ items: [SavedItem],
		in container: Container,
		_ organization: BrowserOrganization,
		_ previousItems: [SavedItemKey: (container: Container, position: String)]
	) throws {
		let keys: [SavedItemKey] = items.map(SavedItemKey.init)
		var previous: [SavedItemKey: String] = [:]
		for key in keys {
			guard let entry = previousItems[key], entry.container == container else { continue }

			previous[key] = entry.position
		}
		let positions: [String] = OrderedPositions.assign(keys, previous: previous)
		for (item, position) in zip(items, positions) {
			switch item {
			case let .folder(id):
				guard let folder = organization.folders[id: id] else { continue }

				folders[id.rawValue] = .init(
					id: id.rawValue,
					spaceID: container.spaceID,
					parentFolderID: container.folderID,
					name: folder.name,
					position: position
				)

			case let .tab(id):
				guard
					let tab = organization.tabs[id: id],
					let destination = tab.savedDestination
				else { continue }

				pinnedTabs[id.rawValue] = .init(
					id: id.rawValue,
					spaceID: container.spaceID,
					folderID: container.folderID,
					title: destination.title,
					url: destination.url.absoluteString,
					iconURL: destination.iconURL?.absoluteString,
					customTitle: tab.customTitle,
					icon: try JSONColumn.encode(tab.icon),
					position: position
				)
			}
		}
	}

	private mutating func addTabs(
		_ organization: BrowserOrganization,
		previous: Self
	) throws {
		let ordinals: [String] = OrderedPositions.assign(
			organization.tabs.map(\.id.rawValue),
			previous: previous.tabStates.mapValues(\.ordinal)
		)
		for (tab, ordinal) in zip(organization.tabs, ordinals) {
			tabStates[tab.id.rawValue] = .init(
				id: tab.id.rawValue,
				restorationTitle: tab.restoration.title,
				restorationURL: tab.restoration.url.absoluteString,
				automationClientID: tab.automationClientID,
				ordinal: ordinal
			)
		}
	}

	private mutating func addLocalLists(
		_ organization: BrowserOrganization,
		previous: Self,
		archiveIsUnchanged: Bool
	) throws {
		if archiveIsUnchanged {
			archivedTabs = previous.archivedTabs
		} else {
			let archivePositions: [String] = OrderedPositions.assign(
				organization.archive.map(\.id.rawValue),
				previous: previous.archivedTabs.mapValues(\.position)
			)
			for (entry, position) in zip(organization.archive, archivePositions) {
				archivedTabs[entry.id.rawValue] = .init(entry, position: position)
			}
		}

		let splitPositions: [String] = OrderedPositions.assign(
			organization.splits.map(\.id.rawValue),
			previous: previous.splitGroups.mapValues(\.position)
		)
		for (split, position) in zip(organization.splits, splitPositions) {
			splitGroups[split.id.rawValue] = .init(
				id: split.id.rawValue,
				value: try JSONColumn.encode(split),
				position: position
			)
		}

		let groupPositions: [String] = OrderedPositions.assign(
			organization.tabGroups.map(\.id.rawValue),
			previous: previous.tabGroups.mapValues(\.position)
		)
		for (group, position) in zip(organization.tabGroups, groupPositions) {
			tabGroups[group.id.rawValue] = .init(
				id: group.id.rawValue,
				value: try JSONColumn.encode(group),
				position: position
			)
		}
	}

	// MARK: - Reading rows

	/// The organization these rows describe. The caller validates it.
	///
	/// A tab with no location row is dropped, and a located tab with no ``TabStateRecord`` (as a
	/// record synced from another Mac will be) starts at its saved destination.
	public func organization() throws -> BrowserOrganization {
		let profileOrder: [ProfileRecord] = profiles.values.sorted(by: Self.order(\.position))
		let spaceOrder: [SpaceRecord] = spaces.values.sorted(by: Self.order(\.position))
		var tabs: [Tab.ID: Tab] = [:]

		func tab(
			_ id: UUID,
			profileID: UUID,
			saved: Tab.SavedDestination?,
			customTitle: String?,
			icon: String?
		) throws -> Tab.ID {
			let state: TabStateRecord? = tabStates[id]
			let restoration: Tab.Restoration = if let state {
				.init(title: state.restorationTitle, url: try Self.url(state.restorationURL))
			} else if let saved {
				.init(title: saved.title, url: saved.url)
			} else {
				throw ReadError.missingTabState(id)
			}
			let tab: Tab = .init(
				id: .init(rawValue: id),
				profileID: .init(rawValue: profileID),
				savedDestination: saved,
				restoration: restoration,
				customTitle: customTitle,
				// One this version can't read, as from a newer Mac, leaves the site's icon.
				icon: (try? JSONColumn.decode(SpaceIcon.self, from: icon)) ?? nil,
				automationClientID: state?.automationClientID
			)
			tabs[tab.id] = tab
			return tab.id
		}

		var resultProfiles: [Profile] = []
		for record in profileOrder {
			let favoriteIDs: [Tab.ID] = try favorites.values
				.filter { $0.profileID == record.id }
				.sorted(by: Self.order(\.position))
				.map { favorite in
					try tab(
						favorite.id,
						profileID: record.id,
						saved: .init(
							title: favorite.title,
							url: try Self.url(favorite.url),
							iconURL: try favorite.iconURL.map(Self.url)
						),
						customTitle: favorite.customTitle,
						icon: favorite.icon
					)
				}
			resultProfiles.append(
				.init(
					id: .init(rawValue: record.id),
					name: record.name,
					favorites: favoriteIDs,
					searchEngine: record.searchEngine.flatMap(SearchEngine.init(rawValue:)),
					appearance: try JSONColumn.decode(AppearanceOverride.self, from: record.appearance),
					tabArchiveInterval: record.tabArchiveInterval.flatMap(TabArchiveInterval.init(rawValue:)),
					remoteSearchSuggestions: record.remoteSearchSuggestions,
					showsFullURL: record.showsFullURL,
					keptLoadedSites: try JSONColumn.decode([String].self, from: record.keptLoadedSites),
					darkPagesOffSites: try JSONColumn.decode([String].self, from: record.darkPagesOffSites),
					unreadBadges: record.unreadBadges.flatMap(UnreadBadgeVisibility.init(rawValue:)),
					syncsWithICloud: localProfileIDs.contains(record.id) ? false : nil
				)
			)
		}

		let containers: [Container: [SavedRow]] = savedRowsByContainer
		func items(
			in container: Container,
			profileID: UUID
		) throws -> [SavedItem] {
			try (containers[container] ?? []).map { row in
				switch row {
				case let .folder(folder):
					return .folder(.init(rawValue: folder.id))

				case let .pinnedTab(pinned):
					let id: Tab.ID = try tab(
						pinned.id,
						profileID: profileID,
						saved: .init(
							title: pinned.title,
							url: try Self.url(pinned.url),
							iconURL: try pinned.iconURL.map(Self.url)
						),
						customTitle: pinned.customTitle,
						icon: pinned.icon
					)
					return .tab(id)
				}
			}
		}

		var resultSpaces: [Space] = []
		for record in spaceOrder {
			let regularIDs: [Tab.ID] = try regularTabs.values
				.filter { $0.spaceID == record.id }
				.sorted(by: Self.order(\.position))
				.map { regular in
					try tab(regular.id, profileID: record.profileID, saved: nil, customTitle: regular.customTitle, icon: regular.icon)
				}
			resultSpaces.append(
				.init(
					id: .init(rawValue: record.id),
					profileID: .init(rawValue: record.profileID),
					name: record.name,
					icon: try JSONColumn.decode(SpaceIcon.self, from: record.icon),
					appearance: try JSONColumn.decode(AppearanceOverride.self, from: record.appearance),
					savedItems: try items(in: .init(spaceID: record.id, folderID: nil), profileID: record.profileID),
					unpinnedTabs: regularIDs,
					selectedTabID: spaceStates[record.id]?.selectedTabID.map(Tab.ID.init(rawValue:))
				)
			)
		}

		// `BrowserOrganization.folders` keeps this Mac's order; folders without one (synced in) follow.
		let folderOrder: [FolderRecord] = folders.values.sorted { lhs, rhs in
			let left: String? = folderStates[lhs.id]?.ordinal
			let right: String? = folderStates[rhs.id]?.ordinal
			switch (left, right) {
			case let (left?, right?): return (left, lhs.id.uuidString) < (right, rhs.id.uuidString)
			case (.some, nil): return true
			case (nil, .some): return false
			case (nil, nil): return (lhs.position, lhs.id.uuidString) < (rhs.position, rhs.id.uuidString)
			}
		}
		var resultFolders: [Folder] = []
		for record in folderOrder {
			guard let profileID = spaces[record.spaceID]?.profileID
			else { throw ReadError.missingSpace(record.spaceID) }

			resultFolders.append(
				.init(
					id: .init(rawValue: record.id),
					spaceID: .init(rawValue: record.spaceID),
					name: record.name,
					children: try items(in: .init(spaceID: record.spaceID, folderID: record.id), profileID: profileID),
					isExpanded: folderStates[record.id]?.isExpanded ?? true
				)
			)
		}

		let tabOrder: [Tab] = tabs.values.sorted { lhs, rhs in
			let left: String? = tabStates[lhs.id.rawValue]?.ordinal
			let right: String? = tabStates[rhs.id.rawValue]?.ordinal
			switch (left, right) {
			case let (left?, right?): return (left, lhs.id.rawValue.uuidString) < (right, rhs.id.rawValue.uuidString)
			case (.some, nil): return true
			case (nil, .some): return false
			case (nil, nil): return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
			}
		}

		return .init(
			profiles: resultProfiles,
			legacyProfileID: legacyProfileID.map(Profile.ID.init(rawValue:)),
			retiredProfileIDs: Set(retiredProfiles.keys.map(Profile.ID.init(rawValue:))),
			spaces: resultSpaces,
			folders: resultFolders,
			tabs: tabOrder,
			archive: Self.archive(archivedTabs),
			splits: try splitGroups.values
				.sorted(by: Self.order(\.position))
				.map { try JSONColumn.decode(SplitGroup.self, from: $0.value) },
			tabGroups: try tabGroups.values
				.sorted(by: Self.order(\.position))
				.map { try JSONColumn.decode(TabGroup.self, from: $0.value) }
		)
	}

	public enum ReadError: Error, Equatable, Sendable {
		case invalidURL(String)
		case missingSpace(UUID)
		case missingTabState(UUID)
	}

	// MARK: - Helpers

	/// Ordered by `(position, id)`, as ADR 0001 orders rows with equal keys.
	/// The entries in order. A row whose address isn't one, as another Mac's damaged row could have,
	/// is left out, and of entries for the same tab, as two Macs archiving a tab that was closed,
	/// brought back and closed again can leave, only the latest.
	private static func archive(_ rows: [UUID: ArchiveEntryRecord]) -> [ArchivedTab] {
		var latest: [UUID: ArchiveEntryRecord] = [:]
		for row in rows.values {
			guard let kept = latest[row.tabID] else {
				latest[row.tabID] = row
				continue
			}
			if (row.closedAt, row.id.uuidString) > (kept.closedAt, kept.id.uuidString) {
				latest[row.tabID] = row
			}
		}
		return latest.values.sorted(by: order(\.position)).compactMap(\.entry)
	}

	private static func order<Record: Identifiable>(
		_ position: KeyPath<Record, String>
	) -> (Record, Record) -> Bool where Record.ID == UUID {
		{ lhs, rhs in
			(lhs[keyPath: position], lhs.id.uuidString) < (rhs[keyPath: position], rhs.id.uuidString)
		}
	}

	private static func url(_ text: String) throws -> URL {
		guard let url = URL(string: text) else { throw ReadError.invalidURL(text) }

		return url
	}

	/// A space root (`folderID == nil`) or a folder: one ordered collection of folders and pinned tabs.
	internal struct Container: Hashable, Sendable {
		internal var spaceID: UUID
		internal var folderID: UUID?

		internal init(
			spaceID: UUID,
			folderID: UUID?
		) {
			self.spaceID = spaceID
			self.folderID = folderID
		}
	}

	/// Folders and pinned tabs share their containers' positions, so they share one key type.
	internal enum SavedItemKey: Hashable, Sendable {
		case folder(UUID)
		case tab(UUID)

		internal init(_ item: SavedItem) {
			switch item {
			case let .folder(id): self = .folder(id.rawValue)
			case let .tab(id): self = .tab(id.rawValue)
			}
		}
	}

	private enum SavedRow {
		case folder(FolderRecord)
		case pinnedTab(PinnedTabRecord)

		internal var id: UUID {
			switch self {
			case let .folder(folder): folder.id
			case let .pinnedTab(tab): tab.id
			}
		}

		internal var position: String {
			switch self {
			case let .folder(folder): folder.position
			case let .pinnedTab(tab): tab.position
			}
		}
	}

	private var savedItemPositions: [SavedItemKey: (container: Container, position: String)] {
		var result: [SavedItemKey: (container: Container, position: String)] = [:]
		for folder in folders.values {
			result[.folder(folder.id)] = (.init(spaceID: folder.spaceID, folderID: folder.parentFolderID), folder.position)
		}
		for tab in pinnedTabs.values {
			result[.tab(tab.id)] = (.init(spaceID: tab.spaceID, folderID: tab.folderID), tab.position)
		}
		return result
	}

	private var savedRowsByContainer: [Container: [SavedRow]] {
		var result: [Container: [SavedRow]] = [:]
		for folder in folders.values {
			result[.init(spaceID: folder.spaceID, folderID: folder.parentFolderID), default: []].append(.folder(folder))
		}
		for tab in pinnedTabs.values {
			result[.init(spaceID: tab.spaceID, folderID: tab.folderID), default: []].append(.pinnedTab(tab))
		}
		return result.mapValues { rows in
			rows.sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
		}
	}
}

// MARK: - "This Mac only" profiles (DEV-981)

extension OrganizationRows {
	/// The profile each row belongs to, for the rows split between the synced and the local file:
	/// profiles, spaces, folders, pinned tabs, Favorites, space and folder state, open tabs and Tab
	/// Archive entries. Other rows aren't any profile's.
	internal struct Owners {
		internal var spaces: [UUID: UUID] = [:]
		internal var folders: [UUID: UUID] = [:]

		internal init(_ rows: OrganizationRows) {
			for (id, space) in rows.spaces {
				spaces[id] = space.profileID
			}
			for (id, folder) in rows.folders {
				folders[id] = spaces[folder.spaceID]
			}
		}
	}

	/// These rows split into those of synced profiles, with every row no profile owns, and those of
	/// ``localProfileIDs``.
	internal func split() -> (synced: Self, local: Self) {
		let owners: Owners = .init(self)
		let local: Set<UUID> = localProfileIDs
		func isLocal(_ profileID: UUID?) -> Bool { profileID.map(local.contains) ?? false }

		var synced: Self = self
		var localRows: Self = .init(localProfileIDs: local)
		func move<Record>(_ path: WritableKeyPath<Self, [UUID: Record]>, owner: (UUID, Record) -> UUID?) {
			for (id, row) in self[keyPath: path] where isLocal(owner(id, row)) {
				synced[keyPath: path][id] = nil
				localRows[keyPath: path][id] = row
			}
		}
		move(\.profiles) { id, _ in id }
		move(\.spaces) { _, row in row.profileID }
		move(\.folders) { id, _ in owners.folders[id] }
		move(\.pinnedTabs) { _, row in owners.spaces[row.spaceID] }
		move(\.favorites) { _, row in row.profileID }
		move(\.spaceStates) { id, _ in owners.spaces[id] }
		move(\.folderStates) { id, _ in owners.folders[id] }
		move(\.regularTabs) { _, row in owners.spaces[row.spaceID] }
		move(\.archivedTabs) { _, row in row.profileID }
		return (synced, localRows)
	}

	/// The synced rows a save writes: `self`, plus the synced rows `old` has of the profiles that are
	/// local now, unchanged. A profile turned "this Mac only" leaves its synced copies
	/// as they are, for the other Macs; they're never deleted or hidden for it (DEV-981). Its space,
	/// folder and open-tab state moves: only this Mac has it.
	internal func keepingMoved(
		to local: Self,
		from old: Self
	) -> Self {
		var rows: Self = self

		// Everything a local profile had in the synced file, even what this save removes with it.
		var owned: Self = old
		owned.localProfileIDs = local.localProfileIDs
		let (_, subtree) = owned.split()

		// Only what a local profile had: an item moved into a local profile from a synced one leaves
		// that profile, which is a deletion there as any other.
		func keep<Record>(_ path: WritableKeyPath<Self, [UUID: Record]>) {
			for (id, row) in old[keyPath: path] where rows[keyPath: path][id] == nil && subtree[keyPath: path][id] != nil {
				rows[keyPath: path][id] = row
			}
		}
		keep(\.profiles)
		keep(\.spaces)
		keep(\.folders)
		keep(\.pinnedTabs)
		keep(\.favorites)
		keep(\.archivedTabs)
		return rows
	}

	/// The rows of both files as one workspace: `synced` without the synced copies of `local`'s
	/// profiles, which this Mac doesn't show, with `local`'s rows.
	internal static func merging(
		synced: Self,
		local: Self
	) -> Self {
		var shown: Self = synced
		shown.localProfileIDs = local.localProfileIDs
		var (kept, _) = shown.split()

		// The local copy's own rows, wherever another Mac moved their synced copies, and what's in
		// them there.
		let shadowed: Set<UUID> = local.shadowedIDs
		let spaces: Set<UUID> = Set(local.spaces.keys).union(shadowed)
		var folders: Set<UUID> = Set(local.folders.keys).union(shadowed)
		kept.profiles = kept.profiles.filter { !shadowed.contains($0.key) }
		kept.spaces = kept.spaces.filter { !spaces.contains($0.key) }
		var changed: Bool = true
		while changed {
			changed = false
			for (id, folder) in kept.folders where !folders.contains(id)
				&& (spaces.contains(folder.spaceID) || folder.parentFolderID.map(folders.contains) == true)
			{
				folders.insert(id)
				changed = true
			}
		}
		kept.folders = kept.folders.filter { !folders.contains($0.key) }
		kept.pinnedTabs = kept.pinnedTabs.filter { id, pin in
			local.pinnedTabs[id] == nil && !shadowed.contains(id) && !spaces.contains(pin.spaceID)
				&& !(pin.folderID.map(folders.contains) ?? false)
		}
		kept.favorites = kept.favorites.filter { local.favorites[$0.key] == nil && !shadowed.contains($0.key) }
		kept.spaceStates = kept.spaceStates.filter { !spaces.contains($0.key) }
		kept.folderStates = kept.folderStates.filter { !folders.contains($0.key) }
		kept.regularTabs = kept.regularTabs.filter { !spaces.contains($0.value.spaceID) }
		kept.archivedTabs = kept.archivedTabs.filter { local.archivedTabs[$0.key] == nil && !shadowed.contains($0.key) }
		var rows: Self = kept
		rows.localProfileIDs = local.localProfileIDs
		func add<Record>(_ path: WritableKeyPath<Self, [UUID: Record]>) {
			rows[keyPath: path].merge(local[keyPath: path]) { _, local in local }
		}
		add(\.profiles)
		add(\.spaces)
		add(\.folders)
		add(\.pinnedTabs)
		add(\.favorites)
		add(\.spaceStates)
		add(\.folderStates)
		add(\.regularTabs)
		add(\.archivedTabs)
		return rows
	}
}
