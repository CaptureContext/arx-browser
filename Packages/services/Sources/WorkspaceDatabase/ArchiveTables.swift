import BrowserCore
import Foundation
import _SQLiteData

// MARK: - Tab Archive (DEV-983)

/// One Tab Archive entry, in `arx-archive.sqlite`: its own file, so Tab Archive can sync on its own
/// (ADR 0001, decision 4), off by default. Real columns, so iCloud merges an entry field by field,
/// and no foreign key: the profile is in the organization file.
@Table("archiveEntry")
public struct ArchiveEntryRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	/// The tabs archived together, as one close of several makes them.
	@Column("groupID")
	public var groupID: UUID

	/// Seconds since the reference date.
	@Column("closedAt")
	public var closedAt: Double

	@Column("spaceID")
	public var spaceID: UUID

	@Column("spaceName")
	public var spaceName: String

	@Column("originalIndex")
	public var originalIndex: Int

	/// The archived tab's own ID, which a restore never reuses.
	@Column("tabID")
	public var tabID: UUID

	@Column("profileID")
	public var profileID: UUID

	/// The page's last title and address.
	@Column("title")
	public var title: String

	@Column("url")
	public var url: String

	@Column("customTitle")
	public var customTitle: String?

	@Column("automationClientID")
	public var automationClientID: UUID?

	/// A ``FractionalIndex`` key in the archive's order.
	@Column("position")
	public var position: String

	public init(
		id: UUID,
		groupID: UUID,
		closedAt: Double,
		spaceID: UUID,
		spaceName: String,
		originalIndex: Int,
		tabID: UUID,
		profileID: UUID,
		title: String,
		url: String,
		customTitle: String? = nil,
		automationClientID: UUID? = nil,
		position: String
	) {
		self.id = id
		self.groupID = groupID
		self.closedAt = closedAt
		self.spaceID = spaceID
		self.spaceName = spaceName
		self.originalIndex = originalIndex
		self.tabID = tabID
		self.profileID = profileID
		self.title = title
		self.url = url
		self.customTitle = customTitle
		self.automationClientID = automationClientID
		self.position = position
	}

	public init(
		_ entry: ArchivedTab,
		position: String
	) {
		self.init(
			id: entry.id.rawValue,
			groupID: entry.groupID,
			closedAt: entry.closedAt.timeIntervalSinceReferenceDate,
			spaceID: entry.originalSpaceID.rawValue,
			spaceName: entry.originalSpaceName,
			originalIndex: entry.originalIndex,
			tabID: entry.tab.id.rawValue,
			profileID: entry.tab.profileID.rawValue,
			title: entry.tab.restoration.title,
			url: entry.tab.restoration.url.absoluteString,
			customTitle: entry.tab.customTitle,
			automationClientID: entry.tab.automationClientID,
			position: position
		)
	}

	/// The entry, or `nil` when its address isn't one, as another Mac's damaged row could have. Only
	/// open tabs are archived, so an entry has no saved destination.
	public var entry: ArchivedTab? {
		guard let pageURL = URL(string: url) else { return nil }

		return .init(
			id: .init(rawValue: id),
			groupID: groupID,
			closedAt: Date(timeIntervalSinceReferenceDate: closedAt),
			originalSpaceID: .init(rawValue: spaceID),
			originalSpaceName: spaceName,
			originalIndex: originalIndex,
			tab: .init(
				id: .init(rawValue: tabID),
				profileID: .init(rawValue: profileID),
				restoration: .init(title: title, url: pageURL),
				customTitle: customTitle,
				automationClientID: automationClientID
			)
		)
	}
}

/// One Mac's removal of a Tab Archive entry, as ``DeletionRecord`` is for the organization (DEV-980).
/// Its own record type: SQLiteData routes a fetched record by type whatever its zone, so the two
/// categories' rows must never share one.
@Table("archiveDeletion")
public struct ArchiveDeletionRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("itemID")
	public var itemID: UUID

	/// The Mac that removed it (``StoreInfoKey/deviceID`` in the organization file).
	@Column("deviceID")
	public var deviceID: UUID

	/// Seconds since 1970.
	@Column("deletedAt")
	public var deletedAt: Double

	public init(
		id: UUID,
		itemID: UUID,
		deviceID: UUID,
		deletedAt: Double
	) {
		self.id = id
		self.itemID = itemID
		self.deviceID = deviceID
		self.deletedAt = deletedAt
	}
}

/// A Mac that syncs Tab Archive, as ``SyncDeviceRecord`` is for the organization.
@Table("archiveDevice")
public struct ArchiveDeviceRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	/// Seconds since 1970, updated at most once a day.
	@Column("lastSeen")
	public var lastSeen: Double

	public init(
		id: UUID,
		lastSeen: Double
	) {
		self.id = id
		self.lastSeen = lastSeen
	}
}

/// A save's change to Tab Archive, kept in the organization file by the same transaction as the rest
/// of the save and applied to the archive file after it (DEV-983): a restore moves a tab out of the
/// archive and into a space across two files, and a save cut short between them is finished on the
/// next open or save instead of losing the tab.
internal struct PendingArchiveChange: Codable, Equatable, Sendable {
	internal struct Entry: Codable, Equatable, Sendable {
		internal var entry: ArchivedTab
		internal var position: String
	}

	internal var upserted: [Entry]
	internal var removed: [UUID]

	/// This Mac's ID, which hides a removal once Tab Archive has synced.
	internal var deviceID: UUID? = nil
}

/// This Mac's own state for its Tab Archive file. Never syncs.
@Table("archiveState")
public struct ArchiveStateRecord: Equatable, Identifiable, Sendable {
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

public enum ArchiveStateKey {
	/// The ID shared with the organization file's ``StoreInfoKey/archiveFileID``.
	public static let fileID: String = "fileID"

	/// Set once Tab Archive sync has been on: from then, removing an entry hides it on this Mac and
	/// leaves it on the others, as other deletions (DEV-980), even while sync is off again, whose
	/// engine sends this Mac's changes when it's back on. Before, a removal deletes.
	public static let deletionsStayLocal: String = "deletionsStayLocal"
}
