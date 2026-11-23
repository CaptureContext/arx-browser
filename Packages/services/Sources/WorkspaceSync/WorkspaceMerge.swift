import Foundation
import WorkspaceDatabase
import _SQLiteData

/// Merging what matches (DEV-1216): this Mac's profiles, spaces, folders, pins and Favorites against
/// iCloud's, so turning sync on later doesn't copy everything twice.
///
/// - **Profiles** match by name, ignoring case and spaces. With several candidates, the pair whose
///   spaces overlap most wins.
/// - **Spaces** match within a matched profile: the starter space with the starter space, then by
///   name, then by pinned tabs in common.
/// - **Folders** match by name and path, **pins and Favorites** by address, with the scheme and host
///   lowercased and a trailing slash and fragment ignored. A match becomes one item; the rest are
///   added after iCloud's, in this Mac's order.
/// - **iCloud wins** for a matched item's settings. Unmatched items are added as they are, with the
///   Mac's name after a name iCloud already has.
///
/// The joining Mac merges before any of its rows upload: ``applyJoining(_:local:cloud:)`` moves its
/// own rows into iCloud's IDs. Two synced profiles are merged from Settings with ``applySynced(_:now:_:)``,
/// which writes a ``MergedItemRecord`` for each merged item, so every Mac moves its own open tabs and
/// website data before it hides the merged one (``applyMergedItems(_:now:)``).
public enum WorkspaceMerge {
	// MARK: - Snapshot

	/// The synced organization rows a merge looks at.
	public struct Snapshot: Equatable, Sendable {
		public var profiles: [ProfileRecord]
		public var spaces: [SpaceRecord]
		public var folders: [FolderRecord]
		public var pinnedTabs: [PinnedTabRecord]
		public var favorites: [FavoriteRecord]

		public init(
			profiles: [ProfileRecord] = [],
			spaces: [SpaceRecord] = [],
			folders: [FolderRecord] = [],
			pinnedTabs: [PinnedTabRecord] = [],
			favorites: [FavoriteRecord] = []
		) {
			self.profiles = profiles
			self.spaces = spaces
			self.folders = folders
			self.pinnedTabs = pinnedTabs
			self.favorites = favorites
		}

		public var isEmpty: Bool {
			profiles.isEmpty && spaces.isEmpty && folders.isEmpty && pinnedTabs.isEmpty && favorites.isEmpty
		}

