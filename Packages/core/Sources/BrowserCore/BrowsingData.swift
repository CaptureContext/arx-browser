import Foundation

/// What Clear Browsing Data removes from one ordinary profile (DEV-647). Saved
/// passwords aren't here: they have their own Settings page, as in Chrome, where
/// Clear Browsing Data no longer deletes them.
public enum BrowsingDataKind: String, CaseIterable, Codable, Hashable, Sendable {
	/// Arx's history of visited pages, and Chromium's own record of visits.
	case history

	/// The Downloads list. Downloaded files stay where they are.
	case downloads

	/// Cookies and every other kind of site storage. Signs the profile out of sites.
	case cookies

	/// Cached images and files.
	case cache

	/// Autofill form entries, addresses and payment cards.
	case autofill

	/// Site permissions, page zoom and other per-site settings.
	case siteSettings

	/// Checked when the sheet opens, as in Chrome.
	public static let defaults: Set<Self> = [.history, .cookies, .cache]
}

/// How far back Clear Browsing Data reaches.
public enum BrowsingDataRange: String, CaseIterable, Codable, Hashable, Sendable {
	case lastHour
	case lastDay
	case lastWeek
	case lastFourWeeks
	case allTime

	/// The earliest moment cleared, or nil for all time.
	public func start(before now: Date) -> Date? {
		switch self {
		case .lastHour: now.addingTimeInterval(-3_600)
		case .lastDay: now.addingTimeInterval(-86_400)
		case .lastWeek: now.addingTimeInterval(-7 * 86_400)
		case .lastFourWeeks: now.addingTimeInterval(-28 * 86_400)
		case .allTime: nil
		}
	}
}

/// What clearing would remove. Each value is nil until it's known, and stays nil
/// for a kind that couldn't be counted.
public struct BrowsingDataCounts: Equatable, Sendable {
	public struct Autofill: Equatable, Sendable {
		public var entries: Int
		public var addresses: Int
		public var cards: Int

		public init(
			entries: Int,
			addresses: Int = 0,
			cards: Int = 0
		) {
			self.entries = entries
			self.addresses = addresses
			self.cards = cards
		}
	}

	public var history: Int?
	public var downloads: Int?

	/// Sites with cookies or other stored data.
	public var cookieSites: Int?
	public var cacheBytes: Int64?

	/// The cache size is an upper bound: Chromium can't size a cache limited by time exactly.
	public var cacheIsUpperBound: Bool
	public var autofill: Autofill?
	public var siteSettingsSites: Int?

	public init(
		history: Int? = nil,
		downloads: Int? = nil,
		cookieSites: Int? = nil,
		cacheBytes: Int64? = nil,
		cacheIsUpperBound: Bool = false,
		autofill: Autofill? = nil,
		siteSettingsSites: Int? = nil
	) {
		self.history = history
		self.downloads = downloads
		self.cookieSites = cookieSites
		self.cacheBytes = cacheBytes
		self.cacheIsUpperBound = cacheIsUpperBound
		self.autofill = autofill
		self.siteSettingsSites = siteSettingsSites
	}

	/// Engine counts take over the kinds the engine counts; the app's own stay.
	public mutating func merge(engine counts: Self) {
		cookieSites = counts.cookieSites ?? cookieSites
		cacheBytes = counts.cacheBytes ?? cacheBytes
		cacheIsUpperBound = counts.cacheBytes == nil ? cacheIsUpperBound : counts.cacheIsUpperBound
		autofill = counts.autofill ?? autofill
		siteSettingsSites = counts.siteSettingsSites ?? siteSettingsSites
	}
}

public enum ProfileDataFailure: Error, Equatable, Sendable {
	/// The engine can't do this, or the profile is private, unknown or closing.
	case unavailable

	/// A folder that doesn't exist, or no kinds.
	case invalid

	/// A clear is already running for this profile.
	case busy

	/// Policy decides this, such as the downloads folder or keeping history.
	case managed
	case failed
}

/// Where an ordinary profile saves downloads (DEV-647). Chromium keeps it with the
/// profile, so each profile has its own. A private window follows the settings of the
/// profile it was opened from (DEV-729).
public struct DownloadSettings: Equatable, Sendable {
	public var directory: URL

	/// Asks where to save each file before downloading.
	public var asksWhereToSave: Bool

	/// The folder a new profile starts with: the user's Downloads folder.
	public var defaultDirectory: URL

	/// Policy decides the folder or the question; Settings shows it read-only.
	public var isManaged: Bool

	public init(
		directory: URL,
		asksWhereToSave: Bool = false,
		defaultDirectory: URL,
		isManaged: Bool = false
	) {
		self.directory = directory
		self.asksWhereToSave = asksWhereToSave
		self.defaultDirectory = defaultDirectory
		self.isManaged = isManaged
	}
}

extension BrowsingHistorySnapshot {
	/// Entries last visited at or after `since` (all of them when nil).
	public func count(since: Date?) -> Int {
		guard let since else { return entries.count }
		return entries.count(where: { $0.lastVisited >= since })
	}

	/// Drops entries last visited at or after `since` (all of them when nil).
	public mutating func remove(since: Date?) {
		guard let since else {
			entries.removeAll()
			return
		}
		entries.removeAll { $0.lastVisited >= since }
	}
}

extension DownloadQueue {
	/// A profile's finished transfers in the Downloads list that started at or
	/// after `since`: what clearing download history removes. Transfers still in
	/// progress stay.
	public func finishedCount(
		profileID: Profile.ID,
		since: Date?
	) -> Int {
		finished(profileID: profileID, since: since).count
	}

	/// The IDs of those transfers.
	public func finished(
		profileID: Profile.ID,
		since: Date?
	) -> Set<BrowserDownload.ID> {
		Set(downloads.lazy.filter { download in
			download.id.profileID == profileID
			&& download.status != .inProgress
			&& since.map { download.startedAt >= $0 } ?? true
		}.map(\.id))
	}
}
