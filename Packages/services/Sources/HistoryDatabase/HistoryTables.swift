import Foundation
import _SQLiteData

// The history database, `arx-history.sqlite`: the History sync category of ADR 0001.
//
// `historyVisit` and `historyClear` are the synced records (ADR 0001, section 3 and decision 5). The
// History `SyncEngine` gets exactly these two, so they follow the synced tables' rules: a UUID primary
// key, no foreign key, no other unique index, no CloudKit reserved column names, and every column
// nullable or `NOT NULL ON CONFLICT REPLACE` with a default. Columns are never renamed or dropped once
// shipped.
//
// Local history (`historyEntry`) is a separate table that never syncs: a sync deletes only mirror rows,
// so pruning the mirror or another Mac's deletion never removes a page from this Mac's history.
//
// Times are seconds since the reference date (`Date.timeIntervalSinceReferenceDate`), so a date reads
// back exactly as it was written.

// MARK: - Synced

/// A page visited in the sync window, mirrored from one Mac's history for the others. Its ID comes
/// from its profile and address (``HistoryDatabase/visitID(profileID:url:)``), so Macs that visit the
/// same page write one record, and the later visit wins.
@Table("historyVisit")
public struct HistoryVisitRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("profileID")
	public var profileID: UUID

	@Column("url")
	public var url: String

	@Column("lastVisited")
	public var lastVisited: Double

	/// The title with the visit it was written with (``titledVisit(title:lastVisited:)``). The
	/// library merges columns one by one and only stamps a column whose value changed, so a title of
	/// its own could be paired with another Mac's visit; this column changes with every visit.
	@Column("titledVisit")
	public var titledVisit: String

	public init(
		id: UUID,
		profileID: UUID,
		url: String,
		title: String,
		lastVisited: Double
	) {
		self.id = id
		self.profileID = profileID
		self.url = url
		self.lastVisited = lastVisited
		self.titledVisit = Self.titledVisit(title: title, lastVisited: lastVisited)
	}
}

extension HistoryVisitRecord {
	/// The visit's title, empty when the column holds another visit's title.
	public var title: String {
		guard
			let separator = titledVisit.firstIndex(of: " "),
			Double(titledVisit[..<separator]) == lastVisited
		else { return "" }

		return String(titledVisit[titledVisit.index(after: separator)...])
	}

	/// `<lastVisited> <title>`: a `Double` prints the shortest text that reads back exactly.
	public static func titledVisit(
		title: String,
		lastVisited: Double
	) -> String {
		"\(lastVisited) \(title)"
	}
}

/// History a person cleared on one Mac, which every Mac applies to its own history: a profile's
/// visits up to `before`, narrowed to those from `after` on, to one site or to one page.
@Table("historyClear")
public struct HistoryClearRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("profileID")
	public var profileID: UUID

	@Column("before")
	public var before: Double

	@Column("after")
	public var after: Double?

	/// A site as ``BrowserCore/BrowsingHistoryRemoval/siteKey(_:)`` compares it.
	@Column("host")
	public var host: String?

	@Column("url")
	public var url: String?

	public init(
		id: UUID,
		profileID: UUID,
		before: Double,
		after: Double? = nil,
		host: String? = nil,
		url: String? = nil
	) {
		self.id = id
		self.profileID = profileID
		self.before = before
		self.after = after
		self.host = host
		self.url = url
	}
}

// MARK: - Local

/// A page in one profile's history on this Mac. Never synced.
@Table("historyEntry")
public struct HistoryEntryRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("profileID")
	public var profileID: UUID

	@Column("url")
	public var url: String

	@Column("title")
	public var title: String

	@Column("lastVisited")
	public var lastVisited: Double

	/// The command bar's ranking data (DEV-1015), kept as ``BrowserCore/BrowsingHistoryEntry`` has it.
	@Column("visitCount")
	public var visitCount: Int

	@Column("typedCount")
	public var typedCount: Int

	@Column("lastSpaceID")
	public var lastSpaceID: UUID?

	public init(
		id: UUID,
		profileID: UUID,
		url: String,
		title: String,
		lastVisited: Double,
		visitCount: Int = 1,
		typedCount: Int = 0,
		lastSpaceID: UUID? = nil
	) {
		self.id = id
		self.profileID = profileID
		self.url = url
		self.title = title
		self.lastVisited = lastVisited
		self.visitCount = visitCount
		self.typedCount = typedCount
		self.lastSpaceID = lastSpaceID
	}
}

/// A profile whose history is in this database, and its write revision. A profile without a row
/// hasn't been moved from its JSON file yet.
@Table("historyProfile")
public struct HistoryProfileRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("revision")
	public var revision: Int

	/// Whether its entries came from the profile's JSON file (`History/<profile>.json`).
	@Column("migratedFromJSON")
	public var migratedFromJSON: Bool

	public init(
		id: UUID,
		revision: Int,
		migratedFromJSON: Bool
	) {
		self.id = id
		self.revision = revision
		self.migratedFromJSON = migratedFromJSON
	}
}

/// What Delete from History took on this Mac (DEV-810), so a visit from before it that arrives later,
/// from a record on its way or from another Mac's mirror, doesn't bring the page back. Same fields as
/// ``HistoryClearRecord``; never synced.
@Table("historyRemoval")
public struct HistoryRemovalRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("profileID")
	public var profileID: UUID

	@Column("before")
	public var before: Double

	@Column("after")
	public var after: Double?

	@Column("host")
	public var host: String?

	@Column("url")
	public var url: String?

	public init(
		id: UUID,
		profileID: UUID,
		before: Double,
		after: Double? = nil,
		host: String? = nil,
		url: String? = nil
	) {
		self.id = id
		self.profileID = profileID
		self.before = before
		self.after = after
		self.host = host
		self.url = url
	}
}

/// This Mac's history sync state, by ``HistorySyncStateKey``. Never synced.
@Table("historySyncState")
public struct HistorySyncStateRecord: Equatable, Identifiable, Sendable {
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

/// The ``HistorySyncStateRecord`` keys.
public enum HistorySyncStateKey {
	/// The sync window in days while History sync is on; absent while it's off.
	public static let mirrorWindowDays: String = "mirrorWindowDays"

	/// When the mirror was last pruned, in seconds since the reference date.
	public static let lastPruned: String = "lastPruned"

	/// When this Mac's data was replaced with an account's, in seconds since the reference date: the
	/// mirror takes only visits from then on, so history from before never reaches that account.
	public static let mirrorsFrom: String = "mirrorsFrom"

	/// The "this Mac only" profiles, as a JSON array of IDs (DEV-981): their history never syncs,
	/// either way.
	public static let localProfiles: String = "localProfiles"
}