		/// This Mac's synced rows as it shows them: without "this Mac only" profiles (DEV-981), which
		/// never sync, and without what this Mac deleted (DEV-980). A hidden folder's children count in
		/// the closest folder above it that shows.
		public init(_ db: Database) throws {
			let hidden: HiddenItems = try LocalDeletion.hiddenItems(db)
			let attachesLocal: Bool = try Bool.fetchOne(
				db,
				sql: "SELECT EXISTS (SELECT 1 FROM pragma_database_list WHERE \"name\" = 'local')"
			) ?? false
			let localProfiles: Set<UUID> = attachesLocal
			? Set(try UUID.fetchAll(db, sql: #"SELECT "id" FROM "local"."profile""#))
			: []

			let profiles: [ProfileRecord] = try ProfileRecord.all.fetchAll(db).filter { profile in
				!localProfiles.contains(profile.id) && !hidden.contains(profile.id, in: ProfileRecord.tableName)
			}
			let profileIDs: Set<UUID> = Set(profiles.map(\.id))
			let spaces: [SpaceRecord] = try SpaceRecord.all.fetchAll(db).filter { space in
				profileIDs.contains(space.profileID) && !hidden.contains(space.id, in: SpaceRecord.tableName)
			}
			let spaceIDs: Set<UUID> = Set(spaces.map(\.id))
			let allFolders: [FolderRecord] = try FolderRecord.all.fetchAll(db)
			let folderParents: [UUID: UUID?] = Dictionary(
				allFolders.map { ($0.id, $0.parentFolderID) },
				uniquingKeysWith: { first, _ in first }
			)

			func shownFolder(_ id: UUID?) -> UUID? {
				var current: UUID? = id
				var visited: Set<UUID> = []
				while let folderID = current, visited.insert(folderID).inserted {
					guard hidden.contains(folderID, in: FolderRecord.tableName) else { return folderID }

					current = folderParents[folderID] ?? nil
				}
				return nil
			}

			let folders: [FolderRecord] = allFolders
				.filter { spaceIDs.contains($0.spaceID) && !hidden.contains($0.id, in: FolderRecord.tableName) }
				.map { folder in
					var folder: FolderRecord = folder
					folder.parentFolderID = shownFolder(folder.parentFolderID)
					return folder
				}
			let pinnedTabs: [PinnedTabRecord] = try PinnedTabRecord.all.fetchAll(db)
				.filter { spaceIDs.contains($0.spaceID) && !hidden.contains($0.id, in: PinnedTabRecord.tableName) }
				.map { tab in
					var tab: PinnedTabRecord = tab
					tab.folderID = shownFolder(tab.folderID)
					return tab
				}
			let favorites: [FavoriteRecord] = try FavoriteRecord.all.fetchAll(db).filter { favorite in
				profileIDs.contains(favorite.profileID) && !hidden.contains(favorite.id, in: FavoriteRecord.tableName)
			}
			self.init(profiles: profiles, spaces: spaces, folders: folders, pinnedTabs: pinnedTabs, favorites: favorites)
		}

		/// iCloud's rows, from the whole organization zone (``CloudAccess/zoneRecords``) read with
		/// ``fields``. A record missing what makes it valid is left out, with what's in it.
		public init(_ records: [CloudAccess.ZoneRecord]) {
			var profiles: [ProfileRecord] = []
			var spaces: [SpaceRecord] = []
			var folders: [FolderRecord] = []
			var pinnedTabs: [PinnedTabRecord] = []
			var favorites: [FavoriteRecord] = []
			for record in records {
				guard let id = record.id else { continue }

				let fields: [String: String] = record.fields
				func uuid(_ key: String) -> UUID? { fields[key].flatMap(UUID.init(uuidString:)) }
				func flag(_ key: String) -> Bool? { fields[key].flatMap(Int.init).map { $0 != 0 } }
				let position: String = fields["position"] ?? "V"

				switch record.type {
				case ProfileRecord.tableName:
					profiles.append(
						.init(
							id: id,
							name: fields["name"] ?? "",
							searchEngine: fields["searchEngine"],
							appearance: fields["appearance"],
							tabArchiveInterval: fields["tabArchiveInterval"],
							remoteSearchSuggestions: flag("remoteSearchSuggestions"),
							showsFullURL: flag("showsFullURL"),
							keptLoadedSites: fields["keptLoadedSites"],
							darkPagesOffSites: fields["darkPagesOffSites"],
							unreadBadges: fields["unreadBadges"],
							position: position,
							isStarter: flag("isStarter") ?? false
						)
					)

				case SpaceRecord.tableName:
					guard let profileID = uuid("profileID") else { continue }

					spaces.append(
						.init(
							id: id,
							profileID: profileID,
							name: fields["name"] ?? "",
							icon: fields["icon"],
							appearance: fields["appearance"],
							position: position,
							isStarter: flag("isStarter") ?? false
						)
					)

				case FolderRecord.tableName:
					guard let spaceID = uuid("spaceID") else { continue }

					folders.append(
						.init(
							id: id,
							spaceID: spaceID,
							parentFolderID: uuid("parentFolderID"),
							name: fields["name"] ?? "",
							position: position
						)
					)

				case PinnedTabRecord.tableName:
					guard let spaceID = uuid("spaceID") else { continue }

					pinnedTabs.append(
						.init(
							id: id,
							spaceID: spaceID,
							folderID: uuid("folderID"),
							title: fields["title"] ?? "",
							url: fields["url"] ?? "about:blank",
							iconURL: fields["iconURL"],
							customTitle: fields["customTitle"],
							icon: fields["icon"],
							position: position
						)
					)

				case FavoriteRecord.tableName:
					guard let profileID = uuid("profileID") else { continue }

					favorites.append(
						.init(
							id: id,
							profileID: profileID,
							title: fields["title"] ?? "",
							url: fields["url"] ?? "about:blank",
							iconURL: fields["iconURL"],
							customTitle: fields["customTitle"],
							icon: fields["icon"],
							position: position
						)
					)

				default:
					continue
				}
			}
			self.init(profiles: profiles, spaces: spaces, folders: folders, pinnedTabs: pinnedTabs, favorites: favorites)
		}

		/// Every column of the five tables, as ``CloudAccess/zoneRecords`` asks for them.
		public static let fields: [String] = [
			"name", "searchEngine", "appearance", "tabArchiveInterval", "remoteSearchSuggestions", "showsFullURL",
			"keptLoadedSites", "darkPagesOffSites", "unreadBadges", "position", "isStarter", "profileID", "icon", "spaceID",
			"parentFolderID", "folderID", "title", "url", "iconURL", "customTitle",
		]

		/// These profiles and everything in them.
		internal func only(profiles ids: Set<UUID>) -> Self {
			let spaces: [SpaceRecord] = spaces.filter { ids.contains($0.profileID) }
			let spaceIDs: Set<UUID> = Set(spaces.map(\.id))
			return .init(
				profiles: profiles.filter { ids.contains($0.id) },
				spaces: spaces,
				folders: folders.filter { spaceIDs.contains($0.spaceID) },
				pinnedTabs: pinnedTabs.filter { spaceIDs.contains($0.spaceID) },
				favorites: favorites.filter { ids.contains($0.profileID) }
			)
		}
	}

	// MARK: - Keys

	/// A profile's or space's name as matching compares it: case and spaces ignored.
	public static func nameKey(_ name: String) -> String {
		name
			.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
			.filter { !$0.isWhitespace }
	}

	/// An address as matching compares it: the scheme and host lowercased, a trailing slash and the
	/// fragment ignored. Text that isn't a URL is compared as it is, trimmed.
	public static func addressKey(_ address: String) -> String {
		let trimmed: String = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			var components = URLComponents(string: trimmed),
			let scheme = components.scheme
		else { return trimmed }

		components.scheme = scheme.lowercased()
		if let host = components.percentEncodedHost {
			components.percentEncodedHost = host.lowercased()
		}
		components.percentEncodedFragment = nil
		if components.percentEncodedPath.hasSuffix("/") {
			components.percentEncodedPath.removeLast()
		}
		return components.string ?? trimmed
	}

	// MARK: - Plan

	/// What a merge does, as the preview lists it. Each match can be kept separate instead, by its
	/// ``ProfileMatch/mergedID`` or ``SpaceMatch/mergedID``.
	public struct Plan: Equatable, Sendable {
		/// "Will merge": this Mac's profiles (or, from Settings, the merged profiles) and the one each
		/// merges into.
		public var profiles: [ProfileMatch]

		/// "Will be added": this Mac's profiles iCloud has none like.
		public var addedProfiles: [Addition]

		public init(
			profiles: [ProfileMatch] = [],
			addedProfiles: [Addition] = []
		) {
			self.profiles = profiles
			self.addedProfiles = addedProfiles
		}

		/// Nothing to merge or add.
		public var isEmpty: Bool {
			profiles.isEmpty && addedProfiles.isEmpty
		}

		/// Whether the person sees it first. A merge of copies that adds nothing and changes nothing,
		/// such as an untouched starter profile into iCloud's, needs no preview.
		public var needsReview: Bool {
			guard addedProfiles.isEmpty else { return true }

			return profiles.contains { profile in
				!profile.addedSpaces.isEmpty
					|| !profile.settings.isEmpty
					|| profile.favorites.new > 0
					|| profile.spaces.contains { space in
						space.reason == .pins
							|| !space.settings.isEmpty
							|| space.pins.new > 0
							|| space.folders.new > 0
					}
			}
		}

		/// Every match that can be kept separate.
		public var mergeIDs: Set<UUID> {
			Set(profiles.flatMap { [$0.mergedID] + $0.spaces.map(\.mergedID) })
		}
	}

	public struct ProfileMatch: Equatable, Identifiable, Sendable {
		public var id: UUID { mergedID }

		/// This Mac's profile, or the one merged away.
		public var mergedID: UUID

		/// iCloud's, or the one kept.
		public var keptID: UUID

		/// The kept profile's name, which the merged one takes.
		public var name: String
		public var mergedName: String

		/// The merged profile's name when it's kept separate: its own, or with the Mac's name after it
		/// when that's taken.
		public var separateName: String
		public var spaces: [SpaceMatch]

		/// This Mac's spaces of it that iCloud has none like, added to the kept profile.
		public var addedSpaces: [Addition]
		public var favorites: Count

		/// What iCloud's settings change here.
		public var settings: [SettingChange]

		public init(
			mergedID: UUID,
			keptID: UUID,
			name: String,
			mergedName: String,
			separateName: String,
			spaces: [SpaceMatch] = [],
			addedSpaces: [Addition] = [],
			favorites: Count = .init(),
			settings: [SettingChange] = []
		) {
			self.mergedID = mergedID
			self.keptID = keptID
			self.name = name
			self.mergedName = mergedName
			self.separateName = separateName
			self.spaces = spaces
			self.addedSpaces = addedSpaces
			self.favorites = favorites
			self.settings = settings
		}
	}

	public struct SpaceMatch: Equatable, Identifiable, Sendable {
		/// Why two spaces match.
		public enum Reason: String, Equatable, Sendable {
			/// Both are the space each install starts with.
			case starter
			case name

			/// Most of their pinned tabs are the same.
			case pins
		}

		public var id: UUID { mergedID }

		public var mergedID: UUID
		public var keptID: UUID
		public var name: String
		public var mergedName: String

		/// Its name when it's kept separate, in the kept profile.
		public var separateName: String
		public var reason: Reason
		public var pins: Count
		public var folders: Count
		public var settings: [SettingChange]

		public init(
			mergedID: UUID,
			keptID: UUID,
			name: String,
			mergedName: String,
			separateName: String,
			reason: Reason,
			pins: Count = .init(),
			folders: Count = .init(),
			settings: [SettingChange] = []
		) {
			self.mergedID = mergedID
			self.keptID = keptID
			self.name = name
			self.mergedName = mergedName
			self.separateName = separateName
			self.reason = reason
			self.pins = pins
			self.folders = folders
			self.settings = settings
		}
	}

	/// A profile or space added as it is, renamed when its name is taken.
	public struct Addition: Equatable, Identifiable, Sendable {
		public var id: UUID
		public var name: String

		/// The name it gets, with the Mac's name after it, when the one it has is taken.
		public var newName: String?

		public init(
			id: UUID,
			name: String,
			newName: String? = nil
		) {
			self.id = id
			self.name = name
			self.newName = newName
		}
	}

	/// Items once merged: how many there are, and how many of them only the merged side had.
	public struct Count: Equatable, Sendable {
		public var total: Int
		public var new: Int

		public init(
			total: Int = 0,
			new: Int = 0
		) {
			self.total = total
			self.new = new
		}
	}

	/// A setting the merged item takes from the kept one.
	public struct SettingChange: Equatable, Sendable {
		public enum Setting: String, Equatable, Sendable {
			case name
			case icon

			/// A space's colors.
			case colors
			case searchEngine

			/// A profile's appearance.
			case appearance
			case tabArchive
			case searchSuggestions
			case fullURL
			case keptLoadedSites
			case darkPagesOffSites

			/// A profile's unread badges (DEV-1258).
			case unreadBadges

			/// A pin's or Favorite's own title, which the person gave it.
			case title
		}

		/// The kept item's name.
		public var itemName: String
		public var setting: Setting

		/// The merged side's value, when it's readable text.
		public var from: String?

		/// The kept side's value, when it's readable text.
		public var to: String?

		public init(
			itemName: String,
			setting: Setting,
			from: String? = nil,
			to: String? = nil
		) {
			self.itemName = itemName
			self.setting = setting
			self.from = from
			self.to = to
		}
	}

	// MARK: - Matching

	/// Where a moved item goes: its profile or space, its folder, and its key there.
	public struct Placement: Equatable, Sendable {
		public var parentID: UUID
		public var folderID: UUID?
		public var position: String

		public init(
			parentID: UUID,
			folderID: UUID? = nil,
			position: String
		) {
			self.parentID = parentID
			self.folderID = folderID
			self.position = position
		}
	}

	/// The merge in full: which item merges into which, and where everything else goes.
	public struct Matching: Equatable, Sendable {
		/// Merged → kept, by table.
		public var profiles: [UUID: UUID] = [:]
		public var spaces: [UUID: UUID] = [:]
		public var folders: [UUID: UUID] = [:]
		public var pinnedTabs: [UUID: UUID] = [:]
		public var favorites: [UUID: UUID] = [:]

		/// The merged side's items that move, with where they go: a space or Favorite into a profile,
		/// a folder or pin into a space and folder.
		public var spaceMoves: [UUID: Placement] = [:]
		public var folderMoves: [UUID: Placement] = [:]
		public var pinMoves: [UUID: Placement] = [:]
		public var favoriteMoves: [UUID: Placement] = [:]
		public var profilePositions: [UUID: String] = [:]

		/// Profiles and spaces whose name is taken.
		public var profileNames: [UUID: String] = [:]
		public var spaceNames: [UUID: String] = [:]

		/// The preview.
		public var plan: Plan = .init()

		public init() {}

		/// Every merged item, with its table and the item it merges into.
		public var pairs: [(table: String, merged: UUID, kept: UUID)] {
			let tables: [(String, [UUID: UUID])] = [
				(ProfileRecord.tableName, profiles),
				(SpaceRecord.tableName, spaces),
				(FolderRecord.tableName, folders),
				(PinnedTabRecord.tableName, pinnedTabs),
				(FavoriteRecord.tableName, favorites),
			]
			return tables.flatMap { table, map in
				map.sorted { $0.key.uuidString < $1.key.uuidString }.map { (table, $0.key, $0.value) }
			}
		}
	}

	/// Matches `local` (this Mac's rows, or the profiles merged away) against `cloud` (iCloud's, or
	/// the profile kept).
	///
	/// - Parameters:
	///   - macName: added after a name that's taken, as "Work (MacBook Air)".
	///   - keepingSeparate: matches the person kept separate, by the merged side's profile or space ID.
	///   - forcedProfiles: merged → kept profiles to merge whatever their names, from Settings; `nil`
	///     matches profiles by name.
	public static func match(
		local: Snapshot,
		cloud: Snapshot,
		macName: String,
		keepingSeparate: Set<UUID> = [],
		forcedProfiles: [UUID: UUID]? = nil
	) -> Matching {
		var matching: Matching = .init()

		// What's in both is one item already, synced before.
		let cloudIDs: Set<UUID> = Set(
			cloud.profiles.map(\.id) + cloud.spaces.map(\.id) + cloud.folders.map(\.id)
				+ cloud.pinnedTabs.map(\.id) + cloud.favorites.map(\.id)
		)
		let local: Snapshot = forcedProfiles == nil
		? .init(
			profiles: local.profiles.filter { !cloudIDs.contains($0.id) },
			spaces: local.spaces.filter { !cloudIDs.contains($0.id) },
			folders: local.folders.filter { !cloudIDs.contains($0.id) },
			pinnedTabs: local.pinnedTabs.filter { !cloudIDs.contains($0.id) },
			favorites: local.favorites.filter { !cloudIDs.contains($0.id) }
		)
		: local

		let localProfiles: [ProfileRecord] = local.profiles.sorted(by: ordered)
		let cloudProfiles: [ProfileRecord] = cloud.profiles.sorted(by: ordered)

		// Profiles: by name, the pair whose spaces overlap most first.
		var profilePairs: [(merged: ProfileRecord, kept: ProfileRecord)] = []
		if let forcedProfiles {
			for profile in localProfiles {
				guard
					let keptID = forcedProfiles[profile.id],
					let kept = cloudProfiles.first(where: { $0.id == keptID })
				else { continue }

				profilePairs.append((profile, kept))
			}
		} else {
			var candidates: [(merged: ProfileRecord, kept: ProfileRecord, score: Int)] = []
			for profile in localProfiles {
				for kept in cloudProfiles where nameKey(kept.name) == nameKey(profile.name) {
					candidates.append((profile, kept, overlap(profile.id, kept.id, local: local, cloud: cloud)))
				}
			}
			candidates.sort { lhs, rhs in
				if lhs.score != rhs.score { return lhs.score > rhs.score }
				if lhs.merged.id != rhs.merged.id { return ordered(lhs.merged, rhs.merged) }
				return ordered(lhs.kept, rhs.kept)
			}
			var mergedTaken: Set<UUID> = []
			var keptTaken: Set<UUID> = []
			for candidate in candidates
			where !mergedTaken.contains(candidate.merged.id) && !keptTaken.contains(candidate.kept.id) {
				mergedTaken.insert(candidate.merged.id)
				keptTaken.insert(candidate.kept.id)
				profilePairs.append((candidate.merged, candidate.kept))
			}
			profilePairs.sort { ordered($0.merged, $1.merged) }
		}

		var takenProfileNames: Set<String> = Set(cloudProfiles.map { nameKey($0.name) })
		var lastProfilePosition: String? = cloudProfiles.map(\.position).max()
		let pairedProfiles: Set<UUID> = Set(profilePairs.map(\.merged.id))

		for (merged, kept) in profilePairs {
			let separateName: String = uniqueName(merged.name, macName: macName, taken: takenProfileNames)
			guard !keepingSeparate.contains(merged.id) else { continue }

			matching.profiles[merged.id] = kept.id
			var profileMatch: ProfileMatch = .init(
				mergedID: merged.id,
				keptID: kept.id,
				name: kept.name,
				mergedName: merged.name,
				separateName: separateName,
				settings: settingChanges(merged, kept)
			)
			matchSpaces(
				of: merged,
				into: kept,
				local: local,
				cloud: cloud,
				macName: macName,
				keepingSeparate: keepingSeparate,
				profileMatch: &profileMatch,
				matching: &matching
			)
			profileMatch.favorites = matchFavorites(
				local.favorites.filter { $0.profileID == merged.id },
				cloud.favorites.filter { $0.profileID == kept.id },
				into: kept.id,
				matching: &matching,
				titles: &profileMatch.settings
			)
			matching.plan.profiles.append(profileMatch)
		}

		// This Mac's other profiles are added after iCloud's, in its order.
		for profile in localProfiles where !matching.profiles.keys.contains(profile.id) {
			// From Settings, only the profiles being merged take part.
			guard forcedProfiles == nil || pairedProfiles.contains(profile.id) else { continue }

			let name: String = uniqueName(profile.name, macName: macName, taken: takenProfileNames)
			takenProfileNames.insert(nameKey(name))
			let position: String = WorkspaceRepair.positionAfter(lastProfilePosition)
			lastProfilePosition = position
			matching.profilePositions[profile.id] = position
			if name != profile.name {
				matching.profileNames[profile.id] = name
			}
			matching.plan.addedProfiles.append(.init(id: profile.id, name: profile.name, newName: name == profile.name ? nil : name))
		}
		return matching
	}

	private static func matchSpaces(
		of merged: ProfileRecord,
		into kept: ProfileRecord,
		local: Snapshot,
		cloud: Snapshot,
		macName: String,
		keepingSeparate: Set<UUID>,
		profileMatch: inout ProfileMatch,
		matching: inout Matching
	) {
		let localSpaces: [SpaceRecord] = local.spaces.filter { $0.profileID == merged.id }.sorted(by: ordered)
		let cloudSpaces: [SpaceRecord] = cloud.spaces.filter { $0.profileID == kept.id }.sorted(by: ordered)
		var pairs: [(merged: SpaceRecord, kept: SpaceRecord, reason: SpaceMatch.Reason)] = []
		var keptTaken: Set<UUID> = []
		var mergedTaken: Set<UUID> = []

		func take(
			_ space: SpaceRecord,
			_ other: SpaceRecord,
			_ reason: SpaceMatch.Reason
		) {
			pairs.append((space, other, reason))
			mergedTaken.insert(space.id)
			keptTaken.insert(other.id)
		}

		// The starter space with the starter space.
		for space in localSpaces where space.isStarter {
			if let other = cloudSpaces.first(where: { $0.isStarter && !keptTaken.contains($0.id) }) {
				take(space, other, .starter)
			}
		}

		// Then by name.
		for space in localSpaces where !mergedTaken.contains(space.id) {
			if let other = cloudSpaces.first(where: { !keptTaken.contains($0.id) && nameKey($0.name) == nameKey(space.name) }) {
				take(space, other, .name)
			}
		}

		// Then by pinned tabs in common: most in common first.
		let addresses: (Snapshot, UUID) -> Set<String> = { snapshot, spaceID in
			Set(snapshot.pinnedTabs.filter { $0.spaceID == spaceID }.map { addressKey($0.url) })
		}
		var overlaps: [(merged: SpaceRecord, kept: SpaceRecord, common: Int)] = []
		for space in localSpaces where !mergedTaken.contains(space.id) {
			let mine: Set<String> = addresses(local, space.id)
			for other in cloudSpaces where !keptTaken.contains(other.id) {
				let theirs: Set<String> = addresses(cloud, other.id)
				let common: Int = mine.intersection(theirs).count
				if isStrongOverlap(common: common, mine.count, theirs.count) {
					overlaps.append((space, other, common))
				}
			}
		}
		overlaps.sort { lhs, rhs in
			if lhs.common != rhs.common { return lhs.common > rhs.common }
			if lhs.merged.id != rhs.merged.id { return ordered(lhs.merged, rhs.merged) }
			return ordered(lhs.kept, rhs.kept)
		}
		for overlap in overlaps where !mergedTaken.contains(overlap.merged.id) && !keptTaken.contains(overlap.kept.id) {
			take(overlap.merged, overlap.kept, .pins)
		}
		pairs.sort { ordered($0.merged, $1.merged) }

		var takenNames: Set<String> = Set(cloudSpaces.map { nameKey($0.name) })
		var lastPosition: String? = cloudSpaces.map(\.position).max()
		var separate: Set<UUID> = []
		for (space, other, reason) in pairs {
			let separateName: String = uniqueName(space.name, macName: macName, taken: takenNames)
			guard !keepingSeparate.contains(space.id) else {
				separate.insert(space.id)
				continue
			}

			matching.spaces[space.id] = other.id
			var titles: [SettingChange] = []
			let (pins, folders) = matchItems(of: space, into: other, local: local, cloud: cloud, matching: &matching, titles: &titles)
			profileMatch.spaces.append(
				.init(
					mergedID: space.id,
					keptID: other.id,
					name: other.name,
					mergedName: space.name,
					separateName: separateName,
					reason: reason,
					pins: pins,
					folders: folders,
					settings: settingChanges(space, other) + titles
				)
			)
		}

		// The rest of this Mac's spaces go after iCloud's, in this Mac's order.
		for space in localSpaces where matching.spaces[space.id] == nil {
			let name: String = uniqueName(space.name, macName: macName, taken: takenNames)
			takenNames.insert(nameKey(name))
			let position: String = WorkspaceRepair.positionAfter(lastPosition)
			lastPosition = position
			matching.spaceMoves[space.id] = .init(parentID: kept.id, position: position)
			if name != space.name {
				matching.spaceNames[space.id] = name
			}
			profileMatch.addedSpaces.append(.init(id: space.id, name: space.name, newName: name == space.name ? nil : name))
		}
	}

	/// Folders by path and pins by address within two matched spaces; the rest of this Mac's go after
	/// iCloud's in each folder, in this Mac's order.
	private static func matchItems(
		of merged: SpaceRecord,
		into kept: SpaceRecord,
		local: Snapshot,
		cloud: Snapshot,
		matching: inout Matching,
		titles: inout [SettingChange]
	) -> (pins: Count, folders: Count) {
		let localFolders: [FolderRecord] = local.folders.filter { $0.spaceID == merged.id }
		let cloudFolders: [FolderRecord] = cloud.folders.filter { $0.spaceID == kept.id }
		let localPins: [PinnedTabRecord] = local.pinnedTabs.filter { $0.spaceID == merged.id }
		let cloudPins: [PinnedTabRecord] = cloud.pinnedTabs.filter { $0.spaceID == kept.id }

		let localPaths: [UUID: [String]] = paths(localFolders)
		let cloudPaths: [UUID: [String]] = paths(cloudFolders)
		var keptFolders: Set<UUID> = []

		// Parents before children, so a folder's path is only matched once its parent's is.
		for folder in localFolders.sorted(by: { (localPaths[$0.id]?.count ?? 0, $0.position, $0.id.uuidString) < (localPaths[$1.id]?.count ?? 0, $1.position, $1.id.uuidString) }) {
			guard let path = localPaths[folder.id] else { continue }

			if let other = cloudFolders.sorted(by: ordered).first(where: { !keptFolders.contains($0.id) && cloudPaths[$0.id] == path }) {
				keptFolders.insert(other.id)
				matching.folders[folder.id] = other.id
			}
		}

		var keptPins: Set<UUID> = []
		for pin in localPins.sorted(by: ordered) {
			let address: String = addressKey(pin.url)
			if let other = cloudPins.sorted(by: ordered).first(where: { !keptPins.contains($0.id) && addressKey($0.url) == address }) {
				keptPins.insert(other.id)
				matching.pinnedTabs[pin.id] = other.id
				titles += titleChange(pin.customTitle, pin.title, other.customTitle, other.title)
			}
		}

		// Where each of this Mac's folders' contents go: a matched folder's into iCloud's.
		func target(_ folderID: UUID?) -> UUID? {
			folderID.map { matching.folders[$0] ?? $0 }
		}

		// The last key in each of iCloud's folders (nil: the root), and after it this Mac's.
		var lastKeys: [UUID?: String] = [:]
		for folder in cloudFolders {
			lastKeys[folder.parentFolderID] = max(lastKeys[folder.parentFolderID] ?? "", folder.position)
		}
		for pin in cloudPins {
			lastKeys[pin.folderID] = max(lastKeys[pin.folderID] ?? "", pin.position)
		}

		struct Item {
			var id: UUID
			var parentID: UUID?
			var position: String
			var isFolder: Bool
		}

		let movedFolders: [FolderRecord] = localFolders.filter { matching.folders[$0.id] == nil }
		let movedPins: [PinnedTabRecord] = localPins.filter { matching.pinnedTabs[$0.id] == nil }
		let items: [Item] = (
			movedFolders.map { Item(id: $0.id, parentID: $0.parentFolderID, position: $0.position, isFolder: true) }
			+ movedPins.map { Item(id: $0.id, parentID: $0.folderID, position: $0.position, isFolder: false) }
		)
		.sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }

		for item in items {
			let parent: UUID? = target(item.parentID)

			// In one of this Mac's own folders, which moves along, it keeps its place.
			let staysInOwnFolder: Bool = item.parentID.map { matching.folders[$0] == nil } ?? false
			let position: String
			if staysInOwnFolder {
				position = item.position
			} else {
				let key: String = WorkspaceRepair.positionAfter(lastKeys[parent].flatMap { $0.isEmpty ? nil : $0 })
				lastKeys[parent] = key
				position = key
			}
			if item.isFolder {
				matching.folderMoves[item.id] = .init(parentID: kept.id, folderID: parent, position: position)
			} else {
				matching.pinMoves[item.id] = .init(parentID: kept.id, folderID: parent, position: position)
			}
		}

		return (
			Count(total: cloudPins.count + movedPins.count, new: movedPins.count),
			Count(total: cloudFolders.count + movedFolders.count, new: movedFolders.count)
		)
	}

