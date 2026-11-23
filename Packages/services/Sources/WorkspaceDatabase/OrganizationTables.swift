import Foundation
import _SQLiteData

// The organization database: the Profiles and spaces sync category of ADR 0001.
//
// The first five tables are the synced records (ADR 0001, section 4). Phase 2 hands exactly these to
// this category's `SyncEngine`, so they follow its rules: a UUID primary key, at most one foreign key,
// no other unique index, no CloudKit reserved column names, and every column either nullable or
// `NOT NULL ON CONFLICT REPLACE` with a default. Columns are never renamed or dropped once shipped.
//
// The rest are device-local: they live in the same file so one transaction covers both, and they are
// never passed to a `SyncEngine`.

// MARK: - Synced

/// A profile's identity and portable settings. Its Chromium data never syncs.
@Table("profile")
public struct ProfileRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("name")
	public var name: String

	/// `SearchEngine` as JSON, or `nil` for the default.
	@Column("searchEngine")
	public var searchEngine: String?

	/// `AppearanceOverride` as JSON.
	@Column("appearance")
	public var appearance: String?

	/// `TabArchiveInterval`'s raw value.
	@Column("tabArchiveInterval")
	public var tabArchiveInterval: String?

	@Column("remoteSearchSuggestions")
	public var remoteSearchSuggestions: Bool?

	@Column("showsFullURL")
	public var showsFullURL: Bool?

	/// The sorted `[String]` of kept-loaded sites as JSON (DEV-932).
	@Column("keptLoadedSites")
	public var keptLoadedSites: String?

	/// The sorted `[String]` of sites dark pages stay off on, as JSON (DEV-1020). A column added
	/// after the first schema, so nullable, as synced columns must be.
	@Column("darkPagesOffSites")
	public var darkPagesOffSites: String?

	/// `UnreadBadgeVisibility`'s raw value, or nil to follow the browser default (DEV-1258). A
	/// column added after the first schema, so nullable, as synced columns must be.
	@Column("unreadBadges")
	public var unreadBadges: String?

	/// A ``FractionalIndex`` key among every profile.
	@Column("position")
	public var position: String

	/// Marks the profile Arx made on first launch, for phase 2's first merge. Nothing sets it yet.
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
		darkPagesOffSites: String? = nil,
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
		self.darkPagesOffSites = darkPagesOffSites
		self.unreadBadges = unreadBadges
		self.position = position
		self.isStarter = isStarter
	}
}

@Table("space")
public struct SpaceRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	/// The one foreign key: deleting the profile deletes its spaces.
	@Column("profileID")
	public var profileID: UUID

	@Column("name")
	public var name: String

	/// `SpaceIcon` as JSON.
	@Column("icon")
	public var icon: String?

	/// `AppearanceOverride` as JSON.
	@Column("appearance")
	public var appearance: String?

	/// A ``FractionalIndex`` key among every space, whatever its profile.
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

@Table("folder")
public struct FolderRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	/// The one foreign key.
	@Column("spaceID")
	public var spaceID: UUID

	/// The folder holding this one, or `nil` at the space root. A plain column, kept valid by phase 2's
	/// repair pass, so the table keeps a single foreign key.
	@Column("parentFolderID")
	public var parentFolderID: UUID?

	@Column("name")
	public var name: String

	/// A ``FractionalIndex`` key among its parent's children, shared with ``PinnedTabRecord``.
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

/// A tab pinned to a space: its saved destination only. Its current page is ``TabStateRecord``.
@Table("pinnedTab")
public struct PinnedTabRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	/// The one foreign key.
	@Column("spaceID")
	public var spaceID: UUID

	/// A plain column, like ``FolderRecord/parentFolderID``.
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

	/// A ``FractionalIndex`` key among its parent's children, shared with ``FolderRecord``.
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

/// A favorite (profile tab): a tab pinned to a profile.
@Table("favorite")
public struct FavoriteRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	/// The one foreign key.
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

	/// A ``FractionalIndex`` key among the profile's favorites.
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

// MARK: - Device-local

/// Facts about this store: where it came from and its write revision. Keys are ``StoreInfoKey``.
@Table("storeInfo")
public struct StoreInfoRecord: Equatable, Identifiable, Sendable {
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

/// Profiles removed on this Mac whose storage identity must never come back.
@Table("retiredProfile")
public struct RetiredProfileRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	public init(id: UUID) {
		self.id = id
	}
}

