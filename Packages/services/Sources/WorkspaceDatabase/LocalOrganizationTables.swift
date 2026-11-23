import Foundation
import _SQLiteData

// MARK: - "This Mac only" profiles (DEV-981)

// The organization tables of `arx-organization-local.sqlite`, attached to the organization connection
// as `local`: the same schema, never synced. A "this Mac only" profile's rows live here, with the
// space, folder and open-tab state that refers to them. Each twin converts to and from its synced
// table's record, so the diff writer and the reader work in one row type.

@Table("profile", schema: "local")
public struct LocalProfileRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("name")
	public var name: String

	@Column("searchEngine")
	public var searchEngine: String?

	@Column("appearance")
	public var appearance: String?

	@Column("tabArchiveInterval")
	public var tabArchiveInterval: String?

	@Column("remoteSearchSuggestions")
	public var remoteSearchSuggestions: Bool?

	@Column("showsFullURL")
	public var showsFullURL: Bool?

	@Column("keptLoadedSites")
	public var keptLoadedSites: String?

	/// DEV-1258; the local file gains the column with the same migration as the synced one.
	@Column("unreadBadges")
	public var unreadBadges: String?

	@Column("position")
	public var position: String

	@Column("isStarter")
	public var isStarter: Bool

	public init(
		id: UUID,
		name: String,
		searchEngine: String? = nil,
		appearance: String? = nil,
		tabArchiveInterval: String? = nil,
		remoteSearchSuggestions: Bool? = nil,
		showsFullURL: Bool? = nil,
		keptLoadedSites: String? = nil,
		unreadBadges: String? = nil,
		position: String,
		isStarter: Bool = false
	) {
		self.id = id
		self.name = name
		self.searchEngine = searchEngine
		self.appearance = appearance
		self.tabArchiveInterval = tabArchiveInterval
		self.remoteSearchSuggestions = remoteSearchSuggestions
		self.showsFullURL = showsFullURL
		self.keptLoadedSites = keptLoadedSites
		self.unreadBadges = unreadBadges
		self.position = position
		self.isStarter = isStarter
	}
}

extension LocalProfileRecord {
	public init(_ record: ProfileRecord) {
		self.init(id: record.id, name: record.name, searchEngine: record.searchEngine, appearance: record.appearance, tabArchiveInterval: record.tabArchiveInterval, remoteSearchSuggestions: record.remoteSearchSuggestions, showsFullURL: record.showsFullURL, keptLoadedSites: record.keptLoadedSites, unreadBadges: record.unreadBadges, position: record.position, isStarter: record.isStarter)
	}

	public var record: ProfileRecord {
		.init(id: id, name: name, searchEngine: searchEngine, appearance: appearance, tabArchiveInterval: tabArchiveInterval, remoteSearchSuggestions: remoteSearchSuggestions, showsFullURL: showsFullURL, keptLoadedSites: keptLoadedSites, unreadBadges: unreadBadges, position: position, isStarter: isStarter)
	}
}

@Table("space", schema: "local")
public struct LocalSpaceRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("profileID")
	public var profileID: UUID

	@Column("name")
	public var name: String

	@Column("icon")
	public var icon: String?

	@Column("appearance")
	public var appearance: String?

	@Column("position")
	public var position: String

	@Column("isStarter")
	public var isStarter: Bool

	public init(
		id: UUID,
		profileID: UUID,
		name: String,
		icon: String? = nil,
		appearance: String? = nil,
		position: String,
		isStarter: Bool = false
	) {
		self.id = id
		self.profileID = profileID
		self.name = name
		self.icon = icon
		self.appearance = appearance
		self.position = position
		self.isStarter = isStarter
	}
}

extension LocalSpaceRecord {
	public init(_ record: SpaceRecord) {
		self.init(id: record.id, profileID: record.profileID, name: record.name, icon: record.icon, appearance: record.appearance, position: record.position, isStarter: record.isStarter)
	}