	private static func matchFavorites(
		_ local: [FavoriteRecord],
		_ cloud: [FavoriteRecord],
		into profileID: UUID,
		matching: inout Matching,
		titles: inout [SettingChange]
	) -> Count {
		var kept: Set<UUID> = []
		var lastPosition: String? = cloud.map(\.position).max()
		var added: Int = 0
		let cloudOrdered: [FavoriteRecord] = cloud.sorted(by: ordered)
		for favorite in local.sorted(by: ordered) {
			let address: String = addressKey(favorite.url)
			if let other = cloudOrdered.first(where: { !kept.contains($0.id) && addressKey($0.url) == address }) {
				kept.insert(other.id)
				matching.favorites[favorite.id] = other.id
				titles += titleChange(favorite.customTitle, favorite.title, other.customTitle, other.title)
			} else {
				let position: String = WorkspaceRepair.positionAfter(lastPosition)
				lastPosition = position
				matching.favoriteMoves[favorite.id] = .init(parentID: profileID, position: position)
				added += 1
			}
		}
		return .init(total: cloud.count + added, new: added)
	}

	/// Each folder's path of names from its space's root, as matching compares them. A folder in a
	/// cycle has none.
	private static func paths(_ folders: [FolderRecord]) -> [UUID: [String]] {
		let byID: [UUID: FolderRecord] = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		var result: [UUID: [String]] = [:]
		for folder in folders {
			var path: [String] = []
			var current: FolderRecord? = folder
			var visited: Set<UUID> = []
			var isValid: Bool = true
			while let node = current {
				guard visited.insert(node.id).inserted else {
					isValid = false
					break
				}

				path.insert(nameKey(node.name), at: 0)
				current = node.parentFolderID.flatMap { byID[$0] }
			}
			if isValid {
				result[folder.id] = path
			}
		}
		return result
	}