/// A space's selected tab on this Mac. Only spaces with a selection have a row.
@Table("spaceState")
public struct SpaceStateRecord: Equatable, Identifiable, Sendable {
	/// The space's ID.
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

/// A folder's expansion on this Mac, and its place in `BrowserOrganization.folders`.
@Table("folderState")
public struct FolderStateRecord: Equatable, Identifiable, Sendable {
	/// The folder's ID.
	@Column(primaryKey: true)
	public let id: UUID

	@Column("isExpanded")
	public var isExpanded: Bool

	/// A ``FractionalIndex`` key in `BrowserOrganization.folders`, which isn't the sidebar's order.
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

/// Every tab's per-Mac state, whatever its location: the page it last showed and its automation client.
/// Its profile is its location's.
@Table("tabState")
public struct TabStateRecord: Equatable, Identifiable, Sendable {
	/// The tab's ID.
	@Column(primaryKey: true)
	public let id: UUID

	@Column("restorationTitle")
	public var restorationTitle: String

	@Column("restorationURL")
	public var restorationURL: String

	@Column("automationClientID")
	public var automationClientID: UUID?

	/// A ``FractionalIndex`` key in `BrowserOrganization.tabs`.
	@Column("ordinal")
	public var ordinal: String

	public init(
		id: UUID,
		restorationTitle: String,
		restorationURL: String,
		automationClientID: UUID? = nil,
		ordinal: String
	) {
		self.id = id
		self.restorationTitle = restorationTitle
		self.restorationURL = restorationURL
		self.automationClientID = automationClientID
		self.ordinal = ordinal
	}
}

/// A regular tab: a space's open, unpinned tab. Tabs from other devices are a separate category.
@Table("regularTab")
public struct RegularTabRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("spaceID")
	public var spaceID: UUID

	@Column("customTitle")
	public var customTitle: String?

	/// The icon chosen for the tab (DEV-1251), a `SpaceIcon` as JSON like ``SpaceRecord/icon``.
	@Column("icon")
	public var icon: String?

	/// A ``FractionalIndex`` key among the space's regular tabs.
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

/// One Tab Archive entry as JSON. Tab Archive never syncs.
@Table("archivedTab")
public struct ArchivedTabRecord: Equatable, Identifiable, Sendable {
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

/// One Split View group as JSON.
@Table("splitGroup")
public struct SplitGroupRecord: Equatable, Identifiable, Sendable {
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

/// One group of open tabs as JSON (DEV-911).
@Table("tabGroup")
public struct TabGroupRecord: Equatable, Identifiable, Sendable {
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

/// The ``StoreInfoRecord`` keys.
public enum StoreInfoKey {
	/// A save's change to Tab Archive not yet applied to the archive file (`PendingArchiveChange`, DEV-983).
	public static let pendingArchive: String = "pendingArchive"

	/// The ID shared with the archive file's ``ArchiveStateKey/fileID``, so a lost archive file isn't
	/// taken for an empty Tab Archive.
	public static let archiveFileID: String = "archiveFileID"

	/// The ID shared with the local file's own `storeInfo`, so "this Mac only" profiles never fall
	/// back to their synced copies when that file is lost (DEV-981).
	public static let localFileID: String = "localFileID"

	/// The JSON snapshot version this store was migrated from; absent when it started empty.
	public static let migratedFromWorkspaceVersion: String = "migratedFromWorkspaceVersion"

	/// The migrated JSON snapshot's revision.
	public static let sourceRevision: String = "sourceRevision"

	/// Counts this store's writes, so a write that finds another writer's revision stops. Both
	/// files record it.
	public static let revision: String = "revision"

	/// A UUID made when the store first holds a workspace. Both files record it.
	public static let storeID: String = "storeID"

	/// `BrowserOrganization.legacyProfileID`.
	public static let legacyProfileID: String = "legacyProfileID"

	/// Only in the preferences file, holding the store ID, while a first save through separate
	/// connections has written the preferences file and not yet the organization file. One cut
	/// short there reads as an empty store, not as a lost organization file.
	public static let unfinishedFirstWrite: String = "unfinishedFirstWrite"

	/// This Mac's ID in ``DeletionRecord``, ``UsageRecord`` and ``SyncDeviceRecord`` (DEV-980).
	public static let deviceID: String = "deviceID"
}