	public var record: SpaceRecord {
		.init(id: id, profileID: profileID, name: name, icon: icon, appearance: appearance, position: position, isStarter: isStarter)
	}
}

@Table("folder", schema: "local")
public struct LocalFolderRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("spaceID")
	public var spaceID: UUID

	@Column("parentFolderID")
	public var parentFolderID: UUID?

	@Column("name")
	public var name: String

	@Column("position")
	public var position: String

	public init(
		id: UUID,
		spaceID: UUID,
		parentFolderID: UUID? = nil,
		name: String,
		position: String
	) {
		self.id = id
		self.spaceID = spaceID
		self.parentFolderID = parentFolderID
		self.name = name
		self.position = position
	}
}

extension LocalFolderRecord {
	public init(_ record: FolderRecord) {
		self.init(id: record.id, spaceID: record.spaceID, parentFolderID: record.parentFolderID, name: record.name, position: record.position)
	}

	public var record: FolderRecord {
		.init(id: id, spaceID: spaceID, parentFolderID: parentFolderID, name: name, position: position)
	}
}

@Table("pinnedTab", schema: "local")
public struct LocalPinnedTabRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("spaceID")
	public var spaceID: UUID

	@Column("folderID")
	public var folderID: UUID?

	@Column("title")
	public var title: String

	@Column("url")
	public var url: String

	@Column("iconURL")
	public var iconURL: String?

	@Column("customTitle")
	public var customTitle: String?

	/// The icon chosen for the tab (DEV-1251), a `SpaceIcon` as JSON like ``SpaceRecord/icon``.
	@Column("icon")
	public var icon: String?

	@Column("position")
	public var position: String

	public init(
		id: UUID,
		spaceID: UUID,
		folderID: UUID? = nil,
		title: String,
		url: String,
		iconURL: String? = nil,
		customTitle: String? = nil,
		icon: String? = nil,
		position: String
	) {
		self.id = id
		self.spaceID = spaceID
		self.folderID = folderID
		self.title = title
		self.url = url
		self.iconURL = iconURL
		self.customTitle = customTitle
		self.icon = icon
		self.position = position
	}
}

extension LocalPinnedTabRecord {
	public init(_ record: PinnedTabRecord) {
		self.init(id: record.id, spaceID: record.spaceID, folderID: record.folderID, title: record.title, url: record.url, iconURL: record.iconURL, customTitle: record.customTitle, icon: record.icon, position: record.position)
	}

	public var record: PinnedTabRecord {
		.init(id: id, spaceID: spaceID, folderID: folderID, title: title, url: url, iconURL: iconURL, customTitle: customTitle, icon: icon, position: position)
	}
}

@Table("favorite", schema: "local")
public struct LocalFavoriteRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("profileID")
	public var profileID: UUID

	@Column("title")
	public var title: String

	@Column("url")
	public var url: String

	@Column("iconURL")
	public var iconURL: String?

	@Column("customTitle")
	public var customTitle: String?

	/// The icon chosen for the tab (DEV-1251), a `SpaceIcon` as JSON like ``SpaceRecord/icon``.
	@Column("icon")
	public var icon: String?

	@Column("position")
	public var position: String

	public init(
		id: UUID,
		profileID: UUID,
		title: String,
		url: String,
		iconURL: String? = nil,
		customTitle: String? = nil,
		icon: String? = nil,
		position: String
	) {
		self.id = id
		self.profileID = profileID
		self.title = title
		self.url = url
		self.iconURL = iconURL
		self.customTitle = customTitle
		self.icon = icon
		self.position = position
	}
}

extension LocalFavoriteRecord {
	public init(_ record: FavoriteRecord) {
		self.init(id: record.id, profileID: record.profileID, title: record.title, url: record.url, iconURL: record.iconURL, customTitle: record.customTitle, icon: record.icon, position: record.position)
	}