	/// How much two profiles' spaces have in common: matching names first, then pinned tabs.
	private static func overlap(
		_ merged: UUID,
		_ kept: UUID,
		local: Snapshot,
		cloud: Snapshot
	) -> Int {
		let localSpaces: [SpaceRecord] = local.spaces.filter { $0.profileID == merged }
		let cloudSpaces: [SpaceRecord] = cloud.spaces.filter { $0.profileID == kept }
		let names: Int = Set(localSpaces.map { nameKey($0.name) }).intersection(cloudSpaces.map { nameKey($0.name) }).count
		let localSpaceIDs: Set<UUID> = Set(localSpaces.map(\.id))
		let cloudSpaceIDs: Set<UUID> = Set(cloudSpaces.map(\.id))
		let pins: Int = Set(local.pinnedTabs.filter { localSpaceIDs.contains($0.spaceID) }.map { addressKey($0.url) })
			.intersection(cloud.pinnedTabs.filter { cloudSpaceIDs.contains($0.spaceID) }.map { addressKey($0.url) })
			.count
		return names * 1_000 + pins
	}

	/// Two spaces' pins overlap strongly: at least two in common, and more than half of the smaller
	/// space's.
	public static func isStrongOverlap(
		common: Int,
		_ count: Int,
		_ otherCount: Int
	) -> Bool {
		common >= 2 && common * 2 > min(count, otherCount)
	}

