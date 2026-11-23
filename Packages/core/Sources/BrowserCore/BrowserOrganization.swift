import Foundation

/// An editable value snapshot. Validate before accepting decoded or externally edited data.
public struct BrowserOrganization: Equatable, Codable, Sendable {
	/// Identity that owns Chromium's original Default directory, even after removal.
	public var legacyProfileID: Profile.ID?
	public var retiredProfileIDs: Set<Profile.ID>
	public var profiles: IdentifiedArrayOf<Profile>
	public var spaces: IdentifiedArrayOf<Space>
	public var folders: IdentifiedArrayOf<Folder>
	public var tabs: IdentifiedArrayOf<Tab>
	public var archive: [ArchivedTab]

	/// Split View groups. Repaired by `normalizeSplits()` rather than validated, so a closed or
	/// moved member never blocks an edit.
	public var splits: IdentifiedArrayOf<SplitGroup>

	/// Groups of open tabs (DEV-911). Repaired by `normalizeTabGroups()` like splits.
	public var tabGroups: IdentifiedArrayOf<TabGroup>

	/// Duplicate identifiers keep their first occurrence; `validate()` reports the conflict
	/// when decoding, so constructing a value never traps.
	public init(
		profiles: [Profile] = [],
		legacyProfileID: Profile.ID? = nil,
		retiredProfileIDs: Set<Profile.ID> = [],
		spaces: [Space] = [],
		folders: [Folder] = [],
		tabs: [Tab] = [],
		archive: [ArchivedTab] = [],
		splits: [SplitGroup] = [],
		tabGroups: [TabGroup] = []
	) {
		self.legacyProfileID = legacyProfileID ?? profiles.first?.id
		self.retiredProfileIDs = retiredProfileIDs
		self.profiles = .init(profiles, uniquingIDsWith: { first, _ in first })
		self.spaces = .init(spaces, uniquingIDsWith: { first, _ in first })
		self.folders = .init(folders, uniquingIDsWith: { first, _ in first })
		self.tabs = .init(tabs, uniquingIDsWith: { first, _ in first })
		self.archive = archive
		self.splits = .init(splits, uniquingIDsWith: { first, _ in first })
		self.tabGroups = .init(tabGroups, uniquingIDsWith: { first, _ in first })
		normalizeSplits()
		normalizeTabGroups()
	}

	private enum CodingKeys: String, CodingKey {
		case legacyProfileID, retiredProfileIDs, profiles, spaces, folders, tabs, archive, splits, tabGroups
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.legacyProfileID = try values.decodeIfPresent(Profile.ID.self, forKey: .legacyProfileID)
		self.retiredProfileIDs = try values.decodeIfPresent(Set<Profile.ID>.self, forKey: .retiredProfileIDs) ?? []
		self.profiles = try values.decode(IdentifiedArrayOf<Profile>.self, forKey: .profiles)
		self.spaces = try values.decode(IdentifiedArrayOf<Space>.self, forKey: .spaces)
		self.folders = try values.decode(IdentifiedArrayOf<Folder>.self, forKey: .folders)
		self.tabs = try values.decode(IdentifiedArrayOf<Tab>.self, forKey: .tabs)
		self.archive = try values.decodeIfPresent([ArchivedTab].self, forKey: .archive) ?? []

		// Absent before Split View groups were saved.
		let splits = try values.decodeIfPresent([SplitGroup].self, forKey: .splits) ?? []
		self.splits = .init(splits, uniquingIDsWith: { first, _ in first })

		// Absent before open tabs could be grouped (DEV-911).
		let tabGroups = try values.decodeIfPresent([TabGroup].self, forKey: .tabGroups) ?? []
		self.tabGroups = .init(tabGroups, uniquingIDsWith: { first, _ in first })
		normalizeSplits()
		normalizeTabGroups()
	}

	/// Commits a complete, valid edit or leaves this value unchanged.
	public mutating func update(_ edit: (inout Self) throws -> Void) throws {
		var candidate = self
		try edit(&candidate)
		candidate.normalizeSplits()
		candidate.normalizeTabGroups()

		// The archive grows without bound and most edits leave it alone; an archive array this
		// value already held was validated with it (DEV-947).
		try candidate.validate(includingArchive: candidate.archive != archive)
		self = candidate
	}

	/// Every tab's location in one pass, with the same precedence as `location(of:)`.
	/// Prefer it over repeated `location(of:)` calls when resolving many tabs.
	public var tabLocations: [Tab.ID: TabLocation] {
		var locations: [Tab.ID: TabLocation] = [:]
		for profile in profiles {
			for id in profile.favorites where locations[id] == nil {
				locations[id] = .favorite(profile.id)
			}
		}
		for space in spaces {
			for id in space.unpinnedTabs where locations[id] == nil {
				locations[id] = .unpinned(space.id)
			}
			for case let .tab(id) in space.savedItems where locations[id] == nil {
				locations[id] = .pinned(space.id, folder: nil)
			}
		}
		for folder in folders {
			for case let .tab(id) in folder.children where locations[id] == nil {
				locations[id] = .pinned(folder.spaceID, folder: folder.id)
			}
		}
		return locations
	}

	public func location(of tabID: Tab.ID) -> TabLocation? {
		WorkProbe.record(.tabLocationSearch)
		for profile in profiles where profile.favorites.contains(tabID) {
			return .favorite(profile.id)
		}
		for space in spaces {
			if space.unpinnedTabs.contains(tabID) { return .unpinned(space.id) }
			if space.savedItems.contains(.tab(tabID)) { return .pinned(space.id, folder: nil) }
		}
		for folder in folders where folder.children.contains(.tab(tabID)) {
			return .pinned(folder.spaceID, folder: folder.id)
		}
		return nil
	}
}

extension BrowserOrganization {
	/// Native acknowledged retirements override imported or recovered metadata.
	/// If recovery has no surviving profile/space, it must remain blocked instead
	/// of silently manufacturing a new owner for an old storage identity.
	public func excludingRetiredProfiles(_ identities: Set<Profile.ID>) throws -> Self {
		var result = self
		result.retiredProfileIDs.formUnion(identities)
		let retired = result.retiredProfileIDs
		let removedSpaces = Set(spaces.filter { retired.contains($0.profileID) }.map(\.id))
		result.profiles.removeAll { retired.contains($0.id) }
		result.spaces.removeAll { removedSpaces.contains($0.id) }
		result.folders.removeAll { removedSpaces.contains($0.spaceID) }
		result.tabs.removeAll { retired.contains($0.profileID) }
		guard !result.profiles.isEmpty, !result.spaces.isEmpty
		else { throw OrganizationChangeError.lastProfile }
		try result.validate()
		return result
	}
}

extension BrowserOrganization {
	public enum TabLocation: Equatable, Sendable {
		case favorite(Profile.ID)
		case pinned(Space.ID, folder: Folder.ID?)
		case unpinned(Space.ID)
	}
}