	public var record: FavoriteRecord {
		.init(id: id, profileID: profileID, title: title, url: url, iconURL: iconURL, customTitle: customTitle, icon: icon, position: position)
	}
}

@Table("spaceState", schema: "local")
public struct LocalSpaceStateRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("selectedTabID")
	public var selectedTabID: UUID?

	public init(
		id: UUID,
		selectedTabID: UUID?
	) {
		self.id = id
		self.selectedTabID = selectedTabID
	}
}

extension LocalSpaceStateRecord {
	public init(_ record: SpaceStateRecord) {
		self.init(id: record.id, selectedTabID: record.selectedTabID)
	}

	public var record: SpaceStateRecord {
		.init(id: id, selectedTabID: selectedTabID)
	}
}

@Table("folderState", schema: "local")
public struct LocalFolderStateRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("isExpanded")
	public var isExpanded: Bool

	@Column("ordinal")
	public var ordinal: String

	public init(
		id: UUID,
		isExpanded: Bool,
		ordinal: String
	) {
		self.id = id
		self.isExpanded = isExpanded
		self.ordinal = ordinal
	}
}

extension LocalFolderStateRecord {
	public init(_ record: FolderStateRecord) {
		self.init(id: record.id, isExpanded: record.isExpanded, ordinal: record.ordinal)
	}

	public var record: FolderStateRecord {
		.init(id: id, isExpanded: isExpanded, ordinal: ordinal)
	}
}

@Table("regularTab", schema: "local")
public struct LocalRegularTabRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("spaceID")
	public var spaceID: UUID

	@Column("customTitle")
	public var customTitle: String?

	/// The icon chosen for the tab (DEV-1251), a `SpaceIcon` as JSON like ``SpaceRecord/icon``.
	@Column("icon")
	public var icon: String?

	@Column("position")
	public var position: String

	public init(
		id: UUID,
		spaceID: UUID,
		customTitle: String? = nil,
		icon: String? = nil,
		position: String
	) {
		self.id = id
		self.spaceID = spaceID
		self.customTitle = customTitle
		self.icon = icon
		self.position = position
	}
}

extension LocalRegularTabRecord {
	public init(_ record: RegularTabRecord) {
		self.init(id: record.id, spaceID: record.spaceID, customTitle: record.customTitle, icon: record.icon, position: record.position)
	}

	public var record: RegularTabRecord {
		.init(id: id, spaceID: spaceID, customTitle: customTitle, icon: icon, position: position)
	}
}

@Table("archivedTab", schema: "local")
public struct LocalArchivedTabRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("value")
	public var value: String

	@Column("position")
	public var position: String

	public init(
		id: UUID,
		value: String,
		position: String
	) {
		self.id = id
		self.value = value
		self.position = position
	}
}

extension LocalArchivedTabRecord {
	public init(_ record: ArchivedTabRecord) {
		self.init(id: record.id, value: record.value, position: record.position)
	}

	public var record: ArchivedTabRecord {
		.init(id: id, value: value, position: position)
	}
}

@Table("storeInfo", schema: "local")
public struct LocalStoreInfoRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: String

	@Column("value")
	public var value: String

	public init(
		id: String,
		value: String
	) {
		self.id = id
		self.value = value
	}
}

extension LocalStoreInfoRecord {
	public init(_ record: StoreInfoRecord) {
		self.init(id: record.id, value: record.value)
	}

	public var record: StoreInfoRecord {
		.init(id: id, value: value)
	}
}

/// Keys of the local file's own `storeInfo` (DEV-981).
public enum LocalStoreInfoKey {
	/// The synced rows a profile had when it was turned "this Mac only", by table: those it no longer
	/// has when it's turned back on were deleted here meanwhile.
	public static func baseline(_ profileID: UUID) -> String {
		"\(baselinePrefix)\(profileID.uuidString.lowercased())"
	}

	public static let baselinePrefix: String = "baseline."
}