	/// `name`, or with the Mac's name after it when that's taken: "Work (MacBook Air)", then
	/// "Work (MacBook Air 2)"…
	public static func uniqueName(
		_ name: String,
		macName: String,
		taken: Set<String>
	) -> String {
		guard taken.contains(nameKey(name)) else { return name }

		let base: String = "\(name) (\(macName))"
		if !taken.contains(nameKey(base)) { return base }

		var number: Int = 2
		while taken.contains(nameKey("\(name) (\(macName) \(number))")) {
			number += 1
		}
		return "\(name) (\(macName) \(number))"
	}

	/// A matched pin or Favorite takes iCloud's title: listed when the person named either one.
	private static func titleChange(
		_ customTitle: String?,
		_ title: String,
		_ otherCustomTitle: String?,
		_ otherTitle: String
	) -> [SettingChange] {
		guard customTitle != otherCustomTitle, customTitle != nil || otherCustomTitle != nil else { return [] }

		let from: String = customTitle ?? title
		let to: String = otherCustomTitle ?? otherTitle
		guard from != to else { return [] }

		return [.init(itemName: to, setting: .title, from: from, to: to)]
	}

	private static func settingChanges(
		_ merged: ProfileRecord,
		_ kept: ProfileRecord
	) -> [SettingChange] {
		var changes: [SettingChange] = []
		if merged.name != kept.name {
			changes.append(.init(itemName: kept.name, setting: .name, from: merged.name, to: kept.name))
		}
		if merged.searchEngine != kept.searchEngine {
			changes.append(.init(itemName: kept.name, setting: .searchEngine, from: merged.searchEngine, to: kept.searchEngine))
		}
		let others: [(SettingChange.Setting, Bool)] = [
			(.appearance, merged.appearance != kept.appearance),
			(.tabArchive, merged.tabArchiveInterval != kept.tabArchiveInterval),
			(.searchSuggestions, merged.remoteSearchSuggestions != kept.remoteSearchSuggestions),
			(.fullURL, merged.showsFullURL != kept.showsFullURL),
			(.keptLoadedSites, merged.keptLoadedSites != kept.keptLoadedSites),
			(.darkPagesOffSites, merged.darkPagesOffSites != kept.darkPagesOffSites),
			(.unreadBadges, merged.unreadBadges != kept.unreadBadges),
		]
		for (setting, differs) in others where differs {
			changes.append(.init(itemName: kept.name, setting: setting))
		}
		return changes
	}

	private static func settingChanges(
		_ merged: SpaceRecord,
		_ kept: SpaceRecord
	) -> [SettingChange] {
		var changes: [SettingChange] = []
		if merged.name != kept.name {
			changes.append(.init(itemName: kept.name, setting: .name, from: merged.name, to: kept.name))
		}
		if merged.icon != kept.icon {
			changes.append(.init(itemName: kept.name, setting: .icon, from: merged.icon, to: kept.icon))
		}
		if merged.appearance != kept.appearance {
			changes.append(.init(itemName: kept.name, setting: .colors))
		}
		return changes
	}

	internal static func ordered(_ lhs: ProfileRecord, _ rhs: ProfileRecord) -> Bool {
		(lhs.position, lhs.id.uuidString) < (rhs.position, rhs.id.uuidString)
	}

	internal static func ordered(_ lhs: SpaceRecord, _ rhs: SpaceRecord) -> Bool {
		(lhs.position, lhs.id.uuidString) < (rhs.position, rhs.id.uuidString)
	}

	internal static func ordered(_ lhs: FolderRecord, _ rhs: FolderRecord) -> Bool {
		(lhs.position, lhs.id.uuidString) < (rhs.position, rhs.id.uuidString)
	}

	internal static func ordered(_ lhs: PinnedTabRecord, _ rhs: PinnedTabRecord) -> Bool {
		(lhs.position, lhs.id.uuidString) < (rhs.position, rhs.id.uuidString)
	}

	internal static func ordered(_ lhs: FavoriteRecord, _ rhs: FavoriteRecord) -> Bool {
		(lhs.position, lhs.id.uuidString) < (rhs.position, rhs.id.uuidString)
	}
}
